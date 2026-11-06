{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Functional (cases) where

import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as L
import Data.List (intercalate)
import Data.Scientific
import qualified Data.Text as T
import Data.Time
import Database.MySQL.Base
import qualified Data.Vector as V
import qualified System.IO.Streams as S
import Validation.Common

data Sample = Sample String String MySQLValue

samples :: [Sample]
samples =
    [ Sample "int8-min" "TINYINT" (MySQLInt8 minBound)
    , Sample "int8-max" "TINYINT" (MySQLInt8 maxBound)
    , Sample "uint8-max" "TINYINT UNSIGNED" (MySQLInt8U maxBound)
    , Sample "int16-min" "SMALLINT" (MySQLInt16 minBound)
    , Sample "int16-max" "SMALLINT" (MySQLInt16 maxBound)
    , Sample "uint16-max" "SMALLINT UNSIGNED" (MySQLInt16U maxBound)
    , Sample "int24-min" "MEDIUMINT" (MySQLInt32 (-8388608))
    , Sample "int24-max" "MEDIUMINT" (MySQLInt32 8388607)
    , Sample "uint24-max" "MEDIUMINT UNSIGNED" (MySQLInt32U 16777215)
    , Sample "int32-min" "INT" (MySQLInt32 minBound)
    , Sample "int32-max" "INT" (MySQLInt32 maxBound)
    , Sample "uint32-max" "INT UNSIGNED" (MySQLInt32U maxBound)
    , Sample "int64-min" "BIGINT" (MySQLInt64 minBound)
    , Sample "int64-max" "BIGINT" (MySQLInt64 maxBound)
    , Sample "uint64-max" "BIGINT UNSIGNED" (MySQLInt64U maxBound)
    , Sample "decimal-65-30" "DECIMAL(65,30)" (MySQLDecimal (scientific (read (replicate 65 '9')) (-30)))
    , Sample "decimal-65-38" "DECIMAL(65,38)" (MySQLDecimal (scientific (negate (read (replicate 65 '9'))) (-38)))
    , Sample "decimal-zero" "DECIMAL(65,30)" (MySQLDecimal 0)
    , Sample "float-exact" "FLOAT" (MySQLFloat 3.125)
    , Sample "double-exact" "DOUBLE" (MySQLDouble (-12345.125))
    , Sample "bit-1" "BIT(1)" (MySQLBit 1)
    , Sample "bit-8" "BIT(8)" (MySQLBit 255)
    , Sample "bit-16" "BIT(16)" (MySQLBit 57514)
    , Sample "bit-64" "BIT(64)" (MySQLBit maxBound)
    , Sample "year-zero" "YEAR" (MySQLYear 0)
    , Sample "year-min" "YEAR" (MySQLYear 1901)
    , Sample "year-max" "YEAR" (MySQLYear 2155)
    , Sample "date-min" "DATE" (MySQLDate (fromGregorian 1000 1 1))
    , Sample "date-leap" "DATE" (MySQLDate (fromGregorian 2000 2 29))
    , Sample "date-max" "DATE" (MySQLDate (fromGregorian 9999 12 31))
    , Sample "datetime-fraction" "DATETIME(6)" (MySQLDateTime (LocalTime (fromGregorian 2024 2 29) (TimeOfDay 12 34 56.123456)))
    , Sample "datetime-max" "DATETIME(6)" (MySQLDateTime (LocalTime (fromGregorian 9999 12 31) (TimeOfDay 23 59 59.999999)))
    , Sample "timestamp-fraction" "TIMESTAMP(6)" (MySQLTimeStamp (LocalTime (fromGregorian 2024 2 29) (TimeOfDay 12 34 56.123456)))
    , Sample "timestamp-after-2038" "TIMESTAMP(6)" (MySQLTimeStamp (LocalTime (fromGregorian 2100 1 1) (TimeOfDay 1 2 3.123456)))
    , Sample "time-zero" "TIME(6)" (MySQLTime 0 (TimeOfDay 0 0 0))
    , Sample "time-positive-limit" "TIME(6)" (MySQLTime 0 (TimeOfDay 838 59 59.999999))
    , Sample "time-negative-limit" "TIME(6)" (MySQLTime 1 (TimeOfDay 838 59 59.999999))
    , Sample "text-empty" "VARCHAR(255)" (MySQLText "")
    , Sample "text-unicode" "VARCHAR(255)" (MySQLText "MariaDB Ελληνικά 中文 العربية")
    , Sample "text-emoji" "VARCHAR(255)" (MySQLText "🦭🚀𐍈")
    , Sample "text-combining" "VARCHAR(255)" (MySQLText "e\x0301")
    , Sample "text-controls" "VARCHAR(255)" (MySQLText "a\0b\n\r\t\\'\"\SUB")
    , Sample "bytes-all-256" "VARBINARY(256)" (MySQLBytes (B.pack [0..255]))
    , Sample "bytes-empty" "VARBINARY(255)" (MySQLBytes B.empty)
    , Sample "null" "VARCHAR(255)" MySQLNull
    , Sample "enum" "ENUM('red','green','blue')" (MySQLText "green")
    , Sample "set" "SET('red','green','blue')" (MySQLText "red,blue")
    ]

roundtrip :: Bool -> Sample -> Case
roundtrip binary (Sample name typ value) = Case
    ("types." ++ mode ++ "." ++ name) "types" $ withConn $ \c -> do
        exec c "SET time_zone='+00:00'"
        exec c ("CREATE TEMPORARY TABLE mb_value(v " ++ typ ++ ")")
        st <- prepareStmt c "INSERT INTO mb_value VALUES (?)"
        void (executeStmt c st [value])
        closeStmt c st
        actual <- if binary then preparedRows c "SELECT v FROM mb_value" [] else rows c "SELECT v FROM mb_value"
        equal (typ ++ " " ++ mode) [[value]] actual
        healthy c
  where mode=if binary then "binary" else "text"

connectionCases :: [Case]
connectionCases =
    [ Case "connection.tcp-native" "connection" $ withConn $ \c -> void (ping c) >> healthy c
    , Case "connection.unix-socket" "connection" $ do
        ci <- config; path <- socketPath
        withConnect (connectUnixSocket path ci) healthy
    , Case "connection.tls-verified" "connection" $ withTLS $ \c -> do
        rs <- rows c "SHOW SESSION STATUS LIKE 'Ssl_cipher'"
        case rs of
            [[_,v]] -> assert (not (T.null (textOf v))) "TLS cipher is empty"
            _ -> throwIO (userError "missing TLS cipher")
        healthy c
    , Case "connection.tls-wrong-hostname" "connection" $ do
        ci <- config
        expectRejection (withConnect (tlsConnect ci "wrong.invalid") healthy)
    , Case "connection.wrong-password" "connection" $ do
        ci <- config
        expectERR [1045] (withConnect (connect ci {ciPassword="definitely-wrong"}) healthy)
    , Case "connection.unknown-user" "connection" $ do
        ci <- config
        expectERR [1045] (withConnect (connect ci {ciUser="mb_user_does_not_exist"}) healthy)
    , Case "connection.missing-database" "connection" $ do
        ci <- config
        expectERR [1044,1049] (withConnect (connect ci {ciDatabase="mb_database_does_not_exist"}) healthy)
    , Case "connection.default-full-unicode" "connection" $ do
        ci <- config
        withConnect (connect ci {ciCharset=ciCharset defaultConnectInfo}) $ \c -> do
            actual <- textOf <$> scalar c "SELECT @@character_set_connection"
            equal "default wire charset" "utf8mb4" actual
    ] ++
    [ Case ("auth." ++ plugin ++ "." ++ transport) "authentication" $ do
        ci <- config
        let authci=ci {ciUser=BC.pack user}
        open <- case transport of
            "tls" -> pure (tlsConnect authci "localhost")
            "socket" -> do path <- socketPath; pure (connectUnixSocket path authci)
            _ -> pure (connect authci)
        withConnect open healthy
    | (plugin,user) <- [("ed25519","mariadb_ed25519"),("parsec","mariadb_parsec"),("sha2","mariadb_sha2")]
    , transport <- ["tcp","tls","socket"]
    ]

sqlCases :: [Case]
sqlCases =
    [ assertQuery "sql.cte" "WITH x AS (SELECT 7 AS n) SELECT n+1 FROM x" [[8]]
    , assertQuery "sql.recursive-cte" "WITH RECURSIVE x(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM x WHERE n<10) SELECT SUM(n) FROM x" [[55]]
    , assertQuery "sql.window" "SELECT ROW_NUMBER() OVER (ORDER BY seq) FROM seq_1_to_3" [[1],[2],[3]]
    , assertQuery "sql.json-functions" "SELECT JSON_VALID('{\"n\":7}'), JSON_VALUE('{\"n\":7}', '$.n')+0" [[1,7]]
    , assertQuery "sql.sequence-table" "SELECT COUNT(*), MIN(seq), MAX(seq) FROM seq_1_to_100" [[100,1,100]]
    , Case "sql.sequence-object" "sql" $ withConn $ \c -> do
        exec c "DROP SEQUENCE IF EXISTS mb_validation_seq"
        exec c "CREATE SEQUENCE mb_validation_seq START WITH 41"
        equal "next sequence values" [[41,42]] . map (map number) =<< rows c "SELECT NEXT VALUE FOR mb_validation_seq, NEXT VALUE FOR mb_validation_seq"
        exec c "DROP SEQUENCE mb_validation_seq"
    , Case "sql.generated-column" "sql" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_generated(n INT, doubled INT AS (n*2) PERSISTENT)"
        exec c "INSERT INTO mb_generated(n) VALUES (21)"
        equal "generated value" 42 =<< scalarInt c "SELECT doubled FROM mb_generated"
    , Case "sql.check-constraint" "sql" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_check(n INT CHECK (n>0))"
        expectERR [4025] (exec c "INSERT INTO mb_check VALUES (-1)")
        healthy c
    , Case "sql.foreign-key" "sql" $ withConn $ \c -> do
        exec c "DROP TABLE IF EXISTS mb_child, mb_parent"
        exec c "CREATE TABLE mb_parent(id INT PRIMARY KEY) ENGINE=InnoDB"
        exec c "CREATE TABLE mb_child(id INT PRIMARY KEY, pid INT, FOREIGN KEY(pid) REFERENCES mb_parent(id)) ENGINE=InnoDB"
        expectERR [1452] (exec c "INSERT INTO mb_child VALUES(1,999)")
        exec c "INSERT INTO mb_parent VALUES(7)"
        exec c "INSERT INTO mb_child VALUES(1,7)"
        equal "foreign key row" 7 =<< scalarInt c "SELECT pid FROM mb_child"
        exec c "DROP TABLE mb_child, mb_parent"
    , Case "sql.insert-returning" "sql" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_returning(id INT)"
        equal "insert returning" [[7],[8]] . map (map number) =<< rows c "INSERT INTO mb_returning VALUES(7),(8) RETURNING id"
        equal "delete returning" [[7]] . map (map number) =<< rows c "DELETE FROM mb_returning WHERE id=7 RETURNING id"
        healthy c
    , Case "sql.prepared-returning" "sql" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_returning(id INT)"
        equal "prepared returning" [[9]] . map (map number) =<< preparedRows c "INSERT INTO mb_returning VALUES(?) RETURNING id" [MySQLInt32 9]
        healthy c
    , Case "sql.procedure-multiple-results" "sql" $ withConn $ \c -> do
        exec c "DROP PROCEDURE IF EXISTS mb_results"
        exec c "CREATE PROCEDURE mb_results() BEGIN SELECT 7; SELECT 8; END"
        actual <- queryMulti_ c "CALL mb_results()"
        equal "row sets and trailing OK" [Right [[7]],Right [[8]],Left 0] (map shape actual)
        healthy c
        exec c "DROP PROCEDURE mb_results"
    , Case "sql.procedure-prepared-out" "sql" $ withConn $ \c -> do
        exec c "DROP PROCEDURE IF EXISTS mb_out"
        exec c "CREATE PROCEDURE mb_out(IN a INT, OUT b INT) SET b=a+1"
        actual <- preparedRows c "CALL mb_out(?,?)" [MySQLInt32 41,MySQLNull]
        equal "prepared OUT result" [[42]] (map (map number) actual)
        exec c "DROP PROCEDURE mb_out"
    , Case "sql.oracle-mode" "sql" $ withConn $ \c -> do
        exec c "SET sql_mode='ORACLE'"
        equal "Oracle functions" [[7,8]] . map (map number) =<< rows c "SELECT NVL(NULL,7), DECODE(1,1,8,0) FROM DUAL"
    , Case "sql.system-versioning" "sql" $ withConn $ \c -> do
        exec c "DROP TABLE IF EXISTS mb_versioned"
        exec c "CREATE TABLE mb_versioned(id INT PRIMARY KEY, n INT) WITH SYSTEM VERSIONING"
        exec c "INSERT INTO mb_versioned VALUES(1,7)"
        exec c "UPDATE mb_versioned SET n=8 WHERE id=1"
        equal "historical versions" [[7],[8]] . map (map number) =<< rows c "SELECT n FROM mb_versioned FOR SYSTEM_TIME ALL ORDER BY n"
        exec c "DROP TABLE mb_versioned"
    , Case "sql.json-native-column" "types" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_json(v JSON)"
        st <- prepareStmt c "INSERT INTO mb_json VALUES(?)"
        void (executeStmt c st [MySQLText "{\"name\":\"🦭\",\"n\":7}"])
        closeStmt c st
        document <- textOf <$> scalar c "SELECT v FROM mb_json"
        assert (T.isInfixOf "🦭" document) "JSON Unicode payload changed"
        equal "JSON extraction" "🦭" . textOf =<< scalar c "SELECT JSON_UNQUOTE(JSON_EXTRACT(v,'$.name')) FROM mb_json"
    , Case "sql.uuid-native-column" "types" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_uuid(v UUID)"
        let uuid="123e4567-e89b-12d3-a456-426614174000"
        st <- prepareStmt c "INSERT INTO mb_uuid VALUES(?)"
        void (executeStmt c st [MySQLText uuid]); closeStmt c st
        equal "UUID text representation" uuid . textOf =<< scalar c "SELECT v FROM mb_uuid"
        actual <- preparedRows c "SELECT v FROM mb_uuid" []
        equal "UUID prepared representation" [[uuid]] (map (map textOf) actual)
    , Case "sql.inet-native-columns" "types" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_inet(v4 INET4, v6 INET6)"
        st <- prepareStmt c "INSERT INTO mb_inet VALUES(?,?)"
        void (executeStmt c st [MySQLText "192.0.2.1",MySQLText "2001:db8::1"]); closeStmt c st
        actual <- preparedRows c "SELECT v4,v6 FROM mb_inet" []
        equal "INET values" [["192.0.2.1","2001:db8::1"]] (map (map textOf) actual)
    , Case "sql.vector-native-column" "types" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_vector(v VECTOR(3))"
        exec c "INSERT INTO mb_vector VALUES(VEC_FromText('[1,2,3]'))"
        let expected=L.toStrict (runPut (mapM_ putFloatle [1,2,3]))
        equal "packed vector bytes" (MySQLBytes expected) =<< scalar c "SELECT v FROM mb_vector"
        equal "vector JSON text" "[1,2,3]" . T.filter (/=' ') . textOf =<< scalar c "SELECT VEC_ToText(v) FROM mb_vector"
    , Case "sql.geometry" "types" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_geom(v GEOMETRY)"
        exec c "INSERT INTO mb_geom VALUES(ST_GeomFromText('POINT(7 8)'))"
        actual <- scalar c "SELECT v FROM mb_geom"
        case actual of
            MySQLGeometry b -> assert (B.length b>=21) "geometry payload truncated"
            _ -> throwIO (userError ("geometry type lost: " ++ show actual))
        equal "geometry coordinates" [[7,8]] . map (map number) =<< rows c "SELECT ST_X(v),ST_Y(v) FROM mb_geom"
    , Case "sql.zero-date-preservation" "types" $ withConn $ \c -> do
        exec c "SET sql_mode=''"
        exec c "CREATE TEMPORARY TABLE mb_zero(v DATE)"
        exec c "INSERT INTO mb_zero VALUES('0000-00-00')"
        value <- scalar c "SELECT v FROM mb_zero"
        st <- prepareStmt c "INSERT INTO mb_zero VALUES(?)"
        void (executeStmt c st [value]); closeStmt c st
        actual <- map (map textOf) <$> rows c "SELECT CAST(v AS CHAR) FROM mb_zero"
        equal "zero date after driver round trip" [["0000-00-00"],["0000-00-00"]] actual
    , Case "sql.unsigned-generated-id" "types" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_id(id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY) AUTO_INCREMENT=9223372036854775808"
        ok <- execute_ c "INSERT INTO mb_id VALUES(NULL)"
        equal "generated unsigned ID" (9223372036854775808 :: Integer) (fromIntegral (okLastInsertID ok))
    , Case "parameters.literal-question-mark" "parameters" $ withConn $ \c -> do
        (_,stream) <- query c "SELECT '?', ?" [MySQLInt32 7]
        equal "literal and bound parameter" [[MySQLText "?",MySQLInt32 7]] =<< S.toList stream
    , Case "parameters.comment-question-mark" "parameters" $ withConn $ \c -> do
        (_,stream) <- query c "SELECT ? /* literal ? */" [MySQLInt32 7]
        equal "comment placeholder" [[7]] . map (map number) =<< S.toList stream
    , Case "parameters.no-backslash-text" "parameters" $ withConn $ \c -> do
        exec c "SET sql_mode='NO_BACKSLASH_ESCAPES'"
        (_,stream) <- query c "SELECT ?" [MySQLText "a'b\\c"]
        equal "SQL mode safe text parameter" [[MySQLText "a'b\\c"]] =<< S.toList stream
    , Case "parameters.no-backslash-binary" "parameters" $ withConn $ \c -> do
        exec c "SET sql_mode='NO_BACKSLASH_ESCAPES'"
        equal "SQL mode safe binary parameter" [[MySQLText "a'b\\c"]] =<< preparedRows c "SELECT ?" [MySQLText "a'b\\c"]
    , Case "results.vector-api" "results" $ withConn $ \c -> do
        (_,stream) <- queryVector_ c "SELECT seq FROM seq_1_to_3 ORDER BY seq"
        actual <- map (map number . V.toList) <$> S.toList stream
        equal "vector row stream" [[1],[2],[3]] actual
    , Case "results.prepared-vector-api" "results" $ withConn $ \c -> do
        st <- prepareStmt c "SELECT ? + seq FROM seq_1_to_3 ORDER BY seq"
        (_,stream) <- queryStmtVector c st [MySQLInt32 7]
        equal "prepared vector rows" [[8],[9],[10]] . map (map number . V.toList) =<< S.toList stream
        closeStmt c st
    , Case "results.empty" "results" $ withConn $ \c -> equal "empty result" [] =<< rows c "SELECT 1 WHERE FALSE"
    , Case "results.no-rowset" "results" $ withConn $ \c -> do
        equal "DO has no rows" [] =<< rows c "DO 1"
        healthy c
    , Case "results.multi-statement" "results" $ withConn $ \c -> do
        actual <- queryMulti_ c "DO 1; SELECT 7; SELECT 8"
        equal "all multi results" [Left 0,Right [[7]],Right [[8]]] (map shape actual)
        healthy c
    , Case "results.discard-and-reuse" "results" $ withConn $ \c -> do
        (_,stream) <- query_ c "SELECT seq FROM seq_1_to_1000"
        void (S.read stream); S.skipToEof stream; healthy c
    , Case "errors.syntax-and-reuse" "errors" $ withConn $ \c -> expectERR [1064] (rows c "THIS IS NOT SQL") >> healthy c
    , Case "errors.missing-table-and-reuse" "errors" $ withConn $ \c -> expectERR [1146] (rows c "SELECT * FROM mb_no_such_table") >> healthy c
    , Case "errors.duplicate-and-reuse" "errors" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_unique(id INT PRIMARY KEY)"
        exec c "INSERT INTO mb_unique VALUES(1)"
        expectERR [1062] (exec c "INSERT INTO mb_unique VALUES(1)")
        healthy c
    , Case "statements.reset-consumed" "statements" $ withConn $ \c -> do
        st <- prepareStmt c "SELECT ?"
        void (queryStmt c st [MySQLInt32 7] >>= S.toList . snd)
        resetStmt c st
        equal "reuse after reset" [[8]] . map (map number) =<< (queryStmt c st [MySQLInt32 8] >>= S.toList . snd)
        closeStmt c st
    , Case "statements.parameter-type-change" "statements" $ withConn $ \c -> do
        st <- prepareStmt c "SELECT ?"
        a <- queryStmt c st [MySQLInt32 7] >>= S.toList . snd
        b <- queryStmt c st [MySQLText "🦭"] >>= S.toList . snd
        d <- queryStmt c st [MySQLNull] >>= S.toList . snd
        equal "int parameter" [[7]] (map (map number) a)
        equal "new text type" [[MySQLText "🦭"]] b
        equal "new NULL type" [[MySQLNull]] d
        closeStmt c st
    , Case "statements.ddl-reprepare" "statements" $ withConn $ \c -> do
        exec c "DROP TABLE IF EXISTS mb_reprepare"
        exec c "CREATE TABLE mb_reprepare(a INT)"
        exec c "INSERT INTO mb_reprepare VALUES(7)"
        st <- prepareStmt c "SELECT * FROM mb_reprepare"
        void (queryStmt c st [] >>= S.toList . snd)
        exec c "ALTER TABLE mb_reprepare ADD b INT DEFAULT 8"
        equal "replacement metadata" [[7,8]] . map (map number) =<< (queryStmt c st [] >>= S.toList . snd)
        closeStmt c st
        exec c "DROP TABLE mb_reprepare"
    , Case "statements.prepare-metadata" "statements" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_metadata(id BIGINT UNSIGNED NOT NULL PRIMARY KEY,v DECIMAL(20,6))"
        (prepared,params,cols) <- prepareStmtDetail c "SELECT id,v FROM mb_metadata WHERE id=? AND v>?"
        equal "parameter count" 2 (stmtParamCnt prepared)
        equal "result count" 2 (stmtColumnCnt prepared)
        equal "parameter definitions" 2 (length params)
        equal "column names" ["id","v"] (map columnName cols)
        case cols of
            [idCol,valueCol] -> do
                assert (flagUnsigned (columnFlags idCol)) "unsigned result flag missing"
                equal "decimal scale" 6 (columnDecimals valueCol)
            _ -> throwIO (userError "expected two column definitions")
        closeStmt c (stmtId prepared)
    , Case "statements.wrong-parameter-count" "statements" $ withConn $ \c -> do
        st <- prepareStmt c "SELECT ?+?"
        expectRejection (queryStmt c st [MySQLInt32 1] >>= S.toList . snd)
        healthy c
        closeStmt c st
    , Case "statements.closed-id-rejected" "statements" $ withConn $ \c -> do
        st <- prepareStmt c "SELECT ?"
        closeStmt c st
        expectERR [1243] (queryStmt c st [MySQLInt32 1] >>= S.toList . snd)
        healthy c
    , Case "session.timestamp-timezone" "session" $ withConn $ \c -> do
        exec c "SET time_zone='+00:00'"
        exec c "CREATE TEMPORARY TABLE mb_timezone(ts TIMESTAMP,dt DATETIME)"
        exec c "INSERT INTO mb_timezone VALUES('2024-02-29 12:00:00','2024-02-29 12:00:00')"
        exec c "SET time_zone='+02:00'"
        actual <- preparedRows c "SELECT ts,dt FROM mb_timezone" []
        equal "TIMESTAMP follows session timezone; DATETIME does not"
            [[MySQLTimeStamp (LocalTime (fromGregorian 2024 2 29) (TimeOfDay 14 0 0)),
              MySQLDateTime (LocalTime (fromGregorian 2024 2 29) (TimeOfDay 12 0 0))]] actual
    , Case "session.use-schema" "session" $ withConn $ \c -> do
        void (command c (COM_INIT_DB "mariadb_haskell_validation"))
        equal "current schema" "mariadb_haskell_validation" . textOf =<< scalar c "SELECT DATABASE()"
        healthy c
    , Case "session.warning-count" "session" $ withConn $ \c -> do
        exec c "SET sql_mode=''"
        exec c "CREATE TEMPORARY TABLE mb_warning(v VARCHAR(1))"
        ok <- execute_ c "INSERT INTO mb_warning VALUES('long')"
        assert (okWarningCnt ok>0) "server warning count was lost"
        equal "server truncated according to SQL mode" "l" . textOf =<< scalar c "SELECT v FROM mb_warning"
    , Case "parameters.many-values" "parameters" $ withConn $ \c -> do
        (_,stream) <- query c "SELECT seq FROM seq_1_to_5 WHERE seq IN (?) ORDER BY seq" [Many [MySQLInt32 1,MySQLInt32 3]]
        equal "IN list" [[1],[3]] . map (map number) =<< S.toList stream
    , Case "parameters.empty-many" "parameters" $ withConn $ \c -> do
        (_,stream) <- query c "SELECT seq FROM seq_1_to_5 WHERE seq IN (?)" [Many []]
        equal "empty IN list" [] =<< S.toList stream
    , Case "parameters.sql-injection-value" "parameters" $ withConn $ \c -> do
        let value=MySQLText "x' OR 1=1; SELECT SLEEP(5); -- "
        actual <- preparedRows c "SELECT ?" [value]
        equal "bound SQL remains data" [[value]] actual
    , Case "batch.empty" "batch" $ withConn $ \c -> equal "empty batch" [] =<< executeMany c "DO ?" ([] :: [[MySQLValue]])
    , Case "batch.ordered-errors" "batch" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_batch(id INT PRIMARY KEY)"
        expectERR [1062] (executeMany c "INSERT INTO mb_batch VALUES(?)" [[MySQLInt32 1],[MySQLInt32 1],[MySQLInt32 2]])
        equal "only preceding statement executed" [[1]] . map (map number) =<< rows c "SELECT id FROM mb_batch"
        healthy c
    ] ++
    [ Case ("types.binary.null-columns-" ++ show n) "types" $ withConn $ \c -> do
        let ps=take n (cycle [MySQLNull,MySQLInt32 7])
        actual <- preparedRows c ("SELECT " ++ intercalate "," (replicate n "?")) ps
        equal "NULL bitmap across byte boundaries" [ps] actual
    | n <- [1,2,7,8,9,15,16,17,63,64,65]
    ] ++
    [ Case ("packets.live-blob-" ++ show n) "large-packets" $ withConn $ \c -> do
        result <- scalar c ("SELECT CAST(REPEAT('x'," ++ show n ++ ") AS BINARY)")
        case result of
            MySQLBytes b -> do
                equal "blob length" n (B.length b)
                assert (B.all (==120) b) "blob bytes changed"
            _ -> throwIO (userError ("blob row missing or misclassified: " ++ take 200 (show result)))
        healthy c
    | n <- [0,1,16383,16384,16385,1048576,16777214,16777215,16777216,16777217,33554430]
    ] ++
    [ Case ("packets.prepared-outbound-blob-" ++ show n) "large-packets" $ withConn $ \c -> do
        let payload=B.replicate n 120
        actual <- preparedRows c "SELECT ?" [MySQLBytes payload]
        equal "prepared outbound bytes" [[MySQLBytes payload]] actual
        healthy c
    | n <- [16384,16777214,16777215,16777216,16777217,33554430]
    ] ++
    [ Case ("packets.text-outbound-blob-" ++ show n) "large-packets" $ withConn $ \c -> do
        let payload=B.replicate n 120
        (_,stream) <- query c "SELECT 937, CAST(? AS BINARY)" [MySQLBytes payload]
        actual <- S.toList stream
        case actual of
            [[idValue,MySQLBytes blob]] -> equal "sentinel" 937 (number idValue) >> equal "text outbound bytes" payload blob
            _ -> throwIO (userError "text command lost its large payload")
        healthy c
    | n <- [16777214,16777215,16777216,16777217]
    ]
  where
    shape (StatementOK ok)=Left (toInteger (okAffectedRows ok))
    shape (StatementRows _ rs)=Right (map (map number) rs)

cases :: [Case]
cases = connectionCases ++ [roundtrip binary s | binary <- [False,True], s <- samples] ++ sqlCases
