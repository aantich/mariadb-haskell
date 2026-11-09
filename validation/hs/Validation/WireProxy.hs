{-# LANGUAGE ScopedTypeVariables #-}
-- | Transparent byte counters for real compressed/plain server exchanges.
-- Neither TLS nor MariaDB framing is decoded or rewritten by this proxy.
module Validation.WireProxy (withWireProxy) where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.IORef
import qualified Data.ByteString as B
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NS
import System.Timeout
import Database.MySQL.Base (ConnectInfo(..))

-- | Counters are (bytes sent to MariaDB, bytes received from MariaDB). Updates
-- happen before forwarding, so a fully consumed reply has already been charged.
-- The proxy accepts one connection and joins every worker during cleanup.
withWireProxy :: ConnectInfo -> (ConnectInfo -> IO (Integer,Integer) -> IO a) -> IO a
withWireProxy ci action = bracket listener N.close $ \server -> do
    N.SockAddrInet port _ <- N.getSocketName server
    counters <- newIORef (0,0)
    finished <- newEmptyMVar
    let serve = bracket (fst <$> N.accept server) N.close $ \client -> do
            addresses <- N.getAddrInfo (Just N.defaultHints {N.addrSocketType=N.Stream})
                (Just (ciHost ci)) (Just (show (ciPort ci)))
            address <- case addresses of first:_ -> pure first; [] -> fail "proxy backend address unavailable"
            bracket (N.socket (N.addrFamily address) N.Stream N.defaultProtocol) N.close $ \backend -> do
                N.connect backend (N.addrAddress address)
                done <- newEmptyMVar
                let forward upstream from to = do
                        bytes <- NS.recv from 32768
                        unless (B.null bytes) $ do
                            atomicModifyIORef' counters $ \(sent,received) ->
                                let size = toInteger (B.length bytes)
                                in (if upstream then (sent+size,received) else (sent,received+size),())
                            NS.sendAll to bytes
                            forward upstream from to
                mask $ \restore -> do
                    firstDone <- newEmptyMVar
                    secondDone <- newEmptyMVar
                    first <- forkFinally (restore (forward True client backend))
                        (\_ -> putMVar firstDone () >> void (tryPutMVar done ()))
                    second <- forkFinally (restore (forward False backend client))
                        (\_ -> putMVar secondDone () >> void (tryPutMVar done ())) `onException` killThread first
                    let cleanup = do
                            killThread first
                            killThread second
                            joined <- timeout 1000000 (takeMVar firstDone >> takeMVar secondDone)
                            when (joined == Nothing) (fail "proxy forwarding workers did not finish")
                    restore (takeMVar done) `finally` cleanup
        stop worker = do
            killThread worker
            joined <- timeout 2000000 (takeMVar finished)
            when (joined == Nothing) (fail "proxy server did not finish")
    bracket (forkFinally serve (const (putMVar finished ()))) stop $ \_ ->
        action ci {ciHost="127.0.0.1",ciPort=port} (readIORef counters)
  where
    listener = bracketOnError (N.socket N.AF_INET N.Stream N.defaultProtocol) N.close $ \sock -> do
        N.setSocketOption sock N.ReuseAddr 1
        N.bind sock (N.SockAddrInet 0 (N.tupleToHostAddress (127,0,0,1)))
        N.listen sock 1
        pure sock
