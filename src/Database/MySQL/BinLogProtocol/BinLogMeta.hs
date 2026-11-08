{-# OPTIONS_GHC -funbox-strict-fields #-}

{-|
Module      : Database.MySQL.BinLogProtocol.BinLogMeta
Description : Binlog protocol column meta
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : PORTABLE

This module provide column meta decoder for binlog protocol.

There're certain type won't appear in binlog event, and some types are compressed into 'mySQLTypeString'
, please take python version as a reference:  <https://github.com/noplay/python-mysql-replication>

You will not directly meet following 'FieldType' namely:

    * mySQLTypeDecimal
    * mySQLTypeNewdate
    * mySQLTypeEnum
    * mySQLTypeSet
    * mySQLTypeTinyBlob
    * mySQLTypeMediumBlOb
    * mySQLTypeLongBlob

-}

module Database.MySQL.BinLogProtocol.BinLogMeta (BinLogMeta(..), getBinLogMeta) where

import           Control.Monad (unless)
import           Data.Binary.Get
import           Data.Bits
import           Data.Word
import           Database.MySQL.Protocol.ColumnDef

-- | An intermedia date type for decoding row-based event's values.
--
data BinLogMeta
    = BINLOG_TYPE_TINY
    | BINLOG_TYPE_SHORT
    | BINLOG_TYPE_INT24
    | BINLOG_TYPE_LONG
    | BINLOG_TYPE_LONGLONG
    | BINLOG_TYPE_FLOAT       !Word8         -- ^ size
    | BINLOG_TYPE_DOUBLE      !Word8         -- ^ size
    | BINLOG_TYPE_BIT         !Word16 !Word8 -- ^ bits, bytes
    | BINLOG_TYPE_TIMESTAMP
    | BINLOG_TYPE_DATETIME
    | BINLOG_TYPE_DATE
    | BINLOG_TYPE_TIME
    | BINLOG_TYPE_TIMESTAMP2  !Word8         -- ^ fsp
    | BINLOG_TYPE_DATETIME2   !Word8         -- ^ fsp
    | BINLOG_TYPE_TIME2       !Word8         -- ^ fsp
    | BINLOG_TYPE_YEAR
    | BINLOG_TYPE_NEWDECIMAL  !Word8 !Word8  -- ^ precision, scale
    | BINLOG_TYPE_ENUM        !Word8         -- ^ 1 or 2('Word8' or 'Word16'), enum index size
    | BINLOG_TYPE_SET         !Word16 !Word8 -- ^ bitmap bits, bytes
    | BINLOG_TYPE_BLOB        !Word8         -- ^ length size
    | BINLOG_TYPE_STRING      !Word16        -- ^ meta length(if < 256, then length is 8bit,
                                             -- if > 256 then length is 16bit)
    | BINLOG_TYPE_GEOMETRY    !Word8         -- ^ length size
  deriving (Show, Eq)

getBinLogMeta :: FieldType -> Get BinLogMeta
getBinLogMeta t
    | t == mySQLTypeTiny       = pure BINLOG_TYPE_TINY
    | t == mySQLTypeShort      = pure BINLOG_TYPE_SHORT
    | t == mySQLTypeInt24      = pure BINLOG_TYPE_INT24
    | t == mySQLTypeLong       = pure BINLOG_TYPE_LONG
    | t == mySQLTypeLongLong   = pure BINLOG_TYPE_LONGLONG
    | t == mySQLTypeFloat      = BINLOG_TYPE_FLOAT <$> checkedByte "FLOAT width" (==4)
    | t == mySQLTypeDouble     = BINLOG_TYPE_DOUBLE <$> checkedByte "DOUBLE width" (==8)

    | t == mySQLTypeBit        = do
        byte0 <- getWord8
        byte1 <- getWord8
        let nbits = (fromIntegral byte1 `shiftL` 3) .|.  fromIntegral byte0
            nbytes = fromIntegral $ (nbits + 7) `shiftR` 3
        unless (byte0 <= 7 && nbits >= 1 && nbits <= 64) (fail "invalid BIT metadata")
        pure (BINLOG_TYPE_BIT nbits nbytes)

    | t == mySQLTypeTimestamp  = pure BINLOG_TYPE_TIMESTAMP
    | t == mySQLTypeDateTime   = pure BINLOG_TYPE_DATETIME
    | t == mySQLTypeDate       = pure BINLOG_TYPE_DATE
    | t == mySQLTypeTime       = pure BINLOG_TYPE_TIME
    | t == mySQLTypeTimestamp2 = BINLOG_TYPE_TIMESTAMP2 <$> checkedByte "fractional precision" (<=6)
    | t == mySQLTypeDateTime2  = BINLOG_TYPE_DATETIME2 <$> checkedByte "fractional precision" (<=6)
    | t == mySQLTypeTime2      = BINLOG_TYPE_TIME2 <$> checkedByte "fractional precision" (<=6)
    | t == mySQLTypeYear       = pure BINLOG_TYPE_YEAR
    | t == mySQLTypeNewDecimal = do
        precision <- getWord8
        scale <- getWord8
        unless (precision >= 1 && precision <= 65 && scale <= 38 && scale <= precision)
            (fail "invalid DECIMAL metadata")
        pure (BINLOG_TYPE_NEWDECIMAL precision scale)
    | t == mySQLTypeVarChar    = BINLOG_TYPE_STRING <$> getWord16le
    | t == mySQLTypeVarString  = BINLOG_TYPE_STRING <$> getWord16le

    | t == mySQLTypeString     = do
        byte0 <- getWord8
        byte1 <- getWord8
        -- http://bugs.mysql.com/37426
        if  byte0 > 0
        then if (byte0 .&. 0x30) /= 0x30
             then if FieldType (byte0 .|. 0x30) == mySQLTypeString
                  then let len = fromIntegral $ (byte0 .&. 0x30) `xor` 0x30
                           len' = len `shiftL` 4 .|. fromIntegral byte1
                       in pure $! BINLOG_TYPE_STRING len'
                  else let len = fromIntegral byte0 `shiftL` 8 :: Word16
                           len' = len .|. fromIntegral byte1
                       in pure $! BINLOG_TYPE_STRING len'
             else let t' = FieldType byte0
                  in if | t' == mySQLTypeSet    -> let nbits = fromIntegral byte1 `shiftL` 3
                                                       nbytes = fromIntegral $ (nbits + 7) `shiftR` 3
                                                   in if byte1 >= 1 && byte1 <= 8 then pure (BINLOG_TYPE_SET nbits nbytes) else fail "invalid SET width"
                        | t' == mySQLTypeEnum   -> if byte1 == 1 || byte1 == 2 then pure (BINLOG_TYPE_ENUM byte1) else fail "invalid ENUM width"
                        | t' == mySQLTypeString -> pure (BINLOG_TYPE_STRING (fromIntegral byte1))
                        | otherwise             -> fail $ "Database.MySQL.BinLogProtocol.BinLogMeta:\
                                                           \ impossible type inside binlog string: " ++ show t'
        else pure (BINLOG_TYPE_STRING (fromIntegral byte1))

    | t == mySQLTypeBlob       = BINLOG_TYPE_BLOB <$> checkedByte "BLOB length width" (\n -> n >= 1 && n <= 4)
    | t == mySQLTypeGeometry   = BINLOG_TYPE_GEOMETRY <$> checkedByte "GEOMETRY length width" (\n -> n >= 1 && n <= 4)
    | otherwise                = fail $ "Database.MySQL.BinLogProtocol.BinLogMeta:\
                                        \ impossible type in binlog: " ++ show t

-- Validate metadata before it can drive byte counts or temporal arithmetic.
checkedByte :: String -> (Word8 -> Bool) -> Get Word8
checkedByte label valid = do
    value <- getWord8
    unless (valid value) (fail ("invalid binlog " ++ label))
    pure value
