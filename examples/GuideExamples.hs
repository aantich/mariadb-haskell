{-# LANGUAGE OverloadedStrings #-}

-- | Complete helpers accompanying docs/USER_GUIDE.md. These are application
-- building blocks, not a schema migration or a runnable benchmark. Compile with:
--
-- @
-- cabal exec -- ghc -fno-code -Wall -package mariadb-haskell examples/GuideExamples.hs
-- @
--
-- Table prerequisites: measurements(sensor_id BIGINT, reading DOUBLE NULL),
-- files(contents LONGBLOB), customers(id BIGINT, name TEXT), and transactional
-- InnoDB tables when transaction guarantees are required. Use your own schema/grants.
module GuideExamples where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Word (Word32)
import qualified Database.MySQL.Base as DB
import qualified Database.MySQL.BinLog as CDC
import Database.MySQL.Field (DecodeError, fromField)
import qualified Database.MySQL.TLS as TLS
import qualified Network.TLS as NetworkTLS
import System.IO (IOMode (ReadMode), withBinaryFile)
import qualified System.IO.Streams as Streams

-- | Consume all rows inside the statement bracket; the caller owns conn.
customersFrom :: DB.MySQLConn -> Int64 -> ([DB.MySQLValue] -> IO ()) -> IO ()
customersFrom conn minimumId handleRow =
    DB.withPreparedStatement conn
        "SELECT id, name FROM customers WHERE id >= ? ORDER BY id" $ \statement -> do
            (_, rows) <- DB.queryPrepared statement [DB.MySQLInt64 minimumId]
            Streams.foldM (\() row -> handleRow row) () rows

-- | Decode an already shape-checked BIGINT field without narrowing/coercion.
signedBigInt :: DB.MySQLValue -> Either DecodeError Int64
signedBigInt = fromField

-- | Demonstrate native NULL binding and one concrete type per bulk column.
insertMeasurements :: DB.MySQLConn -> IO DB.OK
insertMeasurements conn =
    DB.withPreparedStatement conn
        "INSERT INTO measurements(sensor_id, reading) VALUES (?, ?)" $ \statement ->
            DB.executeBulk statement
                [ [DB.BulkValue (DB.MySQLInt64 1), DB.BulkValue (DB.MySQLDouble 12.5)]
                , [DB.BulkValue (DB.MySQLInt64 2), DB.BulkValue DB.MySQLNull]
                ]

-- | Wrap a bulk operation in an explicit transaction. The caller must use a
-- transactional table and must not nest this inside another withTransaction.
transactionalMeasurements :: DB.MySQLConn -> IO DB.OK
transactionalMeasurements conn = DB.withTransaction conn (insertMeasurements conn)

-- | The file handle remains open for the entire one-shot upload. Files larger
-- than the configured aggregate upload budget fail rather than silently split.
uploadFile :: DB.MySQLConn -> FilePath -> IO DB.OK
uploadFile conn path = withBinaryFile path ReadMode $ \handle -> do
    source <- Streams.handleToInputStream handle
    DB.withPreparedStatement conn "INSERT INTO files(contents) VALUES (?)" $ \statement ->
        DB.executePreparedStream statement [DB.PreparedBytes source]

-- | Read a cursor in bounded fetches on the creating thread. Ordinary row
-- streaming is often faster; choose cursors for explicit fetch control.
cursorCustomers :: DB.MySQLConn -> Word32 -> ([DB.MySQLValue] -> IO ()) -> IO ()
cursorCustomers conn batchSize handleRow =
    DB.withPreparedStatement conn "SELECT id, name FROM customers ORDER BY id" $ \statement ->
        DB.withCursor statement [] $ \cursor ->
            let loop = do
                    done <- DB.cursorExhausted cursor
                    unless done $ do
                        rows <- DB.fetchCursor cursor batchSize
                        Streams.foldM (\() row -> handleRow row) () rows
                        loop
            in loop

-- | Prepare TLS settings once outside a pool's connection factory.
withVerifiedTLS :: FilePath -> String -> DB.ConnectInfo -> (DB.MySQLConn -> IO a) -> IO a
withVerifiedTLS caPath serverName ci action = do
    params <- TLS.makeClientParams (TLS.CustomCAStore caPath)
    bracket (TLS.connect ci (params, serverName)) DB.close action

-- | A single hidden PAM prompt; use an application callback for multiple factors.
withPAM :: NetworkTLS.ClientParams -> String -> DB.ConnectInfo -> ByteString
        -> (DB.MySQLConn -> IO a) -> IO a
withPAM params serverName ci password action =
    let auth = DB.defaultAuthenticationOptions
            { DB.authenticationDialog = Just (DB.passwordDialog password) }
    in bracket (TLS.connectWithAuthentication DB.defaultConnectionOptions auth ci
                   (params, serverName)) DB.close action

-- | Use an existing ticket cache. Build the executable with -threaded and
-- configure the realm/server separately. Add TLS for SQL confidentiality.
withKerberos :: DB.ConnectInfo -> ByteString -> (DB.MySQLConn -> IO a) -> IO a
withKerberos ci exactPrincipal =
    let auth = DB.defaultAuthenticationOptions
            { DB.authenticationGSSAPIPrincipal = Just exactPrincipal }
    in bracket (DB.connectWithAuthentication DB.defaultConnectionOptions auth ci) DB.close

-- | Configure optional wire features before connection establishment. The
-- callback is synchronous and must never reenter the same connection.
withProgress :: DB.ConnectInfo -> (DB.Progress -> IO ()) -> (DB.MySQLConn -> IO a) -> IO a
withProgress ci callback action =
    let options = DB.defaultConnectionOptions { DB.enableProgressReporting = True }
    in bracket (DB.connectWithOptions options ci) DB.close $ \conn -> do
        DB.setProgressCallback conn (Just callback)
        action conn

-- | Safely consume a dedicated manual-ACK stream. The supplied sink must
-- durably stage each event and, at a checkpoint event, atomically commit the
-- entire group and its exported resume coordinates before returning. It must
-- not retain an unbounded transaction in memory. The driver supplies no sink
-- persistence or exactly-once protocol. Semisync must be configured server-side.
consumeDurably :: DB.MySQLConn -> Word32 -> ByteString -> (CDC.CDCEvent -> IO ()) -> IO ()
consumeDurably conn replicaId savedGtids applyAndPersist = do
    gtids <- either (ioError . userError) pure (CDC.parseGtidSet savedGtids)
    let options = (CDC.defaultCDCOptions (CDC.FromGtid gtids))
            { CDC.cdcAcknowledgements = CDC.AcknowledgeManually }
    bracket (CDC.openCDC conn replicaId options) CDC.cdcClose $ \stream -> do
        let handleEvent event = do
                applyAndPersist event
                case CDC.cdcEventCheckpoint event of
                    Nothing -> pure ()
                    Just checkpoint -> CDC.cdcAcknowledge stream checkpoint
        Streams.foldM (\() event -> handleEvent event) () (CDC.cdcEvents stream)
