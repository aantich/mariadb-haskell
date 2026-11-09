{-# LANGUAGE ScopedTypeVariables #-}
-- | Literal protocol fixtures and real MariaDB checks for streamed parameters,
-- cursors, progress and compression. Inventory checks call real public APIs.
module Validation.Stage6 (cases, longDataFeature, cursorFeature, progressFeature, compressionFeature) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import qualified Data.Binary as Binary
import qualified Codec.Compression.Zlib as Zlib
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.IORef
import qualified Data.Text as T
import Data.Word
import Database.MySQL.Base
import qualified Database.MySQL.Connection as C
import qualified Database.MySQL.TLS as TLS
import qualified System.IO.Streams as S
import System.Environment (getEnv)
import System.Timeout
import Validation.Common
import Validation.FaultTransport (scripted)
import Validation.WireProxy (withWireProxy)

field :: ColumnDef
field = ColumnDef "" "" "" "n" "" 63 20 mySQLTypeLongLong 0 0

preparePackets :: Int -> Int -> [Packet]
preparePackets parameters columns =
    putToPacket 1 (putWord8 0 >> putWord32le 9 >> putWord16le (fromIntegral columns) >>
        putWord16le (fromIntegral parameters) >> putWord8 0 >> putWord16le 0) :
    [encodeToPacket (fromIntegral n) field | n <- [2..1+parameters+columns]]

ending :: Word8 -> Word16 -> Packet
ending n flags = putToPacket n (putWord8 254 >> putWord8 0 >> putWord8 0 >> putWord16le flags >> putWord16le 0)

binaryRow :: Word8 -> Word64 -> Packet
binaryRow n value = putToPacket n (putWord8 0 >> putWord8 0 >> putWord64le value)

statementFixture :: ConnectionOptions -> Int -> Int -> [Packet]
                 -> IO (MySQLConn, PreparedStatement, IO [Packet], IO Int)
statementFixture options parameters columns packets = do
    (conn,sent,closed) <- scripted options (preparePackets parameters columns ++ packets)
    writeIORef (C.connectionCapabilities conn) (bit 24)
    statement <- prepareStatement conn "SELECT ?"
    pure (conn,statement,sent,closed)

cursorFixture :: [Packet] -> IO (MySQLConn, PreparedCursor, IO [Packet], IO Int)
cursorFixture batches = do
    (conn,statement,sent,closed) <- statementFixture defaultConnectionOptions 0 1
        ([putToPacket 1 (putWord8 1),encodeToPacket 2 field,ending 3 66] ++ batches)
    (_,cursor) <- openCursor statement []
    pure (conn,cursor,sent,closed)

expectStatementError :: (StatementException -> Bool) -> IO a -> IO ()
expectStatementError matches action = do
    result <- try action
    case result of
        Left err -> assert (matches err) ("wrong statement exception: " ++ show err)
        Right _ -> fail "expected a local statement error"

expectLocal :: (ConnectionError -> Bool) -> IO a -> IO ()
expectLocal matches action = do
    result <- try action
    case result of
        Left err -> assert (matches err) ("wrong connection exception: " ++ show err)
        Right _ -> fail "expected a local connection error"

assertRetired :: MySQLConn -> IO Int -> IO a -> IO ()
assertRetired conn closed action = do
    expectRejection action
    equal "retired" Broken =<< connectionStatus conn
    equal "released once" 1 =<< closed

progressPacket :: Word8 -> B.ByteString -> Packet
progressPacket n info = putToPacket n $ do
    putByteString (B.pack [255,255,255,1,1,2,80,195,0]) -- 50.000%, stage 1/2.
    putLenEncBytes info

-- Independent compressed-frame headers, including raw-frame representation.
frame :: Word8 -> Int -> L.ByteString -> L.ByteString
frame n expanded payload = runPut $ do
    put24 (fromIntegral (L.length payload)); putWord8 n; put24 expanded; putLazyByteString payload
  where
    put24 :: Int -> Put
    put24 x = mapM_ (putWord8 . fromIntegral . shiftR x) [0,8,16]

compressedFixture :: [B.ByteString] -> ConnectionOptions
                  -> IO (MySQLConn, IO [L.ByteString], IO Int)
compressedFixture chunks options = do
    input <- S.fromList chunks
    sent <- newIORef []
    closed <- newIORef (0::Int)
    conn <- C.newTransportConnection options {enableCompression=True} input
        (\bytes -> modifyIORef' sent (bytes:)) (modifyIORef' closed (+1))
    writeIORef (C.connectionCapabilities conn) (bit 5)
    C.connectionCompressionStart conn
    pure (conn,reverse <$> readIORef sent,readIORef closed)

case6 :: String -> IO () -> Case
case6 name = Case ("stage6." ++ name) "stage6"

withOptions :: ConnectionOptions -> (MySQLConn -> IO a) -> IO a
withOptions options action = config >>= \ci -> withConnect (connectWithOptions options ci) action

longDataFeature :: IO ()
longDataFeature = withConn $ \conn -> do
    exec conn "CREATE TEMPORARY TABLE mb_stage6_long(n INT,b LONGBLOB,t LONGTEXT)"
    withPreparedStatement conn "INSERT INTO mb_stage6_long VALUES(?,?,?)" $ \statement -> do
        bytes <- S.fromList [B.pack [0..255],B.replicate 200000 97]
        text <- S.fromList ["雪",T.replicate 10000 "😀é"]
        ok <- executePreparedStream statement [PreparedValue (MySQLInt32 7),PreparedBytes bytes,PreparedText text]
        equal "inserted" 1 (okAffectedRows ok)
    equal "all bytes/text stored" [[7,200256,60003,20001]] . map (map number) =<<
        rows conn "SELECT n,OCTET_LENGTH(b),OCTET_LENGTH(t),CHAR_LENGTH(t) FROM mb_stage6_long"
    healthy conn

cursorFeature :: IO ()
cursorFeature = withConn $ \conn -> withPreparedStatement conn "SELECT seq FROM seq_1_to_23" $ \statement -> do
    withCursor statement [] $ \cursor -> do
        let loop acc = do
                done <- cursorExhausted cursor
                if done then pure acc else do
                    stream <- fetchCursor cursor 5
                    values <- S.toList stream
                    decoded <- forM values $ \row -> case row of
                        [value] -> pure (number value)
                        _ -> fail "unexpected cursor row width"
                    loop (acc ++ decoded)
        equal "cursor order and final batch" [1..23] =<< loop []
    healthy conn

progressFeature :: IO ()
progressFeature = withOptions defaultConnectionOptions {enableProgressReporting=True} $ \conn -> do
    reports <- newIORef []
    setProgressCallback conn (Just (\p -> modifyIORef' reports (p:)))
    exec conn "CREATE TEMPORARY TABLE mb_stage6_progress(n INT,v VARCHAR(200)) ENGINE=Aria"
    exec conn "INSERT INTO mb_stage6_progress SELECT seq,REPEAT('x',200) FROM seq_1_to_20000"
    exec conn "ALTER TABLE mb_stage6_progress ADD INDEX(n),ALGORITHM=COPY"
    actual <- readIORef reports
    assert (not (null actual)) "real ALTER must deliver at least one progress report"
    assert (all (\p -> progressStage p > 0 && progressStage p <= progressStageCount p && progressThousandths p <= 100000) actual)
        "valid real progress stages"
    healthy conn

compressionFeature :: IO ()
compressionFeature = withOptions defaultConnectionOptions {enableCompression=True} $ \conn -> do
    equal "compressed value" (T.replicate 100000 "é雪") . textOf =<< scalar conn "SELECT REPEAT('é雪',100000)"
    withPreparedStatement conn "SELECT OCTET_LENGTH(?),?" $ \statement -> do
        (_,stream) <- queryPrepared statement [MySQLBytes (B.replicate 100000 65),MySQLInt64 7]
        equal "compressed prepared parity" [[100000,7]] . map (map number) =<< S.toList stream
    healthy conn

cases :: [Case]
cases =
    [ case6 "long-data-live" longDataFeature
    , case6 "cursor-live" cursorFeature
    , case6 "progress-live" progressFeature
    , case6 "compression-live" compressionFeature
    , case6 "long-data-query-empty-and-binary" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT OCTET_LENGTH(?),HEX(?)" $ \statement -> do
            empty <- S.fromList []
            bytes <- S.fromList [B.pack [0,255,0],B.pack [128,1]]
            (_,stream) <- queryPreparedStream statement [PreparedBytes empty,PreparedBytes bytes]
            values <- S.toList stream
            case values of
                [[size,value]] -> do
                    equal "empty non-NULL" 0 (number size)
                    equal "exact bytes" "00FF008001" (textOf value)
                _ -> fail "unexpected streamed query result shape"
            healthy conn
    , case6 "cursor-close-pending-batch" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT seq FROM seq_1_to_1000" $ \statement -> do
            (_,cursor) <- openCursor statement []
            batch <- fetchCursor cursor 100
            equal "first cursor row" (Just [1]) . fmap (map number) =<< S.read batch
            closeCursor cursor
            closeCursor cursor
            healthy conn
            (_,stream) <- queryPrepared statement []
            equal "statement survives reset" 1000 . length =<< S.toList stream
    , case6 "compression-tls" $ do
        ci <- config
        ca <- getEnv "MB_TLS_CA"
        params <- TLS.makeClientParams (TLS.CustomCAStore ca)
        withConnect (TLS.connectWithOptions defaultConnectionOptions {enableCompression=True} ci (params,"localhost")) $ \conn -> do
            equal "TLS compressed length" 1000000 =<< scalarInt conn "SELECT OCTET_LENGTH(REPEAT('x',1000000))"
            healthy conn
    , case6 "compression-socket" $ do
        ci <- config; path <- socketPath
        withConnect (connectUnixSocketWithOptions defaultConnectionOptions {enableCompression=True} path ci) healthy
    ] ++ longDataCases ++ cursorCases ++ progressCases ++ compressionCases ++ lifecycleCases

longDataCases :: [Case]
longDataCases =
    [ case6 "long-data-wire-omission" $ do
        (_,statement,sent,_) <- statementFixture defaultConnectionOptions 1 0 [encodeToPacket 1 (OK 1 0 2 0)]
        source <- S.fromList ["ab","cd"]
        void (executePreparedStream statement [PreparedBytes source])
        packets <- sent
        equal "prepare, empty marker, coalesced chunk, execute" [22,24,24,23] (map (L.head . pBody) packets)
        equal "coalesced data retains byte order" "abcd" (L.drop 7 (pBody (packets !! 2)))
        equal "uploaded parameter has type but no inline value"
            (L.pack [23,9,0,0,0,0,1,0,0,0,0,1,252,0]) (pBody (last packets))
        equal "each no-reply command resets sequence" [0,0,0,0] (map pSeqN packets)
    , case6 "long-data-arity-does-not-read-source" $ do
        (conn,statement,sent,_) <- statementFixture defaultConnectionOptions 1 0 []
        consumed <- newIORef (0::Int)
        source <- S.makeInputStream (modifyIORef' consumed (+1) >> pure Nothing)
        result <- try (executePreparedStream statement [PreparedBytes source,PreparedValue MySQLNull])
        case result of Left WrongParamsCount -> pure (); _ -> fail "expected exact arity rejection"
        equal "no source reads" 0 =<< readIORef consumed
        equal "no upload writes" 1 . length =<< sent
        equal "connection still ready" Ready =<< connectionStatus conn
    , case6 "long-data-budget" $ do
        (conn,statement,_,closed) <- statementFixture defaultConnectionOptions {maximumLongDataBytes=3} 1 0 []
        source <- S.fromList ["ab","cd"]
        assertRetired conn closed (executePreparedStream statement [PreparedBytes source])
    , case6 "long-data-source-failure" $ do
        (conn,statement,_,closed) <- statementFixture defaultConnectionOptions 1 0 []
        source <- S.makeInputStream (throwIO (userError "source-marker"))
        result <- try (executePreparedStream statement [PreparedBytes source])
        case result of
            Left (err::SomeException) -> assert ("source-marker" `T.isInfixOf` T.pack (displayException err)) "source error identity"
            Right _ -> fail "source did not fail"
        equal "retired after no-reply command" Broken =<< connectionStatus conn
        equal "one close" 1 =<< closed
    , case6 "long-data-cancellation" $ do
        (conn,statement,_,closed) <- statementFixture defaultConnectionOptions 1 0 []
        blocked <- newEmptyMVar
        source <- S.makeInputStream (takeMVar blocked :: IO (Maybe B.ByteString))
        result <- timeout 20000 (executePreparedStream statement [PreparedBytes source])
        equal "cancel propagated" Nothing result
        equal "cancel retired" Broken =<< connectionStatus conn
        equal "one release" 1 =<< closed
    , case6 "long-data-exclusive-source" $ do
        (conn,statement,sent,_) <- statementFixture defaultConnectionOptions 1 0 [encodeToPacket 1 (OK 1 0 2 0)]
        source <- S.makeInputStream $ do
            expectLocal (\e -> case e of ConcurrentConnectionUse -> True; _ -> False) (ping conn)
            pure Nothing
        void (executePreparedStream statement [PreparedBytes source])
        equal "no nested ping bytes" [22,24,23] . map (L.head . pBody) =<< sent
    , case6 "long-data-large-chunk-split" $ do
        (_,statement,sent,_) <- statementFixture defaultConnectionOptions 1 0 [encodeToPacket 1 (OK 1 0 2 0)]
        source <- S.fromList [B.replicate 200000 42]
        void (executePreparedStream statement [PreparedBytes source])
        packets <- sent
        let sizes = [pLen p-7 | p <- packets,L.head (pBody p)==24]
        equal "bounded chunk lengths" [0,65536,65536,65536,3392] sizes
    , case6 "long-data-following-normal-execution" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT OCTET_LENGTH(?)" $ \statement -> do
            forM_ [100,0,200] $ \size -> do
                source <- S.fromList [B.replicate size 42]
                (_,stream) <- queryPreparedStream statement [PreparedBytes source]
                equal "new upload replaces prior state" [[toInteger size]] . map (map number) =<< S.toList stream
                (_,normal) <- queryPrepared statement [MySQLBytes "abc"]
                equal "normal execute has no old upload" [[3]] . map (map number) =<< S.toList normal
    , case6 "long-data-text-client-charset" $ withConn $ \conn -> do
        exec conn "SET NAMES latin1"
        withPreparedStatement conn "SELECT HEX(?)" $ \statement -> do
            source <- S.fromList ["é"]
            (_,stream) <- queryPreparedStream statement [PreparedText source]
            values <- S.toList stream
            equal "latin1 streamed bytes" [["E9"]] (map (map textOf) values)
    , case6 "long-data-rollback" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage6_rollback(v BLOB) ENGINE=InnoDB"
        withPreparedStatement conn "INSERT INTO mb_stage6_rollback VALUES(?)" $ \statement -> do
            result <- try $ withTransaction conn $ do
                source <- S.fromList ["abc"]
                void (executePreparedStream statement [PreparedBytes source])
                throwIO (userError "rollback-marker")
            case result of Left (_::SomeException) -> pure (); Right () -> fail "expected body exception"
        equal "streamed insert rolled back" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage6_rollback"
    ]

cursorCases :: [Case]
cursorCases =
    [ case6 "cursor-wire-and-final-empty-fetch" $ do
        (_,cursor,sent,_) <- cursorFixture [binaryRow 1 7,ending 2 66,ending 1 130]
        first <- fetchCursor cursor 1 >>= S.toList
        equal "binary row" [[7]] (map (map number) first)
        equal "server still reports open" False =<< cursorExhausted cursor
        equal "final empty batch" [] =<< (fetchCursor cursor 1 >>= S.toList)
        equal "server exhausted" True =<< cursorExhausted cursor
        packets <- sent
        equal "read-only execute flag" 1 (L.index (pBody (packets !! 1)) 5)
        equal "literal FETCH" (L.pack [28,9,0,0,0,1,0,0,0]) (pBody (last packets))
    , case6 "cursor-invalid-count-is-local" $ do
        (conn,cursor,sent,_) <- cursorFixture [encodeToPacket 1 (OK 0 0 2 0)]
        forM_ [0,65537] $ \n -> expectStatementError (\e -> case e of InvalidCursorUse _ -> True; _ -> False) (fetchCursor cursor n)
        equal "no FETCH sent" 2 . length =<< sent
        equal "cursor still owns connection" Streaming =<< connectionStatus conn
        closeCursor cursor
    , case6 "cursor-unfinished-batch-is-local" $ do
        (_,cursor,sent,_) <- cursorFixture [binaryRow 1 7,ending 2 66,encodeToPacket 1 (OK 0 0 2 0)]
        batch <- fetchCursor cursor 2
        expectStatementError (\e -> case e of InvalidCursorUse _ -> True; _ -> False) (fetchCursor cursor 2)
        equal "one fetch only" 3 . length =<< sent
        equal "batch remains readable" [[7]] . map (map number) =<< S.toList batch
        closeCursor cursor
    , case6 "cursor-more-rows-than-requested" $ do
        (conn,cursor,_,closed) <- cursorFixture [binaryRow 1 7,binaryRow 2 8,ending 3 130]
        assertRetired conn closed (fetchCursor cursor 1 >>= S.toList)
    , case6 "cursor-invalid-end-status" $ do
        (conn,cursor,_,closed) <- cursorFixture [ending 1 2]
        assertRetired conn closed (fetchCursor cursor 2 >>= S.toList)
    , case6 "cursor-close-without-fetch" $ do
        (conn,cursor,sent,_) <- cursorFixture [encodeToPacket 1 (OK 0 0 2 0)]
        closeCursor cursor
        equal "close uses RESET without fetching" [22,23,26] . map (L.head . pBody) =<< sent
        equal "ready after cursor close" Ready =<< connectionStatus conn
    , case6 "cursor-foreign-thread" $ do
        (_,cursor,sent,_) <- cursorFixture [encodeToPacket 1 (OK 0 0 2 0)]
        done <- newEmptyMVar
        _ <- forkIO (try (fetchCursor cursor 1) >>= putMVar done)
        result <- takeMVar done
        case result of Left ConcurrentConnectionUse -> pure (); _ -> fail "foreign thread must be rejected"
        equal "no foreign writes" 2 . length =<< sent
        closeCursor cursor
    , case6 "cursor-normal-query-blocked" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT seq FROM seq_1_to_100" $ \statement ->
            withCursor statement [] $ \cursor -> do
                result <- try (ping conn)
                case result of Left UnconsumedResultSet -> pure (); _ -> fail "cursor must retain command lease"
                batch <- fetchCursor cursor 3
                void (S.read batch)
    , case6 "cursor-cleanup-transaction-rollback" $ withConn $ \conn -> do
        exec conn "CREATE TEMPORARY TABLE mb_stage6_cursor_tx(n INT) ENGINE=InnoDB"
        void (try (withTransaction conn $ do
            exec conn "INSERT INTO mb_stage6_cursor_tx VALUES(1)"
            withPreparedStatement conn "SELECT seq FROM seq_1_to_1000" $ \statement ->
                withCursor statement [] $ \cursor -> do
                    batch <- fetchCursor cursor 50
                    void (S.read batch)
                    throwIO (userError "cursor-body-marker")) :: IO (Either SomeException ()))
        equal "rollback after cursor release" 0 =<< scalarInt conn "SELECT COUNT(*) FROM mb_stage6_cursor_tx"
        healthy conn
    , case6 "cursor-empty-live" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT 1 WHERE 0" $ \statement ->
            withCursor statement [] $ \cursor -> do
                equal "empty cursor" [] =<< (fetchCursor cursor 10 >>= S.toList)
                equal "empty exhaustion" True =<< cursorExhausted cursor
    , case6 "cursor-metadata-cache-reexecution" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT CAST(? AS SIGNED)" $ \statement -> do
            forM_ [1..3] $ \n -> withCursor statement [MySQLInt64 n] $ \cursor -> do
                equal "cached cursor metadata" [[toInteger n]] . map (map number) =<< (fetchCursor cursor 2 >>= S.toList)
            (_,normal) <- queryPrepared statement [MySQLInt64 9]
            equal "normal after cursor" [[9]] . map (map number) =<< S.toList normal
    ]

progressCases :: [Case]
progressCases =
    [ case6 "progress-literal-envelope" $ do
        (conn,_,_) <- scripted defaultConnectionOptions {enableProgressReporting=True}
            [progressPacket 1 "building",encodeToPacket 2 (OK 0 0 2 0)]
        writeIORef (C.connectionCapabilities conn) (bit 32)
        reports <- newIORef []
        setProgressCallback conn (Just (\p -> modifyIORef' reports (p:)))
        void (ping conn)
        equal "literal progress decoded" [Progress 1 2 50000 "building"] =<< readIORef reports
    , case6 "progress-callback-failure-retires" $ do
        (conn,_,closed) <- scripted defaultConnectionOptions {enableProgressReporting=True}
            [progressPacket 1 "building",encodeToPacket 2 (OK 0 0 2 0)]
        writeIORef (C.connectionCapabilities conn) (bit 32)
        setProgressCallback conn (Just (const (throwIO (userError "callback-marker"))))
        assertRetired conn closed (ping conn)
    , case6 "progress-callback-reentry-rejected" $ do
        (conn,sent,_) <- scripted defaultConnectionOptions {enableProgressReporting=True}
            [progressPacket 1 "",encodeToPacket 2 (OK 0 0 2 0)]
        writeIORef (C.connectionCapabilities conn) (bit 32)
        setProgressCallback conn (Just (const (expectLocal (\e -> case e of ConcurrentConnectionUse -> True; _ -> False) (ping conn))))
        void (ping conn)
        equal "only original ping" 1 . length =<< sent
    , case6 "progress-discard-without-handler" $ do
        (conn,_,_) <- scripted defaultConnectionOptions {enableProgressReporting=True}
            [progressPacket 1 "",progressPacket 2 "next",encodeToPacket 3 (OK 0 0 2 0)]
        writeIORef (C.connectionCapabilities conn) (bit 32)
        void (ping conn)
        equal "reports are not command completion" Ready =<< connectionStatus conn
    , case6 "progress-not-negotiated" $ do
        (conn,sent,_) <- scripted defaultConnectionOptions []
        expectLocal (\e -> case e of ProtocolError _ -> True; _ -> False) (setProgressCallback conn Nothing)
        equal "no negotiation or callback SQL" [] =<< sent
    ] ++
    [ case6 ("progress-malformed-" ++ name) $ do
        (conn,_,closed) <- scripted defaultConnectionOptions {enableProgressReporting=True} [Packet (L.length body) 1 body]
        writeIORef (C.connectionCapabilities conn) (bit 32)
        assertRetired conn closed (ping conn)
    | (name,body) <-
        [("count",L.pack [255,255,255,2,1,2,0,0,0,0]),
         ("stage",L.pack [255,255,255,1,0,2,0,0,0,0]),
         ("percent",L.pack [255,255,255,1,1,2,255,255,255,0]),
         ("truncated",L.pack [255,255,255,1,1]),
         ("trailer",pBody (progressPacket 1 "") <> L.singleton 1)]
    ]

compressionCases :: [Case]
compressionCases =
    [ case6 ("compression-byte-split-" ++ show split) $ do
        let bytes = L.toStrict (frame 1 0 (Binary.encode (encodeToPacket 1 (OK 0 0 2 0))))
        (conn,_,_) <- compressedFixture [B.take split bytes,B.drop split bytes] defaultConnectionOptions
        void (ping conn)
        equal "valid split" Ready =<< connectionStatus conn
    | split <- [1..17]
    ] ++
    [ case6 "compression-zlib-envelope" $ do
        (conn,_,_) <- compressedFixture [L.toStrict (frame 1 (fromIntegral (L.length ordinary)) (Zlib.compress ordinary))] defaultConnectionOptions
        void (ping conn)
    , case6 "compression-small-write-raw-frame" $ do
        (conn,sent,_) <- compressedFixture [L.toStrict (frame 1 0 (Binary.encode (encodeToPacket 1 (OK 0 0 2 0))))] defaultConnectionOptions
        void (ping conn)
        equal "literal compressed-transport PING" [L.pack [5,0,0,0,0,0,0,1,0,0,0,14]] =<< sent
    , case6 "compression-large-roundtrip" $ withOptions defaultConnectionOptions {enableCompression=True} $ \conn ->
        withPreparedStatement conn "SELECT ?" $ \statement -> do
            let bytes = B.replicate 16777216 90
            (_,stream) <- queryPrepared statement [MySQLBytes bytes]
            equal "continued compressed row" [[MySQLBytes bytes]] =<< S.toList stream
            healthy conn
    , case6 "all-features-together" $ withOptions defaultConnectionOptions {enableCompression=True,enableProgressReporting=True} $ \conn -> do
        setProgressCallback conn (Just (const (pure ())))
        withPreparedStatement conn "SELECT OCTET_LENGTH(?)" $ \statement -> do
            source <- S.fromList (replicate 20 (B.replicate 65536 42))
            (_,stream) <- queryPreparedStream statement [PreparedBytes source]
            equal "compressed streamed parameters" [[1310720]] . map (map number) =<< S.toList stream
        withPreparedStatement conn "SELECT seq FROM seq_1_to_100" $ \statement ->
            withCursor statement [] $ \cursor -> do
                values <- fetchCursor cursor 200 >>= S.toList
                equal "compressed cursor" 5050 (sum (map (sum . map number) values))
        void (resetConnection conn)
        healthy conn
    ] ++
    [ case6 ("compression-invalid-" ++ name) $ do
        (conn,_,closed) <- compressedFixture [L.toStrict bytes] defaultConnectionOptions
        assertRetired conn closed (ping conn)
    | (name,bytes) <-
        [("sequence",frame 2 0 ordinary),
         ("zlib",frame 1 11 "garbage"),
         ("length",frame 1 12 (Zlib.compress ordinary)),
         ("expansion",frame 1 1 (Zlib.compress ordinary)),
         ("trailing",frame 1 11 (Zlib.compress ordinary <> "tail")),
         ("empty",frame 1 0 ""),
         ("short-header",L.pack [1,0,0]),
         ("short-body",L.take 10 (frame 1 0 ordinary))]
    ]
  where ordinary = Binary.encode (encodeToPacket 1 (OK 0 0 2 0))

-- These cases exercise the boundaries between the new APIs and existing
-- cancellation, metadata, transaction and session contracts.
lifecycleCases :: [Case]
lifecycleCases =
    [ case6 "cursor-stream-buffered-source-cancellation" $ do
        (conn,statement,_,closed) <- statementFixture defaultConnectionOptions 1 1
            [putToPacket 1 (putWord8 1),encodeToPacket 2 field,ending 3 66,encodeToPacket 1 (OK 0 0 2 0)]
        consumed <- newIORef (0::Int)
        source <- S.makeInputStream $ do
            n <- atomicModifyIORef' consumed (\x -> (x+1,x))
            pure (if n < 10000000 then Just B.empty else Nothing)
        result <- timeout 20000 (withCursorStream statement [PreparedBytes source] (const (pure ())))
        equal "buffered acquisition cancellation propagated" Nothing result
        equal "incomplete upload retired" Broken =<< connectionStatus conn
        equal "acquisition finalizer ran once" 1 =<< closed
        count <- readIORef consumed
        assert (count < 10000000) "source ran to completion under a masked acquisition"
    , case6 "long-data-text-collation-parity" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT COLLATION(?),?='É'" $ \statement ->
            forM_ ["é",""] $ \text -> do
                -- COLLATION is conservatively opaque to the SQL classifier;
                -- explicitly refresh facts before each charset-bound execution.
                refreshSessionState conn
                (_,normal) <- queryPrepared statement [MySQLText text,MySQLText text]
                expected <- S.toList normal
                refreshSessionState conn
                first <- S.fromList [text]
                second <- S.fromList [text]
                (_,streamed) <- queryPreparedStream statement [PreparedText first,PreparedText second]
                equal "text collation and comparison survive upload" expected =<< S.toList streamed
    , case6 "cursor-non-row-more-results-drained" $ do
        (conn,statement,sent,_) <- statementFixture defaultConnectionOptions 0 0
            [encodeToPacket 1 (OK 1 0 10 0),putToPacket 2 (putWord8 1),encodeToPacket 3 field,
             binaryRow 4 7,ending 5 2,encodeToPacket 1 (OK 0 0 2 0)]
        expectStatementError (\e -> case e of InvalidCursorUse _ -> True; _ -> False) (openCursor statement [])
        void (ping conn)
        equal "non-row cursor refusal stays synchronized" [22,23,14] . map (L.head . pBody) =<< sent
    , case6 "cursor-reset-extra-results-rejected" $ do
        (conn,cursor,_,closed) <- cursorFixture [encodeToPacket 1 (OK 0 0 10 0)]
        assertRetired conn closed (closeCursor cursor)
    , case6 "long-data-tiny-chunks-coalesced-with-bounded-segments" $ do
        (_,statement,sent,_) <- statementFixture defaultConnectionOptions 1 0 [encodeToPacket 1 (OK 1 0 2 0)]
        source <- S.fromList (replicate 5000 "x")
        void (executePreparedStream statement [PreparedBytes source])
        packets <- sent
        equal "tiny source segments stay bounded" [0,1024,1024,1024,1024,904]
            [pLen p-7 | p <- packets,L.head (pBody p)==24]
        equal "every tiny byte survives" (L.replicate 5000 120)
            (L.concat [L.drop 7 (pBody p) | p <- packets,L.head (pBody p)==24])
    , case6 "cursor-streamed-parameters" $ withOptions defaultConnectionOptions {enableCompression=True} $ \conn ->
        withPreparedStatement conn "SELECT OCTET_LENGTH(?),seq FROM seq_1_to_3" $ \statement -> do
            source <- S.fromList (replicate 64 (B.replicate 16384 42))
            withCursorStream statement [PreparedBytes source] $ \cursor -> do
                batch <- fetchCursor cursor 5 >>= S.toList
                equal "uploaded parameter used by compressed cursor" [[1048576,1],[1048576,2],[1048576,3]] (map (map number) batch)
            healthy conn
    , case6 "compression-real-wire-byte-savings" $ do
        ci <- config
        counts <- forM [False,True] $ \compressed -> withWireProxy ci $ \proxied counters ->
            withConnect (connectWithOptions defaultConnectionOptions {enableCompression=compressed} proxied) $ \conn -> do
                before <- counters
                equal "complete transfer" (T.replicate 1000000 "x") . textOf =<< scalar conn "SELECT REPEAT('x',1000000)"
                after <- counters
                pure (snd after - snd before)
        case counts of
            [plain,zlib] -> do
                assert (plain > 1000000 && zlib*10 < plain) "real zlib result must reduce wire bytes substantially"
                putStrLn ("STAGE6_WIRE\tplain=" ++ show plain ++ "\tzlib=" ++ show zlib)
            _ -> fail "missing byte-counter alternatives"
    , case6 "cursor-close-after-terminal-connection" $ withConn $ \conn ->
        withPreparedStatement conn "SELECT seq FROM seq_1_to_100" $ \statement -> do
            (_,cursor) <- openCursor statement []
            close conn
            closeCursor cursor
            equal "cursor locally closed" True =<< cursorExhausted cursor
            equal "connection stays closed" Closed =<< connectionStatus conn
    , case6 "long-data-server-error-remains-synchronized" $ do
        let err = putToPacket 1 (putWord8 255 >> putWord16le 1366 >> putByteString "#HY000bad value")
        (conn,statement,sent,closed) <- statementFixture defaultConnectionOptions 1 0
            [err,encodeToPacket 1 (OK 0 0 2 0)]
        source <- S.fromList ["abc"]
        expectERR [1366] (executePreparedStream statement [PreparedBytes source])
        void (ping conn)
        equal "complete server error did not retire" 0 =<< closed
        equal "following ping synchronized" 14 . L.head . pBody . last =<< sent
    , case6 "long-data-closed-handle-no-source-read" $ do
        (_,statement,sent,_) <- statementFixture defaultConnectionOptions 1 0 []
        closePrepared statement
        source <- S.makeInputStream (fail "closed statement consumed source")
        expectStatementError (\e -> case e of StatementClosed -> True; _ -> False)
            (executePreparedStream statement [PreparedBytes source])
        equal "only prepare and close" 2 . length =<< sent
    , case6 "long-data-multiple-results" $ withConn $ \conn ->
        bracket_ (exec conn "CREATE PROCEDURE mb_stage6_long_results(IN b BLOB,OUT n INT) BEGIN SELECT HEX(b) AS b; SET n=OCTET_LENGTH(b); END")
            (exec conn "DROP PROCEDURE mb_stage6_long_results") $
            withPreparedStatement conn "CALL mb_stage6_long_results(?,?)" $ \statement -> do
                source <- S.fromList ["abc"]
                results <- queryPreparedStreamMulti statement [PreparedBytes source,PreparedValue MySQLNull]
                equal "row result with uploaded data" [["616263"]]
                    [map textOf row | PreparedRows _ values <- results,row <- values]
                equal "OUT parameter after upload" [[3]]
                    [map number values | PreparedOutParameters _ values <- results]
    , case6 "cursor-progress-reentry-is-local" $ do
        let options = defaultConnectionOptions {enableProgressReporting=True}
        (conn,statement,sent,_) <- statementFixture options 0 1
            [putToPacket 1 (putWord8 1),encodeToPacket 2 field,ending 3 66,
             progressPacket 1 "fetching",binaryRow 2 7,ending 3 130]
        writeIORef (C.connectionCapabilities conn) (bit 24 .|. bit 32)
        holder <- newIORef Nothing
        setProgressCallback conn (Just (\_ -> do
            cursor <- readIORef holder >>= maybe (fail "cursor not installed") pure
            expectLocal (\e -> case e of ConcurrentConnectionUse -> True; _ -> False) (closeCursor cursor)))
        (_,cursor) <- openCursor statement []
        writeIORef holder (Just cursor)
        equal "callback cannot drain the outer fetch" [[7]] . map (map number) =<< (fetchCursor cursor 3 >>= S.toList)
        equal "no nested RESET" [22,23,28] . map (L.head . pBody) =<< sent
    , case6 "progress-callback-cancellation" $ do
        (conn,_,closed) <- scripted defaultConnectionOptions {enableProgressReporting=True}
            [progressPacket 1 "",encodeToPacket 2 (OK 0 0 2 0)]
        writeIORef (C.connectionCapabilities conn) (bit 32)
        blocked <- newEmptyMVar
        setProgressCallback conn (Just (const (takeMVar blocked)))
        equal "callback cancellation propagates" Nothing =<< timeout 20000 (ping conn)
        equal "callback cancellation retires" Broken =<< connectionStatus conn
        equal "callback release once" 1 =<< closed
    , case6 "compression-bounds-before-body" $ do
        readCount <- newIORef (0::Int)
        header <- newIORef True
        let tooLarge = L.toStrict (L.take 7 (frame 1 1029 "x"))
        input <- S.makeInputStream $ do
            modifyIORef' readCount (+1)
            first <- atomicModifyIORef' header (\x -> (False,x))
            if first then pure (Just tooLarge) else fail "body was read before expansion bound"
        closed <- newIORef (0::Int)
        conn <- C.newTransportConnection defaultConnectionOptions {enableCompression=True,maximumMessageBytes=1024}
            input (const (pure ())) (modifyIORef' closed (+1))
        writeIORef (C.connectionCapabilities conn) (bit 5)
        C.connectionCompressionStart conn
        assertRetired conn (readIORef closed) (ping conn)
        equal "header only" 1 =<< readIORef readCount
    ] ++
    [ case6 ("cursor-metadata-parity-" ++ show tracking ++ "-" ++ show caching) $
        withOptions defaultConnectionOptions {enableSessionTracking=tracking,enableMetadataCaching=caching} $ \conn ->
            withPreparedStatement conn "SELECT seq,IF(seq%2,NULL,REPEAT('雪',10)),CAST(seq*1.25 AS DECIMAL(20,2)) FROM seq_1_to_9" $ \statement -> do
                (_,normal) <- queryPrepared statement []
                expected <- S.toList normal
                withCursor statement [] $ \cursor -> do
                    let loop acc = do
                            done <- cursorExhausted cursor
                            if done then pure acc else do
                                batch <- fetchCursor cursor 2 >>= S.toList
                                loop (acc ++ batch)
                    equal "cursor/scalar/NULL/Unicode/decimal parity" expected =<< loop []
    | tracking <- [False,True],caching <- [False,True]
    ] ++
    [ case6 ("cursor-" ++ operation ++ "-deadline-retires") $ do
        inputPackets <- newIORef (preparePackets 0 1 ++
            [putToPacket 1 (putWord8 1),encodeToPacket 2 field,ending 3 66])
        blocked <- newEmptyMVar
        input <- S.makeInputStream $ do
            packet <- atomicModifyIORef' inputPackets (\xs -> case xs of [] -> ([],Nothing); p:ps -> (ps,Just p))
            maybe (takeMVar blocked) (pure . Just) packet
        closed <- newIORef (0::Int)
        conn <- C.newConnection defaultConnectionOptions {cleanupTimeoutMicros=20000} input
            (const (pure ())) (modifyIORef' closed (+1))
        writeIORef (C.connectionCapabilities conn) (bit 24)
        statement <- prepareStatement conn "SELECT 1"
        (_,cursor) <- openCursor statement []
        if operation == "fetch" then do
            result <- timeout 20000 (fetchCursor cursor 1 >>= S.toList)
            equal "fetch timeout propagated" Nothing result
        else expectLocal (\e -> case e of CleanupDeadlineExceeded -> True; _ -> False) (closeCursor cursor)
        equal "deadline retired" Broken =<< connectionStatus conn
        equal "deadline one release" 1 =<< readIORef closed
    | operation <- ["fetch","close"]
    ]
