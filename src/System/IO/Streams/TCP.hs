{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}

-- | This module provides convenience functions for interfacing raw tcp.
--
-- Please use 'E.bracket' or its friends to ensure exception safety.
--
-- This module is intended to be imported @qualified@, e.g.:
--
-- @
-- import           "Data.Connection"
-- import qualified "System.IO.Streams.TCP" as TCP
-- @
--
module System.IO.Streams.TCP
  ( TCPConnection
    -- * client
  , connect
  , connectSocket
  , connectSocketTimeout
  , socketToConnection
  , socketToConnectionAdaptive
  , defaultChunkSize
    -- * server
  , bindAndListen
  , bindAndListenWith
  , accept
  , acceptWith
  ) where

import qualified Control.Exception         as E
import           System.Timeout (timeout)
import           Control.Monad
import           Data.Connection
import qualified Data.ByteString           as B
import qualified Data.ByteString.Lazy.Internal as L
import qualified Network.Socket            as N
import qualified Network.Socket.ByteString as NB
import qualified Network.Socket.ByteString.Lazy as NL
import qualified System.IO.Streams         as S
import           Foreign.Storable   (sizeOf)
import           Data.IORef (newIORef,readIORef,writeIORef)

addrAny :: N.HostAddress
#if MIN_VERSION_network(2,7,0)
addrAny = N.tupleToHostAddress (0,0,0,0)
#else
addrAny = N.iNADDR_ANY
#endif

-- | Type alias for tcp connection.
--
-- Normally you shouldn't use 'N.Socket' in 'connExtraInfo' directly, this field is
-- intend for used with 'N.setSocketOption' if you need to.
--
type TCPConnection = Connection (N.Socket, N.SockAddr)

-- | The chunk size used for I\/O, less the memory management overhead.
--
-- Currently set to 32k.
--
defaultChunkSize :: Int
defaultChunkSize = 32 * k - chunkOverhead
  where
    k = 1024
    chunkOverhead = 2 * sizeOf (undefined :: Int)

-- | Open a raw TCP socket for the address and port. Name resolution uses
-- @AI_ADDRCONFIG@ and @AI_NUMERICSERV@; usable IPv4/IPv6 addresses are tried
-- within one ten-second default deadline. @TCP_NODELAY@ is enabled.
-- The caller owns the returned socket. This does not authenticate MariaDB.
--
connectSocket :: N.HostName             -- ^ hostname to connect to
              -> N.PortNumber           -- ^ port number to connect to
              -> IO (N.Socket, N.SockAddr)
connectSocket = connectSocketTimeout 10000000

-- | Resolve and try all addresses within one deadline, including DNS time.
-- Each failed attempt closes its socket. Only IO errors permit fallback;
-- asynchronous cancellation propagates immediately. No authentication or TLS
-- failure is retried against another address after this function returns.
connectSocketTimeout :: Int -> N.HostName -> N.PortNumber -> IO (N.Socket, N.SockAddr)
connectSocketTimeout deadline host port
    | deadline <= 0 = ioError (userError "connection timeout must be positive")
    | otherwise = timeout deadline establish >>= maybe
        (ioError (userError "TCP connection establishment timed out")) pure
  where
    establish = N.getAddrInfo (Just hints) (Just host) (Just (show port)) >>= attempts
    hints = N.defaultHints
        { N.addrFlags = [N.AI_ADDRCONFIG, N.AI_NUMERICSERV]
        , N.addrSocketType = N.Stream
        }
    attempts [] = ioError (userError "hostname resolved to no usable addresses")
    attempts (address:rest) = do
        result <- E.try $ E.bracketOnError
            (N.socket (N.addrFamily address) (N.addrSocketType address) (N.addrProtocol address))
            N.close $ \sock -> do
                N.connect sock (N.addrAddress address)
                N.setSocketOption sock N.NoDelay 1
                pure (sock, N.addrAddress address)
        case result of
            Right connected -> pure connected
            Left (err :: E.IOException) -> if null rest then E.throwIO err else attempts rest

