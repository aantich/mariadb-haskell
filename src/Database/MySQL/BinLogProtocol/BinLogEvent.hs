{-# OPTIONS_GHC -funbox-strict-fields #-}

{-|
Module      : Database.MySQL.BinLogProtocol.BinLogEvent
Description : Binlog event
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : Anton Antich <anton.antich@gmail.com>
Stability   : experimental
Portability : PORTABLE

Binlog event type
-}

module Database.MySQL.BinLogProtocol.BinLogEvent
    ( BinLogEventType(..), BinLogPacket(..), putSemiAckResp, getBinLogPacket
    , binLogCRC32, getFromBinLogPacket, getFromBinLogPacket'
    , FormatDescription(..), getFormatDescription, eventHeaderLen
    , RotateEvent(..), getRotateEvent, QueryEvent(..), getQueryEvent
    , QueryEvent'(..), getQueryEvent', TableMapEvent(..), getTableMapEvent
    , DeleteRowsEvent(..), getDeleteRowEvent, WriteRowsEvent(..), getWriteRowEvent
    , UpdateRowsEvent(..), getUpdateRowEvent, getPresentMap
    ) where

import           Control.Monad
import qualified Data.Vector.Unboxed                       as V
import           Data.Binary
import           Data.Binary.Put (putWord64le, putByteString)
import           Data.Binary.Parser
import           Data.Bits
import           Data.ByteString                           (ByteString)
import qualified Data.ByteString                           as B
import qualified Data.ByteString.Lazy                      as L
import qualified Data.ByteString.Unsafe                    as B
import           Database.MySQL.BinLogProtocol.BinLogMeta
import           Database.MySQL.BinLogProtocol.BinLogValue
import           Database.MySQL.Protocol.Packet
import           Database.MySQL.Protocol.MySQLValue
import           Database.MySQL.Protocol.ColumnDef

import           Control.Exception                         (throwIO)
import           Database.MySQL.Query
import           GHC.Generics                              (Generic)

--------------------------------------------------------------------------------
-- | Binlog event identifiers, including MariaDB extensions.
--
data BinLogEventType
    = BINLOG_UNKNOWN_EVENT
    | BINLOG_START_EVENT_V3
    | BINLOG_QUERY_EVENT
    | BINLOG_STOP_EVENT
    | BINLOG_ROTATE_EVENT
    | BINLOG_INTVAR_EVENT
    | BINLOG_LOAD_EVENT
    | BINLOG_SLAVE_EVENT
    | BINLOG_CREATE_FILE_EVENT
    | BINLOG_APPEND_BLOCK_EVENT
    | BINLOG_EXEC_LOAD_EVENT
    | BINLOG_DELETE_FILE_EVENT
    | BINLOG_NEW_LOAD_EVENT
    | BINLOG_RAND_EVENT
    | BINLOG_USER_VAR_EVENT
    | BINLOG_FORMAT_DESCRIPTION_EVENT
    | BINLOG_XID_EVENT
    | BINLOG_BEGIN_LOAD_QUERY_EVENT
    | BINLOG_EXECUTE_LOAD_QUERY_EVENT
    | BINLOG_TABLE_MAP_EVENT
    | BINLOG_WRITE_ROWS_EVENTv0
    | BINLOG_UPDATE_ROWS_EVENTv0
    | BINLOG_DELETE_ROWS_EVENTv0
    | BINLOG_WRITE_ROWS_EVENTv1
    | BINLOG_UPDATE_ROWS_EVENTv1
    | BINLOG_DELETE_ROWS_EVENTv1
    | BINLOG_INCIDENT_EVENT
    | BINLOG_HEARTBEAT_EVENT
    | BINLOG_IGNORABLE_EVENT
    | BINLOG_ROWS_QUERY_EVENT
    | BINLOG_WRITE_ROWS_EVENTv2
    | BINLOG_UPDATE_ROWS_EVENTv2
    | BINLOG_DELETE_ROWS_EVENTv2
    | BINLOG_GTID_EVENT
    | BINLOG_ANONYMOUS_GTID_EVENT
    | BINLOG_PREVIOUS_GTIDS_EVENT
    | MARIADB_ANNOTATE_ROWS_EVENT
    | MARIADB_BINLOG_CHECKPOINT_EVENT
    | MARIADB_GTID_EVENT
    | MARIADB_GTID_LIST_EVENT
    | MARIADB_START_ENCRYPTION_EVENT
    | MARIADB_QUERY_COMPRESSED_EVENT
    | MARIADB_WRITE_ROWS_COMPRESSED_EVENTv1
    | MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv1
    | MARIADB_DELETE_ROWS_COMPRESSED_EVENTv1
    | MARIADB_WRITE_ROWS_COMPRESSED_EVENTv2
    | MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv2
    | MARIADB_DELETE_ROWS_COMPRESSED_EVENTv2
    | MARIADB_PARTIAL_ROW_DATA_EVENT
    | UnrecognizedBinLogEvent !Word8
  deriving (Show, Eq)

-- | Preserve wire identifiers, including future events. Unlike derived Enum,
-- decoding a new MariaDB event can never raise a pure out-of-range exception.
instance Enum BinLogEventType where
    toEnum n = case n of
        0 -> BINLOG_UNKNOWN_EVENT
        1 -> BINLOG_START_EVENT_V3
        2 -> BINLOG_QUERY_EVENT
        3 -> BINLOG_STOP_EVENT
        4 -> BINLOG_ROTATE_EVENT
        5 -> BINLOG_INTVAR_EVENT
        6 -> BINLOG_LOAD_EVENT
        7 -> BINLOG_SLAVE_EVENT
        8 -> BINLOG_CREATE_FILE_EVENT
        9 -> BINLOG_APPEND_BLOCK_EVENT
        10 -> BINLOG_EXEC_LOAD_EVENT
        11 -> BINLOG_DELETE_FILE_EVENT
        12 -> BINLOG_NEW_LOAD_EVENT
        13 -> BINLOG_RAND_EVENT
        14 -> BINLOG_USER_VAR_EVENT
        15 -> BINLOG_FORMAT_DESCRIPTION_EVENT
        16 -> BINLOG_XID_EVENT
        17 -> BINLOG_BEGIN_LOAD_QUERY_EVENT
        18 -> BINLOG_EXECUTE_LOAD_QUERY_EVENT
        19 -> BINLOG_TABLE_MAP_EVENT
        20 -> BINLOG_WRITE_ROWS_EVENTv0
        21 -> BINLOG_UPDATE_ROWS_EVENTv0
        22 -> BINLOG_DELETE_ROWS_EVENTv0
        23 -> BINLOG_WRITE_ROWS_EVENTv1
        24 -> BINLOG_UPDATE_ROWS_EVENTv1
        25 -> BINLOG_DELETE_ROWS_EVENTv1
        26 -> BINLOG_INCIDENT_EVENT
        27 -> BINLOG_HEARTBEAT_EVENT
        28 -> BINLOG_IGNORABLE_EVENT
        29 -> BINLOG_ROWS_QUERY_EVENT
        30 -> BINLOG_WRITE_ROWS_EVENTv2
        31 -> BINLOG_UPDATE_ROWS_EVENTv2
        32 -> BINLOG_DELETE_ROWS_EVENTv2
        33 -> BINLOG_GTID_EVENT
        34 -> BINLOG_ANONYMOUS_GTID_EVENT
        35 -> BINLOG_PREVIOUS_GTIDS_EVENT
        160 -> MARIADB_ANNOTATE_ROWS_EVENT
        161 -> MARIADB_BINLOG_CHECKPOINT_EVENT
        162 -> MARIADB_GTID_EVENT
        163 -> MARIADB_GTID_LIST_EVENT
        164 -> MARIADB_START_ENCRYPTION_EVENT
        165 -> MARIADB_QUERY_COMPRESSED_EVENT
        166 -> MARIADB_WRITE_ROWS_COMPRESSED_EVENTv1
        167 -> MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv1
        168 -> MARIADB_DELETE_ROWS_COMPRESSED_EVENTv1
        169 -> MARIADB_WRITE_ROWS_COMPRESSED_EVENTv2
        170 -> MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv2
        171 -> MARIADB_DELETE_ROWS_COMPRESSED_EVENTv2
        172 -> MARIADB_PARTIAL_ROW_DATA_EVENT
        _ -> UnrecognizedBinLogEvent (fromIntegral n)
    fromEnum t = case t of
        BINLOG_UNKNOWN_EVENT -> 0
        BINLOG_START_EVENT_V3 -> 1
        BINLOG_QUERY_EVENT -> 2
        BINLOG_STOP_EVENT -> 3
        BINLOG_ROTATE_EVENT -> 4
        BINLOG_INTVAR_EVENT -> 5
        BINLOG_LOAD_EVENT -> 6
        BINLOG_SLAVE_EVENT -> 7
        BINLOG_CREATE_FILE_EVENT -> 8
        BINLOG_APPEND_BLOCK_EVENT -> 9
        BINLOG_EXEC_LOAD_EVENT -> 10
        BINLOG_DELETE_FILE_EVENT -> 11
        BINLOG_NEW_LOAD_EVENT -> 12
        BINLOG_RAND_EVENT -> 13
        BINLOG_USER_VAR_EVENT -> 14
        BINLOG_FORMAT_DESCRIPTION_EVENT -> 15
        BINLOG_XID_EVENT -> 16
        BINLOG_BEGIN_LOAD_QUERY_EVENT -> 17
        BINLOG_EXECUTE_LOAD_QUERY_EVENT -> 18
        BINLOG_TABLE_MAP_EVENT -> 19
        BINLOG_WRITE_ROWS_EVENTv0 -> 20
        BINLOG_UPDATE_ROWS_EVENTv0 -> 21
        BINLOG_DELETE_ROWS_EVENTv0 -> 22
        BINLOG_WRITE_ROWS_EVENTv1 -> 23
        BINLOG_UPDATE_ROWS_EVENTv1 -> 24
        BINLOG_DELETE_ROWS_EVENTv1 -> 25
        BINLOG_INCIDENT_EVENT -> 26
        BINLOG_HEARTBEAT_EVENT -> 27
        BINLOG_IGNORABLE_EVENT -> 28
        BINLOG_ROWS_QUERY_EVENT -> 29
        BINLOG_WRITE_ROWS_EVENTv2 -> 30
        BINLOG_UPDATE_ROWS_EVENTv2 -> 31
        BINLOG_DELETE_ROWS_EVENTv2 -> 32
        BINLOG_GTID_EVENT -> 33
        BINLOG_ANONYMOUS_GTID_EVENT -> 34
        BINLOG_PREVIOUS_GTIDS_EVENT -> 35
        MARIADB_ANNOTATE_ROWS_EVENT -> 160
        MARIADB_BINLOG_CHECKPOINT_EVENT -> 161
        MARIADB_GTID_EVENT -> 162
        MARIADB_GTID_LIST_EVENT -> 163
        MARIADB_START_ENCRYPTION_EVENT -> 164
        MARIADB_QUERY_COMPRESSED_EVENT -> 165
        MARIADB_WRITE_ROWS_COMPRESSED_EVENTv1 -> 166
        MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv1 -> 167
        MARIADB_DELETE_ROWS_COMPRESSED_EVENTv1 -> 168
        MARIADB_WRITE_ROWS_COMPRESSED_EVENTv2 -> 169
        MARIADB_UPDATE_ROWS_COMPRESSED_EVENTv2 -> 170
        MARIADB_DELETE_ROWS_COMPRESSED_EVENTv2 -> 171
        MARIADB_PARTIAL_ROW_DATA_EVENT -> 172
        UnrecognizedBinLogEvent n -> fromIntegral n

data BinLogPacket = BinLogPacket
    { blTimestamp :: !Word32
    , blEventType :: !BinLogEventType
    , blServerId  :: !Word32
    , blEventSize :: !Word32
    , blLogPos    :: !Word64   -- ^ for future GTID compatibility
    , blFlags     :: !Word16
    , blBody      :: !L.ByteString
    , blSemiAck   :: !Bool
    } deriving (Show, Eq)

-- | Semisynchronous acknowledgement payload: marker, little-endian 64-bit
-- position, then the un-terminated filename (MariaDB semisync wire format).
putSemiAckResp :: Word64 -> ByteString -> Put
putSemiAckResp pos fn = putWord8 0xef >> putWord64le pos >> putByteString fn

-- | Decode exactly one replication message, verifying CRC32 over the complete
-- event header and body. Packet framing bytes and semisync headers are excluded.
getBinLogPacket :: Bool -> Bool -> Get BinLogPacket
getBinLogPacket checksum semi = do
    marker <- getWord8
    unless (marker == 0) (fail "binlog: missing OK marker")
    ack <- if semi then do
        magic <- getWord8
        flags <- getWord8
        unless (magic == 0xef && flags .&. complement 1 == 0)
            (fail "binlog: malformed semisync header")
        pure (flags == 1)
      else pure False
    raw <- getRemainingLazyByteString
    let hasChecksum = checksum || (L.length raw >= 5 && L.index raw 4 == 15)
        trailer = if hasChecksum then 4 else 0
        total = L.length raw
    when (total < 19 + trailer) (fail "binlog: truncated common header/checksum")
    let parser = do
            ts <- getWord32le
            typ <- toEnum . fromIntegral <$> getWord8
            sid <- getWord32le
            size <- getWord32le
            pos <- getWord32le
            flags <- getWord16le
            unless (fromIntegral size == total) (fail "binlog: event size disagrees with message")
            body <- getLazyByteString (total - 19 - trailer)
            when hasChecksum $ do
                expected <- getWord32le
                unless (expected == binLogCRC32 (L.take (total - 4) raw))
                    (fail "binlog: CRC32 mismatch")
            pure (BinLogPacket ts typ sid size (fromIntegral pos) flags body ack)
    case runGetOrFail parser raw of
        Left (_, _, message) -> fail message
        Right (_, _, event) -> pure event

-- | IEEE CRC32 used by MariaDB. A shared unboxed lookup table avoids eight
-- branches per payload byte and does not concatenate lazy event chunks.
binLogCRC32 :: L.ByteString -> Word32
binLogCRC32 = complement . L.foldl' step 0xffffffff
  where
    step crc byte = (crc `shiftR` 8) `xor`
        (crcTable V.! fromIntegral ((crc `xor` fromIntegral byte) .&. 255))

crcTable :: V.Vector Word32
crcTable = V.generate 256 (go 8 . fromIntegral)
  where
    go :: Int -> Word32 -> Word32
    go 0 n = n
    go k n = go (k - 1) ((n `shiftR` 1) `xor` if testBit n 0 then 0xedb88320 else 0)
{-# NOINLINE crcTable #-}

getFromBinLogPacket :: Get a -> BinLogPacket -> IO a
getFromBinLogPacket g (BinLogPacket _ _ _ _ _ _ body _ ) =
    case parseDetailLazy (g <* endOfInput) body  of
        Left  (buf, offset, errmsg) -> throwIO (DecodePacketFailed buf offset errmsg)
        Right (_,   _,      r     ) -> return r

getFromBinLogPacket' :: (BinLogEventType -> Get a) -> BinLogPacket -> IO a
getFromBinLogPacket' g (BinLogPacket _ typ _ _ _ _ body _ ) =
    case parseDetailLazy (g typ <* endOfInput) body  of
        Left  (buf, offset, errmsg) -> throwIO (DecodePacketFailed buf offset errmsg)
        Right (_,   _,      r     ) -> return r

--------------------------------------------------------------------------------

data FormatDescription = FormatDescription
    { fdVersion              :: !Word16
    , fdMySQLVersion         :: !ByteString
    , fdCreateTime           :: !Word32
    -- , eventHeaderLen :: !Word8  -- const 19
    , fdEventHeaderLenVector :: !ByteString  -- ^ a array indexed by Binlog Event Type - 1
                                             -- to extract the length of the event specific header.
    } deriving (Show, Eq, Generic)

getFormatDescription :: Get FormatDescription
getFormatDescription = do
    version <- getWord16le
    server <- getByteString 50
    created <- getWord32le
    header <- getWord8
    unless (version == 4 && header == 19) (fail "unsupported binlog format/header length")
    rawLengths <- getRemainingLazyByteString
    when (L.null rawLengths || L.length rawLengths > 257) (fail "invalid format-description vector length")
    let lengths = L.toStrict rawLengths
    when (B.last lengths > 1) (fail "missing/unsupported checksum descriptor")
    pure (FormatDescription version (B.copy server) created (B.copy (B.init lengths)))

eventHeaderLen :: FormatDescription -> BinLogEventType -> Word8
eventHeaderLen fd typ
    | idx < 0 || idx >= B.length vec = 0
    | otherwise = B.unsafeIndex vec idx
  where
    vec :: ByteString
    vec = fdEventHeaderLenVector fd
    idx :: Int
    idx = fromEnum typ - 1

data RotateEvent = RotateEvent
    { rPos :: !Word64, rFileName :: !ByteString } deriving (Show, Eq)

getRotateEvent :: Get RotateEvent
getRotateEvent = do
    position <- getWord64le
    name <- getRemainingByteString
    unless (position >= 4 && not (B.null name) && B.length name <= 512 && not (B.elem 0 name))
        (fail "invalid rotate filename/position")
    pure (RotateEvent position name)

-- | This's query parser for statement based binlog's query event, it's actually
-- not used in row based binlog.
--
data QueryEvent = QueryEvent
    { qSlaveProxyId :: !Word32
    , qExecTime     :: !Word32
    , qErrCode      :: !Word16
    , qStatusVars   :: !ByteString
    , qSchemaName   :: !ByteString
    , qQuery        :: !Query
    } deriving (Show, Eq, Generic)

getQueryEvent :: Get QueryEvent
getQueryEvent = do
    pid <- getWord32le
    tim <- getWord32le
    slen <- getWord8
    ecode <- getWord16le
    vlen <- getWord16le
    svar <- getByteString (fromIntegral vlen)
    schema <- getByteString (fromIntegral slen)
    _ <- getWord8
    qry <- getRemainingLazyByteString
    return (QueryEvent pid tim ecode svar schema (Query qry))

-- | This's the query event in row based binlog.
--
data QueryEvent' = QueryEvent' { qQuery' :: !Query } deriving (Show, Eq)

getQueryEvent' :: Get QueryEvent'
getQueryEvent' = do
    _ <- getWord8
    QueryEvent' . Query <$> getRemainingLazyByteString

-- | Metadata validated by 'getTableMapEvent'. Low-level row parsers require
-- the corresponding parsed map; they reuse its proven metadata cardinality.
data TableMapEvent = TableMapEvent
    { tmTableId    :: !Word64
    , tmFlags      :: !Word16
    , tmSchemaName :: !ByteString
    , tmTableName  :: !ByteString
    , tmColumnCnt  :: !Int
    , tmColumnType :: ![FieldType]
    , tmColumnMeta :: ![BinLogMeta]
    , tmOptionalMetadata :: ![(Word8, ByteString)] -- ^ Owned, length-validated MariaDB TLVs, including unknown kinds.
    , tmNullMap    :: !ByteString
    } deriving (Show, Eq, Generic)

getTableMapEvent :: FormatDescription -> Get TableMapEvent
getTableMapEvent fd = do
    let hlen = eventHeaderLen fd BINLOG_TABLE_MAP_EVENT
    unless (hlen == 6 || hlen == 8) (fail "table map: unsupported post-header length")
    tid <- if hlen == 6 then fromIntegral <$> getWord32le else getWord48le
    flgs <- getWord16le
    slen <- getWord8
    schema <- getByteString (fromIntegral slen)
    schemaTerminator <- getWord8
    unless (schemaTerminator == 0) (fail "table map: missing name terminator")
    tlen <- getWord8
    table <- getByteString (fromIntegral tlen)
    zero <- getWord8
    unless (zero == 0) (fail "table map: missing name terminator")
    cc <- getLenEncInt
    when (cc <= 0 || cc > 4096) (fail "table map: invalid/excessive column count")
    colTypBS <- getByteString cc
    let typs = map FieldType (B.unpack colTypBS)
    metadataSize <- getLenEncInt
    when (metadataSize > 2 * cc) (fail "table map: excessive type metadata")
    colMetaBS <- getByteString metadataSize

    metas <- case runGetOrFail (forM typs getBinLogMeta) (L.fromStrict colMetaBS) of
        Left (_, _, errmsg) -> fail errmsg
        Right (rest, _, r) | L.null rest -> return r
        Right _ -> fail "table map: unused column metadata"

    nullmap <- getByteString ((cc + 7) `div` 8)
    optional <- getOptionalMetadata 256
    return (TableMapEvent tid flgs (B.copy schema) (B.copy table) cc typs metas optional (B.copy nullmap))

-- Unknown TLVs remain available to consumers (signedness, charset and column
-- names must not be invented from a SQL query against a potentially newer DDL).
getOptionalMetadata :: Int -> Get [(Word8, ByteString)]
getOptionalMetadata budget = do
    empty <- isEmpty
    if empty then pure [] else do
        when (budget <= 0) (fail "table map: optional metadata item budget exceeded")
        kind <- getWord8
        value <- getLenEncBytes
        ((kind,B.copy value):) <$> getOptionalMetadata (budget - 1)

data DeleteRowsEvent = DeleteRowsEvent
    { deleteTableId    :: !Word64
    , deleteFlags      :: !Word16
    -- , deleteExtraData   :: !RowsEventExtraData
    , deleteColumnCnt  :: !Int
    , deletePresentMap :: !BitMap
    , deleteRowData    :: ![[BinLogValue]]
    } deriving (Show, Eq, Generic)

-- | Decode delete images using the matching validated table map.
getDeleteRowEvent :: FormatDescription -> TableMapEvent -> BinLogEventType -> Get DeleteRowsEvent
getDeleteRowEvent fd tme typ = do
    let hlen = eventHeaderLen fd typ
        version2 = typ `elem` [BINLOG_WRITE_ROWS_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2]
    unless (if version2 then hlen == 10 else hlen == 6 || hlen == 8)
        (fail "rows: unsupported post-header length")
    tid <- if hlen == 6 then fromIntegral <$> getWord32le else getWord48le
    flgs <- getWord16le
    when (typ == BINLOG_DELETE_ROWS_EVENTv2) $ do
        extraLen <- getWord16le
        when (extraLen < 2) (fail "rows: invalid extra-header length")
        skip (fromIntegral extraLen - 2)
    unless (tid == tmTableId tme) (fail "rows: table ID does not match metadata")
    colCnt <- getLenEncInt
    -- Metadata cardinality was proved when the map was parsed and cached.
    -- Compare the stored count in O(1); rescanning the cached list here makes
    -- sparse events pay for every omitted column again.
    unless (colCnt > 0 && colCnt <= 4096 && colCnt == tmColumnCnt tme) (fail "rows: column count does not match metadata")
    let (plen, poffset) = (colCnt + 7) `quotRem` 8
    pmap <- getPresentMap plen poffset
    DeleteRowsEvent tid flgs colCnt pmap <$>
        getNonemptyRows length (getBinLogRow (tmColumnMeta tme) pmap)

data WriteRowsEvent = WriteRowsEvent
    { writeTableId    :: !Word64
    , writeFlags      :: !Word16
    -- , writeExtraData   :: !RowsEventExtraData
    , writeColumnCnt  :: !Int
    , writePresentMap :: !BitMap
    , writeRowData    :: ![[BinLogValue]]
    } deriving (Show, Eq, Generic)

-- | Decode insert images using the matching validated table map.
getWriteRowEvent :: FormatDescription -> TableMapEvent -> BinLogEventType -> Get WriteRowsEvent
getWriteRowEvent fd tme typ = do
    let hlen = eventHeaderLen fd typ
        version2 = typ `elem` [BINLOG_WRITE_ROWS_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2]
    unless (if version2 then hlen == 10 else hlen == 6 || hlen == 8)
        (fail "rows: unsupported post-header length")
    tid <- if hlen == 6 then fromIntegral <$> getWord32le else getWord48le
    flgs <- getWord16le
    when (typ == BINLOG_WRITE_ROWS_EVENTv2) $ do
        extraLen <- getWord16le
        when (extraLen < 2) (fail "rows: invalid extra-header length")
        skip (fromIntegral extraLen - 2)
    unless (tid == tmTableId tme) (fail "rows: table ID does not match metadata")
    colCnt <- getLenEncInt
    -- Metadata cardinality was proved when the map was parsed and cached.
    -- Compare the stored count in O(1); rescanning the cached list here makes
    -- sparse events pay for every omitted column again.
    unless (colCnt > 0 && colCnt <= 4096 && colCnt == tmColumnCnt tme) (fail "rows: column count does not match metadata")
    let (plen, poffset) = (colCnt + 7) `quotRem` 8
    pmap <- getPresentMap plen poffset
    WriteRowsEvent tid flgs colCnt pmap <$>
        getNonemptyRows length (getBinLogRow (tmColumnMeta tme) pmap)

data UpdateRowsEvent = UpdateRowsEvent
    { updateTableId    :: !Word64
    , updateFlags      :: !Word16
    -- , updateExtraData   :: !RowsEventExtraData
    , updateColumnCnt  :: !Int
    , updatePresentMap :: !(BitMap, BitMap)
    , updateRowData    :: ![ ([BinLogValue], [BinLogValue]) ]
    } deriving (Show, Eq, Generic)

-- | Decode both update images using the matching validated table map.
getUpdateRowEvent :: FormatDescription -> TableMapEvent -> BinLogEventType -> Get UpdateRowsEvent
getUpdateRowEvent fd tme typ = do
    let hlen = eventHeaderLen fd typ
        version2 = typ `elem` [BINLOG_WRITE_ROWS_EVENTv2,BINLOG_UPDATE_ROWS_EVENTv2,BINLOG_DELETE_ROWS_EVENTv2]
    unless (if version2 then hlen == 10 else hlen == 6 || hlen == 8)
        (fail "rows: unsupported post-header length")
    tid <- if hlen == 6 then fromIntegral <$> getWord32le else getWord48le
    flgs <- getWord16le
    when (typ == BINLOG_UPDATE_ROWS_EVENTv2) $ do
        extraLen <- getWord16le
        when (extraLen < 2) (fail "rows: invalid extra-header length")
        skip (fromIntegral extraLen - 2)
    unless (tid == tmTableId tme) (fail "rows: table ID does not match metadata")
    colCnt <- getLenEncInt
    -- Metadata cardinality was proved when the map was parsed and cached.
    -- Compare the stored count in O(1); rescanning the cached list here makes
    -- sparse events pay for every omitted column again.
    unless (colCnt > 0 && colCnt <= 4096 && colCnt == tmColumnCnt tme) (fail "rows: column count does not match metadata")
    let (plen, poffset) = (colCnt + 7) `quotRem` 8
    pmap <- getPresentMap plen poffset
    pmap' <- getPresentMap plen poffset
    UpdateRowsEvent tid flgs colCnt (pmap, pmap') <$>
        getNonemptyRows (\(before,after) -> length before + length after)
            ((,) <$> getBinLogRow (tmColumnMeta tme) pmap <*> getBinLogRow (tmColumnMeta tme) pmap')

rowBudget :: Int -> Int
rowBudget columns = min 65536 (1048576 `div` max 1 columns)

-- Each row event must contain at least one image; accepting an empty event
-- could expose a transaction checkpoint after silently losing its changes.
getNonemptyRows :: (a -> Int) -> Get a -> Get [a]
getNonemptyRows valueCount row = do
    empty <- isEmpty
    when empty (fail "rows: event contains no row images")
    first <- progressingRow row
    -- Every change uses the same event bitmaps. The first decoded image gives
    -- the exact value count, including NULLs, without another bitmap scan or
    -- any work for omitted columns. One change has at most 8192 values, below
    -- the global value budget; calculate the remaining allowance before a
    -- second change is decoded. Update before/after images both count.
    rest <- getRows (rowBudget (valueCount first) - 1) row
    pure (first : rest)

-- Empty images must still consume their null bitmap/values. A zero-progress
-- parser is rejected instead of looping forever on a corrupt present bitmap.
getRows :: Int -> Get a -> Get [a]
getRows budget row = do
    empty <- isEmpty
    if empty then pure [] else do
        when (budget <= 0) (fail "rows: decoded row/value budget exceeded")
        value <- progressingRow row
        (value :) <$> getRows (budget - 1) row

progressingRow :: Get a -> Get a
progressingRow row = do
    before <- bytesRead
    value <- row
    after <- bytesRead
    unless (after > before) (fail "rows: zero-length row image")
    pure value

getPresentMap :: Int -> Int -> Get BitMap
getPresentMap plen poffset = do
    pmap <- getByteString plen
    -- quotRem is applied to (columns + 7), so remainder 7 means an exact
    -- multiple of eight columns. Unused high bits must never count as columns.
    let bits = poffset + 1
        mask = if bits == 8 then 255 else (1 `shiftL` bits) - 1
    when (not (B.null pmap) && B.last pmap .&. complement mask /= 0)
        (fail "rows: nonzero padding in present bitmap")
    pure (BitMap pmap)
