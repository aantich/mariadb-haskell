-- | Complete request-boundary costs: reset/restore/prepare versus opening,
-- initializing, preparing and closing a new connection. Both paths perform the
-- same application work and deliberately leave state for the next boundary.
module Validation.Stage4Bench (run) where

import Control.Exception (bracket, evaluate)
import Control.Monad
import Data.List (intercalate, isSuffixOf, isInfixOf)
import Database.MySQL.Base
import GHC.Clock
import GHC.Stats
import System.Mem
import qualified System.IO.Streams as S
import Validation.Common

run :: String -> Int -> IO ()
run ident iterations
    | iterations <= 0 = fail "positive reuse benchmark count required"
    | ident == "session.snapshot" = withConn $ \conn -> do
        let loop 0 !total = pure (toInteger total)
            loop remaining !total = do
                state <- getSessionState conn
                equal "autocommit observed" (Just True) (sessionAutocommit state)
                equal "no transaction observed" (Just False) (sessionInTransaction state)
                loop (remaining - 1) (total + (1 :: Int))
        measure ident iterations (loop iterations 0)
    | otherwise = do
        ci <- config
        path <- socketPath
        name <- env "MB_TLS_NAME" "localhost"
        let open | ".tcp." `isInfixOf` ident = connect ci
                 | ".tls." `isInfixOf` ident = tlsConnect ci name
                 | ".socket." `isInfixOf` ident = connectUnixSocket path ci
                 | otherwise = fail "unknown reuse transport"
            initialize conn = exec conn "SET time_zone='+00:00',sql_mode='STRICT_TRANS_TABLES',autocommit=1"
            request conn = do
                -- Preparation is intentionally inside timing. RESET and a new
                -- connection both remove the preceding request's statement.
                statement <- prepareStatement conn "SELECT 7,@@time_zone,@@sql_mode,@mb_stage4_bench IS NULL"
                (_, stream) <- queryPrepared statement []
                result <- S.toList stream
                case result of
                    [[n,MySQLText zone,MySQLText modes,clean]] -> do
                        equal "request result" 7 (number n)
                        equal "application timezone restored" "+00:00" zone
                        equal "application SQL mode restored" "STRICT_TRANS_TABLES" modes
                        equal "no prior request's variable" 1 (number clean)
                    _ -> fail "reuse benchmark request shape mismatch"
                exec conn "SET @mb_stage4_bench=7,time_zone='+01:00'"
                pure 1
        if ".reset" `isSuffixOf` ident
        then withConnect open $ \conn -> measure ident iterations $ sum <$> replicateM iterations
            (resetConnectionWith conn initialize >> request conn)
        else if ".reconnect" `isSuffixOf` ident
        then measure ident iterations $ sum <$> replicateM iterations
            (bracket open close (\conn -> initialize conn >> request conn))
        else fail "unknown reuse benchmark mode"

-- Same warmups/GC/RTS convention as the native recorder. Units are complete
-- requests, or snapshot calls for session.snapshot; the checksum is one/unit.
measure :: String -> Int -> IO Integer -> IO ()
measure ident count operation = do
    void operation
    void operation
    performGC
    before <- getRTSStats
    start <- getMonotonicTimeNSec
    checksum <- operation >>= evaluate
    end <- getMonotonicTimeNSec
    performGC
    after <- getRTSStats
    equal "reuse benchmark checksum" (toInteger count) checksum
    putStrLn (intercalate "\t" ["STAGE4",ident,show count,show (end-start),
        show (allocated_bytes after-allocated_bytes before),show (cpu_ns after-cpu_ns before),
        show (gc_cpu_ns after-gc_cpu_ns before),show checksum])
