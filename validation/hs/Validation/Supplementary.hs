{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Supplementary (run) where

import Control.Exception (evaluate)
import Control.Monad
import Data.List (isPrefixOf)
import Data.IORef
import qualified Data.ByteString as B
import GHC.Clock
import GHC.Stats
import System.Mem
import Database.MySQL.Base
import qualified System.IO.Streams as S
import Validation.Common

-- Separate experiment: no change to any frozen benchmark function or enumeration.
run :: String -> Int -> IO ()
run ident n = case ident of
    "connect.tcp" -> measured (fromIntegral n) $ replicateM_ n (withConn (const (pure ()))) >> pure (fromIntegral n)
    "parameters.select" -> withConn $ \c -> measured (fromIntegral n) $ loop n (param c)
    "parameters.mixed" -> withConn $ \c -> measured (fromIntegral n) $ loop n (scalarInt c "SELECT 3" >> param c)
    "transaction.empty" -> withConn $ \c -> measured (fromIntegral n) $ loop n (withTransaction c (pure 7))
    "batch.1000" -> withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_stage1_batch(n INT)"
        let action = do
                exec c "TRUNCATE mb_stage1_batch"
                void (executeMany c "INSERT INTO mb_stage1_batch VALUES(?)" [[MySQLInt32 x] | x <- [1..1000]])
                scalarInt c "SELECT SUM(n) FROM mb_stage1_batch"
        measured (fromIntegral (n*1000)) (loop n action)
    "stream.retention" -> withConn $ \c -> measured (fromIntegral n) $ do
        (_,stream) <- query_ c (sql ("SELECT seq,REPEAT('x',128) FROM seq_1_to_" ++ show n))
        S.fold (\a row -> a + sum [number v | v <- take 1 row]) 0 stream
    "retention.tiny-slice" -> withConn $ \c -> do
        retained <- newIORef B.empty
        (_,stream) <- query_ c (sql ("SELECT CAST('x' AS BINARY),CAST(REPEAT('y',"++show n++") AS BINARY)"))
        start <- getMonotonicTimeNSec
        let saveFirst = do
                value <- S.read stream
                case value of
                    Just (MySQLBytes small:_) -> writeIORef retained small
                    _ -> fail "tiny slice shape"
        saveFirst
        S.skipToEof stream
        performGC
        stats <- getRTSStats
        small <- readIORef retained
        equal "tiny slice retained exactly" "x" small
        end <- getMonotonicTimeNSec
        putStrLn ("RETENTION\t"++ident++"\t"++show n++"\t"++show (end-start)++"\t"++show (gcdetails_live_bytes (gc stats))++"\t1")
    _ | "retention." `isPrefixOf` ident -> withConn $ \c -> do
        (_,stream) <- query_ c (sql ("SELECT seq,REPEAT('x',128) FROM seq_1_to_" ++ show n))
        let consume count total = do
                next <- S.read stream
                case next of
                    Nothing -> pure total
                    Just values -> do
                        when (count `mod` 10000==0) $ do
                            performGC
                            stats <- getRTSStats
                            putStrLn ("LIVE_HEAP\t"++show count++"\t"++show (gcdetails_live_bytes (gc stats)))
                        value <- case values of x:_ -> pure (number x); [] -> fail "empty retention row"
                        value `seq` total `seq` consume (count+1) (total+value)
        start <- getMonotonicTimeNSec
        checksum <- consume (0::Int) 0
        end <- getMonotonicTimeNSec
        equal "stream retention checksum" (toInteger n*(toInteger n+1) `div` 2) checksum
        performGC
        stats <- getRTSStats
        putStrLn ("RETENTION\t"++ident++"\t"++show n++"\t"++show (end-start)++"\t"++show (gcdetails_live_bytes (gc stats))++"\t"++show checksum)
      | otherwise -> fail ("unknown supplementary profile: " ++ ident)
  where
    param c = do
        (_,stream) <- query c "SELECT ?" [MySQLInt32 7]
        xs <- S.toList stream
        case xs of [[x]] -> pure (number x); _ -> fail "parameter checksum shape"
    loop count action = sum <$> replicateM count action
    measured :: Integer -> IO Integer -> IO ()
    measured units action = do
        -- Two warm-ups with the same operation, then one measured region.
        void action; void action
        performGC
        before <- getRTSStats
        start <- getMonotonicTimeNSec
        checksum <- action >>= evaluate
        end <- getMonotonicTimeNSec
        performGC
        after <- getRTSStats
        putStrLn ("STAGE1\t" ++ ident ++ "\t" ++ show (units :: Integer) ++ "\t" ++ show (end-start)
            ++ "\t" ++ show (allocated_bytes after-allocated_bytes before)
            ++ "\t" ++ show (max_live_bytes after) ++ "\t" ++ show checksum)
