{-|
Module      : Database.MySQL.BinLogProtocol.BinLogValue
Description : Binlog protocol
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : Anton Antich <anton.antich@gmail.com>
Stability   : experimental
Portability : PORTABLE

Binlog protocol

-}

module Database.MySQL.BinLogProtocol.BinLogValue
    ( BinLogValue(..), getBinLogField, getMicroSecond, getBits', getBinLogRow
    ) where

import           Control.Monad                            (unless)
import           Data.Binary.Get
import           Data.Binary.Put                          ()
import           Data.Bits
import           Data.ByteString                          (ByteString)
import qualified Data.ByteString                          as B
import qualified Data.ByteString.Unsafe                   as B
import           Data.Int
import           Data.Int.Int24
import           Data.Scientific
import           Data.Word
import           Database.MySQL.BinLogProtocol.BinLogMeta
import           Database.MySQL.Protocol.MySQLValue
import           Database.MySQL.Protocol.Packet
import           GHC.Generics                             (Generic)

-- | Data type for representing binlog values.
--
-- Values preserve storage-level numeric and temporal representations. Text and
-- binary columns both use bytes: decoding a character set requires the relevant
-- table metadata, which can differ from the connection's current character set.
--
-- Base column types do not encode signedness. Optional table-map metadata can
-- supply it, but this value decoder leaves integral bits in their inherited
-- signed-width constructors. For an unsigned TINYINT, for example,
-- @fromIntegral (-1 :: Int8) :: Word8@ recovers 255; use the matching width.
-- INT24 similarly converts through the package's Word24 type.
--
-- Timestamps represent server UTC fields; zero retains MariaDB's zero timestamp
-- rather than becoming the Unix epoch. ENUM is its stored index and SET its
-- stored bitmap. Their labels and text collations belong to table metadata.
--
data BinLogValue
    = BinLogTiny       !Int8
    | BinLogShort      !Int16
    | BinLogInt24      !Int24
    | BinLogLong       !Int32
    | BinLogLongLong   !Int64
    | BinLogFloat      !Float
    | BinLogDouble     !Double
    | BinLogBit        !Word64          -- ^ a 64bit bitmap.
    | BinLogTimeStamp  !Word32          -- ^ a utc timestamp, note 0 doesn't mean @1970-01-01 00:00:00@,
                                        -- because mysql choose 0 to present '0000-00-00 00:00:00'
    | BinLogTimeStamp2 !Word32 !Word32  -- ^ like 'BinLogTimeStamp' with an addtional microseconds field.
    | BinLogDateTime   !Word16 !Word8 !Word8 !Word8 !Word8 !Word8         -- ^ YYYY MM DD hh mm ss
    | BinLogDateTime2  !Word16 !Word8 !Word8 !Word8 !Word8 !Word8 !Word32 -- ^ YYYY MM DD hh mm ss microsecond
    | BinLogDate       !Word16 !Word8 !Word8                   -- ^ YYYY MM DD
    | BinLogTime       !Word8  !Word16 !Word8 !Word8           -- ^ sign(1= non-negative, 0= negative) hh mm ss
    | BinLogTime2      !Word8  !Word16 !Word8 !Word8 !Word32   -- ^ sign(1= non-negative, 0= negative) hh mm ss microsecond
    | BinLogYear       !Word16                                 -- ^ year value, 0 stand for '0000'
    | BinLogNewDecimal !Scientific                             -- ^ sign(1= non-negative, 0= negative) integeral part, fractional part
    | BinLogEnum       !Word16                                 -- ^ enum indexing value
    | BinLogSet        !Word64                                 -- ^ set indexing 64bit bitmap.
    | BinLogBytes      !ByteString                             -- ^ all string and blob values.
    | BinLogGeometry   !ByteString
    | BinLogNull
  deriving (Show, Eq, Generic)

--------------------------------------------------------------------------------
-- | BinLog protocol decoder
--
getBinLogField :: BinLogMeta -> Get BinLogValue
getBinLogField BINLOG_TYPE_TINY                = BinLogTiny     <$> getInt8
getBinLogField BINLOG_TYPE_SHORT               = BinLogShort    <$> getInt16le
getBinLogField BINLOG_TYPE_INT24               = BinLogInt24 . fromIntegral <$> getWord24le
getBinLogField BINLOG_TYPE_LONG                = BinLogLong     <$> getInt32le
getBinLogField BINLOG_TYPE_LONGLONG            = BinLogLongLong <$> getInt64le
getBinLogField (BINLOG_TYPE_FLOAT  _         ) = BinLogFloat <$> getFloatle
getBinLogField (BINLOG_TYPE_DOUBLE _         ) = BinLogDouble <$> getDoublele
getBinLogField (BINLOG_TYPE_BIT    _    bytes) = BinLogBit <$> getBits' bytes
getBinLogField BINLOG_TYPE_TIMESTAMP           = BinLogTimeStamp <$> getWord32le

