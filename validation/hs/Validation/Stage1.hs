{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Stage1 (cases) where
import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import Data.IORef
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import Data.Time.LocalTime (TimeOfDay(..))
import Database.MySQL.Base
import qualified Database.MySQL.Connection as C
import qualified Database.MySQL.BinLog as BinLog
import qualified System.IO.Streams as S
import System.Timeout
import Validation.Common
import Validation.FaultTransport

case1 :: String -> IO () -> Case
case1 ident = Case ("stage1."++ident) "stage1"

cases :: [Case]
cases =
    [ case1 "session.executable-comment-tracker-raw" $ withConn $ \c -> do
        exec c "/*M! SET session_track_system_variables='' */"
        expectContextUnknown c
        refreshSessionState c
        healthy c
    , case1 "session.executable-comment-tracker-prepared" $ withConn $ \c -> do
        bracket (prepareStmt c "/*M! SET session_track_system_variables='' */") (closeStmt c) $ \statement -> do
            -- PREPARE itself has no session effect; execution does.
            void (getRenderContext c)
            void (executeStmt c statement [])
            expectContextUnknown c
        refreshSessionState c
        healthy c
    , case1 "session.executable-comment-tracker-bound" $ withConn $ \c -> do
        void (execute c "/*M! SET session_track_system_variables=? */" [MySQLText ""])
        expectContextUnknown c
        refreshSessionState c
        healthy c
    , case1 "parameters.comment-digit-prefixes" $ withConn $ \c -> do
        forM_
            [ ("SELECT ? /*12345678901234567890*/", [MySQLInt32 7], 7)
            , ("SELECT /*!1 + ? */", [MySQLInt32 6], 7)
            , ("SELECT /*!1000007 + ? */", [MySQLInt32 2], 9)
            , ("SELECT ? /*!9999997 + ? */", [MySQLInt32 7], 7)
            , ("SELECT ? /*!999999 ignored /* nested ? */ + ? */", [MySQLInt32 7], 7)
            ] $ \(template, parameters, expected) -> do
                refreshSessionState c
                (_, stream) <- query c template parameters
                equal "server-compatible comment prefix" [[expected]] . map (map number) =<< S.toList stream
    , case1 "parameters.inactive-comment-context-retained" $ withConn $ \c -> do
        (_, first) <- query c "SELECT ? /*!999999 + ? */" [MySQLInt32 7]
        equal "inactive body is skipped" [[7]] . map (map number) =<< S.toList first
        (_, second) <- query c "SELECT ?" [MySQLInt32 8]
        equal "inactive comments need no refresh" [[8]] . map (map number) =<< S.toList second
    , case1 "parameters.server-prepared-lexer-parity" $ withConn $ \c -> do
        -- MariaDB's prepared-parameter count is independent of our text lexer.
        -- Compare actual execution too, normalizing only integer wire widths.
        forM_ ["", "NO_BACKSLASH_ESCAPES", "ANSI_QUOTES", "NO_BACKSLASH_ESCAPES,ANSI_QUOTES"] $ \mode -> do
            exec c ("SET sql_mode='" ++ mode ++ "'")
            forM_
                [ "SELECT ?", "SELECT '?',?", "SELECT 'it''s ?',?"
                , "SELECT 1 /* ? */,?", "SELECT 1 -- ?\n,?", "SELECT 1 # ?\n,?"
                , "SELECT `?`,? FROM (SELECT 1 AS `?`) t"
                , "SELECT /*!1 + ? */", "SELECT /*!1000007 + ? */"
                , "SELECT ? /*!50701 + ? */", "SELECT ? /*!9999997 + ? */"
                , "SELECT ? /*!999999 ignored /* nested ? */ + ? */"
                , "SELECT ? /*12345678901234567890*/"
                ] $ \template -> do
                    refreshSessionState c
                    bracket (prepareStmtDetail c template) (\(info,_,_) -> closeStmt c (stmtId info)) $ \(info,_,_) -> do
                        let parameters = replicate (stmtParamCnt info) (MySQLInt32 7)
                        (_, binary) <- queryStmt c (stmtId info) parameters
                        expected <- S.toList binary
                        -- An active executable comment is deliberately opaque
                        -- even when this fixture's expression is side-effect free.
                        refreshSessionState c
                        (_, text) <- query c template parameters
                        actual <- S.toList text
                        equal "prepared/text lexer parity" (map (map comparable) expected) (map (map comparable) actual)
    , case1 "parameters.batch-trailing-statement-delimiter" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_stage1_delimiter(n INT)"
        -- Connector/C independently confirms the final comment-only OK. Keep
        -- that reply; fixing the separator must not discard server results.
        forM_ [("INSERT INTO mb_stage1_delimiter VALUES(?);", [1,1]),
               ("INSERT INTO mb_stage1_delimiter VALUES(?); -- final comment", [1,1,0]),
               ("INSERT INTO mb_stage1_delimiter VALUES(?); # final comment", [1,1,0]),
               ("INSERT INTO mb_stage1_delimiter VALUES(?) /* semicolon ; */", [1,1])] $ \(template, expected) -> do
            exec c "TRUNCATE mb_stage1_delimiter"
            oks <- executeMany c template [[MySQLInt32 7], [MySQLInt32 8]]
            equal "all native server replies preserved" expected (map okAffectedRows oks)
            equal "all parameter sets inserted" 15 =<< scalarInt c "SELECT SUM(n) FROM mb_stage1_delimiter"
    , case1 "parameters.reversed-comments-rejected" $ do
        (c, sent, _) <- scripted defaultConnectionOptions []
        writeIORef (C.connectionRenderContext c) (Just defaultRenderContext {renderServerVersion=130200})
        forM_ ["SELECT ? /*!!999999 + ? */", "SELECT ? /*M!!999999 + ? */"] $ \template -> do
            result <- try (query c template [MySQLInt32 7])
            case result of
                Left (UnsupportedRenderingContext _) -> pure ()
                _ -> fail "unsupported reversed comment was rendered"
        equal "rejected before writing" [] =<< sent
        equal "pre-send rejection preserves connection" Ready =<< connectionStatus c
    , case1 "session.snapshot-value-bound" $ do
        let values = B.replicate 4097 65 : drop 1 validSnapshot
        (c, _, _) <- scripted defaultConnectionOptions (snapshotPackets values)
        expectRejection (refreshSessionState c)
        equal "oversized rendering fact retires connection" Broken =<< connectionStatus c
        (budgeted, _, _) <- scripted defaultConnectionOptions {maximumMetadataBytes=300}
            (snapshotPackets (B.replicate 512 65 : drop 1 validSnapshot))
        expectRejection (refreshSessionState budgeted)
        equal "snapshot also respects metadata budget" Broken =<< connectionStatus budgeted
    , case1 "session.snapshot-invalid-facts" $ do
        forM_ [take 4 validSnapshot ++ ["not-a-version", "67108864"],
               take 4 validSnapshot ++ ["0.0.0", "67108864"],
               take 5 validSnapshot ++ ["not-a-limit"]] $ \values -> do
            (c, _, _) <- scripted defaultConnectionOptions (snapshotPackets values)
            expectRejection (refreshSessionState c)
            equal "invalid facts fail inside owned exchange" Broken =<< connectionStatus c
    , case1 "session.snapshot-more-results-rejected" $ do
        let packets = take 9 (snapshotPackets validSnapshot) ++ [encodeToPacket 10 (EOF 0 10)]
        (c, _, _) <- scripted defaultConnectionOptions packets
        expectRejection (refreshSessionState c)
        equal "unexpected snapshot continuation cannot publish Ready" Broken =<< connectionStatus c
    , case1 "values.binary-time-microseconds-bounds" $ do
        let field = ColumnDef "" "" "" "v" "" 63 16 mySQLTypeTime 0 6
            packet micro = putToPacket 1
                (putWord8 12 >> putWord8 0 >> putWord32le 0 >> putWord8 0
                 >> putWord8 0 >> putWord8 0 >> putWord32le micro)
        forM_ [1000000, 2147483648, 4294967295] $ \micro ->
            expectRejection (getFromPacketExact (getBinaryField field) (packet micro))
        equal "highest valid fractional TIME" (MySQLTime 0 (TimeOfDay 0 0 0.999999))
            =<< getFromPacketExact (getBinaryField field) (packet 999999)
    , case1 "session.malformed-snapshot-retires" $ do
        let field = ColumnDef "" "" "" "v" "" 224 128 mySQLTypeString 0 0
            metadata = putToPacket 1 (putLenEncInt 6)
                : [encodeToPacket n field | n <- [2..7]] ++ [encodeToPacket 8 (EOF 0 2)]
            snapshot = ["", "utf8mb4", "utf8mb4", "utf8mb4_unicode_ci", "12.3.3", "67108864"]
            row values trailer = putToPacket 9 (mapM_ putLenEncBytes values >> trailer)
            endings = [encodeToPacket 10 (EOF 0 2)]
            malformed =
                [ textTranscript -- Wrong snapshot column count.
                , metadata ++ row snapshot (putWord8 0) : endings
                , metadata ++ row (B.singleton 255 : drop 1 snapshot) (pure ()) : endings
                ]
        forM_ malformed $ \packets -> do
            (c,_,_) <- scripted defaultConnectionOptions packets
            expectRejection (refreshSessionState c)
            equal "malformed snapshot retires before releasing ownership" Broken =<< connectionStatus c
    , case1 "ownership.completed-command-does-not-finish-successor" $ do
        -- Hold the successor in its writer while the completed action unwinds.
        -- Both success and exception paths must leave that new generation alone.
        forM_ [False, True] $ \failEarlier -> do
            (entered, release, completed) <- (,,) <$> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar
            input <- S.fromList [okPacket 1]
            c <- C.newConnection defaultConnectionOptions input
                (\_ -> putMVar entered () >> takeMVar release) (pure ())
            earlier <- try $ C.withCommand c $ do
                C.finishResponse c
                _ <- forkIO $ (try (ping c) :: IO (Either SomeException OK)) >>= putMVar completed
                takeMVar entered
                when failEarlier (throwIO (userError "completed-command-marker"))
            phase <- connectionStatus c
            putMVar release ()
            successor <- takeMVar completed
            equal "successor retains command ownership" Executing phase
            either throwIO (const (pure ())) successor
            case earlier of
                Left (err :: SomeException) -> assert failEarlier (displayException err)
                Right () -> assert (not failEarlier) "earlier exception disappeared"
            equal "successor completes normally" Ready =<< connectionStatus c
    , case1 "ownership.closed-cannot-become-streaming" $ do
        (c,_,_) <- scripted defaultConnectionOptions []
        close c
        expectRejection (C.markStreaming c)
        equal "closed is terminal" Closed =<< connectionStatus c
    , case1 "parameters.batch-trailing-line-comment" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_stage1_comment(n INT)"
        forM_ ["INSERT INTO mb_stage1_comment VALUES(?) -- final comment",
               "INSERT INTO mb_stage1_comment VALUES(?) # final comment"] $ \template -> do
            exec c "TRUNCATE mb_stage1_comment"
            oks <- executeMany c template [[MySQLInt32 7], [MySQLInt32 8]]
            equal "both statements execute" [1,1] (map okAffectedRows oks)
            equal "neither insert is swallowed by a comment" 15 =<< scalarInt c "SELECT SUM(n) FROM mb_stage1_comment"
    , case1 "cleanup.transport-cancellation-propagates" $ do
        input <- S.fromList []
        c <- C.newConnection defaultConnectionOptions input (const (pure ())) (throwIO ThreadKilled)
        result <- try (C.abortConnection c False)
        case result of
            Left ThreadKilled -> pure ()
            _ -> fail "transport cleanup swallowed cancellation"
        equal "retired before cancellation propagates" Broken =<< connectionStatus c
    , case1 "replication.setup-error-retires" $ do
        -- CDC setup now uses one atomic SET without discovery when ACK is off.
        -- Inject the same server error into that first setup command.
        let packets = [encodeToPacket 1 (ERR 1236 "HY000" "injected binlog failure")]
        (c,_,closed) <- scripted defaultConnectionOptions packets
        expectERR [1236] (BinLog.dumpBinLog c 123 (BinLog.BinLogTracker "binlog.000001" 4) False)
        equal "failed replication setup retires its owner" Broken =<< connectionStatus c
        equal "failed replication setup releases transport" 1 =<< closed
    , case1 "transaction.concurrent-close-commit-unknown" $ do
        reached <- newEmptyMVar; released <- newEmptyMVar; completed <- newEmptyMVar
        readCount <- newIORef (0::Int); writes <- newIORef (0::Int)
        input <- S.makeInputStream $ do
            n <- atomicModifyIORef' readCount (\x -> (x+1,x))
            if n==0 then pure (Just (okPacket 1))
            else putMVar reached () >> readMVar released >> throwIO NetworkException
        c <- C.newConnection defaultConnectionOptions input (\_ -> modifyIORef' writes (+1)) (putMVar released ())
        writeIORef (C.connectionServerStatus c) (Just 2)
        _ <- forkIO $ (try (withTransaction c (pure (7::Int))) :: IO (Either SomeException Int)) >>= putMVar completed
        takeMVar reached
        close c
        result <- takeMVar completed
        case result of Left err | Just (CommitOutcomeUnknown _) <- fromException err -> pure (); _ -> fail "concurrent close lost uncertain COMMIT outcome"
        equal "connection remains closed" Closed =<< connectionStatus c
        equal "one BEGIN and one COMMIT, no replay" 2 =<< readIORef writes
        failure <- connectionFailure c
        assert (maybe False commitOutcomeUncertain failure) "uncertain outcome missing from closed diagnostics"
    , case1 "transaction.closed-after-known-commit-error" $ do
        self <- newIORef Nothing
        readCount <- newIORef (0::Int)
        input <- S.makeInputStream $ do
            n <- atomicModifyIORef' readCount (\x -> (x+1,x))
            if n==0 then pure (Just (okPacket 1)) else do
                owner <- readIORef self
                maybe (fail "fixture connection not set") close owner
                pure (Just (encodeToPacket 1 (ERR 1180 "HY000" "known COMMIT failure")))
        c <- C.newConnection defaultConnectionOptions input (const (pure ())) (pure ())
        writeIORef self (Just c)
        writeIORef (C.connectionServerStatus c) (Just 2)
        result <- try (withTransaction c (pure (7::Int))) :: IO (Either SomeException Int)
        case result of Left err | Just (ERRException server) <- fromException err -> equal "known error preserved" 1180 (errCode server); _ -> fail "known terminal error became uncertain"
        equal "closed with complete reply" Closed =<< connectionStatus c
        failure <- connectionFailure c
        assert (maybe True (not . commitOutcomeUncertain) failure) "known error marked uncertain"
    , case1 "proxy.lost-commit-acknowledgement" $ withConn $ \control -> do
        exec control "DROP TABLE IF EXISTS mb_stage1_durable"
        exec control "CREATE TABLE mb_stage1_durable(n INT) ENGINE=InnoDB"
        ci <- config
        withFaultProxy ci DropCommitReply $ \proxyCi stats -> withConnect (connect proxyCi) $ \c -> do
            outcome <- try (withTransaction c (exec c "INSERT INTO mb_stage1_durable VALUES(7)"))
            case outcome of Left (CommitOutcomeUnknown _) -> pure (); _ -> fail "lost commit reply did not report unknown outcome"
            equal "durable row independently verified" 7 =<< scalarInt control "SELECT n FROM mb_stage1_durable"
            equal "no COMMIT replay" 1 . proxyCommits =<< stats
            equal "original connection retired" Broken =<< connectionStatus c
        exec control "DROP TABLE mb_stage1_durable"
    , case1 "proxy.fragmented-handshake-and-results" $ do
        ci <- config
        withFaultProxy ci (FragmentTraffic 1) $ \proxyCi _ -> withConnect (connect proxyCi) $ \c -> do
            equal "fragmented result" 937 =<< scalarInt c "SELECT 937"
            healthy c
    , case1 "proxy.disconnect-before-metadata" $ do
        ci <- config
        withFaultProxy ci DropTargetReply $ \proxyCi _ -> withConnect (connect proxyCi) $ \c -> do
            expectRejection (query_ c "SELECT 7 /*mb_stage1_fault*/")
            equal "retired before metadata" Broken =<< connectionStatus c
    , case1 "proxy.actual-command-counts" $ do
        ci <- config
        withFaultProxy ci (FragmentTraffic 65536) $ \proxyCi stats -> withConnect (connect proxyCi) $ \c -> do
            let count action expected = do
                    before <- proxyCommands <$> stats
                    _ <- action
                    after <- proxyCommands <$> stats
                    equal "wire command count" expected (after-before)
                param = query c "SELECT ?" [MySQLInt32 7] >>= S.skipToEof . snd
            count (param >> param) 2
            count (exec c "DO 1" >> param) 2
            count (withTransaction c (pure ())) 2
            count (void (executeMany c "DO ?" [[MySQLInt32 1],[MySQLInt32 2]])) 1
            exec c "SET @@session.session_track_system_variables=''"
            count (expectContextUnknown c) 0
            count (refreshSessionState c) 2
            count param 1
    , case1 "session.tracker-selection-preserved" $ withConn $ \c -> do
        exec c "SET session_track_system_variables='time_zone'"
        refreshSessionState c
        actual <- rows c "SELECT @@session.session_track_system_variables"
        let bytes=case actual of [[MySQLText value]] -> T.splitOn "," value; _ -> []
        assert (all (`elem` bytes) ["time_zone","sql_mode","character_set_client","character_set_connection"]) "session tracker selections lost"
        exec c "SET session_track_system_variables='*'"
        refreshSessionState c
        equal "wildcard preserved" [[MySQLText "*"]] =<< rows c "SELECT @@session.session_track_system_variables"
    , case1 "session.unknown-tracking-kind-skipped" $ do
        let reply=putToPacket 1 (putWord8 0 >> putWord8 0 >> putWord8 0 >> putWord16le 0x4002 >> putWord16le 0 >> putLenEncBytes "" >> putLenEncBytes (L.toStrict (runPut (putWord8 42 >> putLenEncBytes "opaque"))))
        (c,_,_) <- scripted defaultConnectionOptions [reply]
        writeIORef (C.connectionCapabilities c) 0x1800000
        writeIORef (C.connectionRenderContext c) (Just defaultRenderContext)
        void (ping c)
        equal "known context retained" defaultRenderContext =<< getRenderContext c
    , case1 "cleanup.absolute-deadline-preserves-primary" $ do
        packets <- newIORef (okPacket 1 : take 4 textTranscript)
        stalled <- newEmptyMVar
        input <- S.makeInputStream $ do
            next <- atomicModifyIORef' packets (\xs -> case xs of [] -> ([],Nothing); x:rest -> (rest,Just x))
            case next of Just x -> pure (Just x); Nothing -> takeMVar stalled
        c <- C.newConnection defaultConnectionOptions {cleanupTimeoutMicros=20000} input (const (pure ())) (pure ())
        writeIORef (C.connectionServerStatus c) (Just 2)
        result <- timeout 1000000 $ try $ withTransaction c $ do
            (_,stream) <- query_ c "SELECT 7"
            void (S.read stream)
            throwIO (userError "primary-cleanup-marker")
        case result of Just (Left (err :: SomeException)) -> assert ("primary-cleanup-marker" `T.isInfixOf` T.pack (displayException err)) "primary replaced"; _ -> fail "cleanup deadline failed"
        equal "stalled cleanup retired" Broken =<< connectionStatus c
    , case1 "fault.wrong-first-sequence" $ do
        (c,_,closed) <- scripted defaultConnectionOptions [okPacket 2]
        expectRejection (ping c)
        equal "connection retired" Broken =<< connectionStatus c
        equal "one abort" 1 =<< closed
        close c; close c
        equal "idempotent release" 1 =<< closed
    , case1 "fragments.physical-exchange-sequence-wrap" $ do
        (c,_,_) <- scripted defaultConnectionOptions [Packet 1 n "x" | n <- [254,255,0]]
        C.setExchangeSequence c 254
        actual <- replicateM 3 (pSeqN <$> C.readConnPacket c)
        equal "physical sequence wraps modulo 256" [254,255,0] actual
    , case1 "fault.eof-metadata-validates" $ do
        let packets=take 2 textTranscript ++ [okPacket 3]
        (c,_,_) <- scripted defaultConnectionOptions packets
        expectRejection (query_ c "SELECT 7")
        equal "malformed metadata retires" Broken =<< connectionStatus c
    , case1 "fault.old-stream-cannot-read-new-command" $ do
        (c,sent,_) <- scripted defaultConnectionOptions textTranscript
        (_,stream) <- query_ c "SELECT 7"
        C.finishResponse c -- fixture simulates invalidation before another generation
        closeStmt c 123
        expectRejection (S.read stream)
        equal "exactly two commands" 2 . length =<< sent
    , case1 "fault.unread-close-sends-nothing" $ do
        (c,sent,_) <- scripted defaultConnectionOptions textTranscript
        (_,stream) <- query_ c "SELECT 7"
        expectRejection (closeStmt c 123)
        equal "no close bytes" 1 . length =<< sent
        equal "original stream intact" [[MySQLInt32 7]] =<< S.toList stream
        equal "repeated EOF" Nothing =<< S.read stream
    , case1 "fault.server-error-reusable" $ do
        (c,_,_) <- scripted defaultConnectionOptions [encodeToPacket 1 (ERR 1064 "42000" "syntax"),okPacket 1]
        expectERR [1064] (ping c)
        void (ping c)
        equal "terminal ERR allows reuse" Ready =<< connectionStatus c
    , case1 "fault.partial-write-retires" $ do
        input <- S.fromList []
        closed <- newIORef (0::Int)
        c <- C.newConnection defaultConnectionOptions input (\_ -> throwIO (userError "injected partial write")) (modifyIORef' closed (+1))
        expectRejection (ping c)
        equal "broken" Broken =<< connectionStatus c
        equal "released" 1 =<< readIORef closed
    , case1 "fault.pre-send-limit-is-clean" $ do
        (c,sent,_) <- scripted defaultConnectionOptions {maximumMessageBytes=8} []
        expectRejection (execute_ c "DO 12345678901234567890")
        equal "no bytes sent" [] =<< sent
        equal "clean connection" Ready =<< connectionStatus c
    , case1 "fault.metadata-budget" $ do
        (c,_,_) <- scripted defaultConnectionOptions {maximumMetadataBytes=1} textTranscript
        expectRejection (query_ c "SELECT 7")
        equal "over-limit response retired" Broken =<< connectionStatus c
    , case1 "fault.column-limit" $ do
        (c,_,_) <- scripted defaultConnectionOptions {maximumColumns=1} [putToPacket 1 (putLenEncInt 2)]
        expectRejection (query_ c "SELECT 7,8")
        equal "count rejected" Broken =<< connectionStatus c
    , case1 "fault.ok-terminator-binary-zero-row" $ do
        let col=ColumnDef "" "" "" "n" "" 63 11 mySQLTypeLong 0 0
            end=putToPacket 4 (putWord8 254 >> putWord8 0 >> putWord8 0 >> putWord16le 2 >> putWord16le 0)
            row=putToPacket 3 (putWord8 0 >> putWord8 0 >> putWord32le 7)
        (c,_,_) <- scripted defaultConnectionOptions [putToPacket 1 (putLenEncInt 1),encodeToPacket 2 col,row,end]
        writeIORef (C.connectionCapabilities c) 0x1000000
        (_,stream) <- queryStmt c 1 []
        equal "binary row is not command OK" [[MySQLInt32 7]] =<< S.toList stream
        equal "finished" Ready =<< connectionStatus c
    , case1 "fault.concurrent-command" $ do
        input <- S.fromList [okPacket 1]
        entered <- newEmptyMVar; release <- newEmptyMVar; done <- newEmptyMVar
        c <- C.newConnection defaultConnectionOptions input (\_ -> putMVar entered () >> takeMVar release) (pure ())
        _ <- forkIO ((try (ping c) :: IO (Either SomeException OK)) >>= putMVar done)
        takeMVar entered
        expectRejection (ping c)
        putMVar release ()
        result <- takeMVar done
        either throwIO (const (pure ())) result
        equal "owner completed" Ready =<< connectionStatus c
    , case1 "transaction.thread-exclusion" $ withConn $ \c -> do
        withTransaction c $ do
            result <- newEmptyMVar
            _ <- forkIO ((try (ping c) :: IO (Either ConnectionError OK)) >>= putMVar result)
            other <- takeMVar result
            case other of Left ConcurrentConnectionUse -> pure (); _ -> fail "transaction admitted another thread"
            equal "owner still works" 7 =<< scalarInt c "SELECT 7"
        healthy c
    , case1 "transaction.caught-nested-rejection" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_stage1_tx(n INT) ENGINE=InnoDB"
        withTransaction c $ do
            result <- try (withTransaction c (exec c "INSERT INTO mb_stage1_tx VALUES(8)"))
            case result of Left NestedTransactionUnsupported -> pure (); _ -> fail "nested transaction accepted"
            exec c "INSERT INTO mb_stage1_tx VALUES(7)"
        equal "outer work commits" 7 =<< scalarInt c "SELECT SUM(n) FROM mb_stage1_tx"
    , case1 "transaction.manual-begin-rejected" $ withConn $ \c -> do
        exec c "BEGIN"
        result <- try (withTransaction c (pure ()))
        case result of Left NestedTransactionUnsupported -> pure (); _ -> fail "manual transaction not detected"
        exec c "ROLLBACK"
        healthy c
    , case1 "transaction.returned-unread-rolls-back" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_stage1_tx(n INT) ENGINE=InnoDB"
        expectRejection $ withTransaction c $ do
            exec c "INSERT INTO mb_stage1_tx VALUES(7)"
            query_ c "SELECT seq FROM seq_1_to_1000"
        equal "nothing committed" 0 =<< scalarInt c "SELECT COUNT(*) FROM mb_stage1_tx"
    , case1 "timeout.connection-retired" $ withConn $ \c -> do
        result <- timeout 20000 (rows c "SELECT SLEEP(0.2)")
        equal "timeout propagated" Nothing result
        equal "retired" Broken =<< connectionStatus c
        expectRejection (ping c)
        withConn healthy
    , case1 "session.row-count-no-hidden-probe" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_stage1_rowcount(n INT)"
        exec c "INSERT INTO mb_stage1_rowcount VALUES(1),(2),(3)"
        (_,stream) <- query c "SELECT ROW_COUNT(),?" [MySQLInt32 9]
        actual <- S.toList stream
        equal "preceding statement preserved" [[3,9]] (map (map number) actual)
    , case1 "session.unknown-context-explicit-refresh" $ withConn $ \c -> do
        expectERR [1146] (exec c "SELECT * FROM mb_stage1_missing_table")
        result <- try (query c "SELECT ?" [MySQLInt32 7])
        case result of Left SessionContextUnavailable -> pure (); _ -> fail "unknown context was silently refreshed"
        refreshSessionState c
        (_,stream) <- query c "SELECT ?" [MySQLInt32 7]
        equal "explicit refresh restores parameters" [[7]] . map (map number) =<< S.toList stream
    , case1 "session.tracker-replacement-is-unknown" $ withConn $ \c -> do
        exec c "SET `session_track_system_variables`=''"
        expectContextUnknown c
        refreshSessionState c
        (_,stream) <- query c "SELECT ?" [MySQLInt32 7]
        equal "refresh restores tracking" [[7]] . map (map number) =<< S.toList stream
    , case1 "session.raw-multiple-invalidates" $ withConn $ \c -> do
        void (executeMany_ c "DO 1; DO 2")
        expectContextUnknown c
        refreshSessionState c
        healthy c
    , case1 "session.raw-routine-fast-path-excluded" $ do
        (c,_,_) <- scripted defaultConnectionOptions []
        writeIORef (C.connectionRenderContext c) (Just defaultRenderContext)
        forM_ ["SELECT mb_stage1_context_fn()","SELECT db.mb_stage1_context_fn()","INSERT INTO t(n) VALUES(mb_stage1_context_fn())","SELECT `mb_stage1_context_fn`()"] $ \statement -> do
            C.classifyQueryEffect c statement
            equal "opaque call excluded" (Just True) =<< readIORef (C.connectionQueryEffect c)
        C.classifyQueryEffect c "INSERT INTO t(n) VALUES(1),(2),(3)"
        equal "flat numeric insert fast path" (Just False) =<< readIORef (C.connectionQueryEffect c)
    , case1 "session.prepared-tracker-replacement-is-unknown" $ withConn $ \c -> do
        bracket (prepareStmt c "SET session_track_system_variables=''") (closeStmt c) $ \st -> void (executeStmt c st [])
        expectContextUnknown c
        refreshSessionState c
        healthy c
    , case1 "session.mode-changes-both-directions" $ withConn $ \c -> do
        forM_ ["NO_BACKSLASH_ESCAPES","","NO_BACKSLASH_ESCAPES,ANSI_QUOTES",""] $ \mode -> do
            exec c ("SET sql_mode='"++mode++"'")
            (_,stream) <- query c "SELECT ?" [MySQLText "a'\\\0b"]
            equal "literal preserved" [[MySQLText "a'\\\0b"]] =<< S.toList stream
    , case1 "session.latin1-parameter" $ withConn $ \c -> do
        exec c "SET NAMES latin1"
        (_,stream) <- query c "SELECT ?" [MySQLText "é€"]
        equal "cp1252 bound text" [[MySQLText "é€"]] =<< S.toList stream
    , case1 "session.latin1-prepared-parameter" $ withConn $ \c -> do
        exec c "SET NAMES latin1"
        equal "prepared cp1252 text" [[MySQLText "é€"]] =<< preparedRows c "SELECT ?" [MySQLText "é€"]
    , case1 "cleanup.second-cancellation-propagates" $ do
        packets <- newIORef (okPacket 1 : take 4 textTranscript)
        reached <- newEmptyMVar; blocked <- newEmptyMVar; completed <- newEmptyMVar
        input <- S.makeInputStream $ do
            next <- atomicModifyIORef' packets (\xs -> case xs of [] -> ([],Nothing); x:rest -> (rest,Just x))
            case next of Just x -> pure (Just x); Nothing -> putMVar reached () >> takeMVar blocked
        c <- C.newConnection defaultConnectionOptions input (const (pure ())) (pure ())
        writeIORef (C.connectionServerStatus c) (Just 2)
        tid <- forkIO $ (try (withTransaction c $ do
            (_,stream) <- query_ c "SELECT 7"
            void (S.read stream)
            throwIO (userError "earlier application failure")) :: IO (Either SomeException ())) >>= putMVar completed
        takeMVar reached
        throwTo tid ThreadKilled
        result <- takeMVar completed
        case result of Left e | Just ThreadKilled <- fromException e -> pure (); _ -> fail "new cancellation was replaced"
        equal "cancelled cleanup retired" Broken =<< connectionStatus c
    , case1 "values.invalid-parameter-before-send" $ do
        (c,sent,_) <- scripted defaultConnectionOptions []
        writeIORef (C.connectionRenderContext c) (Just defaultRenderContext)
        expectRejection (query c "SELECT ?" [MySQLDouble (1/0)])
        equal "no command bytes" [] =<< sent
        equal "still ready" Ready =<< connectionStatus c
    , case1 "session.legacy-eof-integration" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {enableSessionTracking=False} ci) $ \c -> do
            healthy c
            equal "legacy prepared results" [[7]] . map (map number) =<< preparedRows c "SELECT 7" []
            refreshSessionState c
            (_,stream) <- query c "SELECT ?" [MySQLInt32 9]
            equal "explicit legacy context" [[9]] . map (map number) =<< S.toList stream
    , case1 "fault.row-trailing-bytes" $ do
        let packets=take 3 textTranscript ++ [putToPacket 4 (putLenEncBytes "7" >> putWord8 0)]
        (c,_,_) <- scripted defaultConnectionOptions packets
        (_,stream) <- query_ c "SELECT 7"
        expectRejection (S.read stream)
        equal "malformed row retired" Broken =<< connectionStatus c
    , case1 "parameters.quoted-semicolon-batch" $ withConn $ \c -> do
        exec c "CREATE TEMPORARY TABLE mb_stage1_quote(v TEXT,n INT)"
        oks <- executeMany c "INSERT INTO mb_stage1_quote VALUES(';?',?)" [[MySQLInt32 7],[MySQLInt32 8]]
        equal "two statements" [1,1] (map okAffectedRows oks)
        equal "correct bound data" 15 =<< scalarInt c "SELECT SUM(n) FROM mb_stage1_quote"
    , case1 "parameters.opaque-routine-batch-rejected" $ withConn $ \c ->
        expectRejection (executeMany c "SELECT mb_stage1_unknown_routine(?)" [[MySQLInt32 7]])
    , case1 "parameters.quoted-routine-batch-rejected" $ do
        (c,sent,_) <- scripted defaultConnectionOptions []
        writeIORef (C.connectionRenderContext c) (Just defaultRenderContext)
        result <- try (executeMany c "SELECT `mb_stage1_unknown_routine`(?)" [[MySQLInt32 7]])
        case result of Left AmbiguousParameterizedBatch -> pure (); _ -> fail "quoted routine passed batch classifier"
        equal "no bytes before rejection" [] =<< sent
    , case1 "session.unencodable-clean" $ withConn $ \c -> do
        exec c "SET NAMES latin1"
        expectRejection (query c "SELECT ?" [MySQLText "😀"])
        equal "pre-send failure clean" Ready =<< connectionStatus c
        healthy c
    , case1 "parameters.batch-ambiguous-rejected-before-send" $ withConn $ \c -> do
        exec c "SET @mb_stage1_marker=0"
        expectRejection (queryMulti c "SET @mb_stage1_marker=?; SELECT ?" [MySQLInt32 1,MySQLInt32 2])
        equal "no partial execution" 0 =<< scalarInt c "SELECT @mb_stage1_marker"
    , case1 "parameters.injection-remains-data" $ withConn $ \c -> do
        forM_ ["'; SELECT 9; -- ","\\' OR 1=1 #","?; /*M! SELECT 3 */"] $ \text -> do
            (_,stream) <- query c "SELECT ?" [MySQLText text]
            equal "data" [[MySQLText text]] =<< S.toList stream
    , case1 "parameters.executable-comment-active" $ withConn $ \c -> do
        (_,stream) <- query c "SELECT 1 /*M! + ? */" [MySQLInt32 6]
        equal "active comment parameter" [[7]] . map (map number) =<< S.toList stream
    , case1 "parameters.executable-comment-inactive" $ withConn $ \c -> do
        (_,stream) <- query c "SELECT ? /*!50701 + ? */" [MySQLInt32 7]
        equal "inactive question ignored" [[7]] . map (map number) =<< S.toList stream
    , case1 "values.invalid-utf8-rejected" $ do
        let col=ColumnDef "" "" "" "v" "" 224 12 mySQLTypeString 0 0
        expectRejection (getFromPacket (getTextField col) (putToPacket 1 (putLenEncBytes (B.pack [255]))))
    , case1 "values.invalid-utf8-rejected-before-yield" $ do
        let col=ColumnDef "" "" "" "v" "" 224 12 mySQLTypeString 0 0
        (c,_,_) <- scripted defaultConnectionOptions [putToPacket 1 (putLenEncInt 1),encodeToPacket 2 col,encodeToPacket 3 (EOF 0 2),putToPacket 4 (putLenEncBytes (B.pack [255]))]
        (_,stream) <- query_ c "SELECT 'value'"
        expectRejection (void (S.read stream))
        equal "bad value retires at IO boundary" Broken =<< connectionStatus c
    , case1 "fault.trailing-row-unfed-chunk" $ do
        let bad=Packet 3 4 (L.fromChunks [B.pack [1,55],B.singleton 0])
        (c,_,_) <- scripted defaultConnectionOptions (take 3 textTranscript ++ [bad])
        (_,stream) <- query_ c "SELECT 7"
        expectRejection (S.read stream)
        equal "unfed bytes rejected" Broken =<< connectionStatus c
    , case1 "fault.logical-limit-before-continuation-body" $ do
        calls <- newIORef (0::Int)
        blocked <- newEmptyMVar
        source <- S.makeInputStream $ do
            n <- atomicModifyIORef' calls (\x -> (x+1,x))
            case n of
                0 -> pure (Just (B.pack [255,255,255,1]))
                1 -> pure (Just (B.replicate 16777215 120))
                2 -> pure (Just (B.pack [2,0,0,2]))
                _ -> takeMVar blocked
        packets <- C.decodeInputStreamWithLimit 16777216 source
        outcome <- timeout 1000000 (try (C.readPacketWithLimit 16777216 packets) :: IO (Either ConnectionError Packet))
        case outcome of Just (Left (ProtocolError _)) -> pure (); _ -> fail "quota not enforced before body read"
        equal "only first body and two headers read" 3 =<< readIORef calls
    , case1 "fault.missing-tracking-payload" $ do
        (c,_,_) <- scripted defaultConnectionOptions [putToPacket 1 (putWord8 0 >> putWord8 0 >> putWord8 0 >> putWord16le 0x4002 >> putWord16le 0)]
        writeIORef (C.connectionCapabilities c) 0x1800000
        expectRejection (ping c)
        equal "malformed OK retires" Broken =<< connectionStatus c
    , case1 "fault.session-envelope-budget" $ do
        let reply=putToPacket 1 (putWord8 0 >> putWord8 0 >> putWord8 0 >> putWord16le 2 >> putWord16le 0 >> putLenEncBytes "0123456789")
        (c,_,_) <- scripted defaultConnectionOptions {maximumMetadataBytes=8} [reply]
        writeIORef (C.connectionCapabilities c) 0x1800000
        expectRejection (ping c)
        equal "oversize envelope retired" Broken =<< connectionStatus c
    , case1 "parameters.oracle-mode-quotes" $ withConn $ \c -> do
        exec c "SET sql_mode='ORACLE'"
        (_,stream) <- query c "SELECT 'don''t ?',?" [MySQLInt32 7]
        equal "Oracle mode quote keeps its question" [[MySQLText "don't ?",MySQLInt32 7]] =<< S.toList stream
    , case1 "parameters.ansi-identifier-backslash" $ withConn $ \c -> do
        exec c "SET sql_mode='ANSI_QUOTES'"
        (_,stream) <- query c "SELECT \"path\\\",? FROM (SELECT 1 AS \"path\\\") t" [MySQLInt32 7]
        equal "identifier backslash is literal" [[1,7]] . map (map number) =<< S.toList stream
    , case1 "values.unmapped-charset-exact-bytes" $ do
        let col=ColumnDef "" "" "" "v" "" 35 12 mySQLTypeString 0 0
        equal "ucs2 preserved" (MySQLBytes (B.pack [0,233])) =<< getFromPacket (getTextField col) (putToPacket 1 (putLenEncBytes (B.pack [0,233])))
    , case1 "values.raw-dates-text-prepared" $ withConn $ \c -> do
        exec c "SET sql_mode='ALLOW_INVALID_DATES'"
        exec c "CREATE TEMPORARY TABLE mb_stage1_date(d DATE,dt DATETIME(6))"
        let d=DateParts 2023 2 31; value=MySQLDateRaw d
        void (execute c "INSERT INTO mb_stage1_date(d) VALUES(?)" [value])
        equal "text date" [[value]] =<< rows c "SELECT d FROM mb_stage1_date"
        equal "binary date" [[value]] =<< preparedRows c "SELECT d FROM mb_stage1_date" []
        exec c "TRUNCATE mb_stage1_date"
        void (bracket (prepareStmt c "INSERT INTO mb_stage1_date(d) VALUES(?)") (closeStmt c) (\st -> executeStmt c st [MySQLDateRaw (DateParts 0 0 0)]))
        equal "zero preserved" [[MySQLDateRaw (DateParts 0 0 0)]] =<< rows c "SELECT d FROM mb_stage1_date"
    ] ++
    [ case1 ("fragments.limit-"++show limit) $ do
        input <- S.fromList [Packet 5 1 "abcde"]
        if limit<5 then expectRejection (C.readPacketWithLimit limit input) else equal "accepted size" 5 . pLen =<< C.readPacketWithLimit limit input
    | limit <- [4,5,6]
    ] ++
    [ case1 ("values.uint64-"++show n) $ do
        let packet=putToPacket 1 (putWord8 0 >> putLenEncWord64 n >> putLenEncWord64 n >> putWord16le 2 >> putWord16le 0)
        ok <- getFromPacket getOK packet
        equal "affected" n (okAffectedRows ok); equal "insert id" n (okLastInsertID ok)
    | n <- [9223372036854775807,9223372036854775808,18446744073709551615]
    ] ++
    [ case1 ("parameters.quote-"++show i) $ withConn $ \c -> do
        (_,stream) <- query c (sql template) [MySQLInt32 7]
        actual <- S.toList stream
        case actual of
            [values] -> case reverse values of value:_ -> equal "bound final cell" 7 (number value); [] -> fail "empty row"
            _ -> fail "expected one row"
    | (i,template) <- zip [1::Int ..]
        ["SELECT '?',?","SELECT 'it''s ?',?","SELECT `?`,? FROM (SELECT 1 AS `?`) t","SELECT 1 /* ? */,?","SELECT 1 -- ?\n,?","SELECT 1 # ?\n,?","SELECT ';?',?"]
    ]

expectContextUnknown :: MySQLConn -> IO ()
expectContextUnknown c = do
    result <- try (query c "SELECT ?" [MySQLInt32 7])
    case result of
        Left SessionContextUnavailable -> pure ()
        Right (_, stream) -> do
            -- Preserve the assertion failure: leaving this accidental success
            -- unread would let a bracketed closeStmt mask it with another error.
            S.skipToEof stream
            fail "unknown context silently reused"
        _ -> fail "unexpected connection error"

-- Fixed six-column snapshot transcript, independent of the live server. Values
-- remain ordinary wire strings so malformed-fact tests exercise real decoding.
validSnapshot :: [B.ByteString]
validSnapshot = ["", "utf8mb4", "utf8mb4", "utf8mb4_unicode_ci", "12.3.3", "67108864"]

snapshotPackets :: [B.ByteString] -> [Packet]
snapshotPackets values =
    putToPacket 1 (putLenEncInt 6)
    : [encodeToPacket n field | n <- [2..7]]
    ++ [ encodeToPacket 8 (EOF 0 2)
       , putToPacket 9 (mapM_ putLenEncBytes values)
       , encodeToPacket 10 (EOF 0 2)
       ]
  where
    field = ColumnDef "" "" "" "v" "" 224 8192 mySQLTypeString 0 0

-- Prepared and rendered numeric expressions can legitimately use different
-- integer widths. Keep text, bytes and NULL distinct while comparing values.
comparable :: MySQLValue -> (String, String)
comparable (MySQLText text) = ("text", T.unpack text)
comparable (MySQLBytes bytes) = ("bytes", show bytes)
comparable MySQLNull = ("null", "")
comparable value = ("number", show (number value))
