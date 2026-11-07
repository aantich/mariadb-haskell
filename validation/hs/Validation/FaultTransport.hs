{-# LANGUAGE ScopedTypeVariables #-}
module Validation.FaultTransport where
import Data.Word (Word8)
import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NS
import System.Timeout
import Data.IORef
import qualified System.IO.Streams as S
import Database.MySQL.Base
import qualified Database.MySQL.Connection as C

-- | Deterministic physical packets plus observable writes/finalizer count. This
-- deliberately bypasses authentication while retaining the real framing and
-- ownership guards; live loopback tests below cover actual socket behavior.
scripted :: ConnectionOptions -> [Packet] -> IO (MySQLConn,IO [Packet],IO Int)
scripted options packets = do
    input <- S.fromList packets
    sent <- newIORef []
    closed <- newIORef 0
    conn <- C.newConnection options input (\p -> modifyIORef' sent (p:)) (modifyIORef' closed (+1))
    pure (conn,reverse <$> readIORef sent,readIORef closed)

okPacket :: Word8 -> Packet
okPacket seqN = encodeToPacket seqN (OK 0 0 2 0)
textTranscript :: [Packet]
textTranscript =
    [putToPacket 1 (putLenEncInt 1)
    ,encodeToPacket 2 (ColumnDef "" "" "" "n" "" 63 11 mySQLTypeLong 0 0)
    ,encodeToPacket 3 (EOF 0 2)
    ,putToPacket 4 (putLenEncBytes "7")
    ,encodeToPacket 5 (EOF 0 2)]

-- | Real loopback faults armed by command bytes rather than timing sleeps. A
-- dropped COMMIT reply is read from the backend before disconnecting the client,
-- allowing a separate connection to check durability without replaying COMMIT.
data ProxyMode = FragmentTraffic Int | DropCommitReply | DropTargetReply deriving Show

data ProxyStats = ProxyStats { proxyCommits :: Int, proxyPackets :: Int, proxyCommands :: Int } deriving Show

withFaultProxy :: ConnectInfo -> ProxyMode -> (ConnectInfo -> IO ProxyStats -> IO a) -> IO a
withFaultProxy ci mode action = N.withSocketsDo $ bracket listener N.close $ \server -> do
    case mode of
        FragmentTraffic size | size <= 0 -> fail "proxy fragment size must be positive"
        _ -> pure ()
    N.SockAddrInet port _ <- N.getSocketName server
    stats <- newIORef (ProxyStats 0 0 0)
    finished <- newEmptyMVar
    let stop worker = do
            killThread worker
            joined <- timeout 1000000 (takeMVar finished)
            when (joined==Nothing) (fail "proxy worker did not terminate")
    bracket (forkFinally (serve server stats) (const (putMVar finished ()))) stop $ \_ ->
        action ci {ciHost="127.0.0.1",ciPort=port} (readIORef stats)
  where
    listener = bracketOnError (N.socket N.AF_INET N.Stream N.defaultProtocol) N.close $ \sock -> do
        N.setSocketOption sock N.ReuseAddr 1
        N.bind sock (N.SockAddrInet 0 (N.tupleToHostAddress (127,0,0,1)))
        N.listen sock 1
        pure sock
    serve listenerSocket stats = bracket (fst <$> N.accept listenerSocket) N.close $ \client -> do
        addresses <- N.getAddrInfo (Just N.defaultHints {N.addrSocketType=N.Stream}) (Just (ciHost ci)) (Just (show (ciPort ci)))
        address <- case addresses of
            firstAddress:_ -> pure firstAddress
            [] -> fail "proxy backend address unavailable"
        bracket (N.socket (N.addrFamily address) N.Stream N.defaultProtocol) N.close $ \backend -> do
            N.connect backend (N.addrAddress address)
            armed <- newIORef False
            done <- newEmptyMVar
            let send sock packet = case mode of
                    FragmentTraffic size -> chunks sock size packet
                    _ -> NS.sendAll sock packet
                upstream = forever $ do
                    (header,body) <- receivePacket client
                    let queryBody=if not (B.null body) && B.head body==3 then BC.map toUpperASCII (B.tail body) else ""
                        isCommit=queryBody=="COMMIT"
                        target="MB_STAGE1_FAULT" `B.isInfixOf` queryBody
                    when (not (B.null body) && B.head body `elem` [3,14,22,23,25,26,250])
                        (updateStats stats (\x -> x {proxyCommands=proxyCommands x+1}))
                    when isCommit (updateStats stats (\x -> x {proxyCommits=proxyCommits x+1}))
                    case mode of
                        DropCommitReply -> when isCommit (writeIORef armed True)
                        DropTargetReply -> when target (writeIORef armed True)
                        _ -> pure ()
                    send backend (header<>body)
                downstream = do
                    (header,body) <- receivePacket backend
                    dropReply <- readIORef armed
                    unless dropReply $ do
                        updateStats stats (\x -> x {proxyPackets=proxyPackets x+1})
                        send client (header<>body)
                        downstream
            -- Publish both worker finalizers before allowing cancellation of
            -- the parent. Otherwise cancellation between forks can leak one.
            mask $ \restore -> do
                first <- forkFinally (restore upstream) (const (void (tryPutMVar done ())))
                second <- forkFinally (restore downstream) (const (void (tryPutMVar done ())))
                    `onException` killThread first
                restore (takeMVar done) `finally` (killThread first >> killThread second)
    -- Upstream/downstream update different fields of the same record. Atomic
    -- updates avoid a packet counter overwriting a concurrent command count.
    updateStats ref change = atomicModifyIORef' ref (\stats -> (change stats, ()))
    receivePacket sock = do
        header <- exactly sock 4
        let size=fromIntegral (B.index header 0) .|. (fromIntegral (B.index header 1) `shiftL` 8) .|. (fromIntegral (B.index header 2) `shiftL` 16)
        body <- exactly sock size
        pure (header,body)
    exactly sock size = loop size []
      where
        loop 0 acc = pure (B.concat (reverse acc))
        loop n acc = do
            part <- NS.recv sock n
            when (B.null part) (throwIO (userError "proxy peer closed"))
            loop (n-B.length part) (part:acc)
    chunks _ _ packet | B.null packet = pure ()
    chunks sock size packet = NS.sendAll sock (B.take size packet) >> chunks sock size (B.drop size packet)
    toUpperASCII ch | ch >= 'a' && ch <= 'z' = toEnum (fromEnum ch-32)
                    | otherwise = ch