-- | Make a t'Connection' from a 'Network.Socket.Socket' with given buffer size.
--
socketToConnection
    :: Int                      -- ^ receive buffer size
    -> (N.Socket, N.SockAddr)   -- ^ socket address pair
    -> IO TCPConnection
socketToConnection bufsiz (sock, addr) = do
    is <- S.makeInputStream $ do
        s <- NB.recv sock bufsiz
        return $! if B.null s then Nothing else Just s
    return (Connection is (sendSocket sock) (N.close sock) (sock, addr))

-- | Start with a small receive allocation and grow on full reads, up to the
-- supplied ceiling. Each recv still returns independent immutable bytes; no
-- mutable buffer is reused underneath a returned row or metadata slice.
socketToConnectionAdaptive :: Int -> (N.Socket,N.SockAddr) -> IO TCPConnection
socketToConnectionAdaptive ceilingBytes (sock,addr) = do
    when (ceilingBytes<=0) (E.throwIO (userError "receive buffer ceiling must be positive"))
    capacity <- newIORef (min 4096 ceilingBytes)
    is <- S.makeInputStream $ do
        size <- readIORef capacity
        bytes <- NB.recv sock size
        when (B.length bytes==size && size<ceilingBytes) $
            writeIORef capacity (size+min size (ceilingBytes-size))
        pure $! if B.null bytes then Nothing else Just bytes
    pure (Connection is (sendSocket sock) (N.close sock) (sock,addr))

sendSocket :: N.Socket -> L.ByteString -> IO ()
sendSocket _ L.Empty = pure ()
sendSocket sock (L.Chunk bytes L.Empty) = unless (B.null bytes) (NB.sendAll sock bytes)
sendSocket sock bytes = NL.sendAll sock bytes

-- | Connect to server using 'defaultChunkSize'.
--
connect :: N.HostName             -- ^ hostname to connect to
        -> N.PortNumber           -- ^ port number to connect to
        -> IO TCPConnection
connect host port = connectSocket host port >>= socketToConnection defaultChunkSize

-- | Bind and listen on port with a limit on connection count.
--
-- This function will set @SO_REUSEADDR@, @TCP_NODELAY@ before binding.
--
bindAndListen :: Int                 -- ^ connection limit
              -> N.PortNumber        -- ^ port number
              -> IO N.Socket
bindAndListen = bindAndListenWith $ \ sock -> do
    N.setSocketOption sock N.ReuseAddr 1
    N.setSocketOption sock N.NoDelay 1

-- | Bind and listen on port with a limit on connection count.
--
-- Note: The following socket options are inherited by a connected TCP socket from the listening socket:
--
-- @
-- SO_DEBUG
-- SO_DONTROUTE
-- SO_KEEPALIVE
-- SO_LINGER
-- SO_OOBINLINE
-- SO_RCVBUF
-- SO_RCVLOWAT
-- SO_SNDBUF
-- SO_SNDLOWAT
-- TCP_MAXSEG
-- TCP_NODELAY
-- @
--
bindAndListenWith :: (N.Socket -> IO ()) -- ^ set socket options before binding
                  -> Int                 -- ^ connection limit
                  -> N.PortNumber        -- ^ port number
                  -> IO N.Socket
bindAndListenWith f maxc port =
    E.bracketOnError (N.socket N.AF_INET N.Stream 0)
                     N.close
                     (\sock -> do f sock
                                  N.bind sock (N.SockAddrInet port addrAny)
                                  N.listen sock maxc
                                  return sock
                     )

-- | Accept a connection with 'defaultChunkSize'.
--
accept :: N.Socket -> IO TCPConnection
accept = acceptWith (socketToConnection defaultChunkSize)

-- | Accept a connection with user customization.
--
acceptWith :: ((N.Socket, N.SockAddr) -> IO TCPConnection) -- ^ set socket options, adjust receive buffer, etc.
           -> N.Socket
           -> IO TCPConnection
acceptWith f = f <=< N.accept
