{-# LANGUAGE ScopedTypeVariables #-}
-- | Additive native-connection regressions. Wire fixtures and the server's
-- published signing vector are independent of the client encoder under test.
module Validation.Stage2 (cases) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary (put)
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as L
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import Data.IORef
import Database.MySQL.Base
import qualified Database.MySQL.Connection as C
import qualified Database.MySQL.TLS as TLS
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NB
import qualified Network.TLS as WireTLS
import System.Environment
import System.FilePath
import qualified System.IO.Streams as S
import System.Timeout
import Validation.Common

case2 :: String -> IO () -> Case
case2 name = Case ("stage2." ++ name) "stage2-native-connections"

greeting :: B.ByteString -> B.ByteString -> Greeting
greeting plugin nonce = Greeting 10 "12.3.3-MariaDB" 1 (B.take 8 nonce)
    (clientCap .|. 0x1800000) 224 2 (B.drop 8 nonce) plugin

ok :: Word8 -> Packet
ok seqN = putToPacket seqN (putByteString "\0\0\0\2\0\0\0")

switch :: Word8 -> B.ByteString -> B.ByteString -> Packet
switch seqN plugin nonce = putToPacket seqN
    (putWord8 254 >> putByteString plugin >> putWord8 0 >> putByteString nonce)

-- The first packet has already been read by the constructor. All following
-- packets pass through the real sequence-checked connection reader/writer.
conversation :: Greeting -> Packet -> [Packet] -> IO (IORef [Packet], IO ())
conversation initial first rest = do
    input <- S.fromList rest
    writes <- newIORef []
    conn <- C.newConnection defaultConnectionOptions input
        (\p -> modifyIORef' writes (p:)) (pure ())
    C.setExchangeSequence conn (fromIntegral (pSeqN first + 1))
    pure (writes, C.completeAuth conn initial True "foobar" first)

rejectAuth :: IO a -> IO ()
rejectAuth action = do
    result <- try action
    case result of
        Left (_ :: AuthException) -> pure ()
        Right _ -> throwIO (userError "invalid authentication unexpectedly succeeded")

withListener :: (N.Socket -> Int -> IO a) -> IO a
withListener action = bracket (N.socket N.AF_INET N.Stream 0) N.close $ \listener -> do
    N.bind listener (N.SockAddrInet 0 (N.tupleToHostAddress (127,0,0,1)))
    N.listen listener 1
    N.SockAddrInet port _ <- N.getSocketName listener
    action listener (fromIntegral port)

checkSNI :: Bool -> IO ()
checkSNI enabled = withListener $ \listener port -> do
    ca <- getEnv "MB_TLS_CA"
    observed <- newIORef Nothing
    params <- TLS.makeServerParams (takeDirectory ca </> "server-cert.pem") []
        (takeDirectory ca </> "server-key.pem")
    let serverParams = params {WireTLS.serverHooks=(WireTLS.serverHooks params)
            {WireTLS.onServerNameIndication= \name -> writeIORef observed name >> pure mempty}}
        recvExactly sock count = go count []
          where
            go 0 chunks = pure (B.concat (reverse chunks))
            go n chunks = do
                chunk <- NB.recv sock n
                when (B.null chunk) (throwIO (userError "truncated TLS request"))
                go (n-B.length chunk) (chunk:chunks)
    finished <- newEmptyMVar
    -- The actual worker writes a complete native greeting and reads exactly
    -- the unencrypted SSLRequest before handing the socket to tls.
    worker <- forkFinally (bracket (fst <$> N.accept listener) N.close $ \sock -> do
        let hello=(greeting "mysql_native_password" (B.replicate 20 65))
                {greetingCaps=clientCap .|. 0x1800800}
        NB.sendAll sock (L.toStrict (runPut (put (encodeToPacket 0 hello))))
        request <- recvExactly sock 36
        equal "SSLRequest sequence" 1 (B.index request 3)
        bracket (WireTLS.contextNew sock serverParams) WireTLS.contextClose $ \ctx ->
            WireTLS.handshake ctx >> WireTLS.bye ctx) (putMVar finished)
    flip finally (killThread worker) $ do
        ci <- config
        clientParams <- TLS.makeClientParams (TLS.CustomCAStore ca)
        outcome <- try (TLS.connectWithOptions defaultConnectionOptions {connectTimeoutMicros=1000000}
            ci {ciHost="127.0.0.1",ciPort=fromIntegral port} (clientParams {WireTLS.clientUseServerNameIndication=enabled},"localhost"))
        case outcome of
            Left (_ :: SomeException) -> pure ()
            Right conn -> close conn >> throwIO (userError "fixture unexpectedly authenticated")
        result <- timeout 2000000 (takeMVar finished)
        case result of
            Just (Right ()) -> pure ()
            _ -> throwIO (userError "fixture TLS handshake did not finish")
        equal "SNI host" (if enabled then Just "localhost" else Nothing) =<< readIORef observed

cases :: [Case]
cases =
    [ case2 "capabilities.greeting-upper-word" $ do
        let expected = (greeting "mysql_native_password" (B.replicate 20 65))
                {greetingCaps=clientCap .|. bit 35 .|. bit 63}
        actual <- decodeFromPacket (encodeToPacket 0 expected)
        equal "full native greeting" expected actual
    , case2 "capabilities.auth-upper-word-offset" $ do
        let auth = Auth (clientCap .|. bit 35 .|. bit 63) 12345 224 "user" "response" "db" "mysql_native_password"
            packet = encodeToPacket 1 auth
        equal "extension bytes 28..31" [8,0,0,128] (B.unpack (L.toStrict (L.take 4 (L.drop 28 (pBody packet)))))
        equal "auth roundtrip" auth =<< decodeFromPacket packet
    , case2 "capabilities.ssl-upper-word-offset" $ do
        let request = SSLRequest (clientCap .|. bit 35 .|. bit 63 .|. 0x800) 12345 224
            packet = encodeToPacket 1 request
        equal "SSL request length" 32 (pLen packet)
        equal "SSL extension bytes" [8,0,0,128] (B.unpack (L.toStrict (L.drop 28 (pBody packet))))
        equal "SSL roundtrip" request =<< decodeFromPacket packet
    , case2 "capabilities.server-intersection" $ do
        let g = (greeting "mysql_native_password" (B.replicate 20 65)) {greetingCaps=0x8200}
        equal "no unoffered capabilities" 0x8200 (C.negotiatedCapabilities defaultConnectionOptions g)
        assert (C.negotiatedCapabilities defaultConnectionOptions g .&. 0xffffffff00000001 == 0)
            "unimplemented extensions or legacy marker advertised"
    , case2 "auth.ed25519-independent-golden" $ do
        let expected = B.pack [232,61,201,63,67,63,51,53,86,73,238,35,170,117,146,214,26,17,35,9,8,132,245,141,48,99,66,58,36,228,48,84,115,254,187,168,88,162,249,57,35,85,79,238,167,106,68,117,56,135,171,47,20,14,133,79,15,229,124,160,176,100,138,14]
        equal "MariaDB ed25519-t.c vector" expected (C.scrambleEd25519 (B.replicate 32 65) "foobar")
    , case2 "auth.binary-trailing-zero-switch" $ do
        let nonce = B.pack ([1..31] ++ [0])
        (writes, action) <- conversation (greeting "mysql_native_password" (B.replicate 20 65))
            (switch 2 "client_ed25519" nonce) [ok 4]
        action
        sent <- readIORef writes
        equal "signature over all 32 bytes" [L.fromStrict (C.scrambleEd25519 nonce "foobar")] (map pBody sent)
    , case2 "auth.optional-switch-terminator" $ do
        let nonce = B.replicate 20 65
        (writes, action) <- conversation (greeting "mysql_native_password" nonce)
            (switch 2 "caching_sha2_password" (nonce <> "\0")) [ok 4]
        action
        sent <- readIORef writes
        equal "exact nonce without protocol terminator" [L.fromStrict (C.scrambleSHA256 nonce "foobar")] (map pBody sent)
    , case2 "auth.unknown-switch-before-write" $ do
        (writes, action) <- conversation (greeting "mysql_native_password" (B.replicate 20 65))
            (switch 2 "unknown_plugin" (B.replicate 20 65)) []
        rejectAuth action
        equal "no credential response" [] =<< readIORef writes
    , case2 "auth.short-challenges-rejected" $
        forM_ ["mysql_native_password","caching_sha2_password","client_ed25519","parsec"] $ \plugin ->
            forM_ [0,1,19,33,255] $ \len ->
                rejectAuth (evaluate (B.length (C.scrambleForPlugin plugin (B.replicate len 65) "foobar")))
    , case2 "auth.malformed-switch-rejected" $
        forM_ ["\254", "\254missing-nul", "\254\0"] $ \body -> do
            (_, action) <- conversation (greeting "mysql_native_password" (B.replicate 20 65))
                (Packet (fromIntegral (B.length body)) 2 (L.fromStrict body)) []
            rejectAuth action
    , case2 "auth.switch-loop-bounded" $ do
        let nonce = B.replicate 20 65
            first = switch 2 "mysql_native_password" nonce
            rest = [switch n "mysql_native_password" nonce | n <- [4,6..36]]
        (writes, action) <- conversation (greeting "mysql_native_password" nonce) first rest
        rejectAuth action
        sent <- readIORef writes
        assert (length sent <= 16) "auth loop was not bounded"
    , case2 "auth.parsec-excess-work-before-derivation" $ do
        let nonce = B.replicate 32 65
            ext = putToPacket 4 (putByteString (B.pack [1,80,255] <> B.replicate 18 65))
        (writes, action) <- conversation (greeting "mysql_native_password" (B.replicate 20 65))
            (switch 2 "parsec" nonce) [ext]
        rejectAuth action
        equal "only empty ext-salt request" [L.empty] . map pBody =<< readIORef writes
    , case2 "auth.parsec-invalid-parameters" $
        forM_ [B.empty, "P", B.pack [81,0] <> B.replicate 18 65, B.pack [80,0] <> B.replicate 17 65] $ \params -> do
            let ext = putToPacket 4 (putWord8 1 >> putByteString params)
            (_, action) <- conversation (greeting "mysql_native_password" (B.replicate 20 65))
                (switch 2 "parsec" (B.replicate 32 65)) [ext]
            rejectAuth action
    , case2 "tls.sni-and-verified-hostname" $ mapM_ checkSNI [True,False]
    , case2 "auth.sha2-malformed-continuations" $
        forM_ [B.empty, B.pack [3,0], B.pack [4,0], B.singleton 255] $ \body -> do
            let initial=greeting "caching_sha2_password" (B.replicate 20 65)
                packet=putToPacket 2 (putWord8 1 >> putByteString body)
            (writes, action) <- conversation initial packet []
            rejectAuth action
            equal "no malformed continuation response" [] =<< readIORef writes
    , case2 "auth.rsa-invalid-nonce" $
        forM_ [0,1,19,21] $ \count ->
            rejectAuth (evaluate (B.length (C.xorPasswordNonce "foobar" (B.replicate count 65))))
    , case2 "auth.rsa-invalid-key-before-write" $ do
        writes <- newIORef (0::Int)
        rejectAuth (C.doRSAAuth (\_ -> modifyIORef' writes (+1)) 1 "foobar" (B.replicate 20 65) "not PEM")
        equal "invalid key never writes credentials" 0 =<< readIORef writes
    , case2 "auth.rsa-invalid-key-structure" $
        -- Deliberately invalid public SPKI fixtures: negative/zero modulus and
        -- negative/even exponent and an unrelated algorithm identifier.
        -- Reject them before integer conversion or credential encryption.
        forM_ [ "MBwwDQYJKoZIhvcNAQEBBQADCwAwCAIB/wIDAQAB"
              , "MBwwDQYJKoZIhvcNAQEBBQADCwAwCAIBAAIDAQAB"
              , "MBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAQIB/w=="
              , "MBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAQIBBA=="
              , "MBowDQYJKoZIhvcNAQECBQADCQAwBgIBAQIBAw=="
              ] $ \encoded -> do
            let pem="-----BEGIN PUBLIC KEY-----\n" <> encoded <> "\n-----END PUBLIC KEY-----\n"
            case C.parseRSAPublicKey pem of
                Left _ -> pure ()
                Right _ -> throwIO (userError "invalid RSA key structure accepted")
            rejectAuth (C.doRSAAuth (const (pure ())) 1 "foobar" (B.replicate 20 65) pem)
    , case2 "auth.sha2-uncached-full-authentication" $ do
        -- New accounts cannot have been primed by native-client preflight or
        -- another transport. Exercise the full exchange once per transport.
        ci <- config
        withConnect (connect ci {ciUser="testMySQLHaskell",ciPassword="",ciDatabase=""}) $ \admin ->
            forM_ ["tcp","tls","socket"] $ \transport -> do
                stamp <- getMonotonicTimeNSec
                let name="mb_stage2_uncached_" ++ show stamp
                    password="stage2-disposable-full-auth-password"
                    create="CREATE USER '" ++ name ++ "'@'localhost' IDENTIFIED VIA caching_sha2_password USING PASSWORD('" ++ password ++ "')"
                    dropUser="DROP USER '" ++ name ++ "'@'localhost'"
                    account=ci {ciUser=BC.pack name,ciPassword=BC.pack password,ciDatabase=""}
                bracket_ (exec admin create) (exec admin dropUser) $ do
                    opener <- case transport of
                        "tcp" -> pure (connect account)
                        "tls" -> pure (tlsConnect account "localhost")
                        _ -> do path <- socketPath; pure (connectUnixSocket path account)
                    withConnect opener healthy
    , case2 "connection.greeting-deadline-closes-peer" $ withListener $ \listener port -> do
        peerClosed <- newEmptyMVar
        worker <- forkFinally
            (bracket (fst <$> N.accept listener) N.close $ \sock -> NB.recv sock 1)
            (putMVar peerClosed)
        flip finally (killThread worker) $ do
            ci <- config
            rejectAuth (connectWithOptions defaultConnectionOptions {connectTimeoutMicros=50000}
                ci {ciHost="127.0.0.1",ciPort=fromIntegral port})
            result <- timeout 1000000 (takeMVar peerClosed)
            case result of
                Just (Right bytes) -> equal "peer observes cleanup" B.empty bytes
                _ -> throwIO (userError "timed-out handshake did not close its peer")
    , case2 "connection.greeting-cancellation-closes-peer" $ withListener $ \listener port -> do
        accepted <- newEmptyMVar
        peerClosed <- newEmptyMVar
        server <- forkFinally (bracket (fst <$> N.accept listener) N.close $ \sock ->
            putMVar accepted () >> NB.recv sock 1) (putMVar peerClosed)
        ci <- config
        result <- newEmptyMVar
        client <- forkFinally (connect ci {ciHost="127.0.0.1",ciPort=fromIntegral port}) (putMVar result)
        flip finally (killThread client >> killThread server) $ do
            takeMVar accepted
            throwTo client ThreadKilled
            outcome <- takeMVar result
            case outcome of
                Left err -> equal "cancellation identity" (Just ThreadKilled) (fromException err)
                Right conn -> close conn >> throwIO (userError "cancelled constructor succeeded")
            ended <- timeout 1000000 (takeMVar peerClosed)
            case ended of
                Just (Right bytes) -> equal "cancelled peer closed" B.empty bytes
                _ -> throwIO (userError "cancelled handshake leaked transport")
    ] ++
    [ case2 ("auth.wrong-password." ++ user ++ "." ++ transport) $ do
        ci <- config
        let wrong = ci {ciUser=BC.pack user,ciPassword="definitely-wrong-stage2-password"}
        opener <- case transport of
            "tcp" -> pure (connect wrong)
            "tls" -> pure (tlsConnect wrong "localhost")
            _ -> do path <- socketPath; pure (connectUnixSocket path wrong)
        expectERR [1045] (withConnect opener healthy)
    | user <- ["mariadb_ed25519","mariadb_parsec","mariadb_sha2"]
    , transport <- ["tcp","tls","socket"]
    ]
