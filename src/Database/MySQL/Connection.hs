{-# LANGUAGE ScopedTypeVariables #-}

{-|
Module      : Database.MySQL.Connection
Description : Internal MariaDB transport and connection lifecycle
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : PORTABLE

Applications should use the abstract 'MySQLConn' exported by
"Database.MySQL.Base". This exposed internal module also supports deterministic
transport fixtures; modifying its records bypasses the public safety contract.

-}

module Database.MySQL.Connection
    ( module Database.MySQL.Connection
    ) where

import           Control.Exception hiding (handle)
import           Control.Monad
import qualified Crypto.ECC.Edwards25519         as Edwards
import qualified Crypto.PubKey.Ed25519           as Ed25519
import qualified Crypto.KDF.PBKDF2               as PBKDF2
import           Crypto.Error                    (throwCryptoError)
import           Crypto.Random                   (getRandomBytes)
import qualified Crypto.Hash                     as Crypto
import           Crypto.Hash.Algorithms          (SHA1(..))
import qualified Crypto.Number.Serialize         as Serialize
import qualified Crypto.PubKey.RSA               as RSA
import qualified Crypto.PubKey.RSA.OAEP          as OAEP
import qualified Data.ASN1.BinaryEncoding        as ASN1B
import qualified Data.ASN1.BitArray              as ASN1BA
import qualified Data.ASN1.Encoding              as ASN1E
import qualified Data.ASN1.Types                 as ASN1
import qualified Data.Binary                     as Binary
import qualified Data.Binary.Put                 as Binary
import           Data.Bits
import qualified Data.ByteArray                  as BA
import           Data.ByteString                 (ByteString)
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Lazy            as L
import           Data.IORef                      (IORef, newIORef, readIORef, atomicModifyIORef',
                                                  writeIORef)
import qualified Data.PEM                        as PEM
import           Data.Typeable
import           Data.Word
import           Database.MySQL.Protocol.Auth
import           Database.MySQL.Protocol.Command
import           Database.MySQL.Protocol.Packet
import           Network.Socket                  (HostName, PortNumber)
import qualified Network.Socket                  as N
import           System.IO.Streams               (InputStream)
import qualified System.IO.Streams               as Stream
import qualified System.IO.Streams.TCP           as TCP
import qualified Data.Connection                 as Conn

--------------------------------------------------------------------------------

import Control.Concurrent (ThreadId, myThreadId)
import System.Timeout (timeout)
import qualified Data.Binary.Parser as P
import qualified Data.ByteString.Char8 as BC
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Data.Int (Int64)
import Data.Maybe (isJust)
import Database.MySQL.Protocol.ColumnDef
import Database.MySQL.Protocol.MySQLValue
import Database.MySQL.Query

-- | Per-connection resource bounds. Limits are validated before opening a
-- transport; none can be zero. Message limits include continuation fragments.
data ConnectionOptions = ConnectionOptions
    { maximumMessageBytes :: !Word64 -- ^ Maximum inbound/outbound logical message.
    , maximumMetadataBytes :: !Word64 -- ^ Per-metadata-block and OK tracking budget.
    , maximumColumns :: !Int -- ^ Maximum fields in a result or statement metadata block.
    , cleanupTimeoutMicros :: !Int -- ^ One deadline for draining and rollback.
    , connectTimeoutMicros :: !Int -- ^ Whole establishment deadline, including DNS/TLS/auth/setup.
    , maximumAuthIterations :: !Int -- ^ Maximum server-requested PARSEC PBKDF2 work.
    , enableSessionTracking :: !Bool -- ^ Negotiate tracking and OK terminators together.
    } deriving (Eq, Show)

-- | 64 MiB messages, 16 MiB metadata, 65,535 columns, one-second cleanup,
-- ten-second establishment, at most 2^20 PARSEC iterations and session tracking.
defaultConnectionOptions :: ConnectionOptions
defaultConnectionOptions = ConnectionOptions
    { maximumMessageBytes = 64 * 1024 * 1024
    , maximumMetadataBytes = 16 * 1024 * 1024
    , maximumColumns = 65535
    , cleanupTimeoutMicros = 1000000
    , connectTimeoutMicros = 10000000
    , maximumAuthIterations = 1048576
    , enableSessionTracking = True
    }

-- A cached fact must not pin a large result buffer or grow without bound.
-- Startup snapshots and subsequent tracker deltas share this byte limit.
maximumRenderingValueBytes :: Int
maximumRenderingValueBytes = 4096

validateOptions :: ConnectionOptions -> IO ()
validateOptions options = unless
    (maximumMessageBytes options > 0 && maximumMessageBytes options <= fromIntegral (maxBound :: Word32)
      && maximumMessageBytes options <= fromIntegral (maxBound :: Int)
      && maximumMetadataBytes options > 0 && maximumColumns options > 0 && cleanupTimeoutMicros options > 0
      && connectTimeoutMicros options > 0 && maximumAuthIterations options >= 1024
      && maximumAuthIterations options <= 1073741824)
    (throwIO (ProtocolError "invalid connection resource options"))

-- | Observable lifecycle. Only 'Ready' admits a new command. 'Broken' and
-- 'Closed' are terminal; an unfinished stream retains its creating thread.
data ConnectionStatus = Ready | Executing | Streaming | Replicating | Broken | Closed deriving (Eq, Show)
-- Completion must be distinct from "bytes were sent": a concurrent close after
-- a terminal COMMIT reply does not make a known server error uncertain.
data ExchangeProgress = BeforeSend | WireInFlight | ReplyComplete deriving (Eq,Show)
data Runtime = Runtime
    { runtimeStatus :: !ConnectionStatus
    , runtimeGeneration :: !Word64
    , runtimeOwner :: !(Maybe ThreadId)
    , transactionOwner :: !(Maybe ThreadId)
    } deriving Show
-- | Bounded diagnostics, deliberately excluding SQL, parameters and credentials.
data ConnectionFailure = ConnectionFailure
    { failurePhase :: !ConnectionStatus -- ^ Phase in which the connection was retired.
    , commitOutcomeUncertain :: !Bool -- ^ COMMIT may have reached MariaDB without a reply.
    , secondaryCleanupFailure :: !Bool -- ^ Cleanup also failed after a primary exception.
    } deriving (Eq, Show)
-- | Local ownership, resource, session-context and transaction failures.
-- 'CommitOutcomeUnknown' retains the original synchronous exception; inspect
-- connection diagnostics for uncertain commits interrupted by cancellation.
data ConnectionError = ConnectionUnavailable ConnectionStatus | ConcurrentConnectionUse | StaleResultStream
                     | NestedTransactionUnsupported | SessionContextUnavailable | ProtocolError String
                     | CommitOutcomeUnknown SomeException | CleanupDeadlineExceeded
    deriving (Typeable, Show)
instance Exception ConnectionError

-- | A MariaDB session with one command/stream owner at a time. Obtain it through
-- the connection constructors and close it with 'close'. The public Base module
-- keeps this representation abstract; direct internal record access bypasses
-- the ownership, resource and session-state contracts.
data MySQLConn = MySQLConn
    { mysqlRead :: !(InputStream Packet)
    , mysqlWrite :: !(Packet -> IO ())
    , mysqlCloseSocket :: !(IO ())
    , connectionOptions :: !ConnectionOptions
    , connectionRuntime :: !(IORef Runtime)
    , connectionFailureRef :: !(IORef (Maybe ConnectionFailure))
    , connectionServerStatus :: !(IORef (Maybe Word16))
    , connectionRenderContext :: !(IORef (Maybe RenderContext))
    , connectionCapabilities :: !(IORef Word64)
    , connectionSequence :: !(IORef FramingState)
    , connectionExchangeProgress :: !(IORef ExchangeProgress)
    , connectionReleased :: !(IORef Bool)
    , connectionDrain :: !(IORef (Maybe (IO ())))
    , connectionServerPacketLimit :: !(IORef Word64)
    , connectionQueryEffect :: !(IORef (Maybe Bool))
    , connectionOpaqueStatements :: !(IORef [Word32])
    }

-- | Read lifecycle diagnostics without claiming a command or performing I/O.
connectionStatus :: MySQLConn -> IO ConnectionStatus
connectionStatus = fmap runtimeStatus . readIORef . connectionRuntime
-- | Return retirement diagnostics, or 'Nothing' if no failure has been recorded.
connectionFailure :: MySQLConn -> IO (Maybe ConnectionFailure)
connectionFailure = readIORef . connectionFailureRef

-- Shared construction is also used by deterministic transport fixtures.
newConnection :: ConnectionOptions -> InputStream Packet -> (Packet -> IO ()) -> IO () -> IO MySQLConn
newConnection options input output abort = newConnectionUsing options makeReader output abort
  where
    makeReader framing = Stream.makeInputStream $ do
        packet <- Stream.read input
        case packet of
            Nothing -> pure Nothing
            Just value -> advanceFraming (maximumMessageBytes options) framing (pLen value) (pSeqN value) >> pure (Just value)

-- Live sockets validate framing in the byte decoder itself, without another
-- InputStream wrapper and another read/Maybe allocation for each physical row.
newByteConnection :: ConnectionOptions -> InputStream ByteString -> (Packet -> IO ()) -> IO () -> IO MySQLConn
newByteConnection options input output abort = newConnectionUsing options (\framing -> decodeFramedInput (maximumMessageBytes options) framing input) output abort

newConnectionUsing :: ConnectionOptions -> (IORef FramingState -> IO (InputStream Packet)) -> (Packet -> IO ()) -> IO () -> IO MySQLConn
newConnectionUsing options makeReader output abort = do
    validateOptions options
    state <- newIORef (Runtime Ready 0 Nothing Nothing)
    failure <- newIORef Nothing
    status <- newIORef Nothing
    context <- newIORef Nothing
    caps <- newIORef 0
    framing <- newIORef (FramingState 0 0)
    started <- newIORef BeforeSend
    released <- newIORef False
    drain <- newIORef Nothing
    serverLimit <- newIORef (maximumMessageBytes options)
    effect <- newIORef Nothing
    opaque <- newIORef []
    input <- makeReader framing
    let checkedOutput packet = advanceFraming (maximumMessageBytes options) framing (pLen packet) (pSeqN packet) >> output packet
    pure MySQLConn
        { mysqlRead = input
        , mysqlWrite = checkedOutput
        , mysqlCloseSocket = abort
        , connectionOptions = options
        , connectionRuntime = state
        , connectionFailureRef = failure
        , connectionServerStatus = status
        , connectionRenderContext = context
        , connectionCapabilities = caps
        , connectionSequence = framing
        , connectionExchangeProgress = started
        , connectionReleased = released
        , connectionDrain = drain
        , connectionServerPacketLimit = serverLimit
        , connectionQueryEffect = effect
        , connectionOpaqueStatements = opaque
        }

data FramingState = FramingState {-# UNPACK #-} !Word16 {-# UNPACK #-} !Word64
-- The 257 possible empty states are constants, shared by every connection.
-- Ordinary short packets need no new framing-state allocation per row.
emptyFramingStates :: V.Vector FramingState
emptyFramingStates=V.generate 257 (\n -> FramingState (fromIntegral n) 0)
{-# NOINLINE emptyFramingStates #-}
-- 256 is the dedicated replication sequence policy; continuations still use
-- the logical assembler's modulo-256 check. Ordinary exchanges never use it.
setExchangeSequence :: MySQLConn -> Word16 -> IO ()
setExchangeSequence conn sequenceN = writeIORef (connectionSequence conn) (FramingState sequenceN 0)

advanceFraming :: Word64 -> IORef FramingState -> Int64 -> Word8 -> IO ()
advanceFraming limit ref lengthBytes sequenceN = do
    FramingState expected accumulated <- readIORef ref
    unless (expected==256 || expected==fromIntegral sequenceN) (throwIO (ProtocolError "unexpected packet sequence"))
    when (lengthBytes<0 || lengthBytes>16777215) (throwIO (ProtocolError "invalid physical packet length"))
    let bytes=fromIntegral lengthBytes
    when (accumulated>limit || bytes>limit-accumulated) (throwIO (ProtocolError "logical packet exceeds client limit"))
    let next=if expected==256 then 256 else (expected+1) .&. 255
        continued=if lengthBytes==16777215 then accumulated+bytes else 0
    writeIORef' ref (if continued==0 then V.unsafeIndex emptyFramingStates (fromIntegral next) else FramingState next continued)
{-# INLINE advanceFraming #-}

-- Claim the finalizer once so close, cancellation and a failed stream cannot
-- double-close a transport. Transport finalizers must release resources even
-- if their graceful TLS/socket shutdown fails.
releaseTransport :: MySQLConn -> IO ()
releaseTransport conn = do
    already <- atomicModifyIORef' (connectionReleased conn) (\x -> (True,x))
    unless already (mysqlCloseSocket conn)

abortConnection :: MySQLConn -> Bool -> IO ()
abortConnection conn uncertain = mask_ $ do
    phase <- atomicModifyIORef' (connectionRuntime conn) $ \rt ->
        (rt { runtimeStatus=if runtimeStatus rt == Closed then Closed else Broken, runtimeOwner=Nothing },runtimeStatus rt)
    atomicModifyIORef' (connectionFailureRef conn) $ \prior ->
        let failure=case prior of
                Nothing -> ConnectionFailure phase uncertain False
                Just previous -> previous {commitOutcomeUncertain=commitOutcomeUncertain previous || uncertain}
        in (Just failure,())
    writeIORef (connectionRenderContext conn) Nothing
    writeIORef (connectionDrain conn) Nothing
    -- An ordinary close error must not replace the original protocol failure.
    -- A new cancellation still belongs to the caller and must propagate.
    releaseTransport conn `catch` (\(err :: SomeException) -> when (isCancellation err) (throwIO err))

-- The atomic claim rejects misuse instead of queueing commands. The surrounding
-- mask in withCommand closes the cancellation gap between claiming and setup.
claimCommand :: MySQLConn -> IO ()
claimCommand conn = do
    tid <- myThreadId
    result <- atomicModifyIORef' (connectionRuntime conn) $ \rt ->
        let unavailable err = (rt,Left err) in
        if maybe False (/=tid) (transactionOwner rt) then unavailable ConcurrentConnectionUse
        else case runtimeStatus rt of
            Ready -> (rt {runtimeStatus=Executing,runtimeGeneration=runtimeGeneration rt+1,runtimeOwner=Just tid},Right ())
            Streaming -> unavailable (ConnectionUnavailable Streaming)
            Executing -> unavailable ConcurrentConnectionUse
            other -> unavailable (ConnectionUnavailable other)
    case result of
        Left (ConnectionUnavailable Streaming) -> throwIO UnconsumedResultSet
        Left err -> throwIO err
        Right () -> do
            writeIORef (connectionExchangeProgress conn) BeforeSend
            writeIORef (connectionQueryEffect conn) Nothing

-- Finalize every exchange-local reference before publishing Ready. Masking
-- protects this thread from cancellation; it does not exclude another thread
-- from claiming Ready immediately after the atomic runtime update.
finishResponse :: MySQLConn -> IO ()
finishResponse conn = mask_ $ do
    writeIORef (connectionDrain conn) Nothing
    caps <- readIORef (connectionCapabilities conn)
    started <- readIORef (connectionExchangeProgress conn)
    writeIORef (connectionExchangeProgress conn) ReplyComplete
    effect <- readIORef (connectionQueryEffect conn)
    when (started/=BeforeSend && (caps .&. 0x800000 == 0 || effect==Just True)) (writeIORef (connectionRenderContext conn) Nothing)
    atomicModifyIORef' (connectionRuntime conn) $ \rt ->
        (if runtimeStatus rt `elem` [Executing,Streaming] then rt {runtimeStatus=Ready,runtimeOwner=Nothing} else rt,())

-- A pre-send validation failure releases the claim. Once writing may have
-- started, any incomplete reply retires the connection rather than guessing
-- whether the next packet belongs to this command or the next one.
withCommand :: MySQLConn -> IO a -> IO a
withCommand conn action = mask $ \restore -> do
    claimCommand conn
    generation <- runtimeGeneration <$> readIORef (connectionRuntime conn)
    result <- restore action `catch` \(err :: SomeException) -> do
        runtime <- readIORef (connectionRuntime conn)
        started <- readIORef (connectionExchangeProgress conn)
        -- The action may have completed its reply before throwing. A successor
        -- can already own Ready, so finalizers may touch only their generation.
        when (runtimeGeneration runtime == generation && runtimeStatus runtime `elem` [Executing,Streaming,Replicating]) $
            if started==WireInFlight then abortConnection conn False else finishResponse conn
        throwIO err
    runtime <- readIORef (connectionRuntime conn)
    when (runtimeGeneration runtime == generation && runtimeStatus runtime == Executing) (finishResponse conn)
    pure result

-- A completed stream must never read from a later exchange. Check generation
-- before ownership so stale handles fail without consuming a single packet.
streamGuard :: MySQLConn -> Word64 -> IO a -> IO a
streamGuard conn generation action = do
    rt <- readIORef (connectionRuntime conn)
    tid <- myThreadId
    unless (runtimeGeneration rt == generation) (throwIO StaleResultStream)
    unless (runtimeStatus rt `elem` [Streaming,Replicating]) (throwIO (ConnectionUnavailable (runtimeStatus rt)))
    unless (runtimeOwner rt == Just tid) (throwIO ConcurrentConnectionUse)
    action `catch` \(err :: SomeException) -> do
        current <- readIORef (connectionRuntime conn)
        when (runtimeGeneration current == generation && runtimeStatus current `elem` [Streaming,Replicating])
            (abortConnection conn False)
        throwIO err

markStreaming :: MySQLConn -> IO Word64
markStreaming conn = markResponseStream conn Streaming

-- A concurrent close is terminal, including the gap between metadata receipt
-- and stream construction. Never overwrite Closed/Broken with a stream phase.
markResponseStream :: MySQLConn -> ConnectionStatus -> IO Word64
markResponseStream conn phase = do
    result <- atomicModifyIORef' (connectionRuntime conn) $ \rt ->
        if runtimeStatus rt == Executing
        then (rt {runtimeStatus=phase}, Right (runtimeGeneration rt))
        else (rt, Left (ConnectionUnavailable (runtimeStatus rt)))
    either throwIO pure result

beginTransactionLease :: MySQLConn -> IO ()
beginTransactionLease conn = do
    tid <- myThreadId
    result <- atomicModifyIORef' (connectionRuntime conn) $ \rt ->
        if isJust (transactionOwner rt) then (rt,False) else (rt {transactionOwner=Just tid},True)
    unless result (throwIO NestedTransactionUnsupported)

endTransactionLease :: MySQLConn -> IO ()
endTransactionLease conn = atomicModifyIORef' (connectionRuntime conn) (\rt -> (rt {transactionOwner=Nothing},()))

-- | Endpoint, credentials and initial one-byte protocol collation ID. Do not
-- log this value: its inherited Show instance includes the password.
data ConnectInfo = ConnectInfo
    { ciHost :: HostName
    , ciPort :: PortNumber
    , ciDatabase :: ByteString
    , ciUser :: ByteString
    , ciPassword :: ByteString
    , ciCharset :: Word8
    } deriving Show

-- | Local TCP defaults using full Unicode (utf8mb4). MB4 is a compatibility alias.
defaultConnectInfo, defaultConnectInfoMB4 :: ConnectInfo
defaultConnectInfo = ConnectInfo "127.0.0.1" 3306 "" "root" "" utf8mb4_unicode_ci
defaultConnectInfoMB4 = defaultConnectInfo
utf8_general_ci, utf8mb4_unicode_ci :: Word8
utf8_general_ci=33
utf8mb4_unicode_ci=224

bUFSIZE :: Int
bUFSIZE=16384

-- | Open TCP with 'defaultConnectionOptions' and establish a rendering snapshot.
connect :: ConnectInfo -> IO MySQLConn
connect = connectWithOptions defaultConnectionOptions
-- | Open TCP with explicit bounds. Constructor failure closes the transport.
connectWithOptions :: ConnectionOptions -> ConnectInfo -> IO MySQLConn
connectWithOptions opts ci = snd <$> connectDetailWithOptions opts ci
-- | Open TCP and also return the server greeting.
connectDetail :: ConnectInfo -> IO (Greeting,MySQLConn)
connectDetail = connectDetailWithOptions defaultConnectionOptions
-- | Explicit-options variant of 'connectDetail'.
connectDetailWithOptions :: ConnectionOptions -> ConnectInfo -> IO (Greeting,MySQLConn)
connectDetailWithOptions opts ci = withConnectDeadline opts $ do
    validateOptions opts
    bracketOnError (TCP.connectSocketTimeout (connectTimeoutMicros opts) (ciHost ci) (ciPort ci) >>= TCP.socketToConnectionAdaptive bUFSIZE) Conn.close $ \raw -> do
        conn <- newByteConnection opts (Conn.source raw) (\packet -> Conn.send raw (Binary.runPut (Binary.put packet))) (Conn.close raw)
        greet <- readGreeting conn
        let caps=negotiatedCapabilities opts greet
        writeIORef (connectionCapabilities conn) caps
        mysqlWrite conn (encodeToPacket 1 (mkAuthWithOptions opts caps ci greet))
        q <- readConnPacket conn
        completeAuth conn greet False (ciPassword ci) q
        initializeSession conn
        pure (greet,conn)

-- | Open a Unix-domain socket with the same session and ownership contracts as TCP.
connectUnixSocket :: FilePath -> ConnectInfo -> IO MySQLConn
connectUnixSocket = connectUnixSocketWithOptions defaultConnectionOptions
-- | Open a Unix-domain socket with explicit resource bounds.
connectUnixSocketWithOptions :: ConnectionOptions -> FilePath -> ConnectInfo -> IO MySQLConn
connectUnixSocketWithOptions opts path ci = snd <$> connectUnixSocketDetailWithOptions opts path ci
-- | Open a Unix-domain socket and also return the server greeting.
connectUnixSocketDetail :: FilePath -> ConnectInfo -> IO (Greeting,MySQLConn)
connectUnixSocketDetail = connectUnixSocketDetailWithOptions defaultConnectionOptions
-- | Explicit-options variant of 'connectUnixSocketDetail'.
connectUnixSocketDetailWithOptions :: ConnectionOptions -> FilePath -> ConnectInfo -> IO (Greeting,MySQLConn)
connectUnixSocketDetailWithOptions opts path ci = withConnectDeadline opts $ do
    validateOptions opts
    let open=bracketOnError (N.socket N.AF_UNIX N.Stream 0) N.close $ \sock -> do
            N.connect sock (N.SockAddrUnix path)
            TCP.socketToConnectionAdaptive bUFSIZE (sock,N.SockAddrUnix path)
    bracketOnError open Conn.close $ \raw -> do
        conn <- newByteConnection opts (Conn.source raw) (\packet -> Conn.send raw (Binary.runPut (Binary.put packet))) (Conn.close raw)
        greet <- readGreeting conn
        let caps=negotiatedCapabilities opts greet
        writeIORef (connectionCapabilities conn) caps
        mysqlWrite conn (encodeToPacket 1 (mkAuthWithOptions opts caps ci greet))
        q <- readConnPacket conn
        completeAuth conn greet True (ciPassword ci) q
        initializeSession conn
        pure (greet,conn)

-- Greeting parsing consumes the whole envelope; an initial ERR is a server
-- failure, rather than an attempted protocol-10 decode of error text.
readGreeting :: MySQLConn -> IO Greeting
readGreeting conn = do
    packet <- readConnPacket conn
    when (isERR packet) (decodeFromPacket packet >>= throwIO . ERRException)
    getFromPacketExact getGreeting packet

negotiatedCapabilities :: ConnectionOptions -> Greeting -> Word64
-- Advertise tracking and EOF deprecation only as a pair: both OK-envelope and
-- result-terminator parsing must be available before either is used on the wire.
negotiatedCapabilities options greeting = (clientCap .&. greetingCaps greeting) .|.
    (if enableSessionTracking options && greetingCaps greeting .&. 0x01800000 == 0x01800000 then 0x01800000 else 0)

mkAuthWithOptions :: ConnectionOptions -> Word64 -> ConnectInfo -> Greeting -> Auth
mkAuthWithOptions options caps ci greeting =
    let Auth _ _ charset user response database plugin = mkAuth (ciDatabase ci) (ciUser ci) (ciPassword ci) (ciCharset ci) greeting
    in Auth caps (fromIntegral (maximumMessageBytes options)) charset user response database plugin

mkAuth :: ByteString -> ByteString -> ByteString -> Word8 -> Greeting -> Auth
mkAuth db user pass charset greet =
    let salt = greetingSalt1 greet `B.append` greetingSalt2 greet
        plugin = greetingAuthPlugin greet
        scambleBuf = scrambleForPlugin plugin salt pass
    in Auth clientCap clientMaxPacketSize charset user scambleBuf db plugin

-- | Dispatch scramble based on the authentication plugin name.
scrambleForPlugin :: ByteString -> ByteString -> ByteString -> ByteString
scrambleForPlugin plugin salt pass
    | plugin == "caching_sha2_password" = checkedNonce 20 (scrambleSHA256 salt pass)
    | plugin == "mysql_native_password" = checkedNonce 20 (scrambleSHA1 salt pass)
    | plugin == "client_ed25519" = checkedNonce 32 (scrambleEd25519 salt pass)
    | plugin == "parsec" = checkedNonce 32 B.empty
    | otherwise = throw (AuthException ("unsupported MariaDB authentication plugin: " ++ show plugin))
  where
    checkedNonce count result
        | B.length salt == count = result
        | otherwise = throw (AuthException "invalid authentication challenge length")

-- | SHA1-based scramble for @mysql_native_password@.
scrambleSHA1 :: ByteString -> ByteString -> ByteString
scrambleSHA1 salt pass
    | B.null pass = B.empty
    | otherwise   = B.pack (B.zipWith xor sha1pass withSalt)
    where sha1pass = sha1 pass
          withSalt = sha1 (salt `B.append` sha1 sha1pass)
          sha1 :: ByteString -> ByteString
          sha1 = BA.convert . (Crypto.hash :: ByteString -> Crypto.Digest Crypto.SHA1)

-- | SHA256-based scramble for @caching_sha2_password@.
-- XOR(SHA256(password), SHA256(SHA256(SHA256(password)) + nonce))
scrambleSHA256 :: ByteString -> ByteString -> ByteString
scrambleSHA256 salt pass
    | B.null pass = B.empty
    | otherwise   = B.pack (B.zipWith xor sha256pass withSalt)
    where sha256pass = sha256 pass
          withSalt   = sha256 (sha256 sha256pass `B.append` salt)
          sha256 :: ByteString -> ByteString
          sha256 = BA.convert . (Crypto.hash :: ByteString -> Crypto.Digest Crypto.SHA256)

-- | MariaDB's password-based ed25519 variant. The password itself is hashed
-- once to an expanded scalar/prefix, unlike standard Ed25519's 32-byte seed.
-- Arithmetic uses crypton's constant-time Edwards primitives; no server point
-- or client-implemented curve arithmetic is involved.
scrambleEd25519 :: ByteString -> ByteString -> ByteString
scrambleEd25519 nonce password = encodedR <> Edwards.scalarEncode signed
  where
    digest = BA.convert (Crypto.hash password :: Crypto.Digest Crypto.SHA512) :: ByteString
    scalarBytes = B.pack ([B.head digest .&. 248] ++ B.unpack (B.take 30 (B.drop 1 digest))
                         ++ [(B.index digest 31 .&. 63) .|. 64])
    scalar = throwCryptoError (Edwards.scalarDecodeLong scalarBytes)
    hashScalar bytes = throwCryptoError (Edwards.scalarDecodeLong
        (BA.convert (Crypto.hash bytes :: Crypto.Digest Crypto.SHA512) :: BA.ScrubbedBytes))
    public = Edwards.pointEncode (Edwards.toPoint scalar) :: ByteString
    nonceScalar = hashScalar (B.drop 32 digest <> nonce)
    encodedR = Edwards.pointEncode (Edwards.toPoint nonceScalar)
    challenge = hashScalar (encodedR <> public <> nonce)
    signed = Edwards.scalarAdd nonceScalar (Edwards.scalarMul challenge scalar)

-- | Bound the entire connection establishment, including resolver, TLS,
-- authentication and initial session queries. The enclosing brackets release
-- any acquired transports before this timeout becomes a public exception.
withConnectDeadline :: ConnectionOptions -> IO a -> IO a
withConnectDeadline options action = do
    validateOptions options
    timeout (connectTimeoutMicros options) action >>= maybe
        (throwIO (AuthException "MariaDB connection establishment timed out")) pure

-- | Complete a bounded plugin conversation on this connection. Plugin and nonce
-- always travel together, including auth switches. Cleartext full-auth responses
-- are allowed only over TLS or a Unix-domain socket. Malformed messages and
-- unsupported plugins fail closed; the constructor owns transport cleanup.
completeAuth :: MySQLConn -> Greeting -> Bool -> ByteString -> Packet -> IO ()
completeAuth conn greeting secure password = loop 0 (greetingAuthPlugin greeting) initialNonce
  where
    initialNonce = greetingSalt1 greeting <> greetingSalt2 greeting
    input = mysqlRead conn
    output = mysqlWrite conn
    send packet body = output (Packet (fromIntegral (B.length body)) (pSeqN packet + 1) (L.fromStrict body))
    next = readPacket input
    loop :: Int -> ByteString -> ByteString -> Packet -> IO ()
    loop rounds plugin nonce packet
        | rounds >= 16 = throwIO (AuthException "too many authentication exchanges")
        | isOK packet = void (consumeOK conn packet)
        | isERR packet = decodeFromPacket packet >>= throwIO . ERRException
        | isAuthSwitch packet = do
            let (name, rest) = B.break (==0) (B.drop 1 (L.toStrict (pBody packet)))
            when (B.null name || B.length name > 128 || B.null rest)
                (throwIO (AuthException "malformed authentication switch"))
            let challenge = B.drop 1 rest
                expected = if name `elem` ["client_ed25519", "parsec"] then 32 else 20
                exact = if B.length challenge == expected+1 && B.last challenge == 0
                        then B.init challenge else challenge
            response <- evaluate (scrambleForPlugin name exact password)
            send packet response
            next >>= loop (rounds+1) name exact
        | isAuthMoreData packet && plugin == "parsec" = do
            let parameters = B.drop 1 (L.toStrict (pBody packet))
            unless (B.length parameters == 20 && B.head parameters == 80)
                (throwIO (AuthException "invalid PARSEC salt parameters"))
            let factor = fromIntegral (B.index parameters 1) :: Int
            when (factor > 20 || (1024 :: Integer) `shiftL` factor > fromIntegral (maximumAuthIterations (connectionOptions conn)))
                (throwIO (AuthException "PARSEC work exceeds configured iteration limit"))
            let keyBytes = PBKDF2.fastPBKDF2_SHA512 (PBKDF2.Parameters (1024 `shiftL` factor) 32)
                              password (B.drop 2 parameters) :: BA.ScrubbedBytes
                key = throwCryptoError (Ed25519.secretKey keyBytes)
            clientNonce <- getRandomBytes 32
            let signature = BA.convert (Ed25519.sign key (Ed25519.toPublic key) (nonce <> clientNonce))
            send packet (clientNonce <> signature)
            next >>= loop (rounds+1) "parsec-finished" nonce
        | isAuthMoreData packet && plugin == "caching_sha2_password" = do
            let dataBytes = B.drop 1 (L.toStrict (pBody packet))
            case B.unpack dataBytes of
                [3] -> next >>= terminal
                [4] -> do
                    if secure then send packet (password <> "\0")
                    else do
                        send packet (B.singleton 2)
                        keyPacket <- next
                        when (isERR keyPacket) (decodeFromPacket keyPacket >>= throwIO . ERRException)
                        let body = L.toStrict (pBody keyPacket)
                        unless (isAuthMoreData keyPacket && B.length body > 1 && B.length body <= 16384)
                            (throwIO (AuthException "invalid RSA authentication key envelope"))
                        doRSAAuth output (pSeqN keyPacket+1) password nonce (B.drop 1 body)
                    next >>= terminal
                _ -> throwIO (AuthException "invalid SHA-2 authentication continuation")
        | otherwise = throwIO (UnexpectedPacket packet)
    terminal packet
        | isOK packet = void (consumeOK conn packet)
        | isERR packet = decodeFromPacket packet >>= throwIO . ERRException
        | otherwise = throwIO (UnexpectedPacket packet)

-- | Full auth handler for plain TCP connections using RSA encryption.
--
-- The nonce is captured via partial application at the call site:
-- @completeAuth is writePacket pass q (plainFullAuth salt)@
plainFullAuth :: ByteString -> Word8 -> ByteString -> (Packet -> IO ()) -> InputStream Packet -> IO ()
plainFullAuth nonce seqN pass writePacket is = do
    -- Request server's RSA public key
    writePacket (putToPacket seqN (Binary.putWord8 0x02))
    keyPkt <- readPacket is
    -- Key packet body: 0x01 <PEM bytes>
    let pemKey = L.toStrict (L.drop 1 (pBody keyPkt))
    doRSAAuth writePacket (pSeqN keyPkt + 1) pass nonce pemKey
    q <- readPacket is
    if isOK q then pure ()
              else decodeFromPacket q >>= throwIO . ERRException

-- | Parse a PEM-encoded SubjectPublicKeyInfo RSA public key (PKCS#8 / RFC 5480).
parseRSAPublicKey :: ByteString -> Either String RSA.PublicKey
parseRSAPublicKey pemBytes =
    either (Left . show) Right (PEM.pemParseBS pemBytes)
    >>= firstPEM
    >>= decodeDER
    >>= spkiBitString
    >>= decodeDER
    >>= rsaKey
  where
    firstPEM []    = Left "empty PEM"
    firstPEM (x:_) = Right (PEM.pemContent x)

    decodeDER bs = either (Left . show) Right (ASN1E.decodeASN1' ASN1B.DER bs)

    spkiBitString (ASN1.Start ASN1.Sequence
                   : ASN1.Start ASN1.Sequence
                   : ASN1.OID [1,2,840,113549,1,1,1]
                   : ASN1.Null
                   : ASN1.End ASN1.Sequence
                   : ASN1.BitString bs
                   : ASN1.End ASN1.Sequence
                   : [])
        = Right (ASN1BA.bitArrayGetData bs)
    spkiBitString xs = Left ("unexpected SPKI ASN1: " ++ show xs)

    rsaKey (ASN1.Start ASN1.Sequence
            : ASN1.IntVal n
            : ASN1.IntVal e
            : ASN1.End ASN1.Sequence
            : [])
        -- Check signed ASN.1 integers before positive-integer serialization.
        -- The SPKI algorithm above must be rsaEncryption, the OAEP key type.
        | n <= 0 || e < 3 || even e || e > 4294967295 = Left "invalid RSA public integers"
        | otherwise = Right RSA.PublicKey
            { RSA.public_size = B.length (Serialize.i2osp n :: ByteString)
            , RSA.public_n    = n
            , RSA.public_e    = e
            }
    rsaKey xs = Left ("unexpected RSA key ASN1: " ++ show xs)

-- | XOR @(password ++ NUL)@ with a cyclically-extended nonce.
xorPasswordNonce :: ByteString -> ByteString -> ByteString
xorPasswordNonce pass nonce
    | B.length nonce /= 20 = throw (AuthException "invalid RSA authentication nonce length")
    | otherwise =
        let msg = pass `B.snoc` 0x00
            nonceLen = B.length nonce
            cycled = B.pack [nonce `B.index` (i `mod` nonceLen) | i <- [0 .. B.length msg - 1]]
        in B.pack (B.zipWith xor msg cycled)

-- | Encrypt password with the server's RSA public key and send it.
doRSAAuth :: (Packet -> IO ()) -> Word8 -> ByteString -> ByteString -> ByteString -> IO ()
doRSAAuth writePacket seqN pass nonce pemKey = do
    pubKey <- either (\e -> throwIO (AuthException ("RSA key parse: " ++ e))) pure
                     (parseRSAPublicKey pemKey)
    unless (RSA.public_size pubKey >= 256 && RSA.public_size pubKey <= 1024)
        (throwIO (AuthException "RSA authentication key is outside supported bounds"))
    result <- OAEP.encrypt (OAEP.defaultOAEPParams SHA1) pubKey
                           (xorPasswordNonce pass nonce)
    ct <- either (\e -> throwIO (AuthException ("RSA encrypt: " ++ show e))) pure result
    writePacket (putToPacket seqN (Binary.putByteString ct))

-- | Authentication/plugin validation or establishment-deadline failure.
-- Server ERR replies retain ERRException; cancellation keeps its original
-- exception identity. Constructors release their transport before propagating.
data AuthException = AuthException String deriving (Typeable, Show)
instance Exception AuthException


-- Physical framing reads exactly one packet. Limits are checked before its body.
decodeInputStream :: InputStream ByteString -> IO (InputStream Packet)
decodeInputStream = decodeInputStreamWithLimit (maximumMessageBytes defaultConnectionOptions)

decodeInputStreamWithLimit :: Word64 -> InputStream ByteString -> IO (InputStream Packet)
decodeInputStreamWithLimit limit input = do
    framing <- newIORef (FramingState 256 0)
    decodeFramedInput limit framing input

decodeFramedInput :: Word64 -> IORef FramingState -> InputStream ByteString -> IO (InputStream Packet)
decodeFramedInput limit framing input = Stream.makeInputStream $ do
    header <- Stream.readExactly 4 input
    let len=fromIntegral (B.index header 0) .|. (fromIntegral (B.index header 1) `shiftL` 8) .|. (fromIntegral (B.index header 2) `shiftL` 16)
    advanceFraming limit framing len (B.index header 3)
    body <- loop [] len
    pure (Just (Packet len (B.index header 3) body))
  where
    loop acc 0 = pure (L.fromChunks (reverse acc))
    loop acc remaining = do
        chunk <- Stream.read input >>= maybe (throwIO NetworkException) pure
        if B.null chunk then loop acc remaining else do
            let count=fromIntegral (B.length chunk)
            if count >= remaining then do
                let (part,rest)=B.splitAt (fromIntegral remaining) chunk
                unless (B.null rest) (Stream.unRead rest input)
                pure (L.fromChunks (reverse (part:acc)))
            else loop (chunk:acc) (remaining-count)

readPacket :: InputStream Packet -> IO Packet
readPacket = readPacketWithLimit (maximumMessageBytes defaultConnectionOptions)

readPacketWithLimit :: Word64 -> InputStream Packet -> IO Packet
readPacketWithLimit limit input = do
    first <- Stream.read input >>= maybe (throwIO NetworkException) pure
    validateLength (pLen first)
    if pLen first < 16777215 then pure first else go (pLen first) (pSeqN first) [pBody first]
  where
    validateLength len = when (len < 0 || fromIntegral len > limit) (throwIO (ProtocolError "logical packet exceeds message limit"))
    go total sequenceN chunks = do
        packet <- Stream.read input >>= maybe (throwIO NetworkException) pure
        unless (pSeqN packet == sequenceN+1) (throwIO (ProtocolError "invalid continuation sequence"))
        when (pLen packet < 0 || pLen packet > 16777215) (throwIO (ProtocolError "invalid fragment length"))
        let size=total+pLen packet
        validateLength size
        if pLen packet < 16777215 then pure (Packet size (pSeqN packet) (L.concat (reverse (pBody packet:chunks))))
        else go size (pSeqN packet) (pBody packet:chunks)

readConnPacket :: MySQLConn -> IO Packet
readConnPacket conn = readPacketWithLimit (maximumMessageBytes (connectionOptions conn)) (mysqlRead conn)

writeCommand :: Command -> (Packet -> IO ()) -> IO ()
writeCommand cmd writer = let body=Binary.runPut (putCommand cmd) in writeEncoded (L.length body) body writer

writeEncoded :: Int64 -> L.ByteString -> (Packet -> IO ()) -> IO ()
writeEncoded count body writer = send count 0 body
  where
    send len sequenceN payload
        | len < 16777215 = writer (Packet len sequenceN payload)
        | otherwise = do
            let (part,rest)=L.splitAt 16777215 payload
            writer (Packet 16777215 sequenceN part)
            send (len-16777215) (sequenceN+1) rest
-- Validate/encode the complete outgoing command before marking WireInFlight.
-- Traversing bounded lazy chunks keeps oversized builders from being flattened
-- into a second contiguous allocation merely to discover their size.
sendCommand :: MySQLConn -> Command -> IO ()
sendCommand conn cmd = do
    policy <- readIORef (connectionQueryEffect conn)
    when (policy==Nothing) $ case cmd of
        COM_QUERY bytes -> classifyQueryEffect conn (Query bytes)
        COM_STMT_PREPARE bytes -> classifyQueryEffect conn (Query bytes)
        COM_STMT_EXECUTE ident _ _ -> do
            opaque <- readIORef (connectionOpaqueStatements conn)
            writeIORef (connectionQueryEffect conn) (Just (ident `elem` opaque))
        _ -> pure ()
    encoder <- case cmd of
        COM_STMT_EXECUTE ident values nullMap -> do
            let needsEncoding (MySQLText _)=True; needsEncoding _=False
            charset <- if any needsEncoding values then renderClientCharset <$> getRenderContext conn else pure "utf8mb4"
            mapM_ (either (throwIO . UnencodableParameter) pure . validateValue) values
            encoded <- forM values $ \value -> case value of
                MySQLText text -> either (throwIO . UnencodableParameter) (pure . putLenEncBytes) (encodeCharsetText charset text)
                _ -> pure (putBinaryField value)
            pure $ do
                Binary.putWord8 0x17
                Binary.putWord32le ident
                Binary.putWord8 0
                Binary.putWord32le 1
                unless (null values) $ do
                    Binary.putByteString (fromBitMap nullMap)
                    Binary.putWord8 1
                    mapM_ putParamMySQLType values
                    sequence_ encoded
        _ -> pure (putCommand cmd)
    let body=Binary.runPut encoder
    serverLimit <- readIORef (connectionServerPacketLimit conn)
    size <- encodedLength (min serverLimit (maximumMessageBytes (connectionOptions conn))) body
    setExchangeSequence conn 0
    writeIORef (connectionExchangeProgress conn) WireInFlight
    writeEncoded size body (mysqlWrite conn)

-- | Idempotently close the transport. Ready connections attempt bounded COM_QUIT;
-- active ones are interrupted immediately without trying to drain their reply.
close :: MySQLConn -> IO ()
close conn = mask_ $ do
    prior <- atomicModifyIORef' (connectionRuntime conn) (\rt -> (rt {runtimeStatus=Closed,runtimeOwner=Nothing},runtimeStatus rt))
    unless (prior == Closed) $ do
        when (prior `elem` [Executing,Streaming,Replicating]) $
            atomicModifyIORef' (connectionFailureRef conn) (\failure ->
                (case failure of Nothing -> Just (ConnectionFailure prior False False); Just _ -> failure,()))
        writeIORef (connectionDrain conn) Nothing
        let goodbye=when (prior==Ready) $ void $ timeout (cleanupTimeoutMicros (connectionOptions conn)) $ do
                setExchangeSequence conn 0
                writeCommand COM_QUIT (mysqlWrite conn)
        (goodbye `catch` (\(err :: SomeException) -> when (isCancellation err) (throwIO err))) `finally` releaseTransport conn

-- The cheap path recognizes flat ASCII SQL with only known stable calls.
-- Everything else uses the same lexer as parameter templates; a prefix alone
-- never establishes that an arbitrary statement cannot alter session state.
classifyQueryEffect :: MySQLConn -> Query -> IO ()
classifyQueryEffect conn qry@(Query input) = do
    context <- readIORef (connectionRenderContext conn)
    let uncertain=if simpleStableQuery input then False else
            case context >>= either (const Nothing) Just . (`compileQuery` qry) of
                Just plan -> planOpaque plan || planMultiple plan
                Nothing -> True
    writeIORef (connectionQueryEffect conn) (Just uncertain)

-- | Check server responsiveness through the ordinary command ownership guard.
ping :: MySQLConn -> IO OK
ping conn = command conn COM_PING
-- | Low-level command expecting one OK/ERR reply. Commands producing rows or no
-- reply require their dedicated APIs instead (for example 'closeStmt' in Base).
command :: MySQLConn -> Command -> IO OK
command conn cmd = withCommand conn $ sendCommand conn cmd >> readConnPacket conn >>= consumeCommandOK conn

consumeCommandOK :: MySQLConn -> Packet -> IO OK
consumeCommandOK conn packet
    | isERR packet = serverError conn packet
    | isOK packet = consumeOK conn packet
    | otherwise = throwIO (UnexpectedPacket packet)

serverError :: MySQLConn -> Packet -> IO a
serverError conn packet = do
    err <- decodeFromPacket packet
    writeIORef (connectionServerStatus conn) Nothing
    writeIORef (connectionRenderContext conn) Nothing
    finishResponse conn
    throwIO (ERRException err)

updateStatus :: MySQLConn -> Word16 -> IO ()
updateStatus conn flags = do
    previous <- readIORef (connectionServerStatus conn)
    unless (previous==Just flags) $ do
        writeIORef (connectionServerStatus conn) (Just flags)
        when (maybe True (\old -> (old .&. 0x8200) /= (flags .&. 0x8200)) previous) $
            atomicModifyIORef' (connectionRenderContext conn) $ \ctx ->
                let change c = c {renderSQLModes=toggle "NO_BACKSLASH_ESCAPES" 0x200 (toggle "ANSI_QUOTES" 0x8000 (renderSQLModes c))}
                    toggle name flag modes = if flags .&. flag /= 0 then name:filter (/=name) modes else filter (/=name) modes
                in (fmap change ctx,())

consumeOK :: MySQLConn -> Packet -> IO OK
consumeOK conn packet = case P.parseDetailLazy getOK (pBody packet) of
    Left (buffer,offset,message) -> throwIO (DecodePacketFailed buffer offset message)
    Right (_,offset,ok) -> do
        updateStatus conn (okStatus ok)
        caps <- readIORef (connectionCapabilities conn)
        when (caps .&. 0x800000 /= 0) $ do
            when (pLen packet<offset || fromIntegral (pLen packet-offset)>maximumMetadataBytes (connectionOptions conn))
                (throwIO (ProtocolError "OK/session envelope exceeds metadata budget"))
            let trailer=L.toStrict (L.drop offset (pBody packet))
                changed=okStatus ok .&. 0x4000 /= 0
            if B.null trailer then when changed (throwIO (ProtocolError "missing session tracking payload")) else do
                (_,rest) <- either (throwIO . ProtocolError) pure (lenString trailer)
                if changed then do
                    (tracking,leftover) <- either (throwIO . ProtocolError) pure (lenString rest)
                    unless (B.null leftover) (throwIO (ProtocolError "trailing session payload"))
                    when (fromIntegral (B.length tracking)>maximumMetadataBytes (connectionOptions conn)) (throwIO (ProtocolError "session tracking payload exceeds metadata budget"))
                    pairs <- either (throwIO . ProtocolError) pure (trackingPairs tracking)
                    mapM_ (updateTracked conn) pairs
                else unless (B.null rest) (throwIO (ProtocolError "unexpected OK trailer"))
        pure ok

lenString :: ByteString -> Either String (ByteString,ByteString)
lenString bytes = do
    when (B.null bytes) (Left "truncated length string")
    let tag=B.head bytes; after=B.tail bytes
        takeLength width = do
            when (B.length after < width) (Left "truncated encoded length")
            let n=B.foldr (\w a -> a*256+fromIntegral w) (0::Word64) (B.take width after)
            pure (n,B.drop width after)
    (count,rest) <- case tag of
        0xfc -> takeLength 2; 0xfd -> takeLength 3; 0xfe -> takeLength 8
        _ | tag < 0xfb -> Right (fromIntegral tag,after)
          | otherwise -> Left "invalid non-null string length"
    when (count > fromIntegral (B.length rest)) (Left "truncated length string body")
    pure (B.splitAt (fromIntegral count) rest)
-- Each tracker item is length-delimited. Skip unknown kinds by their envelope,
-- not by a guessed layout, and bound both item and variable counts. Retained
-- rendering values are copied by updateTracked to avoid pinning a large packet.
trackingPairs :: ByteString -> Either String [(ByteString,ByteString)]
trackingPairs = items 0 []
  where
    items :: Int -> [(ByteString,ByteString)] -> ByteString -> Either String [(ByteString,ByteString)]
    items count acc bytes
        | B.null bytes = Right (reverse acc)
        | count>=65535 = Left "too many session tracking items"
        | otherwise = do
            (payload,rest) <- lenString (B.tail bytes)
            (count',acc') <- if B.head bytes==0 then variables (count+1) acc payload else Right (count+1,acc)
            items count' acc' rest
    variables count acc body | B.null body = Right (count,acc)
    variables count acc body = do
        when (count>=65535) (Left "too many tracked variables")
        (name,rest) <- lenString body
        (value,left) <- lenString rest
        variables (count+1) ((name,value):acc) left

updateTracked :: MySQLConn -> (ByteString,ByteString) -> IO ()
updateTracked conn (name,value)
    | name `elem` ["sql_mode","character_set_client","character_set_connection","collation_connection"] && B.length value>maximumRenderingValueBytes = throwIO (ProtocolError "tracked rendering value exceeds bound")
    | name == "session_track_system_variables" = do
        let selected=BC.split ',' value
        unless (value=="*" || all (`elem` selected) ["sql_mode","character_set_client","character_set_connection"])
            (writeIORef (connectionRenderContext conn) Nothing)
    | otherwise = atomicModifyIORef' (connectionRenderContext conn) $ \ctx ->
        let apply c = case name of
                "sql_mode" -> c {renderSQLModes=BC.split ',' (B.copy value)}
                "character_set_client" -> c {renderClientCharset=B.copy value}
                "character_set_connection" -> c {renderConnectionCharset=B.copy value,renderConnectionCollation=Nothing}
                "collation_connection" -> c {renderConnectionCollation=Just (B.copy value)}
                _ -> c
        in (fmap apply ctx,())

usesOKTerminator :: MySQLConn -> IO Bool
usesOKTerminator conn = (/=0) . (.&. 0x1000000) <$> readIORef (connectionCapabilities conn)

isResultEnd :: MySQLConn -> Packet -> IO Bool
isResultEnd conn packet = (\modern -> isResultEndFor modern packet) <$> usesOKTerminator conn

isResultEndFor :: Bool -> Packet -> Bool
isResultEndFor modern packet = if modern then pLen packet > 0 && pLen packet < 16777215 && not (L.null (pBody packet)) && L.head (pBody packet)==0xfe else isEOF packet
{-# INLINE isResultEndFor #-}

consumeEnd :: MySQLConn -> Packet -> IO Word16
consumeEnd conn packet = do
    modern <- usesOKTerminator conn
    if modern then okStatus <$> consumeOK conn packet else do
        unless (pLen packet==5) (throwIO (ProtocolError "invalid legacy EOF length"))
        EOF _ flags <- decodeFromPacket packet
        updateStatus conn flags
        pure flags

readMetadataEnd :: MySQLConn -> IO ()
readMetadataEnd conn = do
    modern <- usesOKTerminator conn
    unless modern $ do
        packet <- readConnPacket conn
        unless (isEOF packet) (throwIO (UnexpectedPacket packet))
        void (consumeEnd conn packet)

readColumns :: MySQLConn -> Int -> IO [ColumnDef]
readColumns conn count = do
    unless (count>=0 && count<=maximumColumns (connectionOptions conn)) (throwIO (ProtocolError "column count exceeds client limit"))
    let loop 0 _ = pure []
        loop n total = do
            packet <- readConnPacket conn
            when (isERR packet) (serverError conn packet)
            let budget=maximumMetadataBytes (connectionOptions conn)
                size=fromIntegral (pLen packet)
            when (total>budget || size>budget-total) (throwIO (ProtocolError "metadata exceeds client limit"))
            let total'=total+size
            field <- getFromPacketExact getField packet
            (field:) <$> loop (n-1) total'
    fields <- loop count 0
    when (count>0) (readMetadataEnd conn)
    pure fields

-- | Return known session facts without issuing SQL. A snapshot can become stale
-- after another operation; connected APIs obtain it under their command claim.
-- Unknown facts raise 'SessionContextUnavailable' rather than silently probing.
getRenderContext :: MySQLConn -> IO RenderContext
getRenderContext conn = readIORef (connectionRenderContext conn) >>= maybe (throwIO SessionContextUnavailable) pure

initializeSession :: MySQLConn -> IO ()
initializeSession = refreshSessionState
-- | Reconfigure tracking and explicitly snapshot rendering facts under one lease.
-- This executes SQL and therefore changes preceding-statement diagnostics such
-- as ROW_COUNT(). Existing tracker selections, including '*', are preserved.
refreshSessionState :: MySQLConn -> IO ()
refreshSessionState conn = withSessionLease conn $ do
    guardUnconsumed conn
    caps <- readIORef (connectionCapabilities conn)
    when (caps .&. 0x800000 /= 0) $ void $ command conn (COM_QUERY "SET SESSION session_track_system_variables=IF(@@session.session_track_system_variables='*','*',CONCAT_WS(',',NULLIF(@@session.session_track_system_variables,''),'sql_mode,character_set_client,character_set_connection,character_set_results,session_track_system_variables'))")
    (context, limit) <- withCommand conn $ do
        sendCommand conn (COM_QUERY "SELECT @@sql_mode,@@character_set_client,@@character_set_connection,@@collation_connection,VERSION(),CAST(@@max_allowed_packet AS CHAR)")
        first <- readConnPacket conn
        when (isERR first) (serverError conn first)
        count <- getFromPacketExact getLenEncInt first
        unless (count == 6) (throwIO (ProtocolError "invalid session snapshot column count"))
        fields <- readColumns conn count
        rowPacket <- readConnPacket conn
        when (fromIntegral (pLen rowPacket) > maximumMetadataBytes (connectionOptions conn))
            (throwIO (ProtocolError "session snapshot exceeds metadata budget"))
        rawValues <- getFromPacketExact (getTextRow fields) rowPacket
        -- Force/validate the snapshot while this exchange is still owned. A
        -- lazy UTF-8 exception after Ready would escape retirement, and a
        -- permissive decoder could otherwise accept an unparsed row trailer.
        values <- forM rawValues $ \value -> do
            bytes <- case value of
                MySQLText text -> evaluate (TE.encodeUtf8 text)
                MySQLBytes raw -> pure raw
                _ -> throwIO (ProtocolError "invalid session snapshot value type")
            -- These six cold-start facts outlive the receive buffers. Retain
            -- explicitly owned, bounded storage regardless of codec internals;
            -- ordinary result payloads are not copied by this policy.
            B.copy <$> boundedSnapshotValue bytes
        snapshot <- case values of
            [modes, client, server, collation, version, packetLimit] -> do
                versionID <- maybe (throwIO (ProtocolError "invalid server version snapshot")) pure (versionNumber version)
                limit <- case BC.readInteger packetLimit of
                    Just (n, rest) | B.null rest && n > 0 && n <= fromIntegral (maxBound :: Word64) -> pure (fromIntegral n)
                    _ -> throwIO (ProtocolError "invalid server packet limit snapshot")
                pure (RenderContext (BC.split ',' modes) client server (Just collation) versionID, limit)
            _ -> throwIO (ProtocolError "invalid session snapshot")
        end <- readConnPacket conn
        isEnd <- isResultEnd conn end
        unless isEnd (throwIO (UnexpectedPacket end))
        flags <- consumeEnd conn end
        when (flags .&. 8 /= 0) (throwIO (ProtocolError "unexpected additional session snapshot result"))
        pure snapshot
    writeIORef (connectionServerPacketLimit conn) limit
    writeIORef (connectionRenderContext conn) (Just context)
  where
    -- Failure must be detected under the command claim, not turned into version
    -- zero after Ready: version gates determine which SQL bytes are executable.
    versionNumber value = case traverse component (take 3 (BC.split '.' (BC.takeWhile (\w -> w == '.' || w >= '0' && w <= '9') value))) of
        Just [a,b,c] | a > 0 -> Just (a*10000+b*100+c)
        _ -> Nothing
    component value = case BC.readInt value of
        Just (n, rest) | n >= 0 && n < 100 && B.null rest -> Just n
        _ -> Nothing
    boundedSnapshotValue bytes = do
        when (B.length bytes > maximumRenderingValueBytes)
            (throwIO (ProtocolError "session snapshot value exceeds bound"))
        pure bytes

guardUnconsumed :: MySQLConn -> IO ()
guardUnconsumed conn = do
    rt <- readIORef (connectionRuntime conn)
    tid <- myThreadId
    when (maybe False (/=tid) (transactionOwner rt)) (throwIO ConcurrentConnectionUse)
    case runtimeStatus rt of
        Ready -> pure ()
        Streaming -> throwIO UnconsumedResultSet
        Executing -> throwIO ConcurrentConnectionUse
        other -> throwIO (ConnectionUnavailable other)

-- Legacy low-level helpers retain their behavior for independent packet streams.
waitCommandReply :: InputStream Packet -> IO OK
waitCommandReply input = do
    packet <- readPacket input
    if isERR packet then decodeFromPacket packet >>= throwIO . ERRException
    else if isOK packet then decodeFromPacket packet else throwIO (UnexpectedPacket packet)

waitCommandReplys :: InputStream Packet -> IO [OK]
waitCommandReplys input = do
    ok <- waitCommandReply input
    if isThereMore ok then (ok:) <$> waitCommandReplys input else pure [ok]

writeIORef' :: IORef a -> a -> IO ()
writeIORef' ref value = value `seq` writeIORef ref value

-- | An expected packet/body could not be read from a closed packet source.
-- Other socket/TLS exceptions can propagate directly; inspect connection status
-- to decide whether a new connection is required.
data NetworkException = NetworkException deriving (Typeable,Show)
instance Exception NetworkException
-- | A command was attempted while the preceding result still owns the wire.
-- No bytes for the new command have been sent; consume or discard that result.
data UnconsumedResultSet = UnconsumedResultSet deriving (Typeable,Show)
instance Exception UnconsumedResultSet
-- | MariaDB returned an ERR reply. Ordinary commands consume the complete reply
-- before permitting reuse, but invalidate cached rendering facts. Replication
-- and constructor failures have their own terminal lifecycle rules.
data ERRException = ERRException ERR deriving (Typeable,Show)
instance Exception ERRException
-- | A packet marker/shape is unexpected for the current protocol phase.
data UnexpectedPacket = UnexpectedPacket Packet deriving (Typeable,Show)
instance Exception UnexpectedPacket

-- System.Timeout's private exception is not necessarily SomeAsyncException.
isCancellation :: SomeException -> Bool
isCancellation err@(SomeException inner) = isJust (fromException err :: Maybe SomeAsyncException)
    || tyConName (typeRepTyCon (typeOf inner)) == "Timeout"

-- A refresh's configuration and snapshot exchanges are one logical operation.
withSessionLease :: MySQLConn -> IO a -> IO a
withSessionLease conn action = mask $ \restore -> do
    tid <- myThreadId
    acquired <- atomicModifyIORef' (connectionRuntime conn) $ \rt -> case transactionOwner rt of
        Nothing | runtimeStatus rt==Ready -> (rt {transactionOwner=Just tid},Right True)
        Just owner | owner==tid && runtimeStatus rt==Ready -> (rt,Right False)
        _ -> (rt,Left ConcurrentConnectionUse)
    own <- either throwIO pure acquired
    restore action `finally` when own (endTransactionLease conn)

-- Force bounded encoded chunks once, without first allocating an oversized message.
encodedLength :: Word64 -> L.ByteString -> IO Int64
encodedLength limit = loop 0 . L.toChunks
  where
    loop count []=pure (fromIntegral count)
    loop count (chunk:rest)=do
        let next=count+fromIntegral (B.length chunk)
        when (next>limit) (throwIO (ProtocolError "outgoing message exceeds client/server limit"))
        next `seq` loop next rest

{-# INLINE readConnPacket #-}
{-# INLINE streamGuard #-}
