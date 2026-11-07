-- | Additive native-feature benchmarks. Frozen workloads remain unchanged.
-- Each profile performs two complete warm-ups before the measured region and
-- consumes/checks all values. Connections and statement preparation are outside
-- timing; batch transaction/truncate/verification work is identical in each mode.
module Validation.Stage3Bench (run) where

import Control.Exception (evaluate)
import Control.Monad
import Data.List (intercalate, isPrefixOf, isSuffixOf)
import qualified Data.Text as T
import Database.MySQL.Base
import GHC.Clock
import GHC.Stats
import System.Mem
import Validation.Common
import qualified System.IO.Streams as S

run :: String -> Int -> IO ()
run ident iterations
    | iterations <= 0 = fail "positive native benchmark count required"
    | "bulk." `isPrefixOf` ident = withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage3_bench(n BIGINT NOT NULL,v VARCHAR(128) NOT NULL) ENGINE=InnoDB"
        withPreparedStatement conn "INSERT INTO mb_stage3_bench VALUES(?,?)" $ \stmt -> do
            let values = [[MySQLInt64 n,MySQLText (T.replicate 128 "x")] | n <- [1..1000]]
                batch = map (map BulkValue) values
                operation = do
                    exec conn "TRUNCATE mb_stage3_bench"
                    withTransaction conn $ case ident of
                        "bulk.native" -> do
                            ok <- executeBulk stmt batch
                            equal "bulk count" 1000 (okAffectedRows ok)
                        "bulk.units" -> do
                            result <- executeBulkUnitResults stmt batch
                            equal "unit count" 1000 (sum (map bulkAffectedRows result))
                        "bulk.prepared" -> forM_ values $ \row -> do
                            ok <- executePrepared stmt row
                            equal "prepared count" 1 (okAffectedRows ok)
                        "bulk.text-batch" -> do
                            result <- executeMany conn "INSERT INTO mb_stage3_bench VALUES(?,?)" values
                            equal "text-batch count" 1000 (sum (map okAffectedRows result))
                        _ -> fail "unknown bulk benchmark profile"
                    actual <- rows conn "SELECT COUNT(*),SUM(n),SUM(OCTET_LENGTH(v)) FROM mb_stage3_bench"
                    equal "stored rows and every payload" [[1000,500500,128000]] (map (map number) actual)
                    pure 629500
            measure ident (toInteger iterations * 1000) (toInteger iterations * 629500)
                (sum <$> replicateM iterations operation)
    | "prepared." `isPrefixOf` ident = do
        ci <- config
        let cached = ".cached" `isSuffixOf` ident
            wide = "prepared.wide." `isPrefixOf` ident
            queryText = if wide then sql ("SELECT 7 AS n," ++ intercalate ","
                ["REPEAT('x',128) AS v" ++ show n | n <- [1..30 :: Int]]) else "SELECT 7 AS n"
            expected = if wide then 3847 else 7
        withConnect (connectWithOptions defaultConnectionOptions {enableMetadataCaching=cached} ci) $ \conn ->
            withPreparedStatement conn queryText $ \stmt -> do
                let operation = do
                        (_, stream) <- queryPrepared stmt []
                        checksum <- S.fold (\total row -> total + sum (map value row)) 0 stream
                        equal "all prepared fields consumed" expected checksum
                        pure checksum
                measure ident (toInteger iterations) (toInteger iterations * expected)
                    (sum <$> replicateM iterations operation)
    | otherwise = fail "unknown native benchmark profile"
  where
    value (MySQLText text) = toInteger (T.length text)
    value other = number other

measure :: String -> Integer -> Integer -> IO Integer -> IO ()
measure ident units expected operation = do
    void operation
    void operation
    performGC
    before <- getRTSStats
    start <- getMonotonicTimeNSec
    checksum <- operation >>= evaluate
    end <- getMonotonicTimeNSec
    performGC
    after <- getRTSStats
    equal "measured checksum" expected checksum
    putStrLn (intercalate "\t" ["STAGE3",ident,show units,show (end-start),
        show (allocated_bytes after-allocated_bytes before),
        show (cpu_ns after-cpu_ns before),show (gc_cpu_ns after-gc_cpu_ns before),show checksum])
