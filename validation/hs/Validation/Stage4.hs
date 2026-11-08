{-# LANGUAGE ScopedTypeVariables #-}
-- | Session isolation checks use both literal wire envelopes and a real server.
-- Tests count actual writes and cover cancellation at restoration boundaries;
-- a successful RESET acknowledgement alone does not prove a reusable session.
module Validation.Stage4 (cases, resetFeature, trackingFeature) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.Word (Word8)
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as M
import Database.MySQL.Base
import qualified Database.MySQL.Connection as C
import qualified System.IO.Streams as S
import System.Timeout
import Validation.Common
import Validation.FaultTransport

case4 :: String -> IO () -> Case
case4 name = Case ("stage4." ++ name) "stage4"

-- Independent literal protocol construction: the parser is not used to encode
-- these fixtures, and malformed known types retain their proper outer length.
item :: Word8 -> Put -> Put
item kind body = putWord8 kind >> putLenEncBytes (L.toStrict (runPut body))

variable :: B.ByteString -> B.ByteString -> Put
variable name value = item 0 (putLenEncBytes name >> putLenEncBytes value)

tracked :: Put -> Packet
tracked changes = putToPacket 1 $ do
    putByteString (B.pack [0,0,0,2,64,0,0])
    putLenEncBytes ""
    putLenEncBytes (L.toStrict (runPut changes))

trackingFixture :: Put -> IO (MySQLConn, IO [Packet], IO Int)
trackingFixture changes = do
    result@(conn, _, _) <- scripted defaultConnectionOptions [tracked changes]
    writeIORef (C.connectionCapabilities conn) (bit 23 .|. bit 24)
    pure result

snapshotPackets :: [Packet]
snapshotPackets = roleSnapshotPackets (putWord8 0xfb)

-- Role is nullable, unlike the six mandatory rendering facts. Keep the literal
-- NULL marker independent of the implementation's row/role decoder.
roleSnapshotPackets :: Put -> [Packet]
roleSnapshotPackets role = [putToPacket 1 (putLenEncInt 7)] ++
    [encodeToPacket n (ColumnDef "" "" "" "fact" "" 33 100 mySQLTypeVarString 0 0) | n <- [2..8]] ++
    [encodeToPacket 9 (EOF 0 2), putToPacket 10 (mapM_ putLenEncBytes
        ["","utf8mb4","utf8mb4","utf8mb4_unicode_ci","12.3.3-MariaDB","67108864"] >> role),
     encodeToPacket 11 (EOF 0 2)]

resetFixture :: [Packet] -> IO (MySQLConn, IO [Packet], IO Int)
resetFixture packets = do
    result@(conn, _, _) <- scripted defaultConnectionOptions packets
    writeIORef (C.connectionInitialSession conn)
        (Just (C.InitialSession "db" "utf8mb4" "utf8mb4_unicode_ci" 120303 Nothing))
    writeIORef (C.connectionServerStatus conn) (Just 2)
    C.recordSessionChanges conn [SchemaChanged "db"]
    pure result

resetTranscript :: [Packet]
resetTranscript = encodeToPacket 1 (OK 0 0 2 0) : snapshotPackets

-- Stall after an optional acknowledged prefix, so deadlines/cancellation are
-- armed by an actual read boundary rather than a scheduler-dependent sleep.
stalledReset :: [Packet] -> IO (MySQLConn, IO (), IO Int)
stalledReset prefix = do
    packets <- newIORef prefix
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    released <- newIORef 0
    input <- S.makeInputStream $ do
        next <- atomicModifyIORef' packets (\remaining -> case remaining of
            [] -> ([],Nothing)
            first:rest -> (rest,Just first))
        case next of
            Just packet -> pure (Just packet)
            Nothing -> void (tryPutMVar entered ()) >> takeMVar blocked
    conn <- C.newConnection defaultConnectionOptions {cleanupTimeoutMicros=20000}
        input (const (pure ())) (modifyIORef' released (+1))
    writeIORef (C.connectionInitialSession conn)
        (Just (C.InitialSession "db" "utf8mb4" "utf8mb4_unicode_ci" 120303 Nothing))
    C.recordSessionFacts conn [SchemaChanged "db"]
    pure (conn, takeMVar entered, readIORef released)

resetFeature :: IO ()
resetFeature = withConn $ \conn -> do
    before <- scalarInt conn "SELECT CONNECTION_ID()"
    exec conn "SET @mb_stage4_user=7"
    exec conn "CREATE TEMPORARY TABLE mb_stage4_temp(n INT)"
    stmt <- prepareStatement conn "SELECT 7"
    void (resetConnection conn)
    equal "reset does not reconnect" before =<< scalarInt conn "SELECT CONNECTION_ID()"
    equal "user variables cleared" MySQLNull =<< scalar conn "SELECT @mb_stage4_user"
    expectERR [1146] (rows conn "SELECT * FROM mb_stage4_temp")
    expectRejection (preparedMetadata stmt)
    refreshSessionState conn
    healthy conn

trackingFeature :: IO ()
trackingFeature = withConn $ \conn -> do
    exec conn "SET time_zone='+01:00'"
    state <- getSessionState conn
    equal "tracked timezone exposed" (Just "+01:00") (M.lookup "time_zone" (sessionVariables state))
    equal "autocommit flag exposed" (Just True) (sessionAutocommit state)
    exec conn "START TRANSACTION"
    active <- getSessionState conn
    equal "transaction flag exposed" (Just True) (sessionInTransaction active)
    exec conn "ROLLBACK"
    equal "rollback flag exposed" (Just False) . sessionInTransaction =<< getSessionState conn

cases :: [Case]
cases =
    [ case4 "tracking.initial-state" $ withConn $ \conn -> do
        ci <- config
        state <- getSessionState conn
        equal "constructor schema observed" (Just (ciDatabase ci)) (sessionSchema state)
        equal "initial autocommit" (Just True) (sessionAutocommit state)
        equal "initial transaction" (Just False) (sessionInTransaction state)
        equal "rendering charset observed" (Just "utf8mb4")
            (M.lookup "character_set_client" (sessionVariables state))
    , case4 "tracking.all-kinds-and-wire-order" $ do
        let changes = do
                variable "time_zone" "+02:00"
                item 1 (putLenEncBytes "second")
                item 2 (putByteString "1")
                item 4 (putLenEncBytes "START TRANSACTION READ ONLY;")
                item 5 (putLenEncBytes "T_______")
                item 77 (putByteString "opaque")
        (conn, _, _) <- trackingFixture changes
        void (ping conn)
        state <- getSessionState conn
        equal "schema decoded" (Just "second") (sessionSchema state)
        equal "characteristics decoded" (Just "START TRANSACTION READ ONLY;") (sessionTransactionCharacteristics state)
        equal "transaction state decoded" (Just "T_______") (sessionTransactionState state)
        equal "all changes in wire order"
            [SystemVariableChanged "time_zone" "+02:00", SchemaChanged "second", SessionStateChanged True,
             TransactionCharacteristicsChanged "START TRANSACTION READ ONLY;", TransactionStateChanged "T_______",
             UnknownSessionChange 77 "opaque"] (sessionLastChanges state)
    , case4 "tracking.repeated-variable-last-wins" $ do
        (conn, _, _) <- trackingFixture (variable "time_zone" "+01:00" >> variable "time_zone" "+02:00")
        void (ping conn)
        equal "later variable replaces earlier" (Just "+02:00") . M.lookup "time_zone" . sessionVariables =<< getSessionState conn
    , case4 "tracking.snapshot-does-no-io" $ do
        (conn, sent, _) <- trackingFixture (variable "time_zone" "+01:00")
        void (ping conn)
        before <- sent
        replicateM_ 100 (void (getSessionState conn))
        equal "snapshot sends no SQL" before =<< sent
    , case4 "tracking.owns-receive-bytes" $ do
        (conn, _, _) <- trackingFixture (variable "time_zone" "+01:00")
        void (ping conn)
        state <- getSessionState conn
        case M.lookup "time_zone" (sessionVariables state) of
            Just value -> do
                let (_, offset, size) = BI.toForeignPtr value
                equal "retained value has exact owned storage" (0,6) (offset,size)
            Nothing -> fail "tracked value missing"
    , case4 "tracking.malformed-known-kinds" $ forM_
        [item 1 (putByteString "bad"), item 2 (putByteString "yes"),
         item 4 (putLenEncBytes "x" >> putWord8 0), item 5 (putLenEncBytes "short"),
         item 0 (putLenEncBytes "name"), variable "" "value"] $ \changes -> do
            (conn, _, released) <- trackingFixture changes
            expectRejection (ping conn)
            equal "malformed tracker retires" Broken =<< connectionStatus conn
            equal "malformed tracker releases once" 1 =<< released
    , case4 "tracking.item-count-bound" $ do
        (conn, _, _) <- trackingFixture (replicateM_ 65536 (item 77 (pure ())))
        expectRejection (ping conn)
        equal "empty items still consume the count budget" Broken =<< connectionStatus conn
    , case4 "tracking.length-overflow-rejected" $ do
        (conn, _, _) <- trackingFixture (putWord8 77 >> putWord8 254 >> putWord64le maxBound)
        expectRejection (ping conn)
        equal "encoded length never wraps to a small payload" Broken =<< connectionStatus conn
    , case4 "tracking.accumulated-budget" $ do
        (conn, _, _) <- scripted defaultConnectionOptions {maximumMetadataBytes=100} []
        C.recordSessionChanges conn [SystemVariableChanged "one" (B.replicate 30 65)]
        expectRejection (C.recordSessionChanges conn [SystemVariableChanged "two" (B.replicate 40 65)])
        equal "accumulated state cannot grow unbounded" Broken =<< connectionStatus conn
    , case4 "tracking.replacement-releases-budget" $ do
        (conn, _, _) <- scripted defaultConnectionOptions {maximumMetadataBytes=100} []
        replicateM_ 1000 (C.recordSessionChanges conn [SystemVariableChanged "same" (B.replicate 30 65)])
        equal "one retained variable" 1 . M.size . sessionVariables =<< getSessionState conn
    , case4 "tracking.explicit-facts-retained-envelope-budget" $ do
        (conn, _, _) <- scripted defaultConnectionOptions {maximumMetadataBytes=100} []
        C.recordSessionChanges conn [UnknownSessionChange 77 (B.replicate 80 65)]
        expectRejection (C.recordSessionFacts conn [SystemVariableChanged "name" (B.replicate 30 65)])
        equal "snapshot seeding charges the retained old envelope" Broken =<< connectionStatus conn
    , case4 "tracking.explicit-facts-do-not-forge-events" $ do
        (conn, _, _) <- trackingFixture (variable "time_zone" "+01:00")
        void (ping conn)
        before <- getSessionState conn
        C.recordSessionFacts conn [SchemaChanged "explicit"]
        after <- getSessionState conn
        equal "explicitly known schema" (Just "explicit") (sessionSchema after)
        equal "wire envelope preserved" (sessionLastChanges before) (sessionLastChanges after)
        equal "wire envelope counter preserved" (sessionChangeNumber before) (sessionChangeNumber after)
    , case4 "tracking.subscription-invalidates-values" $ do
        (conn, _, _) <- trackingFixture $ do
            variable "old" "stale"
            variable "time_zone" "+01:00"
            variable "session_track_system_variables" "time_zone"
        void (ping conn)
        state <- getSessionState conn
        equal "unsubscribed value discarded" Nothing (M.lookup "old" (sessionVariables state))
        equal "selected value preserved" (Just "+01:00") (M.lookup "time_zone" (sessionVariables state))
    , case4 "tracking.schema-and-transaction-controls" $ do
        (conn, _, _) <- trackingFixture $ do
            item 1 (putLenEncBytes "old")
            item 4 (putLenEncBytes "START TRANSACTION;")
            item 5 (putLenEncBytes "T_______")
            variable "session_track_schema" "OFF"
            variable "session_track_transaction_info" "OFF"
        void (ping conn)
        state <- getSessionState conn
        equal "untracked schema becomes unknown" Nothing (sessionSchema state)
        equal "untracked transaction details become unknown" Nothing (sessionTransactionState state)
        equal "untracked transaction characteristics become unknown" Nothing (sessionTransactionCharacteristics state)
    , case4 "tracking.collation-direct-live" $ withConn $ \conn -> do
        exec conn "SET collation_connection='utf8mb4_bin'"
        state <- getSessionState conn
        equal "unreported collation is explicitly unknown" Nothing
            (M.lookup "collation_connection" (sessionVariables state))
    , case4 "tracking.collation-set-names-live" $ withConn $ \conn -> do
        exec conn "SET NAMES latin1"
        state <- getSessionState conn
        equal "connection charset changed" (Just "latin1")
            (M.lookup "character_set_connection" (sessionVariables state))
        equal "SET NAMES leaves unreported collation explicitly unknown" Nothing
            (M.lookup "collation_connection" (sessionVariables state))
    , case4 "tracking.collation-delta-order" $ forM_ [False, True] $ \collationFirst -> do
        let charset = variable "character_set_connection" "latin1"
            collation = variable "collation_connection" "latin1_bin"
        (conn, _, _) <- trackingFixture (if collationFirst then collation >> charset else charset >> collation)
        void (ping conn)
        equal "explicit collation survives either wire order" (Just "latin1_bin")
            . M.lookup "collation_connection" . sessionVariables =<< getSessionState conn
    , case4 "tracking.collation-invalidation-releases-budget" $ do
        (conn, _, _) <- scripted defaultConnectionOptions {maximumMetadataBytes=70} []
        C.recordSessionFacts conn [SystemVariableChanged "collation_connection" (B.replicate 30 65)]
        C.recordSessionChanges conn [SystemVariableChanged "character_set_connection" "latin1"]
        state <- getSessionState conn
        equal "unreported dependent collation discarded" Nothing (M.lookup "collation_connection" (sessionVariables state))
        equal "discarded collation releases its byte charge" Ready =<< connectionStatus conn
    , case4 "tracking.collation-explicit-selection" $ withConn $ \conn -> do
        -- Collation first selects that alias for their shared server offset.
        exec conn "SET session_track_system_variables='sql_mode,character_set_client,collation_connection'"
        refreshSessionState conn
        exec conn "SET collation_connection='latin1_bin'"
        state <- getSessionState conn
        equal "explicitly subscribed collation observed" (Just "latin1_bin")
            (M.lookup "collation_connection" (sessionVariables state))
        equal "unreported charset cannot remain stale" Nothing
            (M.lookup "character_set_connection" (sessionVariables state))
        expectRejection (getRenderContext conn)
        refreshSessionState conn
        equal "explicit refresh establishes the new charset" "latin1"
            . renderConnectionCharset =<< getRenderContext conn
    , case4 "tracking.transaction-characteristics-downgrade" $ do
        (conn, _, _) <- trackingFixture $ do
            item 4 (putLenEncBytes "START TRANSACTION READ ONLY;")
            item 5 (putLenEncBytes "T_______")
            variable "session_track_transaction_info" "STATE"
        void (ping conn)
        state <- getSessionState conn
        equal "STATE retains transaction state" (Just "T_______") (sessionTransactionState state)
        equal "STATE cannot retain characteristics" Nothing (sessionTransactionCharacteristics state)
    , case4 "tracking.transaction-characteristics-downgrade-live" $ withConn $ \conn -> do
        exec conn "SET session_track_transaction_info='CHARACTERISTICS'"
        exec conn "START TRANSACTION READ ONLY"
        before <- getSessionState conn
        equal "read-only characteristics observed" (Just "START TRANSACTION READ ONLY;")
            (sessionTransactionCharacteristics before)
        exec conn "SET session_track_transaction_info='STATE'"
        exec conn "ROLLBACK"
        exec conn "START TRANSACTION READ WRITE"
        after <- getSessionState conn
        equal "new transaction state remains observed" (Just "T_______") (sessionTransactionState after)
        equal "previous transaction's replay text discarded" Nothing (sessionTransactionCharacteristics after)
        exec conn "ROLLBACK"
    , case4 "tracking.live-schema" $ withConn $ \conn -> do
        void (command conn (COM_INIT_DB "information_schema"))
        equal "COM_INIT_DB schema reported" (Just "information_schema") . sessionSchema =<< getSessionState conn
        ci <- config
        exec conn ("USE `" ++ map (toEnum . fromIntegral) (B.unpack (ciDatabase ci)) ++ "`")
        equal "USE schema reported" (Just (ciDatabase ci)) . sessionSchema =<< getSessionState conn
    , case4 "tracking.live-transaction-details" $ withConn $ \conn -> do
        exec conn "SET session_track_transaction_info='CHARACTERISTICS'"
        exec conn "START TRANSACTION READ ONLY"
        state <- getSessionState conn
        assert (sessionTransactionState state /= Nothing) "transaction state not exposed"
        assert (sessionTransactionCharacteristics state /= Nothing) "transaction characteristics not exposed"
        exec conn "ROLLBACK"
    , case4 "tracking.multiple-results-retain-real-envelope" $ withConn $ \conn -> do
        void (queryMulti_ conn "SET time_zone='+01:00'; SET time_zone='+02:00'; SELECT 7")
        state <- getSessionState conn
        assert (SystemVariableChanged "time_zone" "+02:00" `elem` sessionLastChanges state)
            "opaque multi-statement processing lost the latest actual tracker envelope"
        equal "opaque final facts remain conservatively unknown" M.empty (sessionVariables state)
    , case4 "tracking.disabled-transaction-flags" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {enableSessionTracking=False} ci) $ \conn -> do
            exec conn "START TRANSACTION"
            equal "legacy status tracks transaction" (Just True) . sessionInTransaction =<< getSessionState conn
            exec conn "ROLLBACK"
            equal "legacy status tracks rollback" (Just False) . sessionInTransaction =<< getSessionState conn
    , case4 "tracking.error-invalidates" $ withConn $ \conn -> do
        expectERR [1064] (exec conn "SELECT FROM")
        state <- getSessionState conn
        equal "ERR invalidates schema" Nothing (sessionSchema state)
        equal "ERR invalidates variable observations" M.empty (sessionVariables state)
        equal "ERR invalidates transaction flags" Nothing (sessionInTransaction state)
        healthy conn
        equal "next complete reply restores transaction flag" (Just False) . sessionInTransaction =<< getSessionState conn
    , case4 "tracking.disabled-honest-unknowns" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {enableSessionTracking=False} ci) $ \conn -> do
            exec conn "SET time_zone='+01:00'"
            state <- getSessionState conn
            equal "untracked variables unknown" M.empty (sessionVariables state)
            equal "wire transaction flags remain known" (Just False) (sessionInTransaction state)
    , case4 "reset.same-session-and-cleanup" resetFeature
    , case4 "reset.rolls-back-open-transaction" $ withConn $ \conn -> do
        exec conn "DROP TABLE IF EXISTS mb_stage4_rollback"
        exec conn "CREATE TABLE mb_stage4_rollback(n INT) ENGINE=InnoDB"
        flip finally (exec conn "DROP TABLE IF EXISTS mb_stage4_rollback") $ do
            exec conn "START TRANSACTION"
            exec conn "INSERT INTO mb_stage4_rollback VALUES(7)"
            void (resetConnection conn)
            equal "uncommitted insert rolled back" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage4_rollback"
    , case4 "reset.restores-constructor-database" $ withConn $ \conn -> do
        ci <- config
        exec conn "USE information_schema"
        void (resetConnection conn)
        equal "constructor schema selected" (MySQLText (textOf (MySQLBytes (ciDatabase ci)))) =<< scalar conn "SELECT DATABASE()"
        equal "public schema matches" (Just (ciDatabase ci)) . sessionSchema =<< getSessionState conn
    , case4 "reset.restores-charset-and-rendering" $ withConn $ \conn -> do
        exec conn "SET NAMES latin1"
        exec conn "SET sql_mode='NO_BACKSLASH_ESCAPES'"
        void (resetConnection conn)
        equal "original client charset" "utf8mb4" . renderClientCharset =<< getRenderContext conn
        (_, stream) <- query conn "SELECT ?" [MySQLText "unicode \x1f642 '"]
        equal "rendering after reset" [[MySQLText "unicode \x1f642 '"]] =<< S.toList stream
    , case4 "reset.custom-initializer" $ withConn $ \conn -> do
        void $ resetConnectionWith conn $ \session -> exec session
            "SET time_zone='+00:00',sql_mode='ANSI_QUOTES,STRICT_TRANS_TABLES',autocommit=1"
        equal "required settings restored" [[MySQLText "+00:00",MySQLText "ANSI_QUOTES,STRICT_TRANS_TABLES"]]
            =<< rows conn "SELECT @@time_zone,@@sql_mode"
        equal "custom modes reflected" ["ANSI_QUOTES","STRICT_TRANS_TABLES"] . renderSQLModes =<< getRenderContext conn
    , case4 "reset.role-none-before-initializer" $ do
        ci <- config
        withConnect (connect ci {ciUser="mariadb_role_none"}) $ \conn -> do
            equal "fixture starts without role" MySQLNull =<< scalar conn "SELECT CURRENT_ROLE()"
            refreshSessionState conn
            void (execute conn "SET ROLE ?" [MySQLText "mb_stage4_rôle_'`"])
            void $ resetConnectionWith conn $ \session ->
                equal "role cleared before application initialization" MySQLNull
                    =<< scalar session "SELECT CURRENT_ROLE()"
    , case4 "reset.role-default-before-database" $ do
        ci <- config
        withConnect (connect ci {ciUser="mariadb_role_default"}) $ \conn -> do
            equal "quoted Unicode default role active" (MySQLText "mb_stage4_rôle_'`")
                =<< scalar conn "SELECT CURRENT_ROLE()"
            exec conn "SET ROLE mb_stage4_other_role"
            exec conn "USE information_schema"
            -- Only the initial role grants access to the constructor database.
            -- Reversing restoration order fails with an actual access error.
            void (resetConnection conn)
            equal "constructor role restored" (MySQLText "mb_stage4_rôle_'`")
                =<< scalar conn "SELECT CURRENT_ROLE()"
            equal "constructor database accessible after role restoration" (MySQLText "mariadb_haskell_validation")
                =<< scalar conn "SELECT DATABASE()"
    , case4 "reset.role-initializer-and-refresh" $ do
        ci <- config
        withConnect (connect ci {ciUser="mariadb_role_none"}) $ \conn -> do
            void $ resetConnectionWith conn $ \session ->
                exec session "SET ROLE mb_stage4_other_role"
            equal "initializer may choose a request role" (MySQLText "mb_stage4_other_role")
                =<< scalar conn "SELECT CURRENT_ROLE()"
            refreshSessionState conn
            void (resetConnection conn)
            equal "refresh never redefines constructor role" MySQLNull
                =<< scalar conn "SELECT CURRENT_ROLE()"
    , case4 "reset.role-without-tracking" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {enableSessionTracking=False}
            ci {ciUser="mariadb_role_default"}) $ \conn -> do
            exec conn "SET ROLE mb_stage4_other_role"
            exec conn "USE information_schema"
            void (resetConnection conn)
            equal "role restored without tracker assistance" (MySQLText "mb_stage4_rôle_'`")
                =<< scalar conn "SELECT CURRENT_ROLE()"
    , case4 "reset.role-latin1-client" $ do
        ci <- config
        withConnect (connect ci {ciUser="mariadb_role_default",ciCharset=8}) $ \conn -> do
            exec conn "SET ROLE mb_stage4_other_role"
            void (resetConnection conn)
            equal "role literal respects the client encoding" (MySQLText "mb_stage4_rôle_'`")
                =<< scalar conn "SELECT CURRENT_ROLE()"
    , case4 "reset.role-lossy-result-charset" $ do
        ci <- config
        withConnect (connect ci {ciUser="mariadb_role_wide",ciCharset=8}) $ \conn -> do
            initial <- readIORef (C.connectionInitialSession conn)
            equal "constructor retains original UTF-8 role bytes" (Just (TE.encodeUtf8 "mb_stage4_汉"))
                (C.initialRole =<< initial)
            -- Both names become mb_stage4_? in latin1 text results. Only the
            -- binary snapshot can distinguish them without lossy conversion.
            exec conn "SET NAMES utf8mb4"
            exec conn "SET ROLE `mb_stage4_字`"
            exec conn "SET NAMES latin1"
            void (resetConnection conn)
            equal "narrow client charset restored after the Unicode role" "latin1"
                . renderClientCharset =<< getRenderContext conn
            equal "different Unicode role cannot survive a lossy comparison"
                (MySQLBytes (TE.encodeUtf8 "mb_stage4_汉"))
                =<< scalar conn "SELECT CAST(CURRENT_ROLE() AS BINARY)"
    , case4 "reset.role-binary-result-charset" $ do
        ci <- config
        withConnect (connect ci {ciUser="mariadb_role_wide"}) $ \conn -> do
            exec conn "SET character_set_results=binary"
            exec conn "SET ROLE `mb_stage4_字`"
            void (resetConnection conn)
            equal "binary results preserve role identity" (MySQLBytes (TE.encodeUtf8 "mb_stage4_汉"))
                =<< scalar conn "SELECT CAST(CURRENT_ROLE() AS BINARY)"
    , case4 "reset.role-tls-and-socket" $ do
        ci <- config
        path <- socketPath
        name <- env "MB_TLS_NAME" "localhost"
        forM_ [tlsConnect ci {ciUser="mariadb_role_none"} name,
               connectUnixSocket path ci {ciUser="mariadb_role_none"}] $ \open ->
            withConnect open $ \conn -> do
                exec conn "SET ROLE mb_stage4_other_role"
                void (resetConnection conn)
                equal "transport reset clears prior role" MySQLNull =<< scalar conn "SELECT CURRENT_ROLE()"
    , case4 "reset.tls" $ withTLS $ \conn -> void (resetConnection conn) >> healthy conn
    , case4 "reset.socket" $ do
        ci <- config
        path <- socketPath
        withConnect (connectUnixSocket path ci) $ \conn -> void (resetConnection conn) >> healthy conn
    , case4 "reset.tracking-disabled" $ do
        ci <- config
        withConnect (connectWithOptions defaultConnectionOptions {enableSessionTracking=False} ci) $ \conn -> do
            void (resetConnection conn)
            (_, stream) <- query conn "SELECT ?" [MySQLText "safe '"]
            equal "explicit reset snapshot works without tracking" [[MySQLText "safe '"]] =<< S.toList stream
    , case4 "reset.raw-command-uses-guarded-restoration" $ withConn $ \conn -> do
        exec conn "USE information_schema"
        void (command conn COM_RESET_CONNECTION)
        ci <- config
        equal "low-level public command restores constructor schema" (Just (ciDatabase ci)) . sessionSchema =<< getSessionState conn
    , case4 "reset.no-database-unchanged-is-safe" $ do
        ci <- config
        withConnect (connect ci {ciDatabase=""}) $ \conn -> do
            void (resetConnection conn)
            equal "no selected database preserved honestly" MySQLNull =<< scalar conn "SELECT DATABASE()"
    , case4 "reset.autocommit-and-isolation-defaults" $ withConn $ \conn -> do
        expected <- rows conn "SELECT @@autocommit,@@tx_isolation"
        exec conn "SET autocommit=0"
        exec conn "SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED"
        void (resetConnection conn)
        equal "transaction settings return to defaults" expected =<< rows conn "SELECT @@autocommit,@@tx_isolation"
    , case4 "reset.after-transaction-tracking" $ withConn $ \conn -> do
        exec conn "SET session_track_transaction_info='CHARACTERISTICS',session_track_state_change=ON"
        exec conn "START TRANSACTION READ ONLY"
        void (resetConnection conn)
        state <- getSessionState conn
        equal "tracked transaction reset is synchronized" (Just False) (sessionInTransaction state)
        equal "old transaction characteristics discarded" Nothing (sessionTransactionCharacteristics state)
        equal "old transaction state discarded" Nothing (sessionTransactionState state)
        healthy conn
    , case4 "reset.releases-advisory-locks" $ withConn $ \conn -> do
        equal "test advisory lock acquired" 1 =<< scalarInt conn "SELECT GET_LOCK('mb_stage4_reset_lock',0)"
        void (resetConnection conn)
        equal "next borrower cannot inherit an advisory lock" 1
            =<< scalarInt conn "SELECT IS_FREE_LOCK('mb_stage4_reset_lock')"
    , case4 "reset.empty-database-after-use-rejected" $ do
        ci <- config
        withConnect (connect ci {ciDatabase=""}) $ \conn -> do
            void (command conn (COM_INIT_DB (ciDatabase ci)))
            expectRejection (resetConnection conn)
            equal "local restoration rejection leaves session intact" Ready =<< connectionStatus conn
    , case4 "reset.stale-handle-and-id-reuse" $ withConn $ \conn -> do
        old <- prepareStatement conn "SELECT 7"
        raw <- prepareStmt conn "SELECT 8"
        void (resetConnection conn)
        expectRejection (queryPrepared old [])
        expectERR [1243] (queryStmt conn raw [])
        refreshSessionState conn
        withPreparedStatement conn "SELECT 9" $ \fresh -> do
            expectRejection (preparedMetadata old)
            equal "new handle works" [[9]] . map (map number) =<< (queryPrepared fresh [] >>= S.toList . snd)
    , case4 "reset.registry-bounded-over-reuse" $ withConn $ \conn -> replicateM_ 100 $ do
        void (prepareStatement conn "SELECT REPEAT('x',1000)")
        void (resetConnection conn)
        registry <- readIORef (C.connectionStatements conn)
        equal "all cached metadata released" (Just 0) (C.registryMetadataBytes <$> registry)
        equal "no stale registrations retained" 0 . length =<< C.statementMap conn
    , case4 "reset.pending-stream-rejected-before-send" $ withConn $ \conn -> do
        (_, stream) <- query_ conn "SELECT seq FROM seq_1_to_10"
        outcome <- try (resetConnection conn)
        case outcome of Left UnconsumedResultSet -> pure (); _ -> fail "reset consumed pending rows"
        equal "pending rows intact" 10 . length =<< S.toList stream
        healthy conn
    , case4 "reset.transaction-helper-rejected" $ withConn $ \conn -> withTransaction conn $ do
        outcome <- try (resetConnection conn)
        case outcome of Left NestedTransactionUnsupported -> pure (); _ -> fail "reset escaped transaction lease"
        equal "outer transaction remains active" 1 =<< scalarInt conn "SELECT @@in_transaction"
    , case4 "reset.initializer-error-retires" $ withConn $ \conn -> do
        result <- try (resetConnectionWith conn (\_ -> fail "initializer-marker"))
        case result of Left (_ :: SomeException) -> pure (); _ -> fail "initializer error swallowed"
        equal "failed initialization cannot enter a pool" Broken =<< connectionStatus conn
    , case4 "reset.initializer-stream-retires" $ withConn $ \conn -> do
        expectRejection (resetConnectionWith conn (\session -> void (query_ session "SELECT seq FROM seq_1_to_10")))
        equal "unfinished initializer result retires" Broken =<< connectionStatus conn
    , case4 "reset.initializer-transaction-retires" $ withConn $ \conn -> do
        expectRejection (resetConnectionWith conn (\session -> exec session "START TRANSACTION"))
        equal "open initializer transaction retires" Broken =<< connectionStatus conn
    , case4 "reset.malformed-reply-retires" $ do
        (conn, _, released) <- resetFixture [putToPacket 1 (putWord8 1)]
        expectRejection (resetConnection conn)
        equal "malformed RESET reply retires" Broken =<< connectionStatus conn
        equal "transport released once" 1 =<< released
    , case4 "reset.server-error-retires" $ do
        (conn, _, released) <- resetFixture [encodeToPacket 1 (ERR 1047 "08S01" "reset unavailable")]
        expectERR [1047] (resetConnection conn)
        equal "RESET ERR retires conservatively" Broken =<< connectionStatus conn
        equal "RESET ERR releases once" 1 =<< released
    , case4 "reset.restore-error-retires" $ do
        (conn, _, released) <- resetFixture
            [encodeToPacket 1 (OK 0 0 2 0), encodeToPacket 1 (ERR 1064 "42000" "snapshot unavailable")]
        expectERR [1064] (resetConnection conn)
        equal "restoration error retires" Broken =<< connectionStatus conn
        equal "restoration releases once" 1 =<< released
    , case4 "reset.wire-byte-and-no-redundant-setup" $ do
        (conn, sent, _) <- resetFixture resetTranscript
        void (resetConnection conn)
        commands <- sent
        equal "RESET then one snapshot; legacy tracking has no setup SET" [31,3]
            (map (L.head . pBody) commands)
        case commands of
            first : _ -> equal "RESET is exactly one byte" (L.singleton 31) (pBody first)
            [] -> fail "RESET was not sent"
    , case4 "reset.role-restoration-error-retires" $ do
        (conn, sent, released) <- resetFixture (encodeToPacket 1 (OK 0 0 2 0)
            : roleSnapshotPackets (putLenEncBytes "different") ++ [encodeToPacket 1 (ERR 1959 "OP000" "role unavailable")])
        expectERR [1959] (resetConnection conn)
        equal "failed role restoration retires" Broken =<< connectionStatus conn
        equal "role failure releases once" 1 =<< released
        commands <- sent
        case reverse commands of
            role : _ -> equal "role command precedes initializer" "\x03SET ROLE NONE" (pBody role)
            [] -> fail "role restoration sent no command"
    , case4 "reset.role-snapshot-value-bound" $ do
        (conn, _, released) <- resetFixture (encodeToPacket 1 (OK 0 0 2 0)
            : roleSnapshotPackets (putLenEncBytes (B.replicate 4097 65)))
        expectRejection (resetConnection conn)
        equal "oversized role rejected under ownership" Broken =<< connectionStatus conn
        equal "oversized role releases once" 1 =<< released
    , case4 "reset.role-restoration-deadline" $ do
        (conn, _, released) <- stalledReset (encodeToPacket 1 (OK 0 0 2 0)
            : roleSnapshotPackets (putLenEncBytes "different"))
        result <- timeout 1000000 (try (resetConnection conn))
        case result of Just (Left CleanupDeadlineExceeded) -> pure (); _ -> fail "role restoration ignored cleanup deadline"
        equal "stalled role restoration retires" Broken =<< connectionStatus conn
        equal "role deadline releases once" 1 =<< released
    , case4 "reset.known-unsupported-version-no-send" $ do
        (conn, sent, _) <- resetFixture []
        writeIORef (C.connectionInitialSession conn) (Just (C.InitialSession "db" "utf8mb4" "utf8mb4_unicode_ci" 100203 Nothing))
        expectRejection (resetConnection conn)
        equal "version rejection sends nothing" [] =<< sent
        equal "version rejection preserves connection" Ready =<< connectionStatus conn
    , case4 "reset.no-database-unsafe-restore-rejected" $ do
        (conn, sent, _) <- resetFixture []
        writeIORef (C.connectionInitialSession conn) (Just (C.InitialSession "" "utf8mb4" "utf8mb4_unicode_ci" 120303 Nothing))
        expectRejection (resetConnection conn)
        equal "cannot silently preserve another borrower's database" [] =<< sent
    , case4 "reset.closed-and-broken-never-revived" $ do
        forM_ [close, \conn -> C.abortConnection conn False] $ \retire -> do
            (conn, sent, _) <- resetFixture []
            retire conn
            before <- sent
            expectRejection (resetConnection conn)
            equal "terminal reset sends nothing" before =<< sent
            equal "terminal snapshot unknown" Nothing . sessionSchema =<< getSessionState conn
    , case4 "reset.buffered-initializer-deadline" $ do
        (conn, _, released) <- resetFixture resetTranscript
        counter <- newIORef (0 :: Int)
        let bounded = conn {C.connectionOptions=defaultConnectionOptions {cleanupTimeoutMicros=20000}}
            spin = let loop = modifyIORef' counter (+1) >> loop in loop
        result <- timeout 1000000 (try (resetConnectionWith bounded (\_ -> spin)))
        case result of Just (Left CleanupDeadlineExceeded) -> pure (); _ -> fail "buffered initializer ignored deadline"
        equal "buffered timeout retires" Broken =<< connectionStatus bounded
        equal "deadline releases once" 1 =<< released
    , case4 "reset.wire-and-restoration-deadlines" $ forM_
        [[], [encodeToPacket 1 (OK 0 0 2 0)]] $ \prefix -> do
            (conn, _, released) <- stalledReset prefix
            result <- timeout 1000000 (try (resetConnection conn))
            case result of Just (Left CleanupDeadlineExceeded) -> pure (); _ -> fail "reset/restoration read ignored deadline"
            equal "stalled reset/restoration retires" Broken =<< connectionStatus conn
            equal "stalled read releases once" 1 =<< released
    , case4 "reset.wire-cancellation" $ do
        (conn, entered, released) <- stalledReset []
        let patient = conn {C.connectionOptions=defaultConnectionOptions {cleanupTimeoutMicros=5000000}}
        done <- newEmptyMVar
        worker <- forkFinally (resetConnection patient) (putMVar done)
        entered
        killThread worker
        result <- takeMVar done
        case result of Left err | Just ThreadKilled <- fromException err -> pure (); _ -> fail "wire cancellation lost identity"
        equal "wire cancellation retires" Broken =<< connectionStatus patient
        equal "wire cancellation releases once" 1 =<< released
    , case4 "reset.close-race-stays-terminal" $ do
        (conn, _, released) <- resetFixture resetTranscript
        entered <- newEmptyMVar
        proceed <- newEmptyMVar
        done <- newEmptyMVar
        worker <- forkFinally
            (resetConnectionWith conn (\_ -> putMVar entered () >> takeMVar proceed)) (putMVar done)
        flip finally (killThread worker) $ do
            takeMVar entered
            close conn
            putMVar proceed ()
            result <- takeMVar done
            case result of Left _ -> pure (); _ -> fail "closed reset was reported successful"
            equal "concurrent close stays terminal" Closed =<< connectionStatus conn
            equal "concurrent close does not revive registry" Nothing . fmap C.registryMetadataBytes
                =<< readIORef (C.connectionStatements conn)
            equal "close race releases once" 1 =<< released
    , case4 "reset.initializer-cancellation-and-exclusive-lease" $ do
        (conn, _, released) <- resetFixture resetTranscript
        entered <- newEmptyMVar
        wait <- newEmptyMVar
        done <- newEmptyMVar
        worker <- forkFinally (resetConnectionWith conn (\_ -> putMVar entered () >> takeMVar wait)) (putMVar done)
        takeMVar entered
        expectRejection (ping conn)
        killThread worker
        result <- takeMVar done
        case result of Left err | Just ThreadKilled <- fromException err -> pure (); _ -> fail "reset swallowed cancellation"
        equal "cancelled initializer retires" Broken =<< connectionStatus conn
        equal "cancellation releases once" 1 =<< released
    ]
