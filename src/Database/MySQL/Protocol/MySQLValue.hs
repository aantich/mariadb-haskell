{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

{-|
Module      : Database.MySQL.Protocol.MySQLValue
Description : Text and binary protocol
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : PORTABLE

Core text and binary row decoder/encoder machinery.

-}

module Database.MySQL.Protocol.MySQLValue
  ( -- * MySQLValue decoder and encoder
    MySQLValue(..)
  , DateParts(..)
  , decodeColumnText
  , encodeCharsetText
  , validateValue
  , parameterTypeSignature
  , putParamMySQLType
  , getTextField
  , putTextField
  , getTextRow
  , prepareTextRow
  , prepareBinaryRow
  , prepareTextRowVector
  , prepareBinaryRowVector
  , getTextRowVector
  , getBinaryField
  , putBinaryField
  , getBinaryRow
  , getBinaryRowVector
  -- * Internal utilities
  , getBits
  , BitMap(..)
  , isColumnSet
  , isColumnNull
  , makeNullMap
  ) where

import qualified Blaze.Text                         as Textual
import Control.Exception (throw)
import           Control.Monad
import           Data.Binary.Put
import           Data.Binary.Parser
import           Data.Bits
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString                    as B
import qualified Data.ByteString.Builder            as BB
import           Data.ByteString.Builder.Scientific (FPFormat (..),
                                                     formatScientificBuilder)
import qualified Data.ByteString.Char8              as BC
import qualified Data.ByteString.Lazy               as L
import qualified Data.ByteString.Lex.Fractional     as LexFrac
import qualified Data.ByteString.Lex.Integral       as LexInt
import qualified Data.ByteString.Unsafe             as B
import           Data.Char (chr, ord)
import qualified Data.Text as Text
import           Data.Fixed                         (Pico)
import           Data.Int
import           Data.Scientific                    (Scientific, coefficient, base10Exponent, normalize)
import           Data.Text                          (Text)
import qualified Data.Text.Encoding                 as T
import           Data.Time.Calendar                 (Day, fromGregorianValid,
                                                     toGregorian)
import           Data.Time.Format                   (defaultTimeLocale,
                                                     formatTime)
import           Data.Time.LocalTime                (LocalTime (..),
                                                     TimeOfDay (..))
import           Data.Word
import           Database.MySQL.Protocol.ColumnDef
import           Database.MySQL.Protocol.Escape
import           Database.MySQL.Protocol.Packet
import           GHC.Generics                       (Generic)
import qualified Data.Vector                        as V

--------------------------------------------------------------------------------
-- | Unnormalized MariaDB year, month and day components. Zero and invalid
-- calendar combinations are preserved when the server's SQL mode permits them.
-- Binding checks component bounds without coercing them to a different date.
data DateParts = DateParts !Integer !Int !Int deriving (Show, Eq, Generic)

-- | Values shared by text and prepared-binary protocols. DATE and DATETIME are
-- calendar values; TIMESTAMP is converted by MariaDB through the session time
-- zone, so its returned 'LocalTime' describes that zone rather than UTC.
--
-- TIME can be a duration up to 838:59:59.999999. Its 'TimeOfDay' may therefore
-- have hours greater than 23. Built-in binding rejects sub-microsecond precision
-- rather than silently truncating it. Raw date constructors preserve values
-- that 'Day' cannot represent; ordinary valid values use the existing forms.
data MySQLValue
    = MySQLDecimal       !Scientific   -- ^ DECIMAL, NEWDECIMAL
    | MySQLInt8U         !Word8        -- ^ Unsigned TINY
    | MySQLInt8          !Int8         -- ^ TINY
    | MySQLInt16U        !Word16       -- ^ Unsigned SHORT
    | MySQLInt16         !Int16        -- ^ SHORT
    | MySQLInt32U        !Word32       -- ^ Unsigned LONG, INT24
    | MySQLInt32         !Int32        -- ^ LONG, INT24
    | MySQLInt64U        !Word64       -- ^ Unsigned LONGLONG
    | MySQLInt64         !Int64        -- ^ LONGLONG
    | MySQLFloat         !Float        -- ^ IEEE 754 single precision format
    | MySQLDouble        !Double       -- ^ IEEE 754 double precision format
    | MySQLYear          !Word16       -- ^ YEAR
    | MySQLDateTime      !LocalTime    -- ^ DATETIME
    | MySQLTimeStamp     !LocalTime    -- ^ TIMESTAMP
    | MySQLDate          !Day              -- ^ DATE
    | MySQLDateRaw       !DateParts -- ^ Zero, partial-zero or invalid calendar DATE.
    | MySQLDateTimeRaw   !DateParts !TimeOfDay -- ^ Unrepresentable DATETIME date part.
    | MySQLTimeStampRaw  !DateParts !TimeOfDay -- ^ Unrepresentable TIMESTAMP date part.
    | MySQLTime          !Word8 !TimeOfDay -- ^ sign(0 = non-negative, 1 = negative) hh mm ss microsecond
                                           -- The sign is OPPOSITE to binlog one !!!
    | MySQLGeometry      !ByteString       -- ^ todo: parsing to something meanful
    | MySQLBytes         !ByteString
    | MySQLBit           !Word64
    | MySQLText          !Text
    | MySQLNull
  deriving (Show, Eq, Generic)

-- | Put 'FieldType' and usigned bit(0x80/0x00) for 'MySQLValue's.
--
-- | The two-byte prepared parameter type: low byte is the wire type, high
-- byte carries unsignedness. Bulk validation compares this scalar without
-- allocating a temporary encoded ByteString for every cell.
parameterTypeSignature :: MySQLValue -> Word16
parameterTypeSignature value = case value of
    MySQLDecimal _ -> 0x00
    MySQLInt8U _ -> 0x8001
    MySQLInt8 _ -> 0x01
    MySQLInt16U _ -> 0x8002
    MySQLInt16 _ -> 0x02
    MySQLInt32U _ -> 0x8003
    MySQLInt32 _ -> 0x03
    MySQLInt64U _ -> 0x8008
    MySQLInt64 _ -> 0x08
    MySQLFloat _ -> 0x04
    MySQLDouble _ -> 0x05
    MySQLYear _ -> 0x8002
    MySQLDateTime _ -> 0x0c
    MySQLTimeStamp _ -> 0x07
    MySQLDate _ -> 0x0a
    MySQLTime _ _ -> 0x0b
    MySQLBytes _ -> 0xfc
    MySQLGeometry _ -> 0xff
    MySQLBit _ -> 0x8008
    MySQLText _ -> 0xfe
    MySQLDateRaw _ -> 0x0a
    MySQLDateTimeRaw _ _ -> 0x0c
    MySQLTimeStampRaw _ _ -> 0x07
    MySQLNull -> 0x06
{-# INLINE parameterTypeSignature #-}

-- | Encode exactly the same signature used to validate bulk column homogeneity.
putParamMySQLType :: MySQLValue -> Put
putParamMySQLType = putWord16le . parameterTypeSignature
{-# INLINE putParamMySQLType #-}

--------------------------------------------------------------------------------
-- | Text protocol decoder
getTextField :: ColumnDef -> Get MySQLValue
getTextField = getTextFieldGeneral
{-# NOINLINE getTextField #-}

-- Consume the nullable length marker once on the common paths, avoiding a
-- separate peek and repeated Get wrappers for every field of every row.
nullableTextField :: ColumnDef -> Get MySQLValue
nullableTextField field
    | typ == mySQLTypeLongLong = do
        tag <- getWord8
        if tag==0xfb then pure MySQLNull else do
            len <- getLenEncIntAfterTag tag
            when (len>128) (fail "numeric field exceeds representable width")
            bytes <- getByteString len
            if flagUnsigned (columnFlags field)
                then maybe (fail "invalid unsigned integer") (pure . MySQLInt64U) (boundedInteger 0 18446744073709551615 bytes)
                else maybe (fail "invalid signed integer") (pure . MySQLInt64) (boundedInteger (-9223372036854775808) 9223372036854775807 bytes)
    | typ == mySQLTypeVarString || typ == mySQLTypeVarChar || typ == mySQLTypeString = do
        tag <- getWord8
        if tag==0xfb then pure MySQLNull else do
            len <- getLenEncIntAfterTag tag
            bytes <- getByteString len
            pure (decodeString bytes)
    | otherwise = do
        tag <- peek
        if tag==0xfb then skipN 1 >> pure MySQLNull else getTextFieldGeneral field
  where
    typ=columnType field
    charset=columnCharSet field
    decodeString bytes
        | charset==63 = MySQLBytes bytes
        | charset>=192 && charset<=247 || charset==33 || charset==45 || charset==46 || charset==76 || charset==83 || charset>=2048 && charset<2560 = MySQLText (T.decodeUtf8 bytes)
        | otherwise = case parseOnly (decodeColumnText charset bytes) B.empty of
            Left message -> throw (DecodePacketFailed B.empty 0 message)
            Right value -> value
{-# INLINE nullableTextField #-}

stringField :: Word16 -> Get MySQLValue
stringField charset
    | charset == 63 = MySQLBytes <$> getLenEncBytes
    | charset>=192 && charset<=247 || charset==33 || charset==45 || charset==46 || charset==76 || charset==83 || charset>=2048 && charset<2560 = MySQLText . T.decodeUtf8 <$> getLenEncBytes
    | otherwise = getLenEncBytes >>= decodeColumnText charset
{-# INLINE stringField #-}

-- | Decode one non-NULL prepared field using its metadata. The enclosing row
-- parser consumes the NULL bitmap; standalone callers must do so themselves.
getBinaryField :: ColumnDef -> Get MySQLValue
getBinaryField field
    | columnType field == mySQLTypeLongLong = if flagUnsigned (columnFlags field) then MySQLInt64U <$> getWord64le else MySQLInt64 <$> getInt64le
    | columnType field == mySQLTypeVarString || columnType field == mySQLTypeVarChar || columnType field == mySQLTypeString = stringField (columnCharSet field)
    | otherwise = getBinaryFieldGeneral field
{-# INLINE getBinaryField #-}

getTextFieldGeneral :: ColumnDef -> Get MySQLValue
getTextFieldGeneral f
    | t == mySQLTypeNull            = pure MySQLNull
    | t == mySQLTypeDecimal
        || t == mySQLTypeNewDecimal = feedLenEncBytes t MySQLDecimal fracLexer
    | t == mySQLTypeTiny            = if isUnsigned then feedLenEncBytes t MySQLInt8U (boundedInteger 0 255)
                                                    else feedLenEncBytes t MySQLInt8 (boundedInteger (-128) 127)
    | t == mySQLTypeShort           = if isUnsigned then feedLenEncBytes t MySQLInt16U (boundedInteger 0 65535)
                                                    else feedLenEncBytes t MySQLInt16 (boundedInteger (-32768) 32767)
    | t == mySQLTypeLong
        || t == mySQLTypeInt24      = if isUnsigned then feedLenEncBytes t MySQLInt32U (boundedInteger 0 (if t == mySQLTypeInt24 then 16777215 else 4294967295))
                                                    else feedLenEncBytes t MySQLInt32 (boundedInteger (if t == mySQLTypeInt24 then -8388608 else -2147483648) (if t == mySQLTypeInt24 then 8388607 else 2147483647))
    | t == mySQLTypeLongLong        = if isUnsigned then feedLenEncBytes t MySQLInt64U (boundedInteger 0 18446744073709551615)
                                                    else feedLenEncBytes t MySQLInt64 (boundedInteger (-9223372036854775808) 9223372036854775807)
    | t == mySQLTypeFloat           = feedLenEncBytes t MySQLFloat fracLexer
    | t == mySQLTypeDouble          = feedLenEncBytes t MySQLDouble fracLexer
    | t == mySQLTypeYear            = feedLenEncBytes t MySQLYear (boundedInteger 0 65535)
    | t == mySQLTypeTimestamp || t == mySQLTypeTimestamp2 = feedLenEncBytes t id (parseDateTime MySQLTimeStamp MySQLTimeStampRaw)
    | t == mySQLTypeDateTime || t == mySQLTypeDateTime2 = feedLenEncBytes t id (parseDateTime MySQLDateTime MySQLDateTimeRaw)
    | t == mySQLTypeDate || t == mySQLTypeNewDate = feedLenEncBytes t id (fmap dateValue . parseDateParts)
    | t == mySQLTypeTime
        || t == mySQLTypeTime2      = feedLenEncBytes t id $ \ bs ->
                                          guard (not (B.null bs)) >>
                                          if B.index bs 0 == 45  -- '-'
                                               then MySQLTime 1 <$> timeParser (B.drop 1 bs)
                                               else MySQLTime 0 <$> timeParser bs

    | t == mySQLTypeGeometry        = MySQLGeometry <$> getLenEncBytes
    | t == mySQLTypeVarChar
        || t == mySQLTypeEnum
        || t == mySQLTypeSet
        || t == mySQLTypeTinyBlob
        || t == mySQLTypeMediumBlob
        || t == mySQLTypeLongBlob
        || t == mySQLTypeBlob
        || t == mySQLTypeVarString
        || t == mySQLTypeString     = getLenEncBytes >>= decodeColumnText (columnCharSet f)

    | t == mySQLTypeBit             = MySQLBit <$> (getBits =<< getLenEncInt)

    | otherwise                     = fail $ "Database.MySQL.Protocol.MySQLValue: missing text decoder for " ++ show t
  where
    t = columnType f
    isUnsigned = flagUnsigned (columnFlags f)
    fracLexer bs = do
        (x,rest) <- LexFrac.readSigned LexFrac.readDecimal bs
        guard (B.null rest)
        pure x
    timeParser = parseTime 838


feedLenEncBytes :: FieldType -> (t -> b) -> (ByteString -> Maybe t) -> Get b
feedLenEncBytes typ con parser = do
    len <- getLenEncInt
    when (len>128) (fail "scalar field exceeds representable width")
    bs <- getByteString len
    case parser bs of
        Just v -> return (con v)
        Nothing -> fail $ "Database.MySQL.Protocol.MySQLValue: parsing " ++ show typ ++ " failed, \
                          \input: " ++ BC.unpack bs
{-# INLINE feedLenEncBytes #-}

--------------------------------------------------------------------------------
-- | Text protocol encoder
putTextField :: MySQLValue -> Put
putTextField (MySQLDecimal    n) = putBuilder (formatScientificBuilder Fixed Nothing (normalize n))
putTextField (MySQLInt8U      n) = putBuilder (Textual.integral n)
putTextField (MySQLInt8       n) = putBuilder (Textual.integral n)
putTextField (MySQLInt16U     n) = putBuilder (Textual.integral n)
putTextField (MySQLInt16      n) = putBuilder (Textual.integral n)
putTextField (MySQLInt32U     n) = putBuilder (Textual.integral n)
putTextField (MySQLInt32      n) = putBuilder (Textual.integral n)
putTextField (MySQLInt64U     n) = putBuilder (Textual.integral n)
putTextField (MySQLInt64      n) = putBuilder (Textual.integral n)
putTextField (MySQLFloat      x) = putBuilder (Textual.float x)
putTextField (MySQLDouble     x) = putBuilder (Textual.double x)
putTextField (MySQLYear       n) = putBuilder (Textual.integral n)
putTextField (MySQLDateTime  dt) = putInQuotes $
                                      putByteString (BC.pack (formatTime defaultTimeLocale "%F %T%Q" dt))
putTextField (MySQLTimeStamp dt) = putInQuotes $
                                      putByteString (BC.pack (formatTime defaultTimeLocale "%F %T%Q" dt))
putTextField (MySQLDate       d) = putInQuotes $
                                      putByteString (BC.pack (formatTime defaultTimeLocale "%F" d))
putTextField (MySQLTime  sign t) = putInQuotes $ do
                                      when (sign == 1) (putCharUtf8 '-')
                                      putByteString (BC.pack (formatTime defaultTimeLocale "%T%Q" t))
                                      -- this works even for hour > 24
putTextField (MySQLGeometry  bs) = putInQuotes $ putByteString . escapeBytes $ bs
putTextField (MySQLBytes     bs) = putInQuotes $ putByteString . escapeBytes $ bs
putTextField (MySQLText       t) = putInQuotes $
                                      putByteString . T.encodeUtf8 . escapeText $ t
putTextField (MySQLBit        b) = do putBuilder "b\'"
                                      putBuilder . execPut $ putTextBits b
                                      putCharUtf8 '\''
  where
    putTextBits :: Word64 -> Put
    putTextBits word = forM_ [63,62..0] $ \ pos ->
            if word `testBit` pos then putCharUtf8 '1' else putCharUtf8 '0'
    {-# INLINE putTextBits #-}

putTextField (MySQLDateRaw d) = putInQuotes (putRawDate d)
putTextField (MySQLDateTimeRaw d t) = putInQuotes (putRawDate d >> putWord8 32 >> putByteString (BC.pack (formatTime defaultTimeLocale "%T%Q" t)))
putTextField (MySQLTimeStampRaw d t) = putTextField (MySQLDateTimeRaw d t)
putTextField MySQLNull           = putBuilder "NULL"

putInQuotes :: Put -> Put
putInQuotes p = putCharUtf8 '\'' >> p >> putCharUtf8 '\''
{-# INLINE putInQuotes #-}

--------------------------------------------------------------------------------
-- | Text row decoder
getTextRow :: [ColumnDef] -> Get [MySQLValue]
getTextRow fs = mapM nullableTextField fs
{-# INLINE getTextRow #-}

-- | Vector form of 'getTextRow', including each field's nullable length tag.
getTextRowVector :: V.Vector ColumnDef -> Get (V.Vector MySQLValue)
getTextRowVector fs = V.mapM nullableTextField fs
{-# INLINE getTextRowVector #-}

--------------------------------------------------------------------------------
-- | Binary protocol decoder
getBinaryFieldGeneral :: ColumnDef -> Get MySQLValue
getBinaryFieldGeneral f
    | t == mySQLTypeNull              = pure MySQLNull
    | t == mySQLTypeDecimal
        || t == mySQLTypeNewDecimal   = feedLenEncBytes t MySQLDecimal fracLexer
    | t == mySQLTypeTiny              = if isUnsigned then MySQLInt8U <$> getWord8
                                                      else MySQLInt8  <$> getInt8
    | t == mySQLTypeShort             = if isUnsigned then MySQLInt16U <$> getWord16le
                                                      else MySQLInt16  <$> getInt16le
    | t == mySQLTypeLong
        || t == mySQLTypeInt24        = if isUnsigned then MySQLInt32U <$> getWord32le
                                                      else MySQLInt32  <$> getInt32le
    | t == mySQLTypeYear              = MySQLYear <$> getWord16le
    | t == mySQLTypeLongLong          = if isUnsigned then MySQLInt64U <$> getWord64le
                                                      else MySQLInt64  <$> getInt64le
    | t == mySQLTypeFloat             = MySQLFloat  <$> getFloatle
    | t == mySQLTypeDouble            = MySQLDouble <$> getDoublele
    | t == mySQLTypeTimestamp || t == mySQLTypeTimestamp2 = binaryDateTime MySQLTimeStamp MySQLTimeStampRaw
    | t == mySQLTypeDateTime || t == mySQLTypeDateTime2 = binaryDateTime MySQLDateTime MySQLDateTimeRaw
    | t == mySQLTypeDate || t == mySQLTypeNewDate = do
        n <- getWord8
        case n of
            0 -> pure (MySQLDateRaw (DateParts 0 0 0))
            4 -> dateValue <$> binaryDateParts
            _ -> fail "invalid binary DATE length"
    | t == mySQLTypeTime
        || t == mySQLTypeTime2        = do
            n <- getLenEncInt
            case n of
               0 -> pure $ MySQLTime 0 (TimeOfDay 0 0 0)
               8 -> do
                   sign <- getWord8
                   unless (sign<=1) (fail "invalid TIME sign")
                   wireDays <- getWord32le
                   when (wireDays>34) (fail "invalid TIME days")
                   let d=fromIntegral wireDays
                   h <- getInt8'
                   minute <- getInt8'
                   seconds <- getSecond4
                   unless (h<24 && d*24+h<=838 && minute<60) (fail "invalid TIME duration")
                   pure (MySQLTime sign (TimeOfDay (d*24+h) minute seconds))

               12 -> do
                   sign <- getWord8
                   unless (sign<=1) (fail "invalid TIME sign")
                   wireDays <- getWord32le
                   when (wireDays>34) (fail "invalid TIME days")
                   let d=fromIntegral wireDays
                   h <- getInt8'
                   minute <- getInt8'
                   seconds <- getSecond8
                   unless (h<24 && d*24+h<=838 && minute<60) (fail "invalid TIME duration")
                   pure (MySQLTime sign (TimeOfDay (d*24+h) minute seconds))
               _ -> fail "Database.MySQL.Protocol.MySQLValue: wrong TIME length"

    | t == mySQLTypeGeometry          = MySQLGeometry <$> getLenEncBytes
    | t == mySQLTypeVarChar
        || t == mySQLTypeEnum
        || t == mySQLTypeSet
        || t == mySQLTypeTinyBlob
        || t == mySQLTypeMediumBlob
        || t == mySQLTypeLongBlob
        || t == mySQLTypeBlob
        || t == mySQLTypeVarString
        || t == mySQLTypeString       = getLenEncBytes >>= decodeColumnText (columnCharSet f)
    | t == mySQLTypeBit               = MySQLBit <$> (getBits =<< getLenEncInt)
    | otherwise                       = fail $ "Database.MySQL.Protocol.MySQLValue:\
                                               \ missing binary decoder for " ++ show t
  where
    t = columnType f
    isUnsigned = flagUnsigned (columnFlags f)
    fracLexer bs = do
        (x,rest) <- LexFrac.readSigned LexFrac.readDecimal bs
        guard (B.null rest)
        pure x
    getInt8' :: Get Int
    getInt8' = fromIntegral <$> getWord8
    getSecond4 :: Get Pico
    getSecond4 = do
        value <- getWord8
        if value<60 then pure (fromIntegral value) else fail "invalid seconds"
    getSecond8 :: Get Pico
    getSecond8 =  do
        s <- getInt8'
        -- Validate on the wire's unsigned type. Converting Word32 to Int first
        -- can turn a large malformed value negative on a 32-bit host, letting
        -- it pass the upper-bound check and produce negative fractional time.
        ms <- getWord32le
        unless (s<60 && ms<1000000) (fail "invalid fractional seconds")
        pure $! (realToFrac s + realToFrac ms / 1000000 :: Pico)


-- | Get a bit sequence as a Word64
--
-- Since 'Word64' has a @Bits@ instance, it's easier to deal with in haskell.
--
getBits :: Int -> Get Word64
getBits bytes =
    if  | bytes == 1 -> fromIntegral <$> getWord8
        | bytes == 2 -> fromIntegral <$> getWord16be
        | bytes == 3 -> fromIntegral <$> getWord24be
        | bytes == 4 -> fromIntegral <$> getWord32be
        | bytes == 5 -> getWord40be
        | bytes == 6 -> getWord48be
        | bytes == 7 -> getWord56be
        | bytes == 8 -> getWord64be
        | otherwise  -> fail $  "Database.MySQL.Protocol.MySQLValue: \
                                \wrong bit length size: " ++ show bytes
{-# INLINE getBits #-}


--------------------------------------------------------------------------------
-- | Binary protocol encoder
putBinaryField :: MySQLValue -> Put
putBinaryField (MySQLDecimal    n) = putLenEncBytes . L.toStrict . BB.toLazyByteString $
                                        formatScientificBuilder Fixed Nothing (normalize n)
putBinaryField (MySQLInt8U      n) = putWord8 n
putBinaryField (MySQLInt8       n) = putWord8 (fromIntegral n)
putBinaryField (MySQLInt16U     n) = putWord16le n
putBinaryField (MySQLInt16      n) = putInt16le n
putBinaryField (MySQLInt32U     n) = putWord32le n
putBinaryField (MySQLInt32      n) = putInt32le n
putBinaryField (MySQLInt64U     n) = putWord64le n
putBinaryField (MySQLInt64      n) = putInt64le n
putBinaryField (MySQLFloat      x) = putFloatle x
putBinaryField (MySQLDouble     x) = putDoublele x
putBinaryField (MySQLYear       n) = putWord16le n
putBinaryField (MySQLTimeStamp (LocalTime date time)) = do putWord8 11    -- always put full
                                                           putBinaryDay date
                                                           putBinaryTime' time
putBinaryField (MySQLDateTime  (LocalTime date time)) = do putWord8 11    -- always put full
                                                           putBinaryDay date
                                                           putBinaryTime' time
putBinaryField (MySQLDate    d)    = do putWord8 4
                                        putBinaryDay d
putBinaryField (MySQLTime sign t)  = do putWord8 12    -- always put full
                                        putWord8 sign
                                        putBinaryTime t
putBinaryField (MySQLGeometry bs)  = putLenEncBytes bs
putBinaryField (MySQLBytes  bs)    = putLenEncBytes bs
putBinaryField (MySQLBit    word)  = putWord64le word
putBinaryField (MySQLText    t)    = putLenEncBytes (T.encodeUtf8 t)
putBinaryField (MySQLDateRaw d) = putWord8 4 >> putBinaryDateParts d
putBinaryField (MySQLDateTimeRaw d t) = putWord8 11 >> putBinaryDateParts d >> putBinaryTime' t
putBinaryField (MySQLTimeStampRaw d t) = putBinaryField (MySQLDateTimeRaw d t)
putBinaryField MySQLNull           = return ()

putBinaryDay :: Day -> Put
putBinaryDay d = do let (yyyy, mm, dd) = toGregorian d
                    putWord16le (fromIntegral yyyy)
                    putWord8 (fromIntegral mm)
                    putWord8 (fromIntegral dd)
{-# INLINE putBinaryDay #-}

putBinaryTime' :: TimeOfDay -> Put
putBinaryTime' (TimeOfDay hh mm ss) = do let s = floor ss
                                             ms = floor $ (ss - realToFrac s) * 1000000
                                         putWord8 (fromIntegral hh)
                                         putWord8 (fromIntegral mm)
                                         putWord8 s
                                         putWord32le ms
{-# INLINE putBinaryTime' #-}

putBinaryTime :: TimeOfDay -> Put
putBinaryTime (TimeOfDay hh mm ss) = do let s = floor ss
                                            ms = floor $ (ss - realToFrac s) * 1000000
                                            (d, h) = hh `quotRem` 24  -- hour may exceed 24 here
                                        putWord32le (fromIntegral d)
                                        putWord8 (fromIntegral h)
                                        putWord8 (fromIntegral mm)
                                        putWord8 s
                                        putWord32le ms
{-# INLINE putBinaryTime #-}

--------------------------------------------------------------------------------
-- | Binary row decoder
--
-- MySQL use a special null bitmap without offset = 2 here.
--
getBinaryRow :: [ColumnDef] -> Int -> Get [MySQLValue]
getBinaryRow fields flen = do
    skipN 1           -- 0x00
    let maplen = (flen + 7 + 2) `shiftR` 3
    nullmap <- BitMap <$> getByteString maplen
    go fields nullmap 0
  where
    go :: [ColumnDef] -> BitMap -> Int -> Get [MySQLValue]
    go []     _       _   = pure []
    go (f:fs) nullmap pos = do
        r <- if isColumnNull nullmap pos
                then return MySQLNull
                else getBinaryField f
        let pos' = pos + 1
        rest <- pos' `seq` go fs nullmap pos'
        return (r `seq` (r : rest))
{-# INLINE getBinaryRow #-}

-- | Vector form of 'getBinaryRow'. The count must equal the metadata length;
-- the enclosing packet phase must already establish the binary row marker.
getBinaryRowVector :: V.Vector ColumnDef -> Int -> Get (V.Vector MySQLValue)
getBinaryRowVector fields flen = do
    skipN 1           -- 0x00
    let maplen = (flen + 7 + 2) `shiftR` 3
    nullmap <- BitMap <$> getByteString maplen
    (`V.imapM` fields) $ \ pos f ->
        if isColumnNull nullmap pos then return MySQLNull else getBinaryField f
{-# INLINE getBinaryRowVector #-}

--------------------------------------------------------------------------------
-- | Use 'ByteString' to present a bitmap.
--
-- When used for represent bits values, the underlining 'ByteString' follows:
--
--  * byteString: head       -> tail
--  * bit:        high bit   -> low bit
--
-- When used as a null-map/present-map, every bit inside a byte
-- is mapped to a column, the mapping order is following:
--
--  * byteString: head -> tail
--  * column:     left -> right
--
-- We don't use 'Int64' here because there maybe more than 64 columns.
--
newtype BitMap = BitMap { fromBitMap :: ByteString } deriving (Eq, Show)

-- | Test if a column is set(binlog protocol).
--
-- The number counts from left to right.
--
isColumnSet :: BitMap -> Int -> Bool
isColumnSet (BitMap bitmap) pos =
  let i = pos `unsafeShiftR` 3
      j = pos .&. 7
  in (bitmap `B.unsafeIndex` i) `testBit` j
{-# INLINE isColumnSet #-}

-- | Test if a column is null(binary protocol).
--
-- The number counts from left to right.
--
isColumnNull :: BitMap -> Int -> Bool
isColumnNull (BitMap nullmap) pos =
  let
    pos' = pos + 2
    i    = pos' `unsafeShiftR` 3
    j    = pos' .&. 7
  in (nullmap `B.unsafeIndex` i) `testBit` j
{-# INLINE isColumnNull #-}

-- | Make a nullmap for params(binary protocol) without offset.
--
makeNullMap :: [MySQLValue] -> BitMap
makeNullMap values = BitMap . B.pack $ go values 0x00 0
  where
    go :: [MySQLValue] -> Word8 -> Int -> [Word8]
    go []             byte   8  = [byte]
    go vs             byte   8  = byte : go vs 0x00 0
    go []             byte   _  = [byte]
    go (MySQLNull:vs) byte pos  = let pos' = pos + 1
                                      byte' = byte .|. bit pos
                                  in pos' `seq` byte' `seq` go vs byte' pos'
    go (_        :vs) byte pos  = let pos' = pos + 1 in pos' `seq` go vs byte pos'

--------------------------------------------------------------------------------
-- TODO: add helpers to parse mySQLTypeGEOMETRY
-- reference: https://github.com/felixge/node-mysql/blob/master/lib/protocol/Parser.js

-- Reject overflow before multiplying the Word64 accumulator. A negative Int64
-- minimum needs magnitude 2^63, which fits Word64 even though it cannot fit an
-- Int64 intermediate. The bounds at each call site also cover MEDIUMINT widths.
boundedInteger :: Integral a => Integer -> Integer -> ByteString -> Maybe a
boundedInteger low high bs = do
    guard (not (B.null bs))
    let negative = B.head bs == 45
        positive = B.head bs == 43
        digits = if negative || positive then B.tail bs else bs
        bound = fromInteger (if negative then negate low else high) :: Word64
    guard (not (B.null digits) && (not negative || low < 0))
    let quotient = bound `quot` 10
        remainder = bound `rem` 10
        loop !index !acc
            | index == B.length digits = Just (if negative then negate (fromIntegral acc) else fromIntegral acc)
            | otherwise =
                let w=B.unsafeIndex digits index
                    digit=fromIntegral (w-48)
                in if w<48 || w>57 || acc>quotient || (acc==quotient && digit>remainder)
                   then Nothing else loop (index+1) (acc*10+digit)
    loop 0 (0::Word64)
{-# INLINE boundedInteger #-}

parseDateParts :: ByteString -> Maybe DateParts
parseDateParts bs = do
    guard (B.length bs == 10 && B.index bs 4 == 45 && B.index bs 7 == 45)
    guard (B.all (\w -> w>=48 && w<=57 || w==45) bs)
    y <- boundedInteger 0 9999 (B.take 4 bs)
    m <- boundedInteger 0 12 (B.take 2 (B.drop 5 bs))
    d <- boundedInteger 0 31 (B.drop 8 bs)
    pure (DateParts y m d)

dateValue :: DateParts -> MySQLValue
dateValue d@(DateParts y m day) = maybe (MySQLDateRaw d) MySQLDate (fromGregorianValid y m day)

parseTime :: Int -> ByteString -> Maybe TimeOfDay
parseTime maxHour bs = do
    (h,rest) <- LexInt.readDecimal bs
    let hoursLength=B.length bs-B.length rest
        secondsBytes=B.drop 4 rest
        (secondsInteger,fraction)=B.break (==46) secondsBytes
        digitsOnly=B.all (\w -> w>=48 && w<=57)
    guard (hoursLength>=2 && hoursLength<=(if maxHour<24 then 2 else 3) && h <= maxHour && B.length rest >= 6 && B.head rest == 58 && B.index rest 3 == 58)
    guard (B.length secondsInteger==2 && digitsOnly secondsInteger && (B.null fraction || B.length fraction>=2 && B.length fraction<=7 && digitsOnly (B.tail fraction)))
    m <- boundedInteger 0 59 (B.take 2 (B.drop 1 rest))
    (sec,tailBytes) <- LexFrac.readDecimal (B.drop 4 rest)
    guard (B.null tailBytes && sec >= 0 && sec < 60)
    pure (TimeOfDay h m sec)

parseDateTime :: (LocalTime -> MySQLValue) -> (DateParts -> TimeOfDay -> MySQLValue) -> ByteString -> Maybe MySQLValue
parseDateTime valid raw bs = do
    guard (B.length bs >= 19 && B.index bs 10 == 32)
    d@(DateParts y m day) <- parseDateParts (B.take 10 bs)
    t <- parseTime 23 (B.drop 11 bs)
    pure (maybe (raw d t) (valid . (`LocalTime` t)) (fromGregorianValid y m day))

binaryDateParts :: Get DateParts
binaryDateParts = do
    y <- fromIntegral <$> getWord16le
    m <- fromIntegral <$> getWord8
    d <- fromIntegral <$> getWord8
    unless (y <= 9999 && m <= 12 && d <= 31) (fail "invalid binary date components")
    pure (DateParts y m d)

binaryDateTime :: (LocalTime -> MySQLValue) -> (DateParts -> TimeOfDay -> MySQLValue) -> Get MySQLValue
binaryDateTime valid raw = do
    n <- getWord8
    unless (n `elem` [0,4,7,11]) (fail "invalid binary datetime length")
    d@(DateParts y m day) <- if n == 0 then pure (DateParts 0 0 0) else binaryDateParts
    t <- if n < 7 then pure (TimeOfDay 0 0 0) else do
        h <- fromIntegral <$> getWord8
        minute <- fromIntegral <$> getWord8
        sec <- fromIntegral <$> getWord8
        micro <- if n == 11 then getWord32le else pure 0
        unless (h < 24 && minute < 60 && sec < 60 && micro < 1000000) (fail "invalid binary clock")
        pure (TimeOfDay h minute (sec + fromIntegral micro / 1000000))
    pure (maybe (raw d t) (valid . (`LocalTime` t)) (fromGregorianValid y m day))

putBinaryDateParts :: DateParts -> Put
putBinaryDateParts (DateParts y m d) = putWord16le (fromIntegral y) >> putWord8 (fromIntegral m) >> putWord8 (fromIntegral d)

putRawDate :: DateParts -> Put
putRawDate (DateParts y m d) = putByteString (BC.pack (pad 4 y ++ "-" ++ pad 2 (fromIntegral m) ++ "-" ++ pad 2 (fromIntegral d)))
  where
    pad :: Int -> Integer -> String
    pad width x = let v = show x in replicate (max 0 (width-length v)) '0' ++ v

-- MariaDB latin1 uses the server's cp1252 mapping, including undefined controls.
cp1252 :: Word8 -> Char
cp1252 w | w >= 128 && w <= 159 = chr (cp1252High !! (fromIntegral w-128))
          | otherwise = chr (fromIntegral w)

cp1252High :: [Int]
cp1252High = [0x20ac,0x81,0x201a,0x192,0x201e,0x2026,0x2020,0x2021,0x2c6,0x2030,0x160,0x2039,0x152,0x8d,0x17d,0x8f,0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x2dc,0x2122,0x161,0x203a,0x153,0x9d,0x17e,0x178]

-- | Decode by the column's collation ID, not by the connection default. UTF-8
-- is strict; MariaDB latin1 uses cp1252. Binary and unmapped encodings return
-- exact bytes so unsupported text cannot be silently replaced or mistranslated.
-- The high ID range covers MariaDB's UCA-1400 UTF-8 collations.
decodeColumnText :: Word16 -> ByteString -> Get MySQLValue
decodeColumnText col bytes
    | col == 63 = pure (MySQLBytes bytes)
    | col `elem` [5,8,15,31,47,48,49,94] = pure (MySQLText (Text.pack (map cp1252 (B.unpack bytes))))
    | col `elem` [11,65] = if B.all (<128) bytes then pure (MySQLText (T.decodeUtf8 bytes)) else fail "non-ASCII data in ASCII column"
    | col `elem` [33,45,46,76,83] || (col >= 192 && col <= 247) || (col >= 256 && col <= 323) || (col >= 2048 && col < 2560) =
        pure $! MySQLText (T.decodeUtf8 bytes)
    | otherwise = pure (MySQLBytes bytes)
{-# INLINE decodeColumnText #-}

-- | Encode a parameter in the verified client charset. Fail on unrepresentable
-- characters, including supplementary Unicode under utf8mb3; never substitute.
encodeCharsetText :: ByteString -> Text -> Either String ByteString
encodeCharsetText charset value
    | charset `elem` ["utf8mb4","utf8mb3","utf8"] =
        if charset /= "utf8mb4" && Text.any ((>65535) . ord) value then Left "character outside utf8mb3" else Right (T.encodeUtf8 value)
    | charset == "ascii" = if Text.all ((<128) . ord) value then Right (B.pack (map (fromIntegral . ord) (Text.unpack value))) else Left "character outside ASCII"
    | charset == "latin1" = B.pack <$> traverse encode (Text.unpack value)
    | otherwise = Left "unsupported client character set"
  where
    encode ch | fromEnum ch<128 || fromEnum ch>=160 && fromEnum ch<=255 = Right (fromIntegral (fromEnum ch))
    encode ch = case [fromIntegral n | n <- [128..159::Int], cp1252 (fromIntegral n) == ch] of
        x:_ -> Right x
        [] -> Left "character outside MariaDB latin1"

-- | Build field dispatch once per result and share it across rows. Metadata is
-- not cached across executions, where DDL/reprepare may have changed its shape.
prepareTextRow :: [ColumnDef] -> Get [MySQLValue]
prepareTextRow fields = sequencePrepared (map nullableTextField fields)
{-# NOINLINE prepareTextRow #-}

sequencePrepared :: [Get a] -> Get [a]
sequencePrepared = foldr (\parser rest -> parser `seq` rest `seq` ((:) <$> parser <*> rest)) (pure [])

-- | Vector counterpart of 'prepareTextRow'.
prepareTextRowVector :: V.Vector ColumnDef -> Get (V.Vector MySQLValue)
prepareTextRowVector fields = V.sequence (V.map nullableTextField fields)
{-# NOINLINE prepareTextRowVector #-}

-- | Share binary field parsers per result. The row's NULL bitmap starts at bit
-- two; an all-zero bitmap can use a prebuilt non-null sequence. Force dispatch
-- here, then force decoded values at the guarded I/O boundary in Base. Adding
-- per-field wrappers/forcing to the hot loop increased allocation in profiling.
prepareBinaryRow :: [ColumnDef] -> Get [MySQLValue]
prepareBinaryRow fields =
    let parsers=map getBinaryField fields
        !count=length fields
        nonNull=sequencePrepared parsers
        force []=()
        force (p:ps)=p `seq` force ps
    in force parsers `seq` nonNull `seq` do
        marker <- getWord8
        unless (marker==0) (fail "invalid binary row marker")
        nullBytes <- getByteString ((count+9) `shiftR` 3)
        let bitmap=BitMap nullBytes
        let go [] _=pure []
            go (p:ps) !position = do
                value <- if isColumnNull bitmap position then pure MySQLNull else p
                (value:) <$> go ps (position+1)
        if B.all (==0) nullBytes then nonNull else go parsers 0
{-# NOINLINE prepareBinaryRow #-}

-- | Vector counterpart of 'prepareBinaryRow', with the same two-bit NULL offset.
prepareBinaryRowVector :: V.Vector ColumnDef -> Get (V.Vector MySQLValue)
prepareBinaryRowVector fields =
    let parsers=V.map getBinaryField fields
        !count=V.length fields
    in V.foldl' (\() parser -> parser `seq` ()) () parsers `seq` do
        marker <- getWord8
        unless (marker==0) (fail "invalid binary row marker")
        bitmap <- BitMap <$> getByteString ((count+9) `shiftR` 3)
        V.imapM (\position parser -> if isColumnNull bitmap position then pure MySQLNull else parser) parsers
{-# NOINLINE prepareBinaryRowVector #-}

-- | Reject lossy/invalid built-in parameters before a command starts writing.
-- Raw dates need valid component ranges, not a valid Gregorian calendar date.
-- This validates wire representability; the server still enforces column type,
-- SQL mode and constraints. Low-level Put encoders assume this check was done.
validateValue :: MySQLValue -> Either String ()
validateValue value = case value of
    MySQLDate day -> calendar day
    MySQLDateTime (LocalTime day time) -> calendar day >> clock 23 time
    MySQLTimeStamp (LocalTime day time) -> calendar day >> clock 23 time
    MySQLDateRaw parts -> date parts
    MySQLDateTimeRaw parts time -> date parts >> clock 23 time
    MySQLTimeStampRaw parts time -> date parts >> clock 23 time
    MySQLTime sign time -> check (sign<=1) "invalid TIME sign" >> clock 838 time
    MySQLFloat x -> check (not (isNaN x || isInfinite x)) "non-finite FLOAT"
    MySQLDouble x -> check (not (isNaN x || isInfinite x)) "non-finite DOUBLE"
    MySQLDecimal x ->
        let n = normalize x
            c = abs (coefficient n)
            decimalExponent = base10Exponent n
        in check (c < 10^(65::Int) && decimalExponent >= (-38) && decimalExponent <= 65
                  && length (show c) + max 0 decimalExponent <= 65)
                 "DECIMAL exceeds MariaDB precision/scale"
    _ -> Right ()
  where
    check True _=Right ()
    check False message=Left message
    date (DateParts y m d)=check (y>=0 && y<=9999 && m>=0 && m<=12 && d>=0 && d<=31) "date component outside MariaDB range"
    calendar day=let (y,m,d)=toGregorian day in date (DateParts y m d)
    clock maximumHour (TimeOfDay h m sec)=check (h>=0 && h<=maximumHour && m>=0 && m<60 && sec>=0 && sec<60 && sec*1000000==fromInteger (floor (sec*1000000))) "invalid clock/duration or sub-microsecond precision"
