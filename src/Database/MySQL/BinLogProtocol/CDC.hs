{-# LANGUAGE BangPatterns #-}
-- | Stateful MariaDB event decoding. The decoder retains table metadata, never
-- transactions or row history; consumers control backpressure by reading once.
module Database.MySQL.BinLogProtocol.CDC
    ( CDCError(..), Gtid(..), GtidSet, gtidSet, parseGtidSet, renderGtidSet, gtidSetEntries
    , GtidList(..)
    , BinLogPosition(..), DecodeLimits(..), defaultDecodeLimits
    , CDCCheckpoint, checkpointPosition, checkpointGtids
    , CDCEvent(..), CDCPayload(..), newCDCDecoder, validCheckpoint
    ) where

import Control.Exception (throwIO, catch, SomeException, Exception)
import Control.Monad
import qualified Codec.Compression.Zlib.Internal as Z
import Data.Binary.Get
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as L
import Data.IORef
import qualified Data.Map.Strict as M
import Data.Unique
import Data.Word
import Database.MySQL.BinLogProtocol.BinLogEvent
import Database.MySQL.Protocol.Packet (getLenEncInt)
import Database.MySQL.Query (fromQuery)
import qualified System.IO.Streams as S
import Text.Read (readMaybe)

-- | CDC-specific failures, separate from packet decoding and connection
-- ownership/transport exceptions. Configuration/checkpoint misuse is rejected
-- locally; decoding, expansion and unsupported-stream failures are terminal
-- when read through 'Database.MySQL.BinLog.openCDC'.
data CDCError
    = CDCInvalidConfiguration !String
    | CDCInvalidCheckpoint !String
    | CDCDecodeError !String
    | CDCResourceLimit !String
    | CDCUnsupportedFeature !String
    deriving (Eq, Show)
instance Exception CDCError

-- | MariaDB identity, domain-server-sequence (not a UUID interval).
data Gtid = Gtid
    { gtidDomainId :: !Word32, gtidServerId :: !Word32, gtidSequence :: !Word64
    } deriving (Eq, Show)

-- | One last completed transaction per replication domain. Construction rejects
-- duplicate domains: silently picking one can skip a different primary's work.
newtype GtidSet = GtidSet (M.Map Word32 Gtid) deriving (Eq, Show)

-- | Validate at most 4096 unique domains with positive sequence numbers.
gtidSet :: [Gtid] -> Either String GtidSet
gtidSet entries
    | length entries > 4096 = Left "GTID set exceeds 4096 domains"
    | any ((== 0) . gtidSequence) entries = Left "GTID sequence must be positive"
    | M.size result /= length entries = Left "duplicate GTID domain"
    | otherwise = Right (GtidSet result)
  where result = M.fromList [(gtidDomainId g, g) | g <- entries]

-- | Parse a bounded MariaDB connect-state string. Empty means start at the
-- beginning of available history; negative, overflowing or ambiguous IDs fail.
parseGtidSet :: B.ByteString -> Either String GtidSet
parseGtidSet bytes
    | B.length bytes > 65535 = Left "GTID set exceeds 65535 bytes"
    | B.null bytes = gtidSet []
    | otherwise = traverse parseOne (C.split ',' bytes) >>= gtidSet
  where
    number :: B.ByteString -> Maybe Integer
    number part | B.length part > 20 || B.null part || B.any (\c -> c < 48 || c > 57) part = Nothing
                | otherwise = readMaybe (C.unpack part)
    parseOne part = case C.split '-' part of
        [d,s,n] -> case (number d, number s, number n) of
            (Just domain,Just server,Just sequenceNo)
                | domain <= 0xffffffff && server <= 0xffffffff && sequenceNo <= 0xffffffffffffffff ->
                    Right (Gtid (fromInteger domain) (fromInteger server) (fromInteger sequenceNo))
            _ -> Left "invalid/overflowing MariaDB GTID"
        _ -> Left "expected domain-server-sequence"

-- | Canonical ascending-domain representation suitable for @slave_connect_state@.
renderGtidSet :: GtidSet -> B.ByteString
renderGtidSet = C.intercalate "," . map render . gtidSetEntries
  where render (Gtid d s n) = C.pack (show d ++ "-" ++ show s ++ "-" ++ show n)

-- | Inspect completed domain positions in canonical order.
gtidSetEntries :: GtidSet -> [Gtid]
gtidSetEntries (GtidSet entries) = M.elems entries

-- | Binlog history advertised by a GTID_LIST event. A domain can contain
-- several originating servers after failover; collapsing it into 'GtidSet'
-- would discard history or guess a resume position. This informational event
-- does not advance a transaction checkpoint.
data GtidList = GtidList
    { gtidListFlags :: !Word32 -- ^ Original upper four bits of the count word.
    , gtidListEntries :: ![Gtid] -- ^ All domain/server entries, in wire order.
    } deriving (Eq, Show)

-- | Binlog coordinates retain 64 bits. Traditional COM_BINLOG_DUMP accepts only
-- 32 bits; the connection API checks that boundary rather than truncating it.
data BinLogPosition = BinLogPosition
    { binlogFile :: !B.ByteString, binlogNextPosition :: !Word64
    } deriving (Eq, Show)

-- | Independent retained-metadata and event expansion budgets. Exceeding a
-- budget fails the stream; eviction would make later row images ambiguous.
data DecodeLimits = DecodeLimits
    { maxTableMaps :: !Int, maxTableMapBytes :: !Int
    , maxExpandedEventBytes :: !Int
    } deriving (Eq, Show)

-- | 4096 maps, 16 MiB retained metadata and 64 MiB expanded/reassembled events.
defaultDecodeLimits :: DecodeLimits
defaultDecodeLimits = DecodeLimits 4096 (16 * 1024 * 1024) (64 * 1024 * 1024)

-- | Opaque complete-group token. Persist its exported position/state, never
-- its stream-local identity; only a live token can acknowledge that stream.
--
-- The unique decoder identity and delivery sequence cannot be manufactured by a
-- caller. Only completed transaction boundaries produce a checkpoint.
data CDCCheckpoint = CDCCheckpoint !Unique !Word64 !BinLogPosition !(Maybe GtidSet)
instance Show CDCCheckpoint where
    show token = "CDCCheckpoint " ++ show (checkpointPosition token) ++ " " ++ show (checkpointGtids token)
instance Eq CDCCheckpoint where
    CDCCheckpoint u n p g == CDCCheckpoint v m q h = u == v && n == m && p == q && g == h

-- | Next event coordinate after a complete delivered transaction/group.
checkpointPosition :: CDCCheckpoint -> BinLogPosition
checkpointPosition (CDCCheckpoint _ _ position _) = position

-- | Complete GTID resume state when the stream started from GTIDs. A file
-- position start has no proven initial GTID state, so returns Nothing; resume
-- it using the file coordinate. Persist the checkpoint atomically with
-- destination writes before acknowledging. This value alone proves no durability.
checkpointGtids :: CDCCheckpoint -> Maybe GtidSet
checkpointGtids (CDCCheckpoint _ _ _ gtids) = gtids

-- | Decoded event plus an optional complete-group checkpoint. Row images retain
-- present-column bitmaps; a missing column is distinct from 'BinLogNull'.
data CDCEvent = CDCEvent
    { cdcEventPosition :: !BinLogPosition, cdcEventTimestamp :: !Word32
    , cdcEventPayload :: !CDCPayload, cdcEventCheckpoint :: !(Maybe CDCCheckpoint)
    , cdcEventAckRequested :: !Bool
    } deriving (Eq, Show)

-- | Events needed to reproduce the change stream. Unsupported non-ignorable
-- events fail instead of silently crossing an unsafe checkpoint boundary.
data CDCPayload
    = CDCBegin !Gtid !Word8
    | CDCQuery !QueryEvent
    | CDCAnnotate !B.ByteString
    | CDCRowQuery !QueryEvent'
    | CDCWrite !TableMapEvent !WriteRowsEvent
    | CDCUpdate !TableMapEvent !UpdateRowsEvent
    | CDCDelete !TableMapEvent !DeleteRowsEvent
    | CDCCommit !(Maybe Word64)
    | CDCRollback
    | CDCRotate !RotateEvent
    | CDCFormat !FormatDescription
    | CDCGtidList !GtidList
    | CDCBinlogCheckpoint !B.ByteString
    | CDCHeartbeat
    | CDCStop
    | CDCIgnorable !BinLogPacket
    deriving (Eq, Show)

data Decoder = Decoder
    { format :: !FormatDescription, filename :: !B.ByteString
    , maps :: !(M.Map Word64 (Int,TableMapEvent)), mapBytes :: !Int
    , active :: !(Maybe (Gtid,Word8)), transactionOpen :: !Bool
    , completed :: !GtidSet, delivery :: !Word64
    }

-- | Check that a token belongs to this decoder and is no newer than the
-- available boundary. Connection code separately enforces monotone ACKs.
validCheckpoint :: CDCCheckpoint -> CDCCheckpoint -> Bool
validCheckpoint (CDCCheckpoint owner current _ _) (CDCCheckpoint candidate sequenceNo _ _) =
    owner == candidate && sequenceNo <= current

-- | Construct a single-consumer decoder and latest-boundary observer. No read
-- ahead or background worker is used. Live callers must wrap reads with their connection
-- ownership/error guard; standalone decoders propagate failures to the caller.
newCDCDecoder :: DecodeLimits -> Maybe GtidSet -> FormatDescription -> B.ByteString
              -> S.InputStream BinLogPacket
              -> IO (S.InputStream CDCEvent, IO (Maybe CDCCheckpoint))
newCDCDecoder limits initialGtids initialFormat initialFile input = do
    when (maxTableMaps limits <= 0 || maxTableMapBytes limits <= 0 || maxExpandedEventBytes limits <= 0)
        (throwIO (CDCInvalidConfiguration "positive CDC budgets required"))
    when (B.null initialFile || B.length initialFile > 512 || B.elem 0 initialFile
          || fdVersion initialFormat /= 4 || B.length (fdMySQLVersion initialFormat) > 50
          || B.length (fdEventHeaderLenVector initialFormat) > 256)
        (throwIO (CDCInvalidConfiguration "invalid initial filename/format"))
    inputEvents <- assembleEvents limits input
    owner <- newUnique
    let initialState = maybe (GtidSet M.empty) id initialGtids
        ownedFormat = initialFormat
            { fdMySQLVersion = B.copy (fdMySQLVersion initialFormat)
            , fdEventHeaderLenVector = B.copy (fdEventHeaderLenVector initialFormat)
            }
    state <- newIORef (Decoder ownedFormat (B.copy initialFile) M.empty 0 Nothing False initialState 0)
    latest <- newIORef Nothing
    ended <- newIORef False
    let step = do
            done <- readIORef ended
            if done then pure Nothing else do
                event <- S.read inputEvents
                current <- readIORef state
                case event of
                    Nothing -> do
                        writeIORef ended True
                        when (transactionOpen current || active current /= Nothing)
                            (bad "binlog ended inside an event group")
                        pure Nothing
                    Just packet -> do
                        expanded <- expandEvent limits (format current) packet
                        decode owner latest state current expanded
        decode ownerId latestRef stateRef current packet = do
            let typ = blEventType packet
                position = BinLogPosition (filename current) (blLogPos packet)
                emit next payload boundary = do
                    when (boundary && (blLogPos packet < 4 || B.null (filename current)))
                        (bad "transaction boundary has no resumable file position")
                    let sequenceNo = delivery current + 1
                        token = if boundary then Just (CDCCheckpoint ownerId sequenceNo position (completed next <$ initialGtids)) else Nothing
                    writeIORef stateRef next { delivery = sequenceNo }
                    forM_ token (writeIORef latestRef . Just)
                    pure (Just (CDCEvent position (blTimestamp packet) payload token (blSemiAck packet)))
                clear next = next { maps = M.empty, mapBytes = 0 }
                finish = do
                    newGtids <- case active current of
                        Nothing -> pure (completed current)
                        Just (g,_) -> advance g (completed current)
                    pure (clear current { active = Nothing, transactionOpen = False, completed = newGtids })
                row parser payload flags = do
                    tid <- getFromBinLogPacket (getTableId (format current) typ) packet
                    table <- maybe (bad "rows reference an unknown/stale table ID") (pure . snd) (M.lookup tid (maps current))
                    value <- getFromBinLogPacket' (parser (format current) table) packet
                    let endStatement = flags value .&. 1 /= 0
                        standalone = maybe False (\(_,f) -> f .&. 1 /= 0) (active current)
                    next <- if endStatement && standalone then finish
                            else pure (if endStatement then clear current else current)
                    emit next (payload table value) (endStatement && standalone)
            case typ of
                BINLOG_TABLE_MAP_EVENT -> do
                    when (toInteger (L.length (blBody packet)) > toInteger (maxTableMapBytes limits))
                        (throwIO (CDCResourceLimit "CDC table metadata wire budget exceeded"))
                    table <- getFromBinLogPacket (getTableMapEvent (format current)) packet
                    let key = tmTableId table
                        -- Account the complete wire metadata plus conservative
                        -- list/constructor overhead; copy only retained slices.
                        charge = toInteger (L.length (blBody packet)) + 512
                            + 128 * toInteger (tmColumnCnt table + length (tmOptionalMetadata table))
                        bytes = fromInteger charge
                        old = maybe 0 fst (M.lookup key (maps current))
                        total = toInteger (mapBytes current) - toInteger old + charge
                        count = M.size (maps current) + if M.member key (maps current) then 0 else 1
                    when (count > maxTableMaps limits || total > toInteger (maxTableMapBytes limits))
                        (throwIO (CDCResourceLimit "CDC table metadata budget exceeded"))
                    writeIORef stateRef current { maps = M.insert key (bytes,table) (maps current), mapBytes = fromInteger total }
                    step
                BINLOG_WRITE_ROWS_EVENTv1 -> row getWriteRowEvent CDCWrite writeFlags
                BINLOG_WRITE_ROWS_EVENTv2 -> row getWriteRowEvent CDCWrite writeFlags
                BINLOG_UPDATE_ROWS_EVENTv1 -> row getUpdateRowEvent CDCUpdate updateFlags
                BINLOG_UPDATE_ROWS_EVENTv2 -> row getUpdateRowEvent CDCUpdate updateFlags
                BINLOG_DELETE_ROWS_EVENTv1 -> row getDeleteRowEvent CDCDelete deleteFlags
                BINLOG_DELETE_ROWS_EVENTv2 -> row getDeleteRowEvent CDCDelete deleteFlags
                MARIADB_GTID_EVENT -> do
                    when (active current /= Nothing || transactionOpen current) (bad "nested/incomplete GTID group")
                    (g,flags,extraFlags) <- getFromBinLogPacket (getGtid (blServerId packet)) packet
                    when (flags .&. 0xc0 /= 0) (throwIO (CDCUnsupportedFeature "XA groups require an XA-aware consumer"))
                    when (extraFlags .&. 0x0e /= 0)
                        (throwIO (CDCUnsupportedFeature "two-phase ALTER requires an ALTER-aware consumer"))
                    when (extraFlags .&. complement 0x1f /= 0)
                        (throwIO (CDCUnsupportedFeature "unknown MariaDB GTID extension flags"))
                    emit (clear current { active = Just (g,flags) }) (CDCBegin g flags) False
                BINLOG_XID_EVENT -> do
                    xid <- getFromBinLogPacket getWord64le packet
                    next <- finish
                    emit next (CDCCommit (Just xid)) True
                BINLOG_QUERY_EVENT -> do
                    query <- getFromBinLogPacket getQueryEvent packet
                    -- Control statements are at most eight bytes. A ninth byte
                    -- proves this is ordinary SQL, so classification need not
                    -- flatten and uppercase a potentially 64 MiB query body.
                    -- Keep the complete original query in the emitted payload.
                    let sql = C.map upper (L.toStrict (L.take 9
                            (L.dropWhile (==32) (fromQuery (qQuery query)))))
                    case sql of
                        "BEGIN" -> emit (clear current { transactionOpen = True }) (CDCQuery query) False
                        "COMMIT" -> finish >>= \next -> emit next (CDCCommit Nothing) True
                        "ROLLBACK" -> finish >>= \next -> emit next CDCRollback True
                        _ -> do
                            let standalone = maybe (not (transactionOpen current)) (\(_,f) -> f .&. 1 /= 0) (active current)
                            next <- if standalone then finish else pure (clear current)
                            emit next (CDCQuery query) standalone
                MARIADB_ANNOTATE_ROWS_EVENT -> emit current (CDCAnnotate (L.toStrict (blBody packet))) False
                BINLOG_ROWS_QUERY_EVENT -> do
                    query <- getFromBinLogPacket getQueryEvent' packet
                    emit current (CDCRowQuery query) False
                BINLOG_ROTATE_EVENT -> do
                    rotation <- getFromBinLogPacket getRotateEvent packet
                    when (transactionOpen current || active current /= Nothing) (bad "rotation inside event group")
                    emit (clear current { filename = B.copy (rFileName rotation) }) (CDCRotate rotation) False
                BINLOG_FORMAT_DESCRIPTION_EVENT -> do
                    fd <- getFromBinLogPacket getFormatDescription packet
                    when (transactionOpen current || active current /= Nothing) (bad "format change inside event group")
                    emit (clear current { format = fd }) (CDCFormat fd) False
                MARIADB_GTID_LIST_EVENT -> do
                    entries <- getFromBinLogPacket getGtidList packet
                    emit current (CDCGtidList entries) False
                MARIADB_BINLOG_CHECKPOINT_EVENT -> do
                    name <- getFromBinLogPacket (getWord32le >>= getByteString . fromIntegral) packet
                    emit current (CDCBinlogCheckpoint name) False
                BINLOG_HEARTBEAT_EVENT -> emit current CDCHeartbeat False
                BINLOG_STOP_EVENT -> do
                    when (active current /= Nothing || transactionOpen current) (bad "STOP inside event group")
                    emit (clear current) CDCStop False
                -- INTVAR/RAND/USER_VAR carry statement context. Expose the raw
                -- event so statement-based consumers cannot lose that context.
                _ | typ `elem` [BINLOG_INTVAR_EVENT,BINLOG_RAND_EVENT,BINLOG_USER_VAR_EVENT,BINLOG_IGNORABLE_EVENT]
                      || blFlags packet .&. 0x80 /= 0 -> emit current (CDCIgnorable packet) False
                  | otherwise -> throwIO (CDCUnsupportedFeature ("non-ignorable event: " ++ show typ))
    failed <- newIORef Nothing
    let guarded = do
            failure <- readIORef failed
            case failure of
                Just err -> throwIO (err :: SomeException)
                Nothing -> step `catch` \err -> writeIORef failed (Just err) >> throwIO (err :: SomeException)
    output <- S.makeInputStream guarded
    pure (output, readIORef latest)
  where
    upper c | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
            | otherwise = c

-- A row's table ID can be inspected without decoding its image. Post-header 6
-- is the old four-byte table ID; ordinary MariaDB headers contain six bytes.
getTableId :: FormatDescription -> BinLogEventType -> Get Word64
getTableId fd typ = do
    tid <- if eventHeaderLen fd typ == 6 then fromIntegral <$> getWord32le else do
        lo <- getWord32le
        hi <- getWord16le
        pure (fromIntegral lo .|. (fromIntegral hi `shiftL` 32))
    void getRemainingLazyByteString
    pure tid

-- MariaDB pads short GTIDs to 19 body bytes, or appends a group-commit ID and
-- typed extensions. Known neutral engine/thread metadata may be skipped only
-- after its complete layout is validated. XA/two-phase DDL are rejected by the
-- caller before delivery; unknown extension flags must never imply safety.
getGtid :: Word32 -> Get (Gtid,Word8,Word8)
getGtid server = do
    start <- bytesRead
    sequenceNo <- getWord64le
    domain <- getWord32le
    flags <- getWord8
    when (sequenceNo == 0) (fail "zero GTID sequence")
    when (flags .&. 2 /= 0) (void getWord64le)
    extraFlags <- if flags .&. 0xc0 /= 0 then do
        -- The XA layout is intentionally not interpreted as ordinary metadata.
        void getRemainingLazyByteString
        pure 0
      else do
        empty <- isEmpty
        extra <- if empty then pure 0 else getWord8
        if extra .&. complement 0x1f /= 0 then void getRemainingLazyByteString
          else do
            when (extra .&. 1 /= 0) $ do
                engines <- getWord8
                when (engines == 0) (fail "zero additional GTID engine count")
            when (extra .&. 0x0c /= 0) (void getWord64le)
            when (extra .&. 0x10 /= 0) (void getWord32le)
            padding <- getRemainingLazyByteString
            unless (L.all (==0) padding) (fail "nonzero GTID padding")
        pure extra
    end <- bytesRead
    when (end - start < 19) (fail "truncated MariaDB GTID header")
    pure (Gtid domain server sequenceNo, flags, extraFlags)

getGtidList :: Get GtidList
getGtidList = do
    countAndFlags <- getWord32le
    let count = countAndFlags .&. 0x0fffffff
    when (count > 4096) (fail "GTID list exceeds entry budget")
    entries <- replicateM (fromIntegral count) (Gtid <$> getWord32le <*> getWord32le <*> getWord64le)
    let identities = M.fromList [((gtidDomainId g,gtidServerId g),()) | g <- entries]
    when (any ((==0) . gtidSequence) entries || M.size identities /= length entries)
        (fail "invalid/duplicate GTID history entry")
    pure (GtidList (countAndFlags .&. 0xf0000000) entries)

advance :: Gtid -> GtidSet -> IO GtidSet
advance g (GtidSet entries) = do
    when (maybe False ((>= gtidSequence g) . gtidSequence) (M.lookup (gtidDomainId g) entries))
        (bad "non-advancing GTID sequence")
    when (M.size entries >= 4096 && M.notMember (gtidDomainId g) entries) (throwIO (CDCResourceLimit "GTID domain budget exceeded"))
    pure (GtidSet (M.insert (gtidDomainId g) g entries))

bad :: String -> IO a
bad = throwIO . CDCDecodeError

-- Compressed events leave their post-header and bitmaps uncompressed. Only
-- the row/query payload has MariaDB's algorithm/length prefix followed by zlib.
-- Incremental inflation enforces both the advertised length and our expansion
-- budget before retaining output, including on a deliberately tiny zip bomb.
expandEvent :: DecodeLimits -> FormatDescription -> BinLogPacket -> IO BinLogPacket
expandEvent limits fd packet
    | L.length (blBody packet) > fromIntegral (maxExpandedEventBytes limits) = throwIO (CDCResourceLimit "event byte budget exceeded")
    | Just normal <- lookup (blEventType packet) compressedTypes = do
        (prefix, compressed) <- getFromBinLogPacket (splitCompressed normal) packet
        (size, payload) <- getFromBinLogPacket compressedHeader packet { blBody = compressed }
        when (size <= 0 || toInteger size + toInteger (L.length prefix) > toInteger (maxExpandedEventBytes limits))
            (throwIO (CDCResourceLimit "compressed event expansion budget exceeded"))
        inflated <- inflateBounded size payload
        pure packet { blEventType = normal, blBody = prefix <> inflated }
    | otherwise = pure packet
  where
    splitCompressed normal = do
        start <- bytesRead
        if normal == BINLOG_QUERY_EVENT then do
            skip 8
            schemaLength <- getWord8
            skip 2
            statusLength <- getWord16le
            skip (fromIntegral statusLength + fromIntegral schemaLength + 1)
          else do
            skip (if eventHeaderLen fd normal == 6 then 6 else 8)
            when (normal `elem` [BINLOG_WRITE_ROWS_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2]) $ do
                extra <- getWord16le
                when (extra < 2) (fail "compressed rows: invalid extra header")
                skip (fromIntegral extra - 2)
            columns <- getLenEncInt
            when (columns <= 0 || columns > 4096) (fail "compressed rows: invalid column count")
            skip (((columns + 7) `div` 8) * if normal `elem` [BINLOG_UPDATE_ROWS_EVENTv1,BINLOG_UPDATE_ROWS_EVENTv2] then 2 else 1)
        end <- bytesRead
        remainder <- getRemainingLazyByteString
        pure (L.take (end - start) (blBody packet), remainder)
    compressedHeader = do
        header <- getWord8
        let width = fromIntegral (header .&. 7)
        unless (header .&. 0xf8 == 0x80 && width >= 1 && width <= 4)
            (fail "unsupported MariaDB binlog compression header")
        bytes <- getByteString width
        let size = B.foldl' (\n b -> n * 256 + fromIntegral b) (0 :: Word64) bytes
        when (size > fromIntegral (maxBound :: Int)) (fail "compressed length overflow")
        payload <- getRemainingLazyByteString
        pure (fromIntegral size, payload)

compressedTypes :: [(BinLogEventType,BinLogEventType)]
compressedTypes = [(MARIADB_QUERY_COMPRESSED_EVENT,BINLOG_QUERY_EVENT),
    (MARIADB_WRITE_ROWS_COMPRESSED_EVENTv1,BINLOG_WRITE_ROWS_EVENTv1),
    (MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv1,BINLOG_UPDATE_ROWS_EVENTv1),
    (MARIADB_DELETE_ROWS_COMPRESSED_EVENTv1,BINLOG_DELETE_ROWS_EVENTv1),
    (MARIADB_WRITE_ROWS_COMPRESSED_EVENTv2,BINLOG_WRITE_ROWS_EVENTv2),
    (MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2),
    (MARIADB_DELETE_ROWS_COMPRESSED_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2)]

inflateBounded :: Int -> L.ByteString -> IO L.ByteString
inflateBounded expected input = go 0 [] (L.toChunks input) (Z.decompressIO Z.zlibFormat Z.defaultDecompressParams)
  where
    go !size chunks pending stream = case stream of
        Z.DecompressInputRequired next -> case pending of
            [] -> next B.empty >>= go size chunks []
            chunk:rest -> next chunk >>= go size chunks rest
        Z.DecompressOutputAvailable chunk next -> do
            let total = size + B.length chunk
            when (total > expected) (throwIO (CDCResourceLimit "inflated event exceeds advertised length"))
            next >>= go total (chunk:chunks) pending
        Z.DecompressStreamEnd trailing -> do
            unless (size == expected && B.null trailing && all B.null pending)
                (bad "compressed event length/trailing data mismatch")
            pure (L.fromChunks (reverse chunks))
        Z.DecompressStreamError err -> bad ("invalid zlib event: " ++ show err)

-- MariaDB 13.2 can split one row event into type-172 fragments. All physical
-- fragments have already passed CRC validation. Reassemble only the one bounded
-- event; reject interleaving, missing/repeated fragments and false size claims.
assembleEvents :: DecodeLimits -> S.InputStream BinLogPacket -> IO (S.InputStream BinLogPacket)
assembleEvents limits input = S.makeInputStream $ do
    next <- S.read input
    case next of
        Just packet | blEventType packet == MARIADB_PARTIAL_ROW_DATA_EVENT -> do
            (total, sequenceNo, flags, size, first) <- getFromBinLogPacket fragment packet
            unless (total >= 2 && total <= 65536 && sequenceNo == 1 && flags == 1
                    && size >= 19 && size <= fromIntegral (maxExpandedEventBytes limits))
                (bad "invalid first row fragment/expansion budget")
            gather total 2 size (L.length first) [first] (blSemiAck packet) packet
        other -> pure other
  where
    fragment = do
        total <- getWord32le
        sequenceNo <- getWord32le
        flags <- getWord8
        size <- if flags .&. 1 /= 0 then getWord64le else pure 0
        body <- getRemainingLazyByteString
        pure (total, sequenceNo, flags, size, body)
    gather total expected size used chunks ack previous
        | used > fromIntegral size = bad "row fragments exceed advertised event size"
        | expected > total = do
            unless (used == fromIntegral size) (bad "incomplete reassembled row event")
            let body = L.concat (reverse chunks)
            -- The embedded event's on-disk size may still include its checksum;
            -- fragments carry their own checksums instead. Decode the common
            -- header directly and require an ordinary row event.
            embedded <- getFromBinLogPacket embeddedRow previous { blBody = body }
            unless (fromIntegral (blEventSize embedded) == used || fromIntegral (blEventSize embedded) == used + 4)
                (bad "embedded row event size mismatch")
            unless (blEventType embedded `elem` [BINLOG_WRITE_ROWS_EVENTv1,BINLOG_UPDATE_ROWS_EVENTv1,
                    BINLOG_DELETE_ROWS_EVENTv1,BINLOG_WRITE_ROWS_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2])
                (bad "fragmented payload is not a supported row event")
            pure (Just embedded { blLogPos = blLogPos previous, blSemiAck = ack })
        | otherwise = do
            packet <- S.read input >>= maybe (bad "binlog ended inside fragmented row event") pure
            unless (blEventType packet == MARIADB_PARTIAL_ROW_DATA_EVENT && blServerId packet == blServerId previous) (bad "interleaved row fragment stream")
            (count, sequenceNo, flags, _, chunk) <- getFromBinLogPacket fragment packet
            unless (count == total && sequenceNo == expected && flags == 0 && not (L.null chunk))
                (bad "out-of-order/invalid row fragment")
            gather total (expected + 1) size (used + L.length chunk) (chunk:chunks) (ack || blSemiAck packet) packet
    embeddedRow = BinLogPacket <$> getWord32le <*> (toEnum . fromIntegral <$> getWord8)
        <*> getWord32le <*> getWord32le <*> (fromIntegral <$> getWord32le)
        <*> getWord16le <*> getRemainingLazyByteString <*> pure False
