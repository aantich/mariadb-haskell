{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Benchmark (benchmarks, runBenchmark) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Get
import Data.Binary.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.List (intercalate, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Vector as V
import Database.MySQL.Base
import GHC.Clock
import GHC.Stats
import qualified System.IO.Streams as S
import System.Mem
import Validation.Common

benchmarks :: [(String,Int)]
benchmarks =
    [("latency.text",500),("latency.prepared",500)
    ,("read.text.narrow",5),("read.prepared.narrow",5),("read.vector.narrow",5)
    ,("read.text.wide",3),("read.prepared.wide",3)
    ,("read.tls.narrow",5),("read.socket.narrow",5)
    ,("read.parallel-4",3),("read.parallel-16",3)
    ,("write.text",1000),("write.prepared",1000),("write.execute-many",1000)
    ,("blob.text",5),("blob.prepared",5)
    ,("micro.text-row",100000),("micro.binary-row",100000)
    ,("native.bulk",1000),("native.metadata-cache",500)]

narrow,wide :: String
narrow="SELECT id,n,payload FROM mb_bench_data ORDER BY id"
wide="SELECT id,n," ++ intercalate "," (replicate 30 "payload") ++ " FROM mb_bench_data ORDER BY id"

weight :: MySQLValue -> Integer
weight (MySQLText x)=toInteger (T.length x)
weight (MySQLBytes x)=toInteger (B.length x)
weight MySQLNull=0
weight x=number x

consume :: S.InputStream [MySQLValue] -> IO Integer
consume=S.fold (\ !acc row -> acc + sum (map weight row)) 0

consumeVector :: S.InputStream (V.Vector MySQLValue) -> IO Integer
consumeVector=S.fold (\ !acc row -> acc + V.foldl' (\ !s x -> s+weight x) 0 row) 0

textRead :: MySQLConn -> String -> IO Integer
textRead c q=query_ c (sql q) >>= consume . snd

preparedRead :: MySQLConn -> StmtID -> IO Integer
preparedRead c st=queryStmt c st [] >>= consume . snd

parallel :: [IO Integer] -> IO Integer
parallel actions=do
    results <- forM actions $ \action -> do
        done <- newEmptyMVar
        _ <- forkIO (try action >>= putMVar done)
        pure done
    values <- mapM takeMVar results
    sum <$> mapM (either throwIO pure) (values :: [Either SomeException Integer])

-- Each sample is one complete operation (query, transaction, or decoder batch).
-- SQL setup and warm-up happen before counters/timers start.
measure :: String -> Int -> Int -> Integer -> IO Integer -> IO ()
measure name iterations units expected action=do
    replicateM_ 2 (action >>= equal "warm-up checksum" expected)
    performGC
    before <- getRTSStats
    start <- getMonotonicTimeNSec
    samples <- replicateM iterations $ do
        t0 <- getMonotonicTimeNSec
        !checksum <- action
        t1 <- getMonotonicTimeNSec
        equal "benchmark checksum" expected checksum
        pure (t1-t0,checksum)
    end <- getMonotonicTimeNSec
    timed <- getRTSStats
    performGC
    after <- getRTSStats
    putStrLn $ intercalate "\t"
        ["BENCH",name,show (iterations*units),show (end-start)
        ,show (allocated_bytes after-allocated_bytes before)
        ,show (gc_cpu_ns timed-gc_cpu_ns before)
        ,show (max_live_bytes after),show (cpu_ns timed-cpu_ns before)
        ,show (sum (map snd samples)),intercalate "," (map (show . fst) samples)]

runBenchmark :: String -> Int -> IO ()
runBenchmark name n
    | name=="native.bulk" = throwIO (Unsupported "binary bulk API absent")
    | name=="native.metadata-cache" = throwIO (Unsupported "metadata caching absent")
    | name=="micro.text-row" = micro False n
    | name=="micro.binary-row" = micro True n
    | "read.parallel-" `isPrefixOf` name = do
        let workers=read (drop (length ("read.parallel-" :: String)) name)
        ci <- config
        bracket (replicateM workers (connect ci)) (mapM_ quietClose) $ \cs ->
            measure name n (workers*10000) (toInteger workers*201300000) (parallel [textRead c narrow | c <- cs])
    | otherwise=withConnect open $ \c -> case name of
        "latency.text" -> measure name n 1 1 (textRead c "SELECT 1")
        "latency.prepared" -> withStmt c "SELECT 1" $ \st -> measure name n 1 1 (preparedRead c st)
        "read.text.narrow" -> measure name n 10000 201300000 (textRead c narrow)
        "read.prepared.narrow" -> withStmt c narrow $ \st -> measure name n 10000 201300000 (preparedRead c st)
        "read.vector.narrow" -> measure name n 10000 201300000 (queryVector_ c (sql narrow) >>= consumeVector . snd)
        "read.text.wide" -> measure name n 10000 238420000 (textRead c wide)
        "read.prepared.wide" -> withStmt c wide $ \st -> measure name n 10000 238420000 (preparedRead c st)
        "read.tls.narrow" -> measure name n 10000 201300000 (textRead c narrow)
        "read.socket.narrow" -> measure name n 10000 201300000 (textRead c narrow)
        "blob.text" -> measure name n 1048576 1048576 (textRead c "SELECT CAST(REPEAT('x',1048576) AS BINARY)")
        "blob.prepared" -> withStmt c "SELECT CAST(REPEAT('x',1048576) AS BINARY)" $ \st -> measure name n 1048576 1048576 (preparedRead c st)
        "write.text" -> writeBench c Nothing
        "write.prepared" -> do
            exec c "CREATE TEMPORARY TABLE mb_bench_write(n BIGINT) ENGINE=InnoDB"
            withStmt c "INSERT INTO mb_bench_write(n) VALUES(?)" (writeBench c . Just)
        "write.execute-many" -> writeBench c Nothing
        _ -> throwIO (userError ("unknown benchmark " ++ name))
  where
    open=do
        ci <- config
        case name of
            "read.tls.narrow" -> tlsConnect ci "localhost"
            "read.socket.narrow" -> socketPath >>= \p -> connectUnixSocket p ci
            _ -> connect ci
    withStmt c q=bracket (prepareStmt c (sql q)) (closeStmt c)
    writeBench c stmt=do
        exec c "CREATE TEMPORARY TABLE IF NOT EXISTS mb_bench_write(n BIGINT) ENGINE=InnoDB"
        let action=do
                exec c "TRUNCATE TABLE mb_bench_write"
                exec c "BEGIN"
                case (name,stmt) of
                    ("write.execute-many",_) -> void (executeMany c "INSERT INTO mb_bench_write(n) VALUES(?)" [[MySQLInt64 (fromIntegral i)] | i <- [1..n]])
                    (_,Just st) -> forM_ [1..n] $ \i -> void (executeStmt c st [MySQLInt64 (fromIntegral i)])
                    _ -> forM_ [1..n] $ \i -> exec c ("INSERT INTO mb_bench_write(n) VALUES(" ++ show i ++ ")")
                exec c "COMMIT"
                count <- scalarInt c "SELECT COUNT(*) FROM mb_bench_write"
                equal "inserted benchmark row count" (toInteger n) count
                scalarInt c "SELECT COALESCE(SUM(n),0) FROM mb_bench_write"
        measure name 1 n (toInteger n*(toInteger n+1) `div` 2) action

{-# NOINLINE decodeWeight #-}
decodeWeight :: Bool -> [ColumnDef] -> L.ByteString -> IO Integer
decodeWeight binary cols input = case runGetOrFail parser input of
    Left (_,_,err) -> throwIO (userError err)
    Right (_,_,xs) -> evaluate (sum (map weight xs))
  where parser=if binary then getBinaryRow cols (length cols) else getTextRow cols

micro :: Bool -> Int -> IO ()
micro binary n=do
    let name=if binary then "micro.binary-row" else "micro.text-row"
        cols=[ColumnDef "" "" "" "id" "" 63 20 mySQLTypeLongLong 0 0
             ,ColumnDef "" "" "" "n" "" 63 20 mySQLTypeLongLong 0 0
             ,ColumnDef "" "" "" "payload" "" 224 128 mySQLTypeVarString 0 0]
        inputs=[runPut $ if binary
                then putWord8 0 >> putWord8 0 >> putInt64le i >> putInt64le (i*3) >> putLenEncBytes (B.replicate 128 120)
                else putLenEncBytes (fromStringBytes (show i)) >> putLenEncBytes (fromStringBytes (show (i*3))) >> putLenEncBytes (B.replicate 128 120)
               | i <- [1..16]]
        action=go 0 0
          where
            go i !acc
                | i>=n = pure acc
                | otherwise = decodeWeight binary cols (inputs !! (i `mod` 16)) >>= \v -> go (i+1) (acc+v)
        expected=sum [toInteger (4*(i `mod` 16+1)+128) | i <- [0..n-1]]
    measure name 1 n expected action
  where fromStringBytes=B.pack . map (fromIntegral . fromEnum)
