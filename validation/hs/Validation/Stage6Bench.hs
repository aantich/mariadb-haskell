-- | Additive Stage 6 workloads. Every alternative consumes and verifies the
-- same values. Two complete warmups precede each measured process. Cursor
-- materialization and upload/execution are timed; connection/preparation are not.
module Validation.Stage6Bench (run, retentionNegativeControl) where

import Control.Exception (evaluate)
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import Data.List (intercalate, isPrefixOf, isSuffixOf)
import Data.IORef
import qualified Data.Text as T
import Database.MySQL.Base
import GHC.Clock
import GHC.Stats
import System.Mem
import Foreign.Marshal.Utils (fillBytes)
import qualified System.IO.Streams as S
import Validation.Common

run :: String -> Int -> IO ()
run ident iterations
    | iterations <= 0 = fail "positive Stage 6 work count required"
    | ident == "upload.retention" = withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage6_upload_heap(v LONGBLOB) ENGINE=InnoDB"
        withPreparedStatement conn "INSERT INTO mb_stage6_upload_heap VALUES(?)" $ \statement -> do
            let operation = do
                    exec conn "TRUNCATE mb_stage6_upload_heap"
                    source <- retentionSource iterations
                    void (executePreparedStream statement [PreparedBytes source])
                    actual <- scalarInt conn "SELECT OCTET_LENGTH(v) FROM mb_stage6_upload_heap"
                    equal "retention upload size" (toInteger iterations) actual
                    equal "retention upload every byte" 1 =<< scalarInt conn
                        ("SELECT BINARY v=BINARY REPEAT('*'," ++ show iterations ++ ") FROM mb_stage6_upload_heap")
                    pure actual
            measure ident (toInteger iterations) (toInteger iterations) operation
    | "upload." `isPrefixOf` ident = withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage6_upload_bench(n INT,v LONGBLOB) ENGINE=InnoDB"
        withPreparedStatement conn "INSERT INTO mb_stage6_upload_bench VALUES(?,?)" $ \statement -> do
            let operation = do
                    exec conn "TRUNCATE mb_stage6_upload_bench"
                    -- Generate equivalent data inside timing. The buffered
                    -- alternative must materialize a full MiB; the streamed
                    -- alternative retains only its reusable 16 KiB chunk.
                    withTransaction conn $ forM_ [1..iterations] $ \n -> do
                        -- IO allocation prevents full-laziness from hoisting
                        -- payload construction out of the warmup/measured runs.
                        chunk <- BI.create 16384 (\ptr -> fillBytes ptr (fromIntegral n) 16384)
                        if ident == "upload.streamed" then do
                            source <- S.fromList (replicate 64 chunk)
                            ok <- executePreparedStream statement [PreparedValue (MySQLInt32 (fromIntegral n)),PreparedBytes source]
                            equal "stream insert" 1 (okAffectedRows ok)
                        else if ident == "upload.buffered" then do
                            let payload = B.concat (replicate 64 chunk)
                            ok <- executePrepared statement [MySQLInt32 (fromIntegral n),MySQLBytes payload]
                            equal "buffered insert" 1 (okAffectedRows ok)
                        else fail "unknown upload profile"
                    actual <- scalarInt conn "SELECT SUM(OCTET_LENGTH(v)) FROM mb_stage6_upload_bench"
                    equal "all stored bytes" (toInteger iterations * 1048576) actual
                    equal "every stored byte matches its row" (toInteger iterations) =<<
                        scalarInt conn "SELECT SUM(BINARY v=BINARY REPEAT(CHAR(MOD(n,256)),1048576)) FROM mb_stage6_upload_bench"
                    pure actual
            measure ident (toInteger iterations * 1048576) (toInteger iterations * 1048576) operation
    | "cursor." `isPrefixOf` ident = withConn $ \conn ->
        withPreparedStatement conn "SELECT seq,REPEAT('x',128) FROM seq_1_to_10000" $ \statement -> do
            let operation = if ident == "cursor.stream" then do
                    (_,stream) <- queryPrepared statement []
                    consume stream
                  else withCursor statement [] $ \cursor -> do
                    let batchSize = case ident of
                            "cursor.batch32" -> 32
                            "cursor.batch512" -> 512
                            "cursor.batch4096" -> 4096
                            _ -> 0
                        loop total = do
                            done <- cursorExhausted cursor
                            if done then pure total else do
                                value <- fetchCursor cursor batchSize >>= consume
                                loop (total + value)
                    loop 0
            measure ident (toInteger iterations * 10000) (toInteger iterations * 51285000)
                (sum <$> replicateM iterations operation)
    | "transport." `isPrefixOf` ident = do
        ci <- config
        let compressed = ".zlib" `isSuffixOf` ident
            wide = "transport.wide." `isPrefixOf` ident
            width = if wide then 2048 else 32 :: Int
            statementText = sql ("SELECT seq,REPEAT('x'," ++ show width ++ ") FROM seq_1_to_1000")
            expected = 500500 + 1000 * toInteger width
        withConnect (connectWithOptions defaultConnectionOptions {enableCompression=compressed} ci) $ \conn ->
            withPreparedStatement conn statementText $ \statement -> do
                let operation = queryPrepared statement [] >>= consume . snd
                measure ident (toInteger iterations * 1000) (toInteger iterations * expected)
                    (sum <$> replicateM iterations operation)
    | "progress." `isPrefixOf` ident = do
        ci <- config
        let enabled = ident == "progress.enabled"
        withConnect (connectWithOptions defaultConnectionOptions {enableProgressReporting=enabled} ci) $ \conn -> do
            when enabled (setProgressCallback conn (Just (const (pure ()))))
            let operation = scalarInt conn "SELECT 937"
            measure ident (toInteger iterations) (toInteger iterations * 937)
                (sum <$> replicateM iterations operation)
    | otherwise = fail "unknown Stage 6 benchmark"

