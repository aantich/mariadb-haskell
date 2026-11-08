{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Reliability (cases) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import qualified Data.Text as T
import Database.MySQL.Base
import qualified Database.MySQL.TLS as TLS
import qualified System.IO.Streams as S
import System.Timeout
import Validation.Common
import qualified Validation.Stage3 as Stage3
import qualified Validation.Stage4 as Stage4

cases :: [Case]
cases =
    [ Case "transaction.commit" "transactions" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_tx(n INT) ENGINE=InnoDB"
        withTransaction c (exec c "INSERT INTO mb_tx VALUES(7)")
        equal "commit persisted" 7 =<< scalarInt c "SELECT n FROM mb_tx"
    , Case "transaction.rollback" "transactions" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_tx(n INT) ENGINE=InnoDB"
        result <- try (withTransaction c (exec c "INSERT INTO mb_tx VALUES(7)" >> throwIO (userError "rollback-marker"))) :: IO (Either SomeException ())
        case result of Left _ -> pure (); Right () -> throwIO (userError "transaction did not raise")
        equal "rollback removed insert" 0 =<< scalarInt c "SELECT COUNT(*) FROM mb_tx"
        healthy c
    , Case "transaction.savepoint" "transactions" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_tx(n INT) ENGINE=InnoDB"
        withTransaction c $ do
            exec c "INSERT INTO mb_tx VALUES(7)"
            exec c "SAVEPOINT before_second"
            exec c "INSERT INTO mb_tx VALUES(8)"
            exec c "ROLLBACK TO SAVEPOINT before_second"
        equal "savepoint rollback" [[7]] . map (map number) =<< rows c "SELECT n FROM mb_tx"
    , Case "transaction.partial-result-exception" "transactions" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_tx(n INT) ENGINE=InnoDB"
        result <- try (withTransaction c $ do
            exec c "INSERT INTO mb_tx VALUES(7)"
            (_,stream) <- query_ c "SELECT seq FROM seq_1_to_1000"
            void (S.read stream)
            throwIO (userError "original-application-exception")) :: IO (Either SomeException ())
        case result of
            Left e -> assert ("original-application-exception" `T.isInfixOf` T.pack (displayException e))
                ("original error replaced by " ++ displayException e)
            Right () -> throwIO (userError "expected application exception")
        equal "rollback completed" 0 =<< scalarInt c "SELECT COUNT(*) FROM mb_tx"
    , Case "transaction.nested-preserves-outer" "transactions" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_tx(n INT) ENGINE=InnoDB"
        void (try (withTransaction c $ do
            exec c "INSERT INTO mb_tx VALUES(7)"
            withTransaction c (exec c "INSERT INTO mb_tx VALUES(8)")
            throwIO (userError "outer-rollback")) :: IO (Either SomeException ()))
        equal "nested call must not implicitly commit outer work" 0 =<< scalarInt c "SELECT COUNT(*) FROM mb_tx"
    , Case "transaction.read-committed-no-dirty-read" "transactions" $ withConn $ \a -> withConn $ \b -> do
        exec a "DROP TABLE IF EXISTS mb_isolation"
        exec a "CREATE TABLE mb_isolation(n INT) ENGINE=InnoDB"
        exec b "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED"
        exec a "BEGIN"
        exec a "INSERT INTO mb_isolation VALUES(7)"
        equal "uncommitted row invisible" 0 =<< scalarInt b "SELECT COUNT(*) FROM mb_isolation"
        exec a "COMMIT"
        equal "committed row visible" 1 =<< scalarInt b "SELECT COUNT(*) FROM mb_isolation"
        exec a "DROP TABLE mb_isolation"
    , Case "transaction.lock-timeout-and-reuse" "transactions" $ withConn $ \a -> withConn $ \b -> do
        exec a "DROP TABLE IF EXISTS mb_lock"
        exec a "CREATE TABLE mb_lock(id INT PRIMARY KEY,n INT) ENGINE=InnoDB"
        exec a "INSERT INTO mb_lock VALUES(1,7)"
        exec a "BEGIN"; exec a "UPDATE mb_lock SET n=8 WHERE id=1"
        exec b "SET innodb_lock_wait_timeout=1"
        expectERR [1205] (exec b "UPDATE mb_lock SET n=9 WHERE id=1")
        exec a "ROLLBACK"
        healthy b
        exec a "DROP TABLE mb_lock"
    , Case "transaction.deadlock-and-reuse" "transactions" $ withConn $ \a -> withConn $ \b -> do
        exec a "DROP TABLE IF EXISTS mb_deadlock"
        exec a "CREATE TABLE mb_deadlock(id INT PRIMARY KEY,n INT) ENGINE=InnoDB"
        exec a "INSERT INTO mb_deadlock VALUES(1,7),(2,8)"
        exec a "BEGIN"; exec b "BEGIN"
        exec a "UPDATE mb_deadlock SET n=n+1 WHERE id=1"
        exec b "UPDATE mb_deadlock SET n=n+1 WHERE id=2"
        done <- newEmptyMVar
        _ <- forkIO (try (exec a "UPDATE mb_deadlock SET n=n+1 WHERE id=2") >>= putMVar done)
        threadDelay 50000
        other <- try (exec b "UPDATE mb_deadlock SET n=n+1 WHERE id=1") :: IO (Either SomeException ())
        first <- takeMVar done :: IO (Either SomeException ())
        let isDeadlock (Left e)=case fromException e of Just (ERRException err)->errCode err==1213; Nothing->False
            isDeadlock _=False
        assert (isDeadlock first || isDeadlock other) "no deadlock error was returned"
        exec a "ROLLBACK"; exec b "ROLLBACK"
        healthy a; healthy b
        exec a "DROP TABLE mb_deadlock"
    , Case "transaction.ddl-implicit-commit" "transactions" $ withConn $ \c -> do
        exec c "DROP TABLE IF EXISTS mb_ddl_commit,mb_ddl_created"
        exec c "CREATE TABLE mb_ddl_commit(n INT) ENGINE=InnoDB"
        exec c "BEGIN"; exec c "INSERT INTO mb_ddl_commit VALUES(7)"
        exec c "CREATE TABLE mb_ddl_created(n INT)"
        exec c "ROLLBACK"
        equal "MariaDB DDL commits preceding work" 1 =<< scalarInt c "SELECT COUNT(*) FROM mb_ddl_commit"
        exec c "DROP TABLE mb_ddl_commit,mb_ddl_created"
    , Case "reliability.reset-unread-result" "reliability" $ withConn $ \c -> do
        st <- prepareStmt c "SELECT seq FROM seq_1_to_1000"
        (_,stream) <- queryStmt c st []
        void (S.read stream)
        result <- try (resetStmt c st) :: IO (Either SomeException ())
        case result of
            Left e | Just UnconsumedResultSet <- fromException e -> S.skipToEof stream
            Left e -> throwIO e
            Right () -> pure ()
        healthy c
    , Case "reliability.timeout-before-metadata" "reliability" $ withConn $ \c -> do
        result <- timeout 20000 (rows c "SELECT SLEEP(0.2)")
        equal "query timed out" Nothing result
        healthy c
    , Case "reliability.server-kill-query" "reliability" $ withConn $ \c -> withConn $ \control -> do
        connectionId <- scalarInt c "SELECT CONNECTION_ID()"
        (_,stream) <- query_ c "SELECT REPEAT('x',20000),SLEEP(0.01) FROM seq_1_to_10000"
        void (S.read stream)
        exec control ("KILL QUERY " ++ show connectionId)
        expectERR [1317] (S.skipToEof stream)
        healthy c
    , Case "reliability.peer-disconnect" "reliability" $ withConn $ \c -> withConn $ \control -> do
        connectionId <- scalarInt c "SELECT CONNECTION_ID()"
        exec control ("KILL CONNECTION " ++ show connectionId)
        expectRejection (healthy c)
    , Case "reliability.unread-result-guard" "reliability" $ withConn $ \c -> do
        (_,stream) <- query_ c "SELECT seq FROM seq_1_to_1000"
        result <- try (ping c)
        case result of
            Left UnconsumedResultSet -> pure ()
            Right _ -> throwIO (userError "command allowed while rows remain unread")
        S.skipToEof stream
        healthy c
    , Case "reliability.tls-cancellation-propagates" "reliability" $ withTLS cancellation
    , Case "reliability.tcp-cancellation-propagates" "reliability" $ withConn cancellation
    , Case "connection.tls-untrusted-ca" "connection" $ do
        ci <- config
        params <- TLS.makeClientParams TLS.SystemCAStore
        expectRejection (withConnect (TLS.connect ci (params,"localhost")) healthy)
    , Case "connection.localhost-address-fallback" "connection" $ do
        ci <- config
        withConnect (connect ci {ciHost="localhost"}) healthy
    , Case "types.non-utf8-results" "types" $ withConn $ \c -> do
        exec c "SET character_set_results=latin1"
        equal "latin1 result" "é" . textOf =<< scalar c "SELECT CONVERT(0xE9 USING latin1)"
    , Case "capability.binary-bulk" "capabilities" $ Stage3.bulkFeature
    , Case "capability.metadata-cache" "capabilities" $ Stage3.cacheFeature
    , Case "capability.extended-metadata" "capabilities" $ Stage3.extendedFeature
    , Case "capability.session-tracking" "capabilities" $ Stage4.trackingFeature
    , Case "capability.reset-connection" "capabilities" $ Stage4.resetFeature
    , Case "capability.progress-reporting" "capabilities" $ throwIO (Unsupported "no negotiated MariaDB progress callback")
    , Case "capability.cursor-fetch" "capabilities" $ throwIO (Unsupported "no COM_STMT_FETCH/cursor API")
    , Case "capability.long-data" "capabilities" $ throwIO (Unsupported "no COM_STMT_SEND_LONG_DATA API")
    , Case "capability.compression" "capabilities" $ throwIO (Unsupported "no compressed packet transport")
    ]
  where
    cancellation c = do
        done <- newEmptyMVar
        thread <- forkIO (try (rows c "SELECT SLEEP(5)") >>= putMVar done)
        threadDelay 100000
        throwTo thread ThreadKilled
        result <- takeMVar done :: IO (Either SomeException [[MySQLValue]])
        case result of
            Left e | Just ThreadKilled <- fromException e -> pure ()
            Left e -> throwIO (userError ("cancellation replaced by " ++ displayException e))
            Right _ -> throwIO (userError "cancellation was swallowed")