-- A integer in @YYYYMMDD@ format, for example:
-- 99991231 stand for @9999-12-31@
getBinLogField BINLOG_TYPE_DATE = do
    i <- getWord24le
    let (i', dd) = i `quotRem` 32
        (yyyy, mm) = i' `quotRem` 16
    pure (BinLogDate (fromIntegral yyyy)
                     (fromIntegral mm)
                     (fromIntegral dd))

getBinLogField (BINLOG_TYPE_TIMESTAMP2  fsp) = do
    s <- getWord32be -- big-endian here!
    ms <- getMicroSecond fsp >>= checkedFraction fsp
    pure (BinLogTimeStamp2 s ms)

-- A integer in @YYYYMMDDhhmmss@, for example:
-- 99991231235959 stand for @9999-12-31 23:59:59@
getBinLogField BINLOG_TYPE_DATETIME = do
    i <- getWord64le
    let (yyyy, i')   = i      `quotRem` 10000000000
        (mm, i'')    = i'     `quotRem` 100000000
        (dd, i''')   = i''    `quotRem` 1000000
        (h, i'''')   = i'''   `quotRem` 10000
        (m, s)       = i''''  `quotRem` 100
    pure (BinLogDateTime (fromIntegral yyyy)
                         (fromIntegral mm)
                         (fromIntegral dd)
                         (fromIntegral h)
                         (fromIntegral m)
                         (fromIntegral s))

-- BINLOG_TYPE_DATETIME2(big endian)
--
-- 1 bit sign (used when on disk)
-- 17 bits year * 13 + month (year 0-9999, month 0-12)
-- 5 bits day (0-31)
-- 5 bits hour (0-23)
-- 6 bits minute (0-59)
-- 6 bits second (0-59)
-- (5 bytes in total)
--
-- fractional-seconds storage (size depends on meta)
--
getBinLogField (BINLOG_TYPE_DATETIME2 fsp) = do
    iPart <- getWord40be
    let yyyymm = iPart `shiftR` 22 .&. 0x01FFFF -- 0b011111111111111111
        (yyyy, mm) = yyyymm `quotRem` 13
        yyyy' = fromIntegral yyyy
        mm' = fromIntegral mm
        dd = fromIntegral $ iPart `shiftR` 17 .&. 0x1F -- 0b00011111
        h =  fromIntegral $ iPart `shiftR` 12 .&. 0x1F -- 0b00011111
        m =  fromIntegral $ iPart `shiftR` 6 .&. 0x3F  -- 0b00111111
        s =  fromIntegral $ iPart .&. 0x3F             -- 0b00111111
    ms <- getMicroSecond fsp >>= checkedFraction fsp
    pure (BinLogDateTime2 yyyy' mm' dd h m s ms)

-- A integer in @hhmmss@ format(can be negative), for example:
-- 8385959 stand for @838:59:59@
getBinLogField BINLOG_TYPE_TIME = do
    i <- getWord24le
    let i' =  fromIntegral i :: Int24
        sign = if i' >= 0 then 1 else 0
    let (h, i'')     = i'     `quotRem` 10000
        (m, s)       = i''    `quotRem` 100
    pure (BinLogTime sign (fromIntegral (abs h))
                          (fromIntegral (abs m))
                          (fromIntegral (abs s)))

-- BINLOG_TYPE_TIME2(big endian)
--
-- 1 bit sign  (1= non-negative, 0= negative)
-- 1 bit unused (Reserved for wider hour range, e.g. for intervals)
-- 10 bit hour (0-838)
-- 6 bit minute (0-59)
-- 6 bit second (0-59)
-- (3 bytes in total)
--
-- fractional-seconds storage (size depends on meta)
--
getBinLogField (BINLOG_TYPE_TIME2 fsp) = do
    raw <- getWord24be
    fraction <- getMicroSecond fsp
    let integerPart = fromIntegral raw - 0x800000 :: Int64
        negative = integerPart < 0
        -- Binary ordering borrows one integer unit only when a negative time
        -- has a nonzero fractional part (MariaDB sql/compat56.cc). Whole
        -- negative seconds must not lose another second during decoding.
        magnitude = abs (if negative && fraction /= 0 then integerPart + 1 else integerPart)
        hours = fromIntegral (magnitude `shiftR` 12) .&. 0x03ff
        minutes = fromIntegral (magnitude `shiftR` 6) .&. 0x3f
        seconds = fromIntegral magnitude .&. 0x3f
    unless (if negative then fraction <= 0 else fraction >= 0)
        (fail "TIME2: inconsistent fractional sign")
    micros <- checkedFraction fsp (abs fraction)
    pure (BinLogTime2 (if negative then 0 else 1) hours minutes seconds micros)

getBinLogField BINLOG_TYPE_YEAR                = do
    y <- getWord8
    pure $! if y == 0 then BinLogYear 0 else BinLogYear (1900 + fromIntegral y)

-- Decimal representation in binlog seems to be as follows:
--
-- 1st bit - sign such that set == +, unset == -
-- every 4 bytes represent 9 digits in big-endian order.
--
-- 80 00 00 05 1b 38 b0 60 00 means:
--
--   0x80 - positive
--   0x00000005 - 5
--   0x1b38b060 - 456700000
--   0x00       - 0
--
-- 54567000000 / 10^{10} = 5.4567
--
-- if there're < 9 digits at first, it will be compressed into suitable length words
-- following a simple lookup table.
--
getBinLogField (BINLOG_TYPE_NEWDECIMAL precision scale)
    | precision == 0 || precision > 65 || scale > 38 || precision < scale = fail "NEWDECIMAL: invalid precision/scale"
    | otherwise = do
    let i = (precision - scale)
        (ucI, cI) = i `quotRem` digitsPerInteger
        (ucF, cF) = scale `quotRem` digitsPerInteger
        ucISize = fromIntegral (ucI `shiftL` 2)
        ucFSize = fromIntegral (ucF `shiftL` 2)
        cISize = fromIntegral (sizeTable `B.unsafeIndex` fromIntegral cI)
        cFSize = fromIntegral (sizeTable `B.unsafeIndex` fromIntegral cF)
        len = ucISize + cISize + ucFSize + cFSize

    buf <- getByteString len

    let fb = buf `B.unsafeIndex` 0
        sign = if fb .&. 0x80 == 0x80 then 1 else 0 :: Word8
        buf' = (fb `xor` 0x80) `B.cons` B.tail buf
        buf'' = if sign == 1 then buf'
                            else B.map (xor 0xFF) buf'

        iPart = fromIntegral (getCompressed cISize (B.unsafeTake cISize buf'')) * (blockSize ^ ucI)
              + getUncompressed ucI (B.unsafeDrop cISize buf'')

    let buf''' = B.unsafeDrop (ucISize + cISize) buf''

        fPart = getUncompressed ucF (B.unsafeTake ucFSize buf''') * (10 ^ cF)
              + fromIntegral (getCompressed cFSize (B.unsafeDrop ucFSize buf'''))

    let sci = scientific (iPart * 10 ^ scale + fPart) (negate $ fromIntegral scale)
        sci' = if sign == 0 then negate sci else sci
    pure (BinLogNewDecimal sci')
  where
    digitsPerInteger = 9
    blockSize = fromIntegral $ (10 :: Int32) ^ (9 :: Int)
    sizeTable = B.pack [0, 1, 1, 2, 2, 3, 3, 4, 4, 4]

    getCompressed :: Int -> ByteString -> Word64
    getCompressed 0 _  = 0
    getCompressed x bs = let fb = bs `B.unsafeIndex` 0
                             x' = x - 1
                         in fromIntegral fb `shiftL` (8 * x') .|. getCompressed x' (B.unsafeDrop 1 bs)

    getUncompressed :: Word8 -> ByteString -> Integer
    getUncompressed 0 _ = 0
    getUncompressed x bs = let v = getCompressed 4 (B.unsafeTake 4 bs)
                               x' = x - 1
                           in fromIntegral v * (blockSize ^ x') + getUncompressed x' (B.unsafeDrop 4 bs)


getBinLogField (BINLOG_TYPE_ENUM size) =
    if  | size == 1 -> BinLogEnum . fromIntegral <$> getWord8
        | size == 2 -> BinLogEnum <$> getWord16le
        | otherwise -> fail $ "Database.MySQL.BinLogProtocol.BinLogValue: wrong \
                              \BINLOG_TYPE_ENUM size: " ++ show size


getBinLogField (BINLOG_TYPE_SET _ bytes)
    | bytes == 0 || bytes > 8 = fail "invalid SET storage width"
    | otherwise = BinLogSet . B.foldr (\byte rest -> fromIntegral byte .|. (rest `shiftL` 8)) 0 <$> getByteString (fromIntegral bytes)
getBinLogField (BINLOG_TYPE_BLOB lensize) = do
    len <- if  | lensize == 1 -> fromIntegral <$> getWord8
               | lensize == 2 -> fromIntegral <$> getWord16le
               | lensize == 3 -> fromIntegral <$> getWord24le
               | lensize == 4 -> fromIntegral <$> getWord32le
               | otherwise    -> fail $ "Database.MySQL.BinLogProtocol.BinLogValue: \
                                        \wrong BINLOG_TYPE_BLOB length size: " ++ show lensize
    BinLogBytes <$> getByteString len

getBinLogField (BINLOG_TYPE_STRING size) = do
    len <- if | size < 256 -> fromIntegral <$> getWord8
              | otherwise  -> fromIntegral <$> getWord16le
    BinLogBytes <$> getByteString len

getBinLogField (BINLOG_TYPE_GEOMETRY lensize) = do
    len <- if | lensize == 1 -> fromIntegral <$> getWord8
              | lensize == 2 -> fromIntegral <$> getWord16le
              | lensize == 3 -> fromIntegral <$> getWord24le
              | lensize == 4 -> fromIntegral <$> getWord32le
              | otherwise    -> fail $  "Database.MySQL.BinLogProtocol.BinLogValue: \
                                        \wrong BINLOG_TYPE_GEOMETRY length size: " ++ show lensize
    BinLogGeometry <$> getByteString len

-- | Decode the signed fractional storage used by TIME2. Adjacent odd/even
-- precisions share a byte scale; the odd precision's last decimal digit is zero.
-- TIMESTAMP2 and DATETIME2 additionally require a nonnegative fraction.
getMicroSecond :: Word8 -> Get Int32
getMicroSecond 0 = pure 0
getMicroSecond 1 = (* 10000) . fromIntegral <$> getInt8
getMicroSecond 2 = (* 10000) . fromIntegral <$> getInt8
getMicroSecond 3 = (* 100) . fromIntegral <$> getInt16be
getMicroSecond 4 = (* 100) . fromIntegral <$> getInt16be
getMicroSecond 5 = fromIntegral <$> getInt24be
getMicroSecond 6 = fromIntegral <$> getInt24be
getMicroSecond _ = fail "invalid fractional-second precision"

-- Validate before converting to Word32: a negative/corrupt fraction must not
-- wrap to a large microsecond value or imply more precision than the column.
checkedFraction :: Word8 -> Int32 -> Get Word32
checkedFraction precision micros = do
    unless (precision <= 6 && micros >= 0 && micros < 1000000
            && micros `mod` (10 ^ (6 - precision)) == 0)
        (fail "invalid binlog fractional seconds")
    pure (fromIntegral micros)

getBits' :: Word8 -> Get Word64
getBits' bytes = if bytes <= 8
    then getBits (fromIntegral bytes)
    else fail $  "Database.MySQL.BinLogProtocol.BinLogValue: \
                 \wrong bit length size: " ++ show bytes

--------------------------------------------------------------------------------
-- | BinLog row decoder
--
getBinLogRow :: [BinLogMeta] -> BitMap -> Get [BinLogValue]
getBinLogRow metas pmap =
    -- Construct this Get once per event/image and reuse it for every row. The
    -- selected metadata list is shared, so sparse images do not rescan every
    -- omitted column for every row in a large event.
    let selected = [meta | (index,meta) <- zip [0..] metas, isColumnSet pmap index]
        maplen = (length selected + 7) `shiftR` 3
    in do
        nullmap <- getByteString maplen
        -- MariaDB initializes this bitmap to 0xff and clears non-NULL bits;
        -- unused high bits are allowed to remain set (sql/rpl_record.cc).
        go selected (BitMap nullmap) 0
  where
    go :: [BinLogMeta] -> BitMap -> Int -> Get [BinLogValue]
    go [] _ _ = pure []
    go (meta:rest) nullmap index = do
        value <- if isColumnSet nullmap index then pure BinLogNull else getBinLogField meta
        values <- go rest nullmap (index + 1)
        pure (value : values)