-- Each producer read owns fresh payload storage. Repeating slices of one
-- immutable chunk would let a whole-input buffer retain only that one chunk,
-- making the heap checkpoints incapable of detecting the regression.
retentionSource :: Int -> IO (S.InputStream B.ByteString)
retentionSource bytes = do
    produced <- newIORef 0
    S.makeInputStream $ do
        n <- readIORef produced
        if n >= bytes then pure Nothing else do
            let size = min 65536 (bytes-n)
                total = n+size
            chunk <- BI.create size (\ptr -> fillBytes ptr 42 size)
            writeIORef produced total
            when (total `elem` [65536,1048576,16777216,67108864] || total == bytes) $ do
                performGC
                stats <- getRTSStats
                putStrLn ("STAGE6_HEAP\t" ++ show total ++ "\t" ++ show (gcdetails_live_bytes (gc stats)))
            pure (Just chunk)

-- Deliberately wrong consumer, run as a separate correctness process. The same
-- source/checkpoints must expose retaining every chunk before upload starts.
-- Python applies the actual publication guard and requires it to reject this
-- output. No timings from this negative control enter benchmark comparisons.
retentionNegativeControl :: IO ()
retentionNegativeControl = replicateM_ 3 $ do
    source <- retentionSource 67108864
    chunks <- S.toList source
    count <- evaluate (sum (map B.length chunks))
    equal "buffering control consumed the complete source" 67108864 count

consume :: S.InputStream [MySQLValue] -> IO Integer
consume = S.fold (\total row -> total + sum (map value row)) 0
  where
    value (MySQLText text) = toInteger (T.length text)
    value (MySQLBytes bytes) = toInteger (B.length bytes)
    value other = number other

measure :: String -> Integer -> Integer -> IO Integer -> IO ()
measure ident units expected operation = do
    replicateM_ 2 (operation >>= equal "Stage 6 warmup checksum" expected)
    performGC
    before <- getRTSStats
    start <- getMonotonicTimeNSec
    checksum <- operation >>= evaluate
    end <- getMonotonicTimeNSec
    performGC
    after <- getRTSStats
    equal "Stage 6 measured checksum" expected checksum
    putStrLn (intercalate "\t" ["STAGE6",ident,show units,show (end-start),
        show (allocated_bytes after-allocated_bytes before),show (cpu_ns after-cpu_ns before),
        show (gc_cpu_ns after-gc_cpu_ns before),show checksum])
