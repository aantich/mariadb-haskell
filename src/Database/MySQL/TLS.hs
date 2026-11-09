{-|
Module      : Database.MySQL.TLS
Description : MariaDB TLS connections via the @tls@ package
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : Anton Antich <anton.antich@gmail.com>
Stability   : experimental
Portability : macOS and Linux tested

TLS connections use the same ownership, limits and session initialization as
TCP. Supply certificate/hostname validation through t'Network.TLS.ClientParams'.

Use 'makeClientParams' with 'SystemCAStore' or a managed 'CustomCAStore', then
reuse the resulting parameters in the connection factory. The tuple's name is
the server certificate DNS identity (and default SNI), which can differ from
the address in 'ciHost'. Do not disable verification to work around CA/name
errors. @makeClientParams'@ also provides a client certificate for X.509 accounts.

@MozillaCAStore@ uses an installed static snapshot, not automatically updated
OS roots; see the packaged @docs/CA_BUNDLE.md@ for provenance and update policy.
TLS protects transport; PAM/GSSAPI options do not replace peer verification. See
the <https://github.com/aantich/mariadb-haskell/blob/main/docs/USER_GUIDE.md connection guide>.

-}

module Database.MySQL.TLS (
      connect
    , connectDetail
    , connectWithOptions
    , connectWithAuthentication
    , connectDetailWithAuthentication
    , connectDetailWithOptions
    , module Data.TLSSetting
    ) where

import           Control.Exception              (bracketOnError, throwIO, finally)
import qualified Data.Binary                    as Binary
import qualified Data.Binary.Put                as Binary
import qualified Data.Connection                as Conn
import           Data.IORef                     (writeIORef)
import           Data.Bits                      (testBit)
import           Control.Monad                  (when)
import           Data.TLSSetting
import           Database.MySQL.Authentication
import           Database.MySQL.Connection      hiding (connect, connectDetail, connectWithOptions, connectDetailWithOptions, connectWithAuthentication, connectDetailWithAuthentication)
import           Database.MySQL.Protocol.Auth
import           Database.MySQL.Protocol.Packet
import qualified Network.TLS                    as TLS
import qualified System.IO.Streams.TCP          as TCP
import qualified System.IO.Streams.TLS          as TLS

--------------------------------------------------------------------------------

-- | Provide a t'Network.TLS.ClientParams' and a subject name to establish a TLS connection.
--
connect :: ConnectInfo -> (TLS.ClientParams,String) -> IO MySQLConn
connect = connectWithOptions defaultConnectionOptions
-- | Connect over TLS with explicit resource/session options. Failure during
-- handshake, authentication or initialization closes both TLS and raw transport.
connectWithOptions :: ConnectionOptions -> ConnectInfo -> (TLS.ClientParams,String) -> IO MySQLConn
connectWithOptions options ci params = snd <$> connectDetailWithOptions options ci params
-- | Establish TLS and return the MariaDB greeting alongside the connection.
connectDetail :: ConnectInfo -> (TLS.ClientParams,String) -> IO (Greeting,MySQLConn)
connectDetail = connectDetailWithOptions defaultConnectionOptions
-- | Explicit-options variant of 'connectDetail'. The plaintext greeting uses
-- sequence zero, SSLRequest one and the authenticated TLS response sequence two.
connectDetailWithOptions :: ConnectionOptions -> ConnectInfo -> (TLS.ClientParams,String) -> IO (Greeting,MySQLConn)
connectDetailWithOptions options = connectDetailWithAuthentication options defaultAuthenticationOptions

-- | TLS connection with explicit PAM callbacks or a pinned GSSAPI principal.
-- Certificate verification remains the responsibility of the supplied TLS
-- parameters; external authentication does not replace peer verification.
connectWithAuthentication :: ConnectionOptions -> AuthenticationOptions -> ConnectInfo -> (TLS.ClientParams,String) -> IO MySQLConn
connectWithAuthentication options auth ci params = snd <$> connectDetailWithAuthentication options auth ci params

-- | Greeting-returning variant of 'connectWithAuthentication'.
connectDetailWithAuthentication :: ConnectionOptions -> AuthenticationOptions -> ConnectInfo -> (TLS.ClientParams,String) -> IO (Greeting,MySQLConn)
connectDetailWithAuthentication options auth ci (params,name) = withConnectDeadline options $ do
    validateOptions options
    bracketOnError (TCP.connectSocketTimeout (connectTimeoutMicros options) (ciHost ci) (ciPort ci) >>= TCP.socketToConnectionAdaptive bUFSIZE) Conn.close $ \raw -> do
        input <- decodeInputStreamWithLimit (authenticationWireLimit options) (Conn.source raw)
        packet <- readPacket input
        if pSeqN packet /= 0 then throwIO (ProtocolError "invalid greeting sequence") else pure ()
        if isERR packet then authenticationDiagnostic (decodeFromPacket packet) >>= throwIO . ERRException else pure ()
        greeting <- authenticationDiagnostic (getFromPacketExact getGreeting packet)
        if not (supportTLS (greetingCaps greeting)) then throwIO (AuthException "MariaDB server does not offer TLS") else pure ()
        let caps=negotiatedCapabilities options greeting
            params'=params {TLS.clientServerIdentification=(name,"")}
            (sock,addr)=Conn.connExtraInfo raw
            ssl=SSLRequest (caps + 0x800) (fromIntegral (maximumMessageBytes options)) (ciCharset ci)
        Conn.send raw (Binary.runPut (Binary.put (encodeToPacket 1 ssl)))
        bracketOnError (TLS.contextNew sock params') (\ctx -> TLS.contextClose ctx `finally` Conn.close raw) $ \ctx -> do
            TLS.handshake ctx
            secure <- TLS.tLsToConnection (ctx,addr)
            (authConn,conn) <- newAuthenticatingTransportConnection options (Conn.source secure) (Conn.send secure) (TLS.contextClose ctx `finally` Conn.close raw)
            setExchangeSequence conn 2
            writeIORef (connectionCapabilities conn) (caps+0x800)
            mysqlWrite conn (encodeToPacket 2 (mkAuthForAuthentication auth options (caps+0x800) ci greeting))
            response <- authenticationDiagnostic (readConnPacket authConn)
            completeAuthWithOptions auth authConn greeting True (ciPassword ci) response
            when (testBit caps 5) (connectionCompressionStart conn)
            role <- initializeSession conn
            rememberInitialSession conn ci role
            pure (greeting,conn)
