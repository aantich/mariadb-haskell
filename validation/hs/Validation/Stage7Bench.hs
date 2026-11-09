-- | Complete external-authentication setup costs. Each operation opens,
-- authenticates, initializes, verifies a query and closes a connection. The
-- fixture already owns a service-ticket cache; KDC acquisition is not timed.
module Validation.Stage7Bench (run) where

import Control.Exception (evaluate)
import Control.Monad
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Database.MySQL.Base
import GHC.Clock
import GHC.Stats
import System.Environment
import System.Mem
import Validation.Common
import Validation.ExternalAuthFixture (pamConnect, gssapiConnect)

run :: String -> Int -> IO ()
run ident count = do
    when (count <= 0) (fail "positive authentication benchmark count required")
    password <- BC.pack <$> getEnv "MB_AUTH_PAM_PASSWORD"
    code <- BC.pack <$> getEnv "MB_AUTH_PAM_CODE"
    let open = case ident of
            "auth.pam.password" -> pamConnect "mariadb_pam" (passwordDialog password)
            "auth.pam.multiple" -> pamConnect "mariadb_pam_multi" (\prompt ->
                pure (if dialogRound prompt == 0 then password else code))
            "auth.gssapi.cached-ticket" -> gssapiConnect
            _ -> fail "unknown authentication benchmark"
        operation = sum <$> replicateM count
            (withConnect open (\conn -> healthy conn >> pure (1 :: Integer)))
    void operation
    void operation
    performGC
    before <- getRTSStats
    start <- getMonotonicTimeNSec
    checksum <- operation >>= evaluate
    end <- getMonotonicTimeNSec
    performGC
    after <- getRTSStats
    equal "authenticated connections verified" (toInteger count) checksum
    putStrLn (intercalate "\t" ["STAGE7",ident,show count,show (end-start),
        show (allocated_bytes after-allocated_bytes before),show (cpu_ns after-cpu_ns before),
        show (gc_cpu_ns after-gc_cpu_ns before),show checksum])
