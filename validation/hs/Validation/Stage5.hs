{-# LANGUAGE ScopedTypeVariables #-}
-- | Independent literal events plus real MariaDB transactions. Fixtures encode
-- bytes directly rather than serializing through the decoder under test.
module Validation.Stage5 (cases, gtidResumeFeature, manualAckFeature,
    fixtureFormat, tableMap, writeRow, packet, transaction, decode) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import qualified Codec.Compression.Zlib as Z
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.Maybe (mapMaybe)
import qualified Data.Text.Encoding as TE
import Data.Word
import Database.MySQL.Base
import Database.MySQL.BinLog
import qualified Database.MySQL.Connection as C
import qualified System.IO.Streams as S
import System.Environment (lookupEnv, getExecutablePath)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Process (callProcess)
import System.Timeout
import Validation.Common
import Validation.FaultTransport (scripted, okPacket)

case5 :: String -> IO () -> Case
case5 name = Case ("stage5." ++ name) "stage5"

fixtureFormat :: FormatDescription
fixtureFormat = FormatDescription 4 "12.3.3-MariaDB" 0
    (B.pack [if kind `elem` [30,31,32,169,170,171] then 10 else if kind==172 then 9 else 8 | kind <- [1..172] :: [Int]])

packet :: BinLogEventType -> Put -> BinLogPacket
packet typ body = BinLogPacket 0 typ 610123 (fromIntegral (19 + L.length bytes)) 100 0 bytes False
  where bytes = runPut body

tableMap :: Word64 -> [Word8] -> BinLogPacket
tableMap tid types = packet BINLOG_TABLE_MAP_EVENT $ do
    putWord48le tid >> putWord16le 0
    putWord8 1 >> putByteString "d" >> putWord8 0
    putWord8 1 >> putByteString "t" >> putWord8 0
    putLenEncInt (length types) >> mapM_ putWord8 types
    putLenEncInt 0 >> putByteString (B.replicate ((length types + 7) `div` 8) 0)

writeRow :: Word64 -> Word16 -> Int -> BinLogPacket
writeRow tid flags value = packet BINLOG_WRITE_ROWS_EVENTv1 $ do
    putWord48le tid >> putWord16le flags >> putLenEncInt 1
    putWord8 1 >> putWord8 0 >> putWord32le (fromIntegral value)

gtid :: Word32 -> Word64 -> Word8 -> BinLogPacket
gtid domain sequenceNo flags = packet MARIADB_GTID_EVENT
    (putWord64le sequenceNo >> putWord32le domain >> putWord8 flags)

queryEvent :: B.ByteString -> BinLogPacket
queryEvent statement = packet BINLOG_QUERY_EVENT $ do
    putWord32le 0 >> putWord32le 0 >> putWord8 0 >> putWord16le 0 >> putWord16le 0 >> putWord8 0 >> putByteString statement

transaction :: Word64 -> Int -> [BinLogPacket]
transaction sequenceNo value = [gtid 0 sequenceNo 4, tableMap 1 [3], writeRow 1 1 value,
    packet BINLOG_XID_EVENT (putWord64le sequenceNo)]

emptyGtids :: GtidSet
emptyGtids = either error id (gtidSet [])

decode :: DecodeLimits -> [BinLogPacket] -> IO [CDCEvent]
decode limits events = do
    input <- S.fromList events
    (output, _) <- newCDCDecoder limits (Just emptyGtids) fixtureFormat "bin.000001" input
    S.toList output

wireEvent :: Bool -> BinLogPacket -> Packet
wireEvent crc p = Packet (L.length bytes) 1 bytes
  where
    raw = runPut $ do
        putWord32le (blTimestamp p) >> putWord8 (fromIntegral (fromEnum (blEventType p)))
        putWord32le (blServerId p) >> putWord32le (fromIntegral (19 + L.length (blBody p) + if crc then 4 else 0))
        putWord32le (fromIntegral (blLogPos p)) >> putWord16le (blFlags p) >> putLazyByteString (blBody p)
    bytes = runPut $ putWord8 0 >> putLazyByteString raw >> when crc (putWord32le (binLogCRC32 raw))

writes :: [CDCEvent] -> [[BinLogValue]]
writes events = concat [writeRowData row | event <- events, CDCWrite _ row <- [cdcEventPayload event]]

cases :: [Case]
cases =
    [ case5 "initial-format-budget" $ do
        input <- S.fromList []
        expectRejection (newCDCDecoder defaultDecodeLimits Nothing
            fixtureFormat {fdEventHeaderLenVector=B.replicate 257 8} "bin.1" input)
    , case5 "initial-filename-budget" $ do
        input <- S.fromList []
        expectRejection (newCDCDecoder defaultDecodeLimits Nothing fixtureFormat (B.replicate 513 65) input)
    , case5 "event-id-roundtrip" $ forM_ [0..255] $ \n -> equal "wire event ID" n (fromEnum (toEnum n :: BinLogEventType))
    , case5 "crc32-known-vector" $ equal "IEEE CRC32" 0xcbf43926 (binLogCRC32 "123456789")
    , case5 "crc32-valid" $ do
        result <- getFromPacket (getBinLogPacket True False) (wireEvent True (writeRow 1 0 7))
        equal "validated body" (blBody (writeRow 1 0 7)) (blBody result)
    , case5 "crc32-every-truncation" $ do
        let p = wireEvent True (writeRow 1 0 7)
        forM_ [0..L.length (pBody p)-1] $ \size -> expectRejection
            (getFromPacket (getBinLogPacket True False) p {pBody=L.take size (pBody p)})
    , case5 "wire-trailing-byte" $ do
        let p = wireEvent False (writeRow 1 0 7)
        expectRejection (getFromPacket (getBinLogPacket False False) p {pBody=pBody p <> "x"})
    , case5 "wire-small-event-size" $ expectRejection $ getFromPacket (getBinLogPacket False False)
        (putToPacket 1 (putWord8 0 >> putWord32le 0 >> putWord8 16 >> putWord32le 1 >> putWord32le 18 >> putWord32le 4 >> putWord16le 0))
    , case5 "unknown-critical-rejected" $ expectRejection (decode defaultDecodeLimits [packet (UnrecognizedBinLogEvent 200) (pure ())])
    , case5 "unknown-ignorable-preserved" $ do
        let original=(packet (UnrecognizedBinLogEvent 200) (putByteString "future")) {blFlags=0x80}
        result <- decode defaultDecodeLimits [original]
        equal "unknown bytes retained" [CDCIgnorable original] (map cdcEventPayload result)
    , case5 "table-map-replacement" $ do
        events <- decode defaultDecodeLimits [tableMap 1 [1],tableMap 1 [3],writeRow 1 0 7]
        equal "new schema metadata" [[BinLogLong 7]] (writes events)
    , case5 "table-map-count-limit" $ expectRejection (decode defaultDecodeLimits {maxTableMaps=1} [tableMap 1 [3],tableMap 2 [3]])
    , case5 "table-map-byte-limit" $ expectRejection (decode defaultDecodeLimits {maxTableMapBytes=1} [tableMap 1 [3]])
    , case5 "table-map-replacement-budget" $ do
        events <- decode defaultDecodeLimits {maxTableMaps=1,maxTableMapBytes=1000} [tableMap 1 [3],tableMap 1 [3],writeRow 1 0 7]
        equal "replacement releases metadata" [[BinLogLong 7]] (writes events)
    , case5 "statement-end-invalidates-maps" $ expectRejection (decode defaultDecodeLimits [tableMap 1 [3],writeRow 1 1 7,writeRow 1 0 8])
    , case5 "query-invalidates-maps" $ expectRejection (decode defaultDecodeLimits [tableMap 1 [3],queryEvent "ALTER TABLE t ADD n INT",writeRow 1 0 8])
    , case5 "rotate-invalidates-maps" $ expectRejection (decode defaultDecodeLimits
        [tableMap 1 [3],packet BINLOG_ROTATE_EVENT (putWord64le 4 >> putByteString "bin.000002"),writeRow 1 0 8])
    , case5 "row-post-header-length-rejected" $ do
        input <- S.fromList [tableMap 1 [3],writeRow 1 0 7]
        (events,_) <- newCDCDecoder defaultDecodeLimits (Just emptyGtids)
            fixtureFormat {fdEventHeaderLenVector=B.replicate 172 9} "bin.1" input
        expectRejection (S.toList events)
    , case5 "row-empty-images-rejected" $ expectRejection (decode defaultDecodeLimits
        [tableMap 1 [3],packet BINLOG_WRITE_ROWS_EVENTv1 (putWord48le 1 >> putWord16le 0 >> putLenEncInt 1 >> putWord8 1)])
    , case5 "row-column-count-mismatch" $ expectRejection (decode defaultDecodeLimits [tableMap 1 [3,3],writeRow 1 0 7])
    , case5 "row-extra-header-underflow" $ expectRejection (decode defaultDecodeLimits
        [tableMap 1 [3],packet BINLOG_WRITE_ROWS_EVENTv2 (putWord48le 1 >> putWord16le 0 >> putWord16le 1)])
    , case5 "row-zero-progress" $ expectRejection (decode defaultDecodeLimits
        [tableMap 1 [3],packet BINLOG_WRITE_ROWS_EVENTv1 (putWord48le 1 >> putWord16le 0 >> putLenEncInt 1 >> putWord8 0 >> putWord8 0)])
    , case5 "row-null-unused-bits-allowed" $ do
        let original=writeRow 1 0 7
            bytes=blBody original
            rowWithUnusedBits=original {blBody=L.take 10 bytes <> L.singleton 0xfe <> L.drop 11 bytes}
        events <- decode defaultDecodeLimits [tableMap 1 [3],rowWithUnusedBits]
        equal "server NULL padding is ignored" [[BinLogLong 7]] (writes events)
    , case5 "table-map-optional-metadata" $ do
        let original=tableMap 1 [3]
            withMetadata=original {blBody=blBody original <> runPut (putWord8 238 >> putLenEncBytes "abc")}
        events <- decode defaultDecodeLimits [withMetadata,writeRow 1 0 7]
        case map cdcEventPayload events of
            [CDCWrite table _] -> equal "unknown TLV preserved" [(238,"abc")] (tmOptionalMetadata table)
            _ -> fail "missing optional metadata"
    , case5 "table-map-invalid-optional-length" $ do
        let original=tableMap 1 [3]
        expectRejection (decode defaultDecodeLimits [original {blBody=blBody original <> L.pack [238,10,1,2,3]}])
    , case5 "file-checkpoint-resumes-by-file" $ do
        input <- S.fromList (transaction 1 7)
        (events,_) <- newCDCDecoder defaultDecodeLimits Nothing fixtureFormat "bin.1" input
        output <- S.toList events
        token <- only "file checkpoint" (mapMaybe cdcEventCheckpoint output)
        equal "unknown initial GTIDs are explicit" Nothing (checkpointGtids token)
        equal "resume preserves file origin" (FromBinLog (BinLogTracker "bin.1" 100)) (resumeFromCheckpoint token)
    , case5 "row-padding-bits-rejected" $ expectRejection (decode defaultDecodeLimits
        [tableMap 1 [3],packet BINLOG_WRITE_ROWS_EVENTv1 (putWord48le 1 >> putWord16le 0 >> putLenEncInt 1 >> putWord8 0x81 >> putWord8 0 >> putWord32le 7)])
    , case5 "sparse-update-images" $ do
        let row = packet BINLOG_UPDATE_ROWS_EVENTv1 $ do
                putWord48le 1 >> putWord16le 1 >> putLenEncInt 3
                putWord8 1 >> putWord8 6
                putWord8 0 >> putWord32le 7
                putWord8 1 >> putWord32le 9
        result <- decode defaultDecodeLimits [tableMap 1 [3,3,3],row]
        case map cdcEventPayload result of
            [CDCUpdate _ value] -> do
                equal "omitted differs from NULL" [([BinLogLong 7],[BinLogNull,BinLogLong 9])] (updateRowData value)
                equal "both sparse maps retained" (BitMap (B.pack [1]),BitMap (B.pack [6])) (updatePresentMap value)
            _ -> fail "missing sparse update"
    , case5 "checkpoint-only-after-commit" $ do
        events <- decode defaultDecodeLimits (transaction 1 7)
        equal "only commit checkpoint" [False,False,True] (map (maybe False (const True) . cdcEventCheckpoint) events)
        let tokens = mapMaybe cdcEventCheckpoint events
        equal "completed GTID" [Just [Gtid 0 610123 1]] (map (fmap gtidSetEntries . checkpointGtids) tokens)
    , case5 "checkpoint-rollback-boundary" $ do
        events <- decode defaultDecodeLimits [gtid 0 1 4,queryEvent "BEGIN",queryEvent "ROLLBACK"]
        equal "rollback emitted" CDCRollback (cdcEventPayload (last events))
        equal "one complete boundary" 1 (length (mapMaybe cdcEventCheckpoint events))
    , case5 "checkpoint-standalone-ddl" $ do
        events <- decode defaultDecodeLimits [gtid 0 1 1,queryEvent "CREATE TABLE t(n INT)"]
        equal "DDL boundary" 1 (length (mapMaybe cdcEventCheckpoint events))
    , case5 "checkpoint-standalone-rows" $ do
        events <- decode defaultDecodeLimits [gtid 0 1 1,tableMap 1 [3],writeRow 1 1 7]
        equal "nontransactional statement boundary" 1 (length (mapMaybe cdcEventCheckpoint events))
    , case5 "checkpoint-cross-domain" $ do
        events <- decode defaultDecodeLimits (transaction 1 7 ++ [gtid 2 9 4,packet BINLOG_XID_EVENT (putWord64le 2)])
        equal "both completed domains" (Just [Gtid 0 610123 1,Gtid 2 610123 9])
            (fmap gtidSetEntries (checkpointGtids (last (mapMaybe cdcEventCheckpoint events))))
    , case5 "checkpoint-incomplete-eof" $ expectRejection (decode defaultDecodeLimits [gtid 0 1 4,tableMap 1 [3],writeRow 1 1 7])
    , case5 "checkpoint-nested-gtid" $ expectRejection (decode defaultDecodeLimits [gtid 0 1 4,gtid 0 2 4])
    , case5 "checkpoint-nonadvancing-gtid" $ expectRejection (decode defaultDecodeLimits (transaction 2 7 ++ transaction 1 8))
    , case5 "checkpoint-xa-rejected" $ expectRejection (decode defaultDecodeLimits [gtid 0 1 64])
    , case5 "checkpoint-stream-identity" $ do
        first <- decode defaultDecodeLimits (transaction 1 7)
        second <- decode defaultDecodeLimits (transaction 1 7)
        a <- only "first checkpoint" (mapMaybe cdcEventCheckpoint first)
        b <- only "second checkpoint" (mapMaybe cdcEventCheckpoint second)
        assert (not (validCheckpoint a b)) "foreign token rejected"
    , case5 "gtid-parser-valid" $ do
        entries <- either fail pure (parseGtidSet "2-9-18446744073709551615,0-1-7")
        equal "canonical ordered state" "0-1-7,2-9-18446744073709551615" (renderGtidSet entries)
    , case5 "gtid-parser-invalid" $ forM_ ["0-1-0","0-1-1,0-2-2","-1-2-3","0-1-18446744073709551616","4294967296-1-2","0-1-2,"," 0-1-2"] $ \text ->
        case parseGtidSet text of Left _ -> pure (); Right _ -> fail "invalid GTID accepted"
    , case5 "backpressure-no-read-ahead" $ do
        count <- newIORef (0::Int)
        source <- S.fromList (transaction 1 7 ++ transaction 2 8)
        observed <- S.makeInputStream (modifyIORef' count (+1) >> S.read source)
        (events,latest) <- newCDCDecoder defaultDecodeLimits (Just emptyGtids) fixtureFormat "bin.1" observed
        void (S.read events)
        equal "one raw event per GTID read" 1 =<< readIORef count
        equal "no premature checkpoint" Nothing =<< latest
    , case5 "compressed-write" $ do
        let row = writeRow 1 0 7
        result <- decode defaultDecodeLimits [tableMap 1 [3], compressRow row]
        equal "inflated row" [[BinLogLong 7]] (writes result)
    , case5 "compressed-expansion-limit" $ expectRejection (decode defaultDecodeLimits {maxExpandedEventBytes=32}
        [tableMap 1 [3], (compressRow (writeRow 1 0 7)) {blBody= L.take 10 (blBody (writeRow 1 0 7)) <> L.pack [0x84,0x7f,0xff,0xff,0xff]}])
    , case5 "compressed-truncated" $ do
        let row=compressRow (writeRow 1 0 7)
        expectRejection (decode defaultDecodeLimits [tableMap 1 [3],row {blBody=L.init (blBody row)}])
    , case5 "compressed-length-mismatch" $ do
        let row=compressRow (writeRow 1 0 7)
            bytes=blBody row
        expectRejection (decode defaultDecodeLimits [tableMap 1 [3],row {blBody=L.take 11 bytes <> L.singleton 4 <> L.drop 12 bytes}])
    , case5 "fragmented-row" $ do
        events <- decode defaultDecodeLimits (tableMap 1 [3] : fragments (writeRow 1 0 7))
        equal "fragmented image" [[BinLogLong 7]] (writes events)
    , case5 "fragment-out-of-order" $ do
        let parts=fragments (writeRow 1 0 7)
        expectRejection (decode defaultDecodeLimits (tableMap 1 [3] : reverse parts))
    , case5 "fragment-missing" $ case fragments (writeRow 1 0 7) of
        first:_ -> expectRejection (decode defaultDecodeLimits [tableMap 1 [3],first])
        _ -> fail "invalid fragment fixture"
    , case5 "fragment-interleaved" $ case fragments (writeRow 1 0 7) of
        first:rest -> expectRejection (decode defaultDecodeLimits ([tableMap 1 [3],first,queryEvent "COMMIT"] ++ rest))
        _ -> fail "invalid fragment fixture"
    , case5 "fragment-expansion-budget" $ expectRejection
        (decode defaultDecodeLimits {maxExpandedEventBytes=32} (tableMap 1 [3] : fragments (writeRow 1 0 7)))
    , case5 "compressed-query" $ do
        let original=queryEvent "CREATE TABLE t(n INT)"
            prefix=L.take 14 (blBody original)
            sqlBytes=L.drop 14 (blBody original)
            compressed=original {blEventType=MARIADB_QUERY_COMPRESSED_EVENT,
                blBody=prefix <> L.pack [0x81,fromIntegral (L.length sqlBytes)] <> Z.compress sqlBytes}
        result <- decode defaultDecodeLimits [gtid 0 1 1,compressed]
        equal "compressed DDL checkpoint" 1 (length (mapMaybe cdcEventCheckpoint result))
    , case5 "set-little-endian" $ do
        value <- getFromBinLogPacket (getBinLogField (BINLOG_TYPE_SET 16 2)) (packet BINLOG_UNKNOWN_EVENT (putWord8 1 >> putWord8 2))
        equal "two-byte SET mask" (BinLogSet 513) value
    , case5 "enum-little-endian" $ do
        value <- getFromBinLogPacket (getBinLogField (BINLOG_TYPE_ENUM 2)) (packet BINLOG_UNKNOWN_EVENT (putWord8 1 >> putWord8 2))
        equal "two-byte ENUM index" (BinLogEnum 513) value
    , case5 "metadata-invalid-precision" $ expectRejection
        (getFromBinLogPacket (getBinLogMeta mySQLTypeNewDecimal) (packet BINLOG_UNKNOWN_EVENT (putWord8 0 >> putWord8 0)))
    , case5 "metadata-invalid-fsp" $ expectRejection
        (getFromBinLogPacket (getBinLogMeta mySQLTypeTimestamp2) (packet BINLOG_UNKNOWN_EVENT (putWord8 7)))
    , case5 "crc32-off-format-still-checked" $ do
        let fd=packet BINLOG_FORMAT_DESCRIPTION_EVENT $ do
                putWord16le 4 >> putByteString ("12.3.3-MariaDB" <> B.replicate 36 0)
                putWord32le 0 >> putWord8 19 >> putByteString (B.replicate 172 8) >> putWord8 0
        parsed <- getFromPacket (getBinLogPacket False False) (wireEvent True fd)
        format <- getFromBinLogPacket getFormatDescription parsed
        equal "descriptor excluded from event vector" 172 (B.length (fdEventHeaderLenVector format))
    , case5 "live-transaction-resume" gtidResumeFeature
    , case5 "manual-ack-wire-order" manualAckFeature
    , case5 "manual-ack-foreign-token" $ do
        (conn,_,_) <- ackFixture (transaction 1 7)
        stream <- openManual conn
        foreignEvents <- decode defaultDecodeLimits (transaction 1 7)
        token <- only "foreign token" (mapMaybe cdcEventCheckpoint foreignEvents)
        expectRejection (cdcAcknowledge stream token)
        equal "misuse preserves replication" Replicating =<< connectionStatus conn
        cdcClose stream
    , case5 "manual-ack-backwards" $ do
        (conn,_,_) <- ackFixture (transaction 1 7 ++ map (\p -> p {blLogPos=200}) (transaction 2 8))
        stream <- openManual conn
        first <- readCheckpoint stream
        second <- readCheckpoint stream
        cdcAcknowledge stream second
        expectRejection (cdcAcknowledge stream first)
        equal "backwards rejection preserves replication" Replicating =<< connectionStatus conn
        cdcClose stream
    , case5 "manual-ack-write-cancellation" $ do
        (original,_,closed) <- ackFixture (transaction 1 7)
        blocked <- newEmptyMVar
        let conn=original {C.mysqlWrite = \p -> if not (L.null (pBody p)) && L.head (pBody p)==0xef
                then takeMVar blocked else C.mysqlWrite original p}
        stream <- openManual conn
        token <- readCheckpoint stream
        equal "ACK write deadline" Nothing =<< timeout 20000 (cdcAcknowledge stream token)
        equal "interrupted ACK retires connection" Broken =<< connectionStatus conn
        equal "ACK cancellation releases once" 1 =<< closed
    , case5 "decoded-error-retires" $ do
        (conn,_,closed) <- ackFixture [tableMap 1 [3],writeRow 2 0 7]
        stream <- openManual conn
        expectRejection (S.read (cdcEvents stream))
        equal "semantic error retires connection" Broken =<< connectionStatus conn
        equal "semantic error releases transport" 1 =<< closed
    , case5 "decoded-error-cannot-be-skipped" $ do
        input <- S.fromList [packet (UnrecognizedBinLogEvent 200) (pure ()),queryEvent "COMMIT"]
        (events,latest) <- newCDCDecoder defaultDecodeLimits (Just emptyGtids) fixtureFormat "bin.1" input
        expectRejection (S.read events)
        expectRejection (S.read events)
        equal "no checkpoint after ignored exception" Nothing =<< latest
    , case5 "foreign-thread-read-rejected" $ do
        (conn,_,_) <- ackFixture (transaction 1 7)
        stream <- openManual conn
        done <- newEmptyMVar
        _ <- forkFinally (S.read (cdcEvents stream)) (putMVar done)
        outcome <- takeMVar done
        case outcome of
            Left err | Just ConcurrentConnectionUse <- fromException err -> pure ()
            _ -> fail "foreign thread accessed replication stream"
        equal "ownership violation preserves stream" Replicating =<< connectionStatus conn
        void (readCheckpoint stream)
        cdcClose stream
    , case5 "live-semisync-ack" liveSemiAck
    , case5 "live-rotation-schema-sparse" liveRotation
    , case5 "live-server-restart-resume" liveRestart
    , case5 "file-position-overflow-rejected" $ withConn $ \conn -> do
        expectRejection (openCDC conn 610126 (defaultCDCOptions (FromBinLog (BinLogTracker "bin.1" 0x100000000))))
        equal "pre-send validation leaves Ready" Ready =<< connectionStatus conn
    , case5 "live-query-excluded-during-cdc" $ withConn $ \conn -> do
        tracker <- getLastBinLogTracker conn >>= maybe (fail "no binlog") pure
        stream <- openCDC conn 610126 (defaultCDCOptions (FromBinLog tracker))
        expectRejection (query_ conn "SELECT 1")
        equal "replication lease intact" Replicating =<< connectionStatus conn
        cdcClose stream
    , case5 "live-read-cancellation-retires" $ withConn $ \conn -> do
        tracker <- getLastBinLogTracker conn >>= maybe (fail "no binlog") pure
        stream <- openCDC conn 610126 (defaultCDCOptions (FromBinLog tracker))
        -- Drain any injected GTID_LIST first, then block on a quiet source.
        result <- timeout 100000 (forever (void (S.read (cdcEvents stream))) :: IO ())
        equal "deadline reached" Nothing result
        equal "cancelled replication retired" Broken =<< connectionStatus conn
    ] ++ [case5 ("compressed-row-variant-" ++ show (fromEnum compressed)) $ do
        let version2=normal `elem` [BINLOG_WRITE_ROWS_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2]
            update=normal `elem` [BINLOG_UPDATE_ROWS_EVENTv1,BINLOG_UPDATE_ROWS_EVENTv2]
            original=packet normal $ do
                putWord48le 1 >> putWord16le 0
                when version2 (putWord16le 2)
                putLenEncInt 1 >> putWord8 1
                when update (putWord8 1)
                putWord8 0 >> putWord32le 7
                when update (putWord8 0 >> putWord32le 8)
            offset=10 + (if version2 then 2 else 0) + (if update then 1 else 0)
            compressedEvent=original {blEventType=compressed,blBody=L.take offset (blBody original)
                <> L.pack [0x81,fromIntegral (L.length (blBody original)-offset)] <> Z.compress (L.drop offset (blBody original))}
        result <- decode defaultDecodeLimits [tableMap 1 [3],compressedEvent]
        case map cdcEventPayload result of
            [CDCWrite _ value] -> equal "compressed insert" [[BinLogLong 7]] (writeRowData value)
            [CDCDelete _ value] -> equal "compressed delete" [[BinLogLong 7]] (deleteRowData value)
            [CDCUpdate _ value] -> equal "compressed update" [([BinLogLong 7],[BinLogLong 8])] (updateRowData value)
            _ -> fail "missing compressed variant"
    | (compressed,normal) <-
        [(MARIADB_WRITE_ROWS_COMPRESSED_EVENTv1,BINLOG_WRITE_ROWS_EVENTv1),
         (MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv1,BINLOG_UPDATE_ROWS_EVENTv1),
         (MARIADB_DELETE_ROWS_COMPRESSED_EVENTv1,BINLOG_DELETE_ROWS_EVENTv1),
         (MARIADB_WRITE_ROWS_COMPRESSED_EVENTv2,BINLOG_WRITE_ROWS_EVENTv2),
         (MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2),
         (MARIADB_DELETE_ROWS_COMPRESSED_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2)]] ++ [case5 ("bitmap-width-" ++ show width) $ do
        let row=packet BINLOG_WRITE_ROWS_EVENTv1 $ do
                putWord48le 1 >> putWord16le 0 >> putLenEncInt width
                putByteString (B.pack (replicate (width `div` 8) 255 ++ [fromIntegral ((1 `shiftL` (width `mod` 8)) - 1 :: Int) | width `mod` 8 /= 0]))
                putByteString (B.replicate ((width+7) `div` 8) 0)
                replicateM_ width (putWord32le 7)
        events <- decode defaultDecodeLimits [tableMap 1 (replicate width 3),row]
        equal "all columns survive bitmap" [replicate width (BinLogLong 7)] (writes events)
    | width <- [1,7,8,9,15,16,17]]

compressRow :: BinLogPacket -> BinLogPacket
compressRow row = row { blEventType=MARIADB_WRITE_ROWS_COMPRESSED_EVENTv1,
    blBody=L.take 10 (blBody row) <> L.pack [0x81,5] <> Z.compress (L.drop 10 (blBody row)) }

-- Real source transactions are committed before a nonblocking dump. Resume from
-- the first delivered checkpoint must return the second transaction exactly once
-- in this controlled log (application crash recovery may legitimately replay).
gtidResumeFeature :: IO ()
gtidResumeFeature = withConn $ \writer -> do
    exec writer "DROP TABLE IF EXISTS mb_stage5_resume"
    exec writer "CREATE TABLE mb_stage5_resume(id INT PRIMARY KEY,n INT) ENGINE=InnoDB"
    (_,stateRows) <- query_ writer "SELECT @@global.gtid_binlog_pos"
    state <- S.toList stateRows
    start <- case state of
        [[MySQLText text]] -> either fail pure (parseGtidSet (TE.encodeUtf8 text))
        _ -> fail "missing GTID position"
    withTransaction writer $ exec writer "INSERT INTO mb_stage5_resume VALUES(1,7)"
    withTransaction writer $ exec writer "INSERT INTO mb_stage5_resume VALUES(2,8)"
    withConn $ \source -> do
        stream <- openCDC source 610126 (defaultCDCOptions (FromGtid start)) {cdcNonBlocking=True}
        first <- untilCheckpoint stream
        equal "first complete transaction" [[BinLogLong 1,BinLogLong 7]] (writes first)
        checkpoint <- maybe (fail "missing first checkpoint") pure (cdcEventCheckpoint (last first))
        cdcClose stream
        withConn $ \resumed -> do
            next <- openCDC resumed 610127 (defaultCDCOptions (resumeFromCheckpoint checkpoint)) {cdcNonBlocking=True}
            result <- S.toList (cdcEvents next)
            equal "GTID resume returns only unprocessed transaction" [[BinLogLong 2,BinLogLong 8]] (writes result)
  where
    untilCheckpoint stream = do
        value <- S.read (cdcEvents stream) >>= maybe (fail "EOF before checkpoint") pure
        if maybe False (const True) (cdcEventCheckpoint value) then pure [value]
        else (value:) <$> untilCheckpoint stream

-- Literal semisync transcript observes actual client writes. Neither GTID nor
-- row delivery may send an ACK; only a completed consumer checkpoint may do so.
manualAckFeature :: IO ()
manualAckFeature = do
    (conn,sent,_) <- ackFixture (transaction 1 7)
    stream <- openCDC conn 610126 (defaultCDCOptions (FromBinLog (BinLogTracker "bin.000001" 4))) {cdcAcknowledgements=AcknowledgeManually}
    let ackPackets = filter (\p -> not (L.null (pBody p)) && L.head (pBody p)==0xef)
    equal "no bootstrap ACK" 0 . length . ackPackets =<< sent
    begin <- S.read (cdcEvents stream)
    assert (maybe False (const True) begin) "GTID delivered"
    void (S.read (cdcEvents stream))
    equal "no row ACK before durability checkpoint" 0 . length . ackPackets =<< sent
    committed <- S.read (cdcEvents stream) >>= maybe (fail "missing commit") pure
    token <- maybe (fail "missing checkpoint") pure (cdcEventCheckpoint committed)
    cdcAcknowledge stream token
    acks <- ackPackets <$> sent
    equal "one explicit ACK" 1 (length acks)
    acknowledgement <- only "one ACK packet" acks
    equal "exact ACK wire bytes" (runPut (putWord8 0xef >> putWord64le 100 >> putByteString "bin.000001")) (pBody acknowledgement)
    cdcAcknowledge stream token
    equal "repeat acknowledgement is idempotent" 1 . length . ackPackets =<< sent
    cdcClose stream


-- This one check owns a disposable socket-only server. Its semisync counter
-- independently proves that a writer waits until our consumer acknowledges.
liveSemiAck :: IO ()
liveSemiAck = do
    fixture <- lookupEnv "MB_CDC_SOCKET"
    case fixture of
        Nothing -> do
            binary <- getExecutablePath
            callProcess "python3" ["validation/cdc_fixture.py",binary,"case","stage5.live-semisync-ack"]
        Just path -> do
            let open = connectUnixSocket path defaultConnectInfo {ciUser="root",ciPassword="",ciDatabase="cdc_validation"}
            withConnect open $ \source -> do
                tracker <- getLastBinLogTracker source >>= maybe (fail "no fixture binlog") pure
                stream <- openCDC source 610128 (defaultCDCOptions (FromBinLog tracker)) {cdcAcknowledgements=AcknowledgeManually}
                done <- newEmptyMVar
                bracket (forkFinally (withConnect open (\writer -> exec writer "INSERT INTO changes VALUES(1)")) (putMVar done))
                    killThread $ \_ -> do
                        let nextCommit = do
                                event <- S.read (cdcEvents stream) >>= maybe (fail "EOF before live commit") pure
                                maybe nextCommit pure (cdcEventCheckpoint event)
                        token <- timeout 2000000 nextCommit >>= maybe (fail "no semisync transaction") pure
                        pending <- tryReadMVar done
                        case pending of
                            Nothing -> pure ()
                            Just (Left err) -> throwIO err
                            Just (Right ()) -> fail "writer completed before explicit acknowledgement"
                        cdcAcknowledge stream token
                        result <- timeout 2000000 (takeMVar done) >>= maybe (fail "writer did not resume after ACK") pure
                        either throwIO pure result
                        cdcClose stream
                withConnect open $ \observer -> do
                    (_,statusRows) <- query_ observer "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_yes_tx'"
                    result <- S.toList statusRows
                    case result of
                        [[_,MySQLText "1"]] -> pure ()
                        _ -> fail ("server did not confirm semisync ACK: " ++ show result)


only :: String -> [a] -> IO a
only _ [value] = pure value
only label _ = fail (label ++ ": expected one value")

fragments :: BinLogPacket -> [BinLogPacket]
fragments event =
    [packet MARIADB_PARTIAL_ROW_DATA_EVENT (putWord32le 2 >> putWord32le 1 >> putWord8 1 >> putWord64le (fromIntegral (L.length raw)) >> putLazyByteString (L.take 21 raw)),
     packet MARIADB_PARTIAL_ROW_DATA_EVENT (putWord32le 2 >> putWord32le 2 >> putWord8 0 >> putLazyByteString (L.drop 21 raw))]
  where raw=L.drop 1 (pBody (wireEvent False event))


ackFixture :: [BinLogPacket] -> IO (MySQLConn,IO [Packet],IO Int)
ackFixture events = do
    let variable name value =
            [putToPacket 1 (putLenEncInt 2)] ++
            [encodeToPacket n (ColumnDef "" "" "" "v" "" 33 100 mySQLTypeVarString 0 0) | n <- [2,3]] ++
            [encodeToPacket 4 (EOF 0 2),putToPacket 5 (putLenEncBytes name >> putLenEncBytes value),encodeToPacket 6 (EOF 0 2)]
        fd = packet BINLOG_FORMAT_DESCRIPTION_EVENT $ do
            putWord16le 4 >> putByteString ("12.3.3-MariaDB" <> B.replicate 36 0)
            putWord32le 0 >> putWord8 19 >> putByteString (B.replicate 172 8) >> putWord8 1
        asSemi event =
            let base = wireEvent True event
                body = L.take 1 (pBody base) <> L.pack [0xef,1] <> L.drop 1 (pBody base)
            in base {pLen=L.length body,pBody=body}
        transcript = variable "rpl_semi_sync_master_enabled" "ON"
            ++ [okPacket 1]
            ++ map asSemi ([packet BINLOG_ROTATE_EVENT (putWord64le 4 >> putByteString "bin.000001"),fd] ++ events)
    scripted defaultConnectionOptions transcript

openManual :: MySQLConn -> IO CDCStream
openManual conn = openCDC conn 610126 (defaultCDCOptions (FromBinLog (BinLogTracker "bin.000001" 4)))
    {cdcAcknowledgements=AcknowledgeManually}

readCheckpoint :: CDCStream -> IO CDCCheckpoint
readCheckpoint stream = do
    event <- S.read (cdcEvents stream) >>= maybe (fail "EOF before expected checkpoint") pure
    maybe (readCheckpoint stream) pure (cdcEventCheckpoint event)


withIsolated :: String -> (IO MySQLConn -> IO ()) -> IO ()
withIsolated ident action = do
    path <- lookupEnv "MB_CDC_SOCKET"
    case path of
        Nothing -> do
            binary <- getExecutablePath
            callProcess "python3" ["validation/cdc_fixture.py",binary,"case",ident]
        Just socket -> action (connectUnixSocket socket defaultConnectInfo
            {ciUser="root",ciPassword="",ciDatabase="cdc_validation"})

sourceGtids :: MySQLConn -> IO GtidSet
sourceGtids conn = do
    (_,input) <- query_ conn "SELECT @@global.gtid_binlog_pos"
    result <- S.toList input
    case result of
        [[MySQLText value]] -> either fail pure (parseGtidSet (TE.encodeUtf8 value))
        _ -> fail "missing source GTID state"

-- Cross a real rotation and CRC32->NONE transition, change schema, and decode
-- minimal before/after/delete images without interpreting omitted fields as NULL.
liveRotation :: IO ()
liveRotation = withIsolated "stage5.live-rotation-schema-sparse" $ \open -> withConnect open $ \writer -> do
    exec writer "SET GLOBAL rpl_semi_sync_master_enabled=0"
    start <- sourceGtids writer
    exec writer "INSERT INTO changes VALUES(1)"
    exec writer "SET GLOBAL binlog_checksum='NONE'"
    exec writer "FLUSH LOGS"
    exec writer "INSERT INTO changes VALUES(2)"
    exec writer "ALTER TABLE changes ADD n INT NOT NULL DEFAULT 7"
    exec writer "SET SESSION binlog_row_image='MINIMAL'"
    exec writer "UPDATE changes SET n=8 WHERE id=2"
    exec writer "DELETE FROM changes WHERE id=2"
    finalPosition <- getLastBinLogTracker writer >>= maybe (fail "no final binlog position") pure
    withConnect open $ \source -> do
        stream <- openCDC source 610128 (defaultCDCOptions (FromGtid start)) {cdcNonBlocking=True}
        result <- S.toList (cdcEvents stream)
        equal "rows across rotation" [[BinLogLong 1],[BinLogLong 2]] (writes result)
        let updates=[updateRowData value | event <- result,CDCUpdate _ value <- [cdcEventPayload event]]
            deletes=[deleteRowData value | event <- result,CDCDelete _ value <- [cdcEventPayload event]]
            rotations=[value | event <- result,CDCRotate value <- [cdcEventPayload event]]
        equal "minimal update images" [[([BinLogLong 2],[BinLogLong 8])]] updates
        equal "minimal delete image" [[[BinLogLong 2]]] deletes
        assert (not (null rotations)) "real rotation delivered"
        case reverse (mapMaybe cdcEventCheckpoint result) of
            token:_ -> equal "checkpoint moved to rotated file" (btFileName finalPosition) (binlogFile (checkpointPosition token))
            _ -> fail "no final checkpoint across rotation"

-- Restart the owned server with the same datadir after a complete checkpoint.
-- The old transport must become terminal and GTID resume must yield only the
-- subsequent transaction. The Python fixture owns every server process.
liveRestart :: IO ()
liveRestart = withIsolated "stage5.live-server-restart-resume" $ \open -> do
    start <- withConnect open $ \writer -> do
        exec writer "SET GLOBAL rpl_semi_sync_master_enabled=0"
        state <- sourceGtids writer
        exec writer "INSERT INTO changes VALUES(1)"
        pure state
    saved <- withConnect open $ \source -> do
        stream <- openCDC source 610128 (defaultCDCOptions (FromGtid start))
        token <- readCheckpoint stream
        directory <- lookupEnv "MB_CDC_CONTROL" >>= maybe (fail "missing fixture control directory") pure
        writeFile (directory </> "restart.request") "restart owned fixture\n"
        let ready = do
                done <- doesFileExist (directory </> "restart.done")
                unless done (threadDelay 20000 >> ready)
        timeout 15000000 ready >>= maybe (fail "server restart deadline") pure
        let untilFailure = do
                event <- S.read (cdcEvents stream)
                case event of Nothing -> fail "old replication ended"; Just _ -> untilFailure
        expectRejection (timeout 2000000 untilFailure >>= maybe (fail "old transport did not terminate") pure)
        status <- connectionStatus source
        assert (status `elem` [Broken,Closed]) "old transport is terminal after server restart"
        pure token
    withConnect open $ \writer -> exec writer "INSERT INTO changes VALUES(2)"
    withConnect open $ \source -> do
        stream <- openCDC source 610128 (defaultCDCOptions (resumeFromCheckpoint saved)) {cdcNonBlocking=True}
        result <- S.toList (cdcEvents stream)
        equal "restart resumes after saved transaction" [[BinLogLong 2]] (writes result)
