{-# LANGUAGE ScopedTypeVariables #-}
-- | Regressions from the independent Stage 6 review. Cancellation tests keep
-- statements alive beyond their cursors; CDC tests use disposable semisync
-- servers and independently inspect their acknowledged-transaction counters.
module Validation.Stage6Review (cases) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import qualified Data.Binary as Binary
import Data.Bits
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.Maybe (isJust)
import Database.MySQL.Base
import Database.MySQL.BinLog
import qualified Database.MySQL.Connection as C
import qualified System.IO.Streams as S
import System.Environment (getExecutablePath, lookupEnv)
import System.Process (callProcess)
import System.Timeout
import Validation.Common
import Validation.FaultTransport (scripted)

cases :: [Case]
cases =
    [ review ("cursor-repeated-cancellation-" ++ name) (repeatedCancellation streamed)
    | (name,streamed) <- [("scalar",False),("streamed",True)]
    ] ++
    [ review ("compressed-cdc-" ++ name) (liveAcknowledgements name mode resume)
    | (name,mode,resume) <- [("manual",AcknowledgeManually,False),
                            ("on-read",AcknowledgeOnRead,False),
                            ("resume",AcknowledgeManually,True)]
    ] ++
    [ review "compressed-ack-preserves-buffered-reply" bufferedReply
    , review "heap-buffering-negative-control" $ do
        binary <- getExecutablePath
        callProcess "python3" ["validation/stage6_benchmarks.py","--verify-heap-control",binary]
    ]
  where review name = Case ("stage6.review-" ++ name) "stage6"

repeatedCancellation :: Bool -> IO ()
repeatedCancellation streamed = replicateM_ 20 $ do
    let field = ColumnDef "" "" "" "n" "" 63 20 mySQLTypeLongLong 0 0
        parameters = if streamed then 1 else 0 :: Int
        ending = putToPacket 3 (putWord8 254 >> putWord8 0 >> putWord8 0 >> putWord16le 66 >> putWord16le 0)
        prepare = putToPacket 1 (putWord8 0 >> putWord32le 9 >> putWord16le 1 >>
            putWord16le (fromIntegral parameters) >> putWord8 0 >> putWord16le 0)
    (conn,_,closed) <- scripted defaultConnectionOptions
        ([prepare] ++ [encodeToPacket (fromIntegral n) field | n <- [2..2+parameters]] ++
         [putToPacket 1 (putWord8 1),encodeToPacket 2 field,ending,encodeToPacket 1 (OK 0 0 2 0)])
    writeIORef (C.connectionCapabilities conn) (bit 24)
    statement <- prepareStatement conn (if streamed then "SELECT ?" else "SELECT 1")
    source <- S.fromList ["abc"]
    started <- newEmptyMVar
    blocked <- newEmptyMVar
    done <- newEmptyMVar
    let body _ = putMVar started () >> takeMVar blocked
        action = if streamed then withCursorStream statement [PreparedBytes source] body else withCursor statement [] body
    bracket (forkFinally action (putMVar done)) killThread $ \worker -> do
        takeMVar started
        -- The second cancellation is pending as the body exception enters
        -- cleanup. It must propagate after protected transport retirement.
        throwTo worker ThreadKilled
        throwTo worker ThreadKilled
        outcome <- timeout 1000000 (takeMVar done) >>= maybe (fail "cursor worker did not finish") pure
        case outcome of
            Left err -> assert (isJust (fromException err :: Maybe AsyncException)) "cancellation identity lost"
            Right () -> fail "cursor cancellation disappeared"
        status <- connectionStatus conn
        assert (status `elem` [Ready,Broken]) ("cursor lease survived cancellation: " ++ show status)
        when (status == Broken) (equal "retirement closes once" 1 =<< closed)
    close conn

-- Independent compressed headers. The first frame intentionally contains two
-- replies; an ACK between reads must not discard the second buffered packet.
bufferedReply :: IO ()
bufferedReply = do
    let raw n = Binary.encode (encodeToPacket n (OK 0 0 2 0))
        frame n payload = runPut $ do
            let size = L.length payload
            mapM_ (putWord8 . fromIntegral . shiftR size) [0,8,16]
            putWord8 n
            mapM_ putWord8 [0,0,0]
            putLazyByteString payload
    input <- S.fromList (map L.toStrict [frame 7 (raw 4 <> raw 5),frame 1 (raw 1)])
    sent <- newIORef []
    conn <- C.newTransportConnection defaultConnectionOptions {enableCompression=True} input
        (\bytes -> modifyIORef' sent (bytes:)) (pure ())
    writeIORef (C.connectionCapabilities conn) (bit 5)
    C.connectionCompressionStart conn
    C.connectionCompressionAllowReplicationResets conn
    C.setExchangeSequence conn 256
    equal "first reply" 4 . pSeqN =<< C.readConnPacket conn
    C.connectionCompressionReset conn
    C.mysqlWrite conn (putToPacket 0 (putWord8 239 >> putWord64le 100 >> putByteString "bin.1"))
    equal "buffered reply survives ACK" 5 . pSeqN =<< C.readConnPacket conn
    equal "server reset accepted only under replication policy" 1 . pSeqN =<< C.readConnPacket conn
    frames <- readIORef sent
    case frames of
        [packet] -> equal "ACK compressed sequence starts at zero" 0 (L.index packet 3)
        _ -> fail "expected exactly one ACK frame"
    close conn

liveAcknowledgements :: String -> AcknowledgementMode -> Bool -> IO ()
liveAcknowledgements name mode resume = do
    socket <- lookupEnv "MB_CDC_SOCKET"
    case socket of
        Nothing -> do
            binary <- getExecutablePath
            callProcess "python3" ["validation/cdc_fixture.py",binary,"case","stage6.review-compressed-cdc-" ++ name]
        Just path -> do
            let info = defaultConnectInfo {ciUser="root",ciPassword="",ciDatabase="cdc_validation"}
                open = connectUnixSocket path info
                compressed = connectUnixSocketWithOptions defaultConnectionOptions {enableCompression=True} path info
                options start = (defaultCDCOptions start) {cdcAcknowledgements=mode}
                consume stream = do
                    rowsSeen <- newIORef (0::Int)
                    let next = do
                            event <- S.read (cdcEvents stream) >>= maybe (fail "EOF before commit") pure
                            case cdcEventPayload event of CDCWrite _ _ -> modifyIORef' rowsSeen (+1); _ -> pure ()
                            maybe next pure (cdcEventCheckpoint event)
                    token <- timeout 2000000 next >>= maybe (fail "no semisync transaction") pure
                    equal "one complete replicated row" 1 =<< readIORef rowsSeen
                    pure token
                insert stream n = do
                    done <- newEmptyMVar
                    bracket (forkFinally (withConnect open (\writer -> exec writer ("INSERT INTO changes VALUES(" ++ show n ++ ")")))
                        (putMVar done)) killThread $ \_ -> do
                            token <- consume stream
                            when (mode == AcknowledgeManually) $ do
                                pending <- tryReadMVar done
                                assert (not (isJust pending)) "writer completed before explicit acknowledgement"
                                cdcAcknowledge stream token
                                cdcAcknowledge stream token -- Idempotence must not disturb either sequence.
                            result <- timeout 2000000 (takeMVar done) >>= maybe (fail "writer did not resume after ACK") pure
                            either throwIO pure result
                            pure token
                initial source = getLastBinLogTracker source >>= maybe (fail "missing fixture binlog") (pure . FromBinLog)
            if resume then do
                saved <- newIORef Nothing
                forM_ [1..3::Int] $ \n -> withConnect compressed $ \source -> do
                    prior <- readIORef saved
                    start <- maybe (initial source) (pure . resumeFromCheckpoint) prior
                    stream <- openCDC source 610128 (options start)
                    token <- insert stream n
                    writeIORef saved (Just token)
                    cdcClose stream
              else if mode == AcknowledgeOnRead then withConnect compressed $ \source -> do
                -- On-read acknowledgement is intentionally confined to the
                -- legacy packet API; openCDC requires explicit durability.
                tracker <- getLastBinLogTracker source >>= maybe (fail "missing fixture binlog") pure
                (_,_,packets) <- dumpBinLog source 610128 tracker True
                let nextCommit = do
                        event <- S.read packets >>= maybe (fail "EOF before legacy commit") pure
                        unless (blEventType event == BINLOG_XID_EVENT) nextCommit
                forM_ [1..3::Int] $ \n -> do
                    done <- newEmptyMVar
                    bracket (forkFinally (withConnect open (\writer -> exec writer ("INSERT INTO changes VALUES(" ++ show n ++ ")")))
                        (putMVar done)) killThread $ \_ -> do
                            void (timeout 2000000 nextCommit >>= maybe (fail "no legacy commit") pure)
                            result <- timeout 2000000 (takeMVar done) >>= maybe (fail "legacy ACK did not release writer") pure
                            either throwIO pure result
              else withConnect compressed $ \source -> do
                start <- initial source
                stream <- openCDC source 610128 (options start)
                forM_ [1..3::Int] (void . insert stream)
                cdcClose stream
            withConnect open $ \observer -> do
                equal "three stored rows" 3 =<< scalarInt observer "SELECT COUNT(*) FROM changes"
                equal "stored values intact" 6 =<< scalarInt observer "SELECT SUM(id) FROM changes"
                (_,values) <- query_ observer "SHOW GLOBAL STATUS WHERE Variable_name IN ('Rpl_semi_sync_master_yes_tx','Rpl_semi_sync_master_no_tx')"
                statuses <- S.toList values
                equal "all commits acknowledged; no timeout fallback"
                    [[MySQLText "Rpl_semi_sync_master_no_tx",MySQLText "0"],
                     [MySQLText "Rpl_semi_sync_master_yes_tx",MySQLText "3"]] statuses
