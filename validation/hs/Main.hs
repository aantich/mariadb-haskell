{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Control.Exception
import Control.Monad
import Data.List (find, intercalate)
import System.Environment
import System.Exit
import System.IO
import Validation.Common
import qualified Validation.Protocol as Protocol
import qualified Validation.Functional as Functional
import qualified Validation.Reliability as Reliability
import qualified Validation.Security as Security
import qualified Validation.CDC as CDC
import qualified Validation.Benchmark as Benchmark
import qualified Validation.Supplementary as Supplementary
import qualified Validation.Stage1 as Stage1

allCases :: [Case]
allCases=Protocol.cases ++ Functional.cases ++ Reliability.cases ++ Security.cases ++ CDC.cases ++ Stage1.cases

main :: IO ()
main=do
    hSetBuffering stdout LineBuffering
    args <- getArgs
    run args `catches`
        [Handler (\(Unsupported msg) -> hPutStrLn stderr msg >> exitWith (ExitFailure 3))
        ,Handler (\(Unavailable msg) -> hPutStrLn stderr msg >> exitWith (ExitFailure 4))
        ,Handler (\(e :: SomeException) -> case fromException e of
            Just (code :: ExitCode) -> exitWith code
            Nothing -> hPutStrLn stderr (displayException e) >> exitFailure)]
  where
    run ["list"]=forM_ allCases $ \c -> putStrLn (intercalate "\t" [caseId c,caseArea c])
    run ["list-benchmarks"]=forM_ Benchmark.benchmarks $ \(ident,n) -> putStrLn (ident ++ "\t" ++ show n)
    run ["preflight"]=preflight
    run ["case",ident]=case find ((==ident) . caseId) allCases of
        Nothing -> throwIO (userError ("unknown test " ++ ident))
        Just c -> caseRun c >> putStrLn ("PASS\t" ++ ident)
    run ["stage1-bench",ident,n]=Supplementary.run ident (read n)
    run ["bench",ident,n]=Benchmark.runBenchmark ident (read n)
    run _=throwIO (userError "usage: mariadb-validation list | list-benchmarks | preflight | case ID | bench ID ITERATIONS | stage1-bench ID ITERATIONS")
