{-# LANGUAGE ScopedTypeVariables #-}

-- | Low-level raw TLS transport helpers. These open TLS immediately on the
-- socket; MariaDB instead requires a plaintext greeting and SSLRequest first.
-- MariaDB applications must use "Database.MySQL.TLS" for that handshake and
-- its connection deadlines/ownership policy. Bracket raw transports yourself.
--
-- This module is intended to be imported @qualified@, e.g.:
--
-- @
-- import           "Data.Connection"
-- import qualified "System.IO.Streams.TLS" as TLS
-- @
--
module System.IO.Streams.TLS
  ( TLSConnection
    -- * client
  , connect
  , connectTLS
  , tLsToConnection
    -- * server
  , accept
    -- * re-export
  , module Data.TLSSetting
  ) where

import qualified Control.Exception     as E
import           Data.Connection
import qualified Data.ByteString       as B
import qualified Data.ByteString.Char8 as BC
import           Data.TLSSetting
import qualified Network.Socket        as N
import           Network.TLS           (ClientParams, Context, ServerParams)
import qualified Network.TLS           as TLS
import qualified System.IO.Streams     as Stream
import qualified System.IO.Streams.TCP as TCP


-- | Type alias for tls connection.
--
-- Normally you shouldn't use 'TLS.Context' in 'connExtraInfo' directly.
--
type TLSConnection = Connection (TLS.Context, N.SockAddr)

-- | Make a t'Connection' from a 'Context'.
--
tLsToConnection :: (Context, N.SockAddr)    -- ^ TLS connection / socket address pair
                -> IO TLSConnection
tLsToConnection (ctx, addr) = do
    is <- Stream.makeInputStream input
    return (Connection is write (closeTLS ctx) (ctx, addr))
  where
    -- Preserve TLS failures and asynchronous cancellation. Treating either as
    -- EOF would let the caller mistake an interrupted reply for a clean close.
    input = do
        s <- TLS.recvData ctx
        return $! if B.null s then Nothing else Just s
    write s = TLS.sendData ctx s

-- | Close a TLS 'Context' and its underlying socket.
--
closeTLS :: Context -> IO ()
closeTLS ctx = (TLS.bye ctx `E.finally` TLS.contextClose ctx) -- sometimes socket was closed before 'TLS.bye'
    `E.catch` (\(_::E.SomeException) -> return ())   -- so we catch the 'Broken pipe' error here

-- | Convenience function for initiating an TLS connection to the given
-- @('Network.Socket.HostName', 'Network.Socket.PortNumber')@ combination.
--
-- This operation may throw 'TLS.TLSException' on failure.
--
connectTLS :: ClientParams         -- ^ check "Data.TLSSetting"
           -> Maybe String         -- ^ Optional certificate subject name, if set to 'Nothing'
                                   -- then we will try to verify 'Network.Socket.HostName' as subject name
           -> N.HostName           -- ^ hostname to connect to
           -> N.PortNumber         -- ^ port number to connect to
           -> IO (Context, N.SockAddr)
connectTLS prms subname host port = do
    let subname' = maybe host id subname
        prms' = prms { TLS.clientServerIdentification = (subname', BC.pack (show port)) }
    (sock, addr) <- TCP.connectSocket host port
    E.bracketOnError (TLS.contextNew sock prms') closeTLS $ \ ctx -> do
        TLS.handshake ctx
        return (ctx, addr)

-- | Connect to server using TLS and return a t'Connection'.
--
connect :: ClientParams         -- ^ check "Data.TLSSetting"
        -> Maybe String         -- ^ Optional certificate subject name, if set to 'Nothing'
                                -- then we will try to verify 'Network.Socket.HostName' as subject name
        -> N.HostName           -- ^ hostname to connect to
        -> N.PortNumber         -- ^ port number to connect to
        -> IO TLSConnection
connect prms subname host port = connectTLS prms subname host port >>= tLsToConnection

-- | Accept a new TLS connection from remote client with listening socket.
--
-- This operation may throw 'TLS.TLSException' on failure.
--
accept :: ServerParams              -- ^ check "Data.TLSSetting"
       -> N.Socket                  -- ^ the listening 'Network.Socket.Socket'
       -> IO TLSConnection
accept prms sock = do
    (sock', addr) <- N.accept sock
    E.bracketOnError (TLS.contextNew sock' prms) closeTLS $ \ ctx -> do
        TLS.handshake ctx
        conn <- tLsToConnection (ctx, addr)
        return conn
