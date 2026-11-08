{-# LANGUAGE ScopedTypeVariables #-}
-- | Follow-up regressions encode independent server-format literals and use
-- disposable MariaDB instances for temporal values, origin changes and DDL.
module Validation.Stage5Review (cases) where

import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.List (intercalate)
import Data.Word
import Database.MySQL.Base
import Database.MySQL.BinLog
import qualified Database.MySQL.Connection as C
import qualified System.IO.Streams as S
import Validation.Common
import Validation.Stage5 (ackFixture, decode, fixtureFormat, packet,
    sourceGtids, tableMap, transaction, withIsolated)

review :: String -> IO () -> Case
review name = Case ("stage5.review-" ++ name) "stage5"

-- MariaDB stores fractional seconds in pairs of decimal digits. Odd precision
-- still uses the same byte scale as the following even precision (compat56.cc).
fractions :: [(Word8,[Word8],Word32)]
fractions = [(0,[],0),(1,[10],100000),(2,[12],120000),
    (3,[0x04,0xce],123000),(4,[0x04,0xd2],123400),
    (5,[0x01,0xe2,0x3a],123450),(6,[0x01,0xe2,0x40],123456)]

field :: BinLogMeta -> [Word8] -> IO BinLogValue
field meta bytes = getFromBinLogPacket (getBinLogField meta)
    (packet BINLOG_UNKNOWN_EVENT (putByteString (B.pack bytes)))

firstEvent :: L.ByteString -> IO (Maybe CDCEvent)
firstEvent body = do
    input <- S.fromList [(packet MARIADB_GTID_EVENT (pure ())) {blBody=body}]
    empty <- either fail pure (gtidSet [])
    (events,_) <- newCDCDecoder defaultDecodeLimits (Just empty) fixtureFormat "bin.1" input
    S.read events

gtidPrefix :: Word8 -> Put
gtidPrefix flags = putWord64le 1 >> putWord32le 0 >> putWord8 flags

expectUnsupported :: IO a -> IO ()
expectUnsupported action = do
    result <- try action
    case result of
        Left (CDCUnsupportedFeature _) -> pure ()
        Left other -> throwIO (other :: CDCError)
        Right _ -> fail "unsafe GTID extension was accepted"

cases :: [Case]
cases = concat
    [ [review ("timestamp-fsp-" ++ show precision) $ equal "timestamp microseconds"
            (BinLogTimeStamp2 0x01020304 micros) =<< field (BINLOG_TYPE_TIMESTAMP2 precision)
                ([1,2,3,4] ++ bytes),
       review ("datetime-fsp-" ++ show precision) $ equal "datetime microseconds"
            (BinLogDateTime2 2026 1 2 3 4 5 micros) =<< field (BINLOG_TYPE_DATETIME2 precision)
                ([0x99,0xb8,0xc4,0x31,0x05] ++ bytes),
       review ("time-positive-fsp-" ++ show precision) $ equal "positive time"
            (BinLogTime2 1 1 2 3 micros) =<< field (BINLOG_TYPE_TIME2 precision)
                ([0x80,0x10,0x83] ++ bytes),
       review ("time-negative-fsp-" ++ show precision) $ do
            -- A nonzero fraction borrows one unit from the integer part. The
            -- zero-fraction encoding below deliberately has no such borrow.
            let prefix = if micros == 0 then [0x7f,0xef,0x7d] else [0x7f,0xef,0x7c]
            equal "negative time" (BinLogTime2 0 1 2 3 micros) =<<
                field (BINLOG_TYPE_TIME2 precision) (prefix ++ negative),
       review ("time-negative-whole-fsp-" ++ show precision) $ equal "negative whole seconds"
            (BinLogTime2 0 1 2 3 0) =<< field (BINLOG_TYPE_TIME2 precision)
                ([0x7f,0xef,0x7d] ++ replicate (length bytes) 0)]
    | ((precision,bytes,micros),negative) <- zip fractions
        [[],[0xf6],[0xf4],[0xfb,0x32],[0xfb,0x2e],[0xfe,0x1d,0xc6],[0xfe,0x1d,0xc0]]] ++
    [ review "gtid-list-multiple-origins" $ do
        let history=packet MARIADB_GTID_LIST_EVENT $ do
                putWord32le 2
                putWord32le 0 >> putWord32le 11 >> putWord64le 7
                putWord32le 0 >> putWord32le 12 >> putWord64le 8
        events <- decode defaultDecodeLimits [history]
        case map cdcEventPayload events of
            [CDCGtidList value] -> do
                equal "all origin history retained" [Gtid 0 11 7,Gtid 0 12 8] (gtidListEntries value)
                equal "history flags" 0 (gtidListFlags value)
            _ -> fail "missing GTID history"
    , review "gtid-list-flags-preserved" $ do
        events <- decode defaultDecodeLimits [packet MARIADB_GTID_LIST_EVENT (putWord32le 0x20000000)]
        equal "ignored-GTID flag preserved" [CDCGtidList (GtidList 0x20000000 [])] (map cdcEventPayload events)
    , review "gtid-list-duplicate-pair-rejected" $ expectRejection $ decode defaultDecodeLimits
        [packet MARIADB_GTID_LIST_EVENT $ do
            putWord32le 2
            replicateM_ 2 (putWord32le 0 >> putWord32le 11 >> putWord64le 7)]
    , review "gtid-list-entry-budget" $ expectRejection $ decode defaultDecodeLimits
        [packet MARIADB_GTID_LIST_EVENT (putWord32le 4097)]
    , review "gtid-short-header" $ forM_ [13..18] $ \size ->
        expectRejection (firstEvent (L.take size (runPut (gtidPrefix 4 >> putWord64le 0))))
    , review "gtid-truncated-engine-extension" $ expectRejection $ firstEvent $ runPut $ do
        gtidPrefix 2 >> putWord64le 3 >> putWord8 1
    , review "gtid-truncated-thread-extension" $ expectRejection $ firstEvent $ runPut $ do
        gtidPrefix 2 >> putWord64le 3 >> putWord8 16 >> putWord8 1
    , review "gtid-known-extensions" $ do
        value <- firstEvent $ runPut $ do
            gtidPrefix 2 >> putWord64le 3 >> putWord8 17 >> putWord8 1 >> putWord32le 9
        assert (maybe False (const True) value) "valid commit/engine/thread extensions rejected"
    , review "gtid-two-phase-alter-rejected" $ forM_ [2,4,8] $ \flags ->
        expectUnsupported $ firstEvent $ runPut $ do
            gtidPrefix 1 >> putWord8 flags
            when (flags .&. 12 /= 0) (putWord64le 1)
            putByteString (B.replicate 5 0)
    , review "gtid-unknown-extension-rejected" $ expectUnsupported $ firstEvent $ runPut $ do
        gtidPrefix 1 >> putWord8 32 >> putByteString (B.replicate 5 0)
    , review "invalid-temporal-fraction-rejected" $ do
        expectRejection (field (BINLOG_TYPE_TIMESTAMP2 1) [1,2,3,4,11])
        expectRejection (field (BINLOG_TYPE_TIMESTAMP2 6) [1,2,3,4,255,255,255])
        expectRejection (field (BINLOG_TYPE_DATETIME2 4) [0x99,0xb8,0xc4,0x31,0x05,0x27,0x10])
        expectRejection (field (BINLOG_TYPE_TIME2 2) [0x80,0x10,0x83,255])
    , review "time-negative-fraction-only" $ equal "negative subsecond time"
        (BinLogTime2 0 0 0 0 1) =<< field (BINLOG_TYPE_TIME2 6) [0x7f,0xff,0xff,255,255,255]
    , review "large-query-control-prefix" $ forM_ ["BEGIN","COMMIT","ROLLBACK"] $ \prefix -> do
        let statement=B.replicate 16384 32 <> prefix <> " " <> B.replicate (1024*1024) 120
            query=packet BINLOG_QUERY_EVENT $ do
                putWord32le 0 >> putWord32le 0 >> putWord8 0
                putWord16le 0 >> putWord16le 0 >> putWord8 0 >> putByteString statement
        case transaction 1 7 of
            [begin,_,_,commit] -> do
                events <- decode defaultDecodeLimits [begin,query,commit]
                equal "prefix is not a transaction boundary" [False,False,True]
                    (map (maybe False (const True) . cdcEventCheckpoint) events)
                case map cdcEventPayload events of
                    [CDCBegin _ _,CDCQuery value,CDCCommit _] ->
                        equal "complete query is retained" (Query (L.fromStrict statement)) (qQuery value)
                    _ -> fail "large query was misclassified"
            _ -> fail "invalid transaction fixture"
    , review "sparse-write-value-budget" (sparseRows BINLOG_WRITE_ROWS_EVENTv1)
    , review "sparse-delete-value-budget" (sparseRows BINLOG_DELETE_ROWS_EVENTv1)
    , review "sparse-update-value-budget" (sparseRows BINLOG_UPDATE_ROWS_EVENTv1)
    , review "row-count-budget-preserved" $ expectRejection $ decode defaultDecodeLimits
        [tableMap 1 [3], packet BINLOG_WRITE_ROWS_EVENTv1 $ do
            putWord48le 1 >> putWord16le 0 >> putLenEncInt 1 >> putWord8 1
            replicateM_ 65537 (putWord8 1)]
    , review "decoded-value-budget-preserved" $ expectRejection $ decode defaultDecodeLimits
        [tableMap 1 (replicate 64 3),packet BINLOG_WRITE_ROWS_EVENTv1 $ do
            putWord48le 1 >> putWord16le 0 >> putLenEncInt 64 >> putWord64le maxBound
            replicateM_ 16385 (putWord64le maxBound)]
    , review "event-limit-max-bound" $ do
        (conn,_,_) <- ackFixture (transaction 1 7)
        stream <- openCDC conn 610126 (defaultCDCOptions (FromBinLog (BinLogTracker "bin.000001" 4)))
            {cdcAcknowledgements=AcknowledgeManually,
             cdcDecodeLimits=defaultDecodeLimits {maxExpandedEventBytes=maxBound}}
        let untilCheckpoint = do
                event <- S.read (cdcEvents stream) >>= maybe (fail "EOF before checkpoint") pure
                maybe untilCheckpoint (const (pure ())) (cdcEventCheckpoint event)
        untilCheckpoint `finally` cdcClose stream
    , review "wire-limit-stops-continuations" $ do
        (original,_,closed) <- ackFixture (transaction 1 7)
        count <- newIORef (0::Int)
        let originalInput=C.mysqlRead original
        input <- S.makeInputStream $ do
            value <- S.read originalInput
            modifyIORef' count (+1)
            readCount <- readIORef count
            -- Discovery has 6 packets, SET has one, then ROTATE and FDE.
            -- The first oversized physical fragment must fail without asking
            -- for another continuation. Its body is irrelevant to this check.
            pure (if readCount == 10 then Just (Packet 16777215 1 "") else value)
        let conn=original {C.mysqlRead=input}
        stream <- openCDC conn 610126 (defaultCDCOptions (FromBinLog (BinLogTracker "bin.000001" 4)))
            {cdcAcknowledgements=AcknowledgeManually,
             cdcDecodeLimits=defaultDecodeLimits {maxExpandedEventBytes=1024}}
        expectRejection (S.read (cdcEvents stream))
        equal "oversized fragment stopped before another read" 10 =<< readIORef count
        equal "oversized stream retired" Broken =<< connectionStatus conn
        equal "transport released once" 1 =<< closed
    , review "live-temporal-values" liveTemporal
    , review "live-origin-change-rotation" liveOrigins
    , review "live-two-phase-alter-rejected" liveTwoPhaseAlter
    ]

sparseRows :: BinLogEventType -> IO ()
sparseRows typ = do
    let update=typ == BINLOG_UPDATE_ROWS_EVENTv1
        image=packet typ $ do
            putWord48le 1 >> putWord16le 0 >> putLenEncInt 4096
            putWord8 1 >> putByteString (B.replicate 511 0)
            when update (putByteString (B.replicate 511 0) >> putWord8 128)
            replicateM_ 1000 $ do
                putWord8 0 >> putWord32le 7
                when update (putWord8 0 >> putWord32le 8)
    events <- decode defaultDecodeLimits [tableMap 1 (replicate 4096 3),image]
    case map cdcEventPayload events of
        [CDCWrite _ value] -> equal "all sparse inserts" (replicate 1000 [BinLogLong 7]) (writeRowData value)
        [CDCDelete _ value] -> equal "all sparse deletes" (replicate 1000 [BinLogLong 7]) (deleteRowData value)
        [CDCUpdate _ value] -> equal "all sparse updates" (replicate 1000 ([BinLogLong 7],[BinLogLong 8])) (updateRowData value)
        _ -> fail "missing sparse images"

-- A real rotation writes the full binlog history, including an older origin in
-- the same domain. That list is not a one-entry-per-domain connect state.
liveOrigins :: IO ()
liveOrigins = withIsolated "stage5.review-live-origin-change-rotation" $ \open -> withConnect open $ \writer -> do
    exec writer "SET GLOBAL rpl_semi_sync_master_enabled=0"
    start <- sourceGtids writer
    exec writer "INSERT INTO changes VALUES(1)"
    exec writer "SET SESSION server_id=610131"
    exec writer "INSERT INTO changes VALUES(2)"
    exec writer "FLUSH LOGS"
    exec writer "INSERT INTO changes VALUES(3)"
    withConnect open $ \source -> do
        stream <- openCDC source 610132 (defaultCDCOptions (FromGtid start)) {cdcNonBlocking=True}
        events <- S.toList (cdcEvents stream)
        equal "all origin changes delivered" [[BinLogLong 1],[BinLogLong 2],[BinLogLong 3]]
            (concat [writeRowData row | event <- events,CDCWrite _ row <- [cdcEventPayload event]])
        let histories=[gtidListEntries value | event <- events,CDCGtidList value <- [cdcEventPayload event]]
        assert (any (\entries -> any ((==610129) . gtidServerId) entries
                    && any ((==610131) . gtidServerId) entries) histories)
            "rotation did not retain both origin histories"

liveTemporal :: IO ()
liveTemporal = withIsolated "stage5.review-live-temporal-values" $ \open -> withConnect open $ \writer -> do
    exec writer "SET GLOBAL rpl_semi_sync_master_enabled=0"
    let columns = concat [["t" ++ show p ++ " TIME(" ++ show p ++ ")",
                          "d" ++ show p ++ " DATETIME(" ++ show p ++ ")",
                          "s" ++ show p ++ " TIMESTAMP(" ++ show p ++ ")"] | (p,_,_) <- fractions]
    exec writer ("CREATE TABLE temporal_values(id INT," ++ intercalate "," columns ++ ")")
    seconds <- fromInteger <$> scalarInt writer "SELECT UNIX_TIMESTAMP('2026-01-02 03:04:05')"
    start <- sourceGtids writer
    forM_ [(1,False,False),(2,True,False),(3,True,True)] $ \(ident,negative,whole) -> do
        let quote text="'" ++ text ++ "'"
            suffix p | p == 0 = ""
                     | otherwise = "." ++ if whole then replicate (fromIntegral p) '0' else take (fromIntegral p) "123456"
            values = concat [[quote ((if negative then "-" else "") ++ "01:02:03" ++ suffix p),
                              quote ("2026-01-02 03:04:05" ++ suffix p),
                              quote ("2026-01-02 03:04:05" ++ suffix p)] | (p,_,_) <- fractions]
        exec writer ("INSERT INTO temporal_values VALUES(" ++ intercalate "," (show (ident::Int):values) ++ ")")
    withConnect open $ \source -> do
        stream <- openCDC source 610132 (defaultCDCOptions (FromGtid start)) {cdcNonBlocking=True}
        events <- S.toList (cdcEvents stream)
        let expected = [BinLogLong ident : concat
                [[BinLogTime2 (if negative then 0 else 1) 1 2 3 micro,
                  BinLogDateTime2 2026 1 2 3 4 5 micro,BinLogTimeStamp2 seconds micro]
                | (_,_,fraction) <- fractions,let micro=if whole then 0 else fraction]
                | (ident,negative,whole) <- [(1,False,False),(2,True,False),(3,True,True)]]
        equal "real temporal rows at every precision" expected
            (concat [writeRowData row | event <- events,CDCWrite _ row <- [cdcEventPayload event]])

liveTwoPhaseAlter :: IO ()
liveTwoPhaseAlter = withIsolated "stage5.review-live-two-phase-alter-rejected" $ \open -> withConnect open $ \writer -> do
    exec writer "SET GLOBAL rpl_semi_sync_master_enabled=0"
    start <- sourceGtids writer
    exec writer "SET SESSION binlog_alter_two_phase=ON"
    exec writer "ALTER TABLE changes ADD n INT, ALGORITHM=COPY"
    withConnect open $ \source -> do
        stream <- openCDC source 610132 (defaultCDCOptions (FromGtid start)) {cdcNonBlocking=True}
        expectUnsupported (S.toList (cdcEvents stream))
        equal "unsupported DDL retires source" Broken =<< connectionStatus source
