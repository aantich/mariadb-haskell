{-# LANGUAGE ScopedTypeVariables #-}
-- | Independent wire fixtures and real-server regressions for native statements.
-- Synthetic packets deliberately use literal protocol bytes where the encoder
-- itself is under test; live cases verify stateful behavior against MariaDB.
module Validation.Stage3 (cases, bulkFeature, cacheFeature, extendedFeature) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.IntMap.Strict as IM
import Data.Time
import Data.Scientific (scientific)
import qualified Data.Text as T
import Data.Word
import Database.MySQL.Base
import qualified Database.MySQL.Connection as C
import qualified System.IO.Streams as S
import System.Timeout
import Validation.Common
import Validation.FaultTransport (scripted, withFaultProxy, ProxyMode(..), ProxyStats(..))

case3 :: String -> IO () -> Case
case3 name = Case ("stage3." ++ name) "stage3"

field :: ColumnDef
field = ColumnDef "" "" "" "n" "" 63 20 mySQLTypeLongLong 0 0

preparePackets :: Word32 -> [Packet]
preparePackets ident = [putToPacket 1 (putWord8 0 >> putWord32le ident >>
    putWord16le 1 >> putWord16le 0 >> putWord8 0 >> putWord16le 0), encodeToPacket 2 field]

end :: Word8 -> Word16 -> Packet
end sequenceNumber flags = putToPacket sequenceNumber $ do
    putWord8 254; putWord8 0; putWord8 0; putWord16le flags; putWord16le 0

cachedRows :: Integer -> [Packet]
cachedRows value = [putToPacket 1 (putWord8 1 >> putWord8 0),
    putToPacket 2 (putWord8 0 >> putWord8 0 >> putWord64le (fromIntegral value)), end 3 2]

cachedFixture :: [Packet] -> IO (MySQLConn, IO [Packet], IO Int)
cachedFixture packets = do
    result@(conn, _, _) <- scripted defaultConnectionOptions packets
    writeIORef (C.connectionCapabilities conn) (bit 24 .|. bit 36)
    pure result

allPreparedRows :: [PreparedResult] -> [[MySQLValue]]
allPreparedRows results = concat [values | PreparedRows _ values <- results]

-- A large, entirely buffered result never blocks on a socket/MVar. It exposes
-- deadlines/cancellation accidentally masked by a bracket's cleanup phase.
-- The finite tail also bounds a broken implementation during development.
bufferedFixture :: Int -> [Packet] -> IO (MySQLConn, IO Int, MVar (), IO Int)
bufferedFixture cleanupMicros prefix = do
    packets <- newIORef prefix
    consumed <- newIORef 0
    started <- newEmptyMVar
    released <- newIORef 0
    input <- S.makeInputStream $ do
        next <- atomicModifyIORef' packets (\xs -> case xs of [] -> ([], Nothing); x:rest -> (rest, Just x))
        case next of
            Just packet -> pure (Just packet)
            Nothing -> do
                index <- atomicModifyIORef' consumed (\n -> (n + 1, n))
                void (tryPutMVar started ())
                pure (Just (if index < 10000000
                    then putToPacket (fromIntegral (index + 2)) (putWord8 0 >> putWord8 0 >> putWord64le 7)
                    else end (fromIntegral (index + 2)) 2))
    conn <- C.newConnection defaultConnectionOptions {cleanupTimeoutMicros=cleanupMicros}
        input (const (pure ())) (modifyIORef' released (+1))
    writeIORef (C.connectionCapabilities conn) (bit 24 .|. bit 36)
    pure (conn, readIORef consumed, started, readIORef released)

bulkFeature :: IO ()
bulkFeature = withConn $ \conn -> do
    exec conn "CREATE TEMPORARY TABLE mb_stage3_bulk(n BIGINT, v VARCHAR(100))"
    withPreparedStatement conn "INSERT INTO mb_stage3_bulk VALUES(?,?)" $ \stmt -> do
        ok <- executeBulk stmt [[BulkValue (MySQLInt64 n), BulkValue (MySQLText "native")] | n <- [1..3]]
        equal "aggregate affected rows" 3 (okAffectedRows ok)
    equal "bulk content" [[3,6]] . map (map number) =<< rows conn "SELECT COUNT(*),SUM(n) FROM mb_stage3_bulk"
    healthy conn

cacheFeature :: IO ()
cacheFeature = withConn $ \conn -> withPreparedStatement conn "SELECT CAST(? AS SIGNED) AS n" $ \stmt -> do
    caps <- readIORef (C.connectionCapabilities conn)
    assert (testBit caps 36) "metadata caching was not negotiated"
    forM_ [7,8,9] $ \value -> do
        (_, stream) <- queryPrepared stmt [MySQLInt64 value]
        equal "repeated cached result" [[fromIntegral value]] . map (map number) =<< S.toList stream
    healthy conn

extendedFeature :: IO ()
extendedFeature = withConn $ \conn -> do
    exec conn "CREATE TEMPORARY TABLE mb_stage3_native(u UUID,j JSON,ip INET6,v VECTOR(3))"
    withPreparedStatement conn "SELECT u,j,ip,v FROM mb_stage3_native" $ \stmt -> do
        metadata <- preparedMetadata stmt
        equal "native column names" ["u","j","ip","v"] (map (columnName . metadataColumn) metadata)
        let attributes = concatMap metadataAttributes metadata
        assert (any ((=="uuid") . snd) attributes) "UUID native metadata missing"
        assert (any ((=="json") . snd) attributes) "JSON format metadata missing"
        (_, stream) <- queryPrepared stmt []
        equal "empty native result" [] =<< S.toList stream

cases :: [Case]
cases =
    [ case3 "prepared.out-and-multiple-results" $ withConn $ \conn -> do
        exec conn "DROP PROCEDURE IF EXISTS mb_stage3_out"
        exec conn "CREATE PROCEDURE mb_stage3_out(IN a INT,INOUT b INT,OUT c INT) BEGIN SELECT a; SELECT a+1; SET b=b+2; SET c=a+b; END"
        withPreparedStatement conn "CALL mb_stage3_out(?,?,?)" $ \stmt -> do
            result <- queryPreparedMulti stmt [MySQLInt32 7,MySQLInt32 10,MySQLNull]
            equal "ordinary result sets" [[7],[8]] (map (map number) (allPreparedRows result))
            equal "OUT values distinct from ordinary rows" [[12,19]]
                [map number values | PreparedOutParameters _ values <- result]
            assert (any isOKResult result) "trailing procedure OK missing"
        healthy conn
        exec conn "DROP PROCEDURE mb_stage3_out"
    , case3 "prepared.raw-multiple-results" $ withConn $ \conn -> do
        exec conn "DROP PROCEDURE IF EXISTS mb_stage3_multi"
        exec conn "CREATE PROCEDURE mb_stage3_multi() BEGIN SELECT 7; SELECT 8; END"
        bracket (prepareStmt conn "CALL mb_stage3_multi()") (closeStmt conn) $ \ident -> do
            result <- queryStmtMulti conn ident []
            equal "raw binary multiple results" [[7],[8]] (map (map number) (allPreparedRows result))
        healthy conn
        exec conn "DROP PROCEDURE mb_stage3_multi"
    , case3 "prepared.single-result-drains-extras" $ withConn $ \conn -> do
        exec conn "DROP PROCEDURE IF EXISTS mb_stage3_extra"
        exec conn "CREATE PROCEDURE mb_stage3_extra() BEGIN SELECT 7; SELECT 8; END"
        withPreparedStatement conn "CALL mb_stage3_extra()" $ \stmt -> do
            result <- try (queryPrepared stmt [] >>= S.toList . snd)
            case result of Left ExtraResultSets -> pure (); _ -> fail "extra rows were silently lost"
        healthy conn
        exec conn "DROP PROCEDURE mb_stage3_extra"
    , case3 "prepared.local-arity" $ do
        (conn, sent, _) <- cachedFixture (preparePackets 7)
        stmt <- prepareStatement conn "SELECT 7"
        before <- length <$> sent
        expectRejection (queryPrepared stmt [MySQLInt32 1])
        equal "arity rejection sends nothing" before . length =<< sent
        equal "arity preserves readiness" Ready =<< connectionStatus conn
    , case3 "prepared.close-idempotent" $ do
        (conn, sent, _) <- cachedFixture (preparePackets 7)
        stmt <- prepareStatement conn "SELECT 7"
        closePrepared stmt
        before <- length <$> sent
        closePrepared stmt
        expectRejection (queryPrepared stmt [])
        equal "closed handle sends nothing" before . length =<< sent
    , case3 "prepared.raw-id-reuse" $ do
        (conn, sent, _) <- cachedFixture (preparePackets 7 ++ preparePackets 7 ++ cachedRows 8)
        old <- prepareStatement conn "SELECT 7"
        closeStmt conn 7
        new <- prepareStatement conn "SELECT 8"
        before <- length <$> sent
        closePrepared old
        expectRejection (queryPrepared old [])
        equal "old generation cannot close replacement" before . length =<< sent
        equal "replacement still executes" [[8]] . map (map number) =<< (queryPrepared new [] >>= S.toList . snd)
        closePrepared new
    , case3 "prepared.registry-bound" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {maximumPreparedStatements=1} ci) $ \conn -> do
            stmt <- prepareStatement conn "SELECT 7"
            expectRejection (prepareStatement conn "SELECT 8")
            healthy conn
            closePrepared stmt
            withPreparedStatement conn "SELECT 9" $ \next ->
                equal "released registry slot" [[9]] . map (map number) =<< (queryPrepared next [] >>= S.toList . snd)
    , case3 "prepared.pending-close-rejected" $ withConn $ \conn -> do
        stmt <- prepareStatement conn "SELECT seq FROM seq_1_to_10"
        (_, stream) <- queryPrepared stmt []
        void (S.read stream)
        expectRejection (closePrepared stmt)
        S.skipToEof stream
        closePrepared stmt
        healthy conn
    , case3 "prepared.bracket-preserves-primary" $ withConn $ \conn -> do
        outcome <- try $ withPreparedStatement conn "SELECT seq FROM seq_1_to_10" $ \stmt -> do
            (_, stream) <- queryPrepared stmt []
            void (S.read stream)
            throwIO (userError "stage3-primary-marker")
        case outcome of
            Left (err :: SomeException) -> assert ("stage3-primary-marker" `isInfixOf` displayException err) "cleanup replaced primary exception"
            Right () -> fail "body exception was lost"
        healthy conn
    , case3 "prepared.reset-retains-cache" $ withConn $ \conn -> withPreparedStatement conn "SELECT ?" $ \stmt -> do
        equal "initial execution" [[7]] . map (map number) =<< (queryPrepared stmt [MySQLInt32 7] >>= S.toList . snd)
        resetPrepared stmt
        equal "execution after statement reset" [[8]] . map (map number) =<< (queryPrepared stmt [MySQLInt32 8] >>= S.toList . snd)
    , case3 "prepared.connection-close-invalidates" $ withConn $ \conn -> do
        stmt <- prepareStatement conn "SELECT 7"
        close conn
        closePrepared stmt
        expectRejection (preparedMetadata stmt)
        expectRejection (queryPrepared stmt [])
    , case3 "timeout.safe-retirement-default" $ withConn $ \conn -> do
        result <- timeout 20000 (rows conn "SELECT SLEEP(0.2)")
        equal "deadline propagated" Nothing result
        equal "unsafe session retired" Broken =<< connectionStatus conn
        expectRejection (ping conn)
        withConn healthy
    , case3 "cache.omitted-first-execution" $ do
        (conn, _, _) <- cachedFixture (preparePackets 7 ++ cachedRows 42)
        stmt <- prepareStatement conn "SELECT 42"
        equal "prepare metadata decodes omitted execute metadata" [[42]] . map (map number) =<< (queryPrepared stmt [] >>= S.toList . snd)
    , case3 "cache.missing-entry-retires" $ do
        (conn, _, released) <- cachedFixture (cachedRows 42)
        expectRejection (queryStmt conn 7 [])
        equal "missing cache is terminal" Broken =<< connectionStatus conn
        equal "transport released" 1 =<< released
    , case3 "cache.invalid-marker" $ do
        (conn, _, _) <- cachedFixture (preparePackets 7 ++ [putToPacket 1 (putWord8 1 >> putWord8 2)])
        stmt <- prepareStatement conn "SELECT 7"
        expectRejection (queryPrepared stmt [])
        equal "invalid marker retires" Broken =<< connectionStatus conn
    , case3 "cache.count-mismatch" $ do
        (conn, _, _) <- cachedFixture (preparePackets 7 ++ [putToPacket 1 (putWord8 2 >> putWord8 0)])
        stmt <- prepareStatement conn "SELECT 7"
        expectRejection (queryPrepared stmt [])
        equal "omitted changed shape rejected" Broken =<< connectionStatus conn
    , case3 "cache.ddl-reprepare" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_ddl(n INT)"
        exec conn "INSERT INTO mb_stage3_ddl VALUES(7)"
        withPreparedStatement conn "SELECT * FROM mb_stage3_ddl" $ \stmt -> do
            equal "initial schema" [[7]] . map (map number) =<< (queryPrepared stmt [] >>= S.toList . snd)
            exec conn "ALTER TABLE mb_stage3_ddl ADD v VARCHAR(20) DEFAULT 'changed'"
            (columns, stream) <- queryPrepared stmt []
            equal "changed result shape" ["n","v"] (map columnName columns)
            values <- S.toList stream
            equal "updated decoder" [[MySQLInt32 7, MySQLText "changed"]] values
            equal "replacement cached" values =<< (queryPrepared stmt [] >>= S.toList . snd)
    , case3 "cache.parameter-type-refresh" $ withConn $ \conn -> withPreparedStatement conn "SELECT ? AS n" $ \stmt -> do
        forM_ [MySQLInt32 7,MySQLText "changed",MySQLInt64U maxBound,MySQLNull] $ \value -> do
            result <- queryPrepared stmt [value] >>= S.toList . snd
            case value of
                MySQLNull -> equal "NULL type change" [[MySQLNull]] result
                MySQLText text -> equal "text type change" [[MySQLText text]] result
                _ -> equal "numeric type change" [[number value]] (map (map number) result)
    , case3 "cache.explicit-opt-out" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {enableMetadataCaching=False,enableExtendedMetadata=False} ci) $ \conn -> do
            caps <- readIORef (C.connectionCapabilities conn)
            assert (not (testBit caps 36 || testBit caps 35)) "opted-out flags advertised"
            withPreparedStatement conn "SELECT ?" $ \stmt -> forM_ [7,8] $ \value ->
                equal "uncached binary result" [[fromIntegral value]] . map (map number) =<< (queryPrepared stmt [MySQLInt32 value] >>= S.toList . snd)
    , case3 "cache.legacy-eof" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {enableSessionTracking=False} ci) $ \conn ->
            withPreparedStatement conn "SELECT 7" $ \stmt -> replicateM_ 3 $
                equal "legacy EOF with omission" [[7]] . map (map number) =<< (queryPrepared stmt [] >>= S.toList . snd)
    , case3 "cache.aggregate-budget" $ do
        let bytes = fromIntegral (pLen (encodeToPacket 2 field))
        (conn, _, released) <- scripted defaultConnectionOptions {maximumMetadataBytes=bytes+1}
            (preparePackets 7 ++ preparePackets 8)
        writeIORef (C.connectionCapabilities conn) (bit 24 .|. bit 36)
        first <- prepareStatement conn "SELECT 7"
        expectRejection (prepareStatement conn "SELECT 8")
        equal "aggregate cache budget retires safely" Broken =<< connectionStatus conn
        equal "budget failure releases transport" 1 =<< released
        expectRejection (preparedMetadata first)
    , case3 "metadata.unknown-attribute" $ do
        let packet = putToPacket 0 $ do
                mapM_ putLenEncBytes ["def","","","","n",""]
                putLenEncBytes (B.pack [42,3,97,0,98])
                putWord8 12; putWord16le 63; putWord32le 20
                putWord8 8; putWord16le 0; putWord8 0; putWord16le 0
        actual <- getFromPacketExact (getColumnMetadata True) packet
        equal "unknown tag and embedded NUL retained" [(42,B.pack [97,0,98])] (metadataAttributes actual)
        equal "core metadata not shifted" field (metadataColumn actual)
    , case3 "metadata.truncated-attribute" $ do
        let packet = putToPacket 0 $ do
                mapM_ putLenEncBytes ["def","","","","n",""]
                putLenEncBytes (B.pack [0,5,97])
                putWord8 12; putWord16le 63; putWord32le 20
                putWord8 8; putWord16le 0; putWord8 0; putWord16le 0
        expectRejection (getFromPacketExact (getColumnMetadata True) packet)
    , case3 "bulk.independent-wire-vector" $ do
        let cmd = COM_STMT_BULK_EXECUTE 0x01020304 128 [MySQLInt32 7,MySQLText "a"]
                [[BulkValue (MySQLInt32 7),BulkValue (MySQLText "a")], [BulkValue MySQLNull,BulkDefault]]
        equal "literal bulk wire bytes" [250,4,3,2,1,128,0,3,0,254,0,0,7,0,0,0,0,1,97,1,2]
            (L.unpack (runPut (putCommand cmd)))
    , case3 "bulk.per-unit-results" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_units(id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,n INT)"
        withPreparedStatement conn "INSERT INTO mb_stage3_units(n) VALUES(?)" $ \stmt -> do
            result <- executeBulkUnitResults stmt [[BulkValue (MySQLInt32 n)] | n <- [7,8,9]]
            equal "individual IDs and counts" [BulkUnitResult 1 1,BulkUnitResult 2 1,BulkUnitResult 3 1] result
        healthy conn
    , case3 "bulk.null-default-ignore" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_indicators(n INT DEFAULT 7,v VARCHAR(20) DEFAULT 'default')"
        withPreparedStatement conn "INSERT INTO mb_stage3_indicators VALUES(?,?)" $ \stmt -> do
            void (executeBulk stmt [[BulkDefault,BulkDefault],[BulkIgnore,BulkValue MySQLNull],
                [BulkValue (MySQLInt32 9),BulkValue (MySQLText "value")]])
        equal "native indicators" [[MySQLInt32 7,MySQLNull],[MySQLInt32 7,MySQLText "default"],[MySQLInt32 9,MySQLText "value"]]
            =<< rows conn "SELECT n,v FROM mb_stage3_indicators ORDER BY n,v"
    , case3 "bulk.update-ignore" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_update(id INT PRIMARY KEY,n INT DEFAULT 7)"
        exec conn "INSERT INTO mb_stage3_update VALUES(1,10),(2,20)"
        withPreparedStatement conn "UPDATE mb_stage3_update SET n=? WHERE id=?" $ \stmt ->
            void (executeBulk stmt [[BulkIgnore,BulkValue (MySQLInt32 1)],[BulkDefault,BulkValue (MySQLInt32 2)]])
        equal "UPDATE indicators" [[1,10],[2,7]] . map (map number) =<< rows conn "SELECT id,n FROM mb_stage3_update ORDER BY id"
    , case3 "bulk.transaction-rollback-no-replay" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_atomic(n INT PRIMARY KEY) ENGINE=InnoDB"
        withPreparedStatement conn "INSERT INTO mb_stage3_atomic VALUES(?)" $ \stmt -> do
            expectERR [1062] $ withTransaction conn $ void $ executeBulk stmt
                [[BulkValue (MySQLInt32 1)],[BulkValue (MySQLInt32 1)],[BulkValue (MySQLInt32 2)]]
        equal "explicit transaction rolled back" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage3_atomic"
        healthy conn
    , case3 "bulk.mixed-types-rejected" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_types(n BIGINT)"
        withPreparedStatement conn "INSERT INTO mb_stage3_types VALUES(?)" $ \stmt -> do
            expectRejection (executeBulk stmt [[BulkValue (MySQLInt32 1)],[BulkValue (MySQLInt64 2)]])
            expectRejection (executeBulk stmt [[BulkValue (MySQLInt32 1)],[BulkValue (MySQLInt32U 2)]])
        equal "type rejection sends no INSERT" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage3_types"
        healthy conn
    , case3 "bulk.empty-and-arity-rejected" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_arity(n INT)"
        withPreparedStatement conn "INSERT INTO mb_stage3_arity VALUES(?)" $ \stmt -> do
            expectRejection (executeBulk stmt [])
            expectRejection (executeBulk stmt [[]])
            expectRejection (executeBulk stmt [[BulkValue (MySQLInt32 1),BulkDefault]])
        equal "invalid dimensions send no INSERT" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage3_arity"
        healthy conn
    , case3 "bulk.row-limit" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {maximumBulkRows=2} ci) $ \conn -> do
            exec conn "CREATE TEMPORARY TABLE mb_stage3_limit(n INT)"
            withPreparedStatement conn "INSERT INTO mb_stage3_limit VALUES(?)" $ \stmt ->
                expectRejection (executeBulk stmt [[BulkValue (MySQLInt32 n)] | n <- [1..3]])
            equal "oversized batch not split" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage3_limit"
            healthy conn
    , case3 "bulk.max-bound-limits" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions
            {maximumBulkRows=maxBound, maximumColumns=maxBound} ci) $ \conn -> do
            exec conn "CREATE TEMPORARY TABLE mb_stage3_max_bound(n INT)"
            withPreparedStatement conn "INSERT INTO mb_stage3_max_bound VALUES(?)" $ \stmt -> do
                ok <- executeBulk stmt [[BulkValue (MySQLInt32 7)], [BulkValue (MySQLInt32 8)]]
                equal "permissive bounds accept a small batch" 2 (okAffectedRows ok)
            equal "maxBound batch contents" [[7], [8]] . map (map number)
                =<< rows conn "SELECT n FROM mb_stage3_max_bound ORDER BY n"
            healthy conn
    , case3 "bulk.message-limit" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {maximumMessageBytes=2048} ci) $ \conn -> do
            exec conn "CREATE TEMPORARY TABLE mb_stage3_message(v BLOB)"
            withPreparedStatement conn "INSERT INTO mb_stage3_message VALUES(?)" $ \stmt ->
                expectRejection (executeBulk stmt [[BulkValue (MySQLBytes (B.replicate 4096 65))]])
            equal "oversized message sends no INSERT" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage3_message"
            healthy conn
    , case3 "bulk.charset-and-unencodable" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_charset(v VARCHAR(100) CHARACTER SET utf8mb4)"
        exec conn "SET NAMES latin1"
        refreshSessionState conn
        withPreparedStatement conn "INSERT INTO mb_stage3_charset VALUES(?)" $ \stmt -> do
            void (executeBulk stmt [[BulkValue (MySQLText "caf\233")]])
            expectRejection (executeBulk stmt [[BulkValue (MySQLText "\x4f60")]])
        exec conn "SET NAMES utf8mb4"
        equal "bulk honors active client encoding" [[MySQLText "caf\233"]] =<< rows conn "SELECT v FROM mb_stage3_charset"
    , case3 "bulk.sql-looking-values" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_safe(v TEXT)"
        let value = "\NUL'\\; DROP TABLE mb_stage3_safe; -- \x1f642"
        withPreparedStatement conn "INSERT INTO mb_stage3_safe VALUES(?)" $ \stmt ->
            void (executeBulk stmt [[BulkValue (MySQLText value)]])
        equal "bulk data never parsed as SQL" [[MySQLText value]] =<< rows conn "SELECT v FROM mb_stage3_safe"
    , case3 "bulk.zero-parameter-rejected" $ do
        (conn, sent, _) <- cachedFixture (preparePackets 7)
        stmt <- prepareStatement conn "SELECT 7"
        before <- length <$> sent
        expectRejection (executeBulk stmt [[BulkValue (MySQLInt32 1)]])
        equal "zero-parameter bulk sends nothing" before . length =<< sent
    , case3 "bulk.scalar-null-parity" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_scalars(id INT,i8 TINYINT,u8 TINYINT UNSIGNED,i16 SMALLINT,u16 SMALLINT UNSIGNED,i32 INT,u32 INT UNSIGNED,i64 BIGINT,u64 BIGINT UNSIGNED,d DECIMAL(30,6),f FLOAT,g DOUBLE,b BIT(64),dt DATETIME(6),da DATE,tm TIME(6),yr YEAR,t TEXT,raw BLOB)"
        let day = fromGregorian 2024 2 29
            values = [MySQLInt8 minBound,MySQLInt8U maxBound,MySQLInt16 minBound,MySQLInt16U maxBound,
                MySQLInt32 minBound,MySQLInt32U maxBound,MySQLInt64 minBound,MySQLInt64U maxBound,
                MySQLDecimal (scientific 12345678901234567890123456 (-6)),MySQLFloat 0.125,MySQLDouble 0.125,
                MySQLBit maxBound,MySQLDateTime (LocalTime day (TimeOfDay 23 59 59.123456)),MySQLDate day,
                MySQLTime 1 (TimeOfDay 838 59 59.123456),MySQLYear 2024,
                MySQLText "\NULunicode \x1f642",MySQLBytes (B.pack [0..255])]
        withPreparedStatement conn "INSERT INTO mb_stage3_scalars VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)" $ \stmt ->
            void (executeBulk stmt [BulkValue (MySQLInt32 1):map BulkValue values,
                BulkValue (MySQLInt32 2):replicate 18 (BulkValue MySQLNull)])
        bracket (prepareStmt conn "SELECT i8,u8,i16,u16,i32,u32,i64,u64,d,f,g,b,dt,da,tm,yr,t,raw FROM mb_stage3_scalars ORDER BY id") (closeStmt conn) $ \ident ->
            equal "bulk/prepared scalar parity including NULL bitmap" [values,replicate 18 MySQLNull]
                =<< (queryStmt conn ident [] >>= S.toList . snd)
    , case3 "bulk.all-null-and-default-column" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_null(n INT DEFAULT 7)"
        withPreparedStatement conn "INSERT INTO mb_stage3_null VALUES(?)" $ \stmt -> do
            void (executeBulk stmt [[BulkValue MySQLNull],[BulkValue MySQLNull]])
            void (executeBulk stmt [[BulkDefault],[BulkDefault]])
        equal "all-NULL/default type selection" [[4,2,14]] . map (map number)
            =<< rows conn "SELECT COUNT(*),COUNT(n),SUM(n) FROM mb_stage3_null"
    , case3 "bulk.unit-result-unsigned-id" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_unsigned(id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,n INT) AUTO_INCREMENT=9223372036854775808"
        withPreparedStatement conn "INSERT INTO mb_stage3_unsigned(n) VALUES(?)" $ \stmt -> do
            result <- executeBulkUnitResults stmt [[BulkValue (MySQLInt32 7)],[BulkValue (MySQLInt32 8)]]
            equal "full Word64 generated IDs" [BulkUnitResult 9223372036854775808 1,BulkUnitResult 9223372036854775809 1] result
    , case3 "bulk.physical-boundary" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_large(v LONGBLOB)"
        let payload = B.replicate 16777216 65
        withPreparedStatement conn "INSERT INTO mb_stage3_large VALUES(?)" $ \stmt ->
            void (executeBulk stmt [[BulkValue (MySQLBytes payload)],[BulkValue (MySQLBytes "small")]])
        equal "bulk continuation content" [[2,16777221]] . map (map number)
            =<< rows conn "SELECT COUNT(*),SUM(OCTET_LENGTH(v)) FROM mb_stage3_large"
        equal "large payload content" [[65,65]] . map (map number)
            =<< rows conn "SELECT ASCII(LEFT(v,1)),ASCII(RIGHT(v,1)) FROM mb_stage3_large WHERE OCTET_LENGTH(v)>100"
        healthy conn
    , case3 "bulk.non-finite-rejected" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_nan(n DOUBLE)"
        withPreparedStatement conn "INSERT INTO mb_stage3_nan VALUES(?)" $ \stmt -> do
            expectRejection (executeBulk stmt [[BulkValue (MySQLDouble (0/0))]])
            expectRejection (executeBulk stmt [[BulkValue (MySQLDouble (1/0))]])
        equal "invalid values send no INSERT" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage3_nan"
        healthy conn
    , case3 "bulk.one-wire-command" $ do
        ci <- config
        withFaultProxy ci (FragmentTraffic 65536) $ \proxyCi statistics -> withConnect (connect proxyCi) $ \conn -> do
            exec conn "CREATE TEMPORARY TABLE mb_stage3_wire(n INT)"
            withPreparedStatement conn "INSERT INTO mb_stage3_wire VALUES(?)" $ \stmt -> do
                before <- proxyCommands <$> statistics
                void (executeBulk stmt [[BulkValue (MySQLInt32 n)] | n <- [1..100]])
                after <- proxyCommands <$> statistics
                equal "one native batch command, no hidden helper query" 1 (after-before)
    , case3 "bulk.capability-rejection-before-send" $ do
        (conn, sent, _) <- cachedFixture []
        let cmd = COM_STMT_BULK_EXECUTE 7 128 [MySQLInt32 1] [[BulkValue (MySQLInt32 1)]]
        expectRejection (C.withCommand conn (C.sendCommand conn cmd))
        equal "unsupported bulk flag sends nothing" [] =<< sent
        writeIORef (C.connectionCapabilities conn) (bit 34)
        expectRejection (C.withCommand conn (C.sendCommand conn (COM_STMT_BULK_EXECUTE 7 192 [MySQLInt32 1] [[BulkValue (MySQLInt32 1)]])))
        equal "unsupported unit results send nothing" [] =<< sent
    , case3 "prepared.cleanup-deadline" $ do
        packets <- newIORef (preparePackets 7 ++ [putToPacket 1 (putWord8 1 >> putWord8 0)])
        stalled <- newEmptyMVar
        input <- S.makeInputStream $ do
            next <- atomicModifyIORef' packets (\xs -> case xs of [] -> ([],Nothing); x:rest -> (rest,Just x))
            maybe (takeMVar stalled) (pure . Just) next
        conn <- C.newConnection defaultConnectionOptions {cleanupTimeoutMicros=20000} input (const (pure ())) (pure ())
        writeIORef (C.connectionCapabilities conn) (bit 24 .|. bit 36)
        outcome <- timeout 1000000 $ try $ withPreparedStatement conn "SELECT 7" $ \stmt -> do
            void (queryPrepared stmt [])
            throwIO (userError "stage3-bounded-primary")
        case outcome of
            Just (Left (err :: SomeException)) -> assert ("stage3-bounded-primary" `isInfixOf` displayException err) "cleanup did not preserve primary"
            _ -> fail "statement cleanup exceeded deadline"
        equal "stalled cleanup retires" Broken =<< connectionStatus conn
    , case3 "prepared.buffered-cleanup-deadline" $ do
        (conn, consumed, _, released) <- bufferedFixture 20000
            (preparePackets 7 ++ [putToPacket 1 (putWord8 1 >> putWord8 0)])
        result <- try $ withPreparedStatement conn "SELECT 7" $ \stmt -> void (queryPrepared stmt [])
        case result of
            Left CleanupDeadlineExceeded -> pure ()
            _ -> fail "buffered drain ignored its cleanup deadline"
        count <- consumed
        assert (count < 10000000) "cleanup consumed the entire oversized result"
        equal "buffered timeout retires" Broken =<< connectionStatus conn
        equal "buffered timeout releases once" 1 =<< released
    , case3 "prepared.buffered-cleanup-cancellation" $ do
        (conn, _, started, released) <- bufferedFixture 5000000
            (preparePackets 7 ++ [putToPacket 1 (putWord8 1 >> putWord8 0)])
        done <- newEmptyMVar
        worker <- forkFinally
            (withPreparedStatement conn "SELECT 7" (\stmt -> void (queryPrepared stmt [])))
            (putMVar done)
        takeMVar started
        killThread worker
        outcome <- takeMVar done
        case outcome of
            Left err | Just ThreadKilled <- fromException err -> pure ()
            _ -> fail "buffered cleanup swallowed the new cancellation"
        equal "cancelled buffered cleanup retires" Broken =<< connectionStatus conn
        equal "cancelled buffered cleanup releases once" 1 =<< released
    , case3 "transaction.buffered-cleanup-deadline" $ do
        (conn, consumed, _, released) <- bufferedFixture 20000
            (preparePackets 7 ++ [encodeToPacket 1 (OK 0 0 3 0), putToPacket 1 (putWord8 1 >> putWord8 0)])
        writeIORef (C.connectionServerStatus conn) (Just 2)
        outcome <- try $ withPreparedStatement conn "SELECT 7" $ \stmt ->
            withTransaction conn (void (queryPrepared stmt []))
        case outcome of
            Left UnconsumedResultSet -> pure ()
            _ -> fail "transaction cleanup replaced the primary pending-result error"
        count <- consumed
        assert (count < 10000000) "rollback cleanup ignored its deadline on buffered data"
        equal "timed-out rollback drain retires" Broken =<< connectionStatus conn
        equal "rollback cleanup releases once" 1 =<< released
    , case3 "cache.incremental-accounting" $ do
        (conn, _, _) <- scripted defaultConnectionOptions {maximumMetadataBytes=100} []
        let block bytes = C.CachedColumns [] [] 0 (pure []) bytes
            store ident ordinal bytes = void (C.storeStatementColumns conn ident ordinal (block bytes))
            charge expected = do
                registry <- readIORef (C.connectionStatements conn)
                case registry of
                    Nothing -> fail "unexpected terminal registry"
                    Just current -> do
                        equal "aggregate metadata charge" expected (C.registryMetadataBytes current)
                        let states = IM.elems (C.registryStatements current)
                        equal "per-statement totals agree" expected (sum (map C.statementMetadataBytes states))
                        equal "cached blocks agree" expected
                            (sum [C.cachedMetadataBytes columns | state <- states, columns <- IM.elems (C.statementResults state)])
        C.registerStatement conn 7 1 0
        store 7 0 10
        charge 10
        store 7 0 25
        store 7 1 20
        charge 45
        C.registerStatement conn 8 2 0
        store 8 0 30
        charge 75
        C.forgetStatement conn 7
        C.forgetStatement conn 7
        charge 30
        C.registerStatement conn 8 3 0
        charge 0
        store 8 0 100
        expectRejection (store 8 1 1)
        charge 100
        close conn
        equal "terminal close discards accounting" Nothing . fmap C.registryMetadataBytes
            =<< readIORef (C.connectionStatements conn)
    , case3 "cache.close-releases-budget" $ do
        let bytes = fromIntegral (pLen (encodeToPacket 2 field))
        (conn, _, _) <- scripted defaultConnectionOptions {maximumMetadataBytes=bytes}
            (preparePackets 7 ++ preparePackets 8)
        writeIORef (C.connectionCapabilities conn) (bit 24 .|. bit 36)
        first <- prepareStatement conn "SELECT 7"
        closePrepared first
        second <- prepareStatement conn "SELECT 8"
        equal "released budget admits replacement" 1 . length =<< preparedMetadata second
        closePrepared second
    , case3 "cache.close-race-does-not-resurrect" $ do
        (conn, _, _) <- cachedFixture (preparePackets 7)
        stmt <- prepareStatement conn "SELECT 7"
        close conn
        empty <- C.statementMap conn
        equal "terminal registry empty" 0 (length empty)
        expectRejection (C.storeStatementColumns conn 7 0 (C.CachedColumns [] [] 0 (pure []) 0))
        expectRejection (preparedMetadata stmt)
    , case3 "cache.server-confirms-omission" $ withConn $ \conn -> do
        let skipped = do
                status <- rows conn "SHOW SESSION STATUS LIKE 'Resultset_metadata_skipped'"
                case status of
                    [[_,MySQLText value]] -> pure (read (T.unpack value) :: Integer)
                    _ -> fail "MariaDB metadata omission counter unavailable"
        withPreparedStatement conn "SELECT 7" $ \stmt -> do
            before <- skipped
            replicateM_ 3 (queryPrepared stmt [] >>= S.skipToEof . snd)
            after <- skipped
            equal "server actually omitted all three metadata blocks" 3 (after-before)
    , case3 "cache.metadata-owns-buffer" $ do
        let packets = preparePackets 7
        sourceColumn <- decodeFromPacket (packets !! 1)
        (conn, _, _) <- cachedFixture packets
        stmt <- prepareStatement conn "SELECT 7"
        retained <- preparedMetadata stmt
        case retained of
            [metadata] -> do
                let (original, _, _) = BI.toForeignPtr (columnName sourceColumn)
                    (owned, _, _) = BI.toForeignPtr (columnName (metadataColumn metadata))
                assert (original /= owned) "cached metadata pins its receive buffer"
            _ -> fail "expected one retained column"
    , case3 "prepared.bracket-drains-on-success" $ withConn $ \conn -> do
        result <- withPreparedStatement conn "SELECT seq FROM seq_1_to_10" $ \stmt -> do
            (_, stream) <- queryPrepared stmt []
            void (S.read stream)
            pure (7 :: Int)
        equal "callback result preserved" 7 result
        healthy conn
        equal "statement released after drain" 0 . length =<< C.statementMap conn
    , case3 "prepared.cleanup-new-cancellation" $ do
        packets <- newIORef (preparePackets 7 ++ [putToPacket 1 (putWord8 1 >> putWord8 0)])
        input <- S.makeInputStream $ do
            next <- atomicModifyIORef' packets (\xs -> case xs of [] -> ([],Nothing); x:rest -> (rest,Just x))
            maybe (throwIO ThreadKilled) (pure . Just) next
        conn <- C.newConnection defaultConnectionOptions input (const (pure ())) (pure ())
        writeIORef (C.connectionCapabilities conn) (bit 24 .|. bit 36)
        result <- try $ withPreparedStatement conn "SELECT 7" $ \stmt -> do
            void (queryPrepared stmt [])
            throwIO (userError "earlier-primary")
        case result of
            Left ThreadKilled -> pure ()
            _ -> fail "new cleanup cancellation was replaced"
        equal "cancelled cleanup retires" Broken =<< connectionStatus conn
    , case3 "metadata.attribute-count-bound" $ do
        let packet = putToPacket 0 $ do
                mapM_ putLenEncBytes ["def","","","","n",""]
                putLenEncBytes (B.replicate 131072 0)
                putWord8 12; putWord16le 63; putWord32le 20
                putWord8 8; putWord16le 0; putWord8 0; putWord16le 0
        expectRejection (getFromPacketExact (getColumnMetadata True) packet)
    , case3 "bulk.minimum-size-before-cell-traversal" $ do
        (conn, sent, _) <- scripted defaultConnectionOptions {maximumMessageBytes=64} []
        writeIORef (C.connectionCapabilities conn) (bit 34)
        let invalidRows = replicate 1000 (error "oversized batch cells must not be visited")
            commandValue = COM_STMT_BULK_EXECUTE 7 128 [MySQLInt32 1] invalidRows
        result <- try (C.withCommand conn (C.sendCommand conn commandValue))
        case result of
            Left (ProtocolError _) -> pure ()
            _ -> fail "minimum encoded size was not rejected locally"
        equal "impossible batch sends nothing" [] =<< sent
        equal "early rejection preserves connection" Ready =<< connectionStatus conn
    ]
  where
    isOKResult (PreparedOK _) = True
    isOKResult _ = False
