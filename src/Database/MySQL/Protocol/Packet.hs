{-# OPTIONS_GHC -funbox-strict-fields #-}

{-|
Module      : Database.MySQL.Protocol.Packet
Description : MariaDB packet framing, replies and limits
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : Anton Antich <anton.antich@gmail.com>
Stability   : experimental
Portability : PORTABLE

MySQL packet decoder&encoder, and varities utility.

-}

module Database.MySQL.Protocol.Packet where

import           Control.Exception     (Exception (..), throwIO)
import           Data.Binary.Parser
import           Data.Binary.Put
import           Data.Binary           (Binary(..), encode)
import           Data.Bits
import qualified Data.ByteString       as B
import           Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy  as L
import           Data.Int.Int24
import           Data.Int
import           Data.Word
import           Data.Typeable
import           Data.Word.Word24

--------------------------------------------------------------------------------
-- | MySQL packet type
--
data Packet = Packet
    { pLen  :: !Int64
    , pSeqN :: !Word8
    , pBody :: !L.ByteString
    } deriving (Show, Eq)

putPacket :: Packet -> Put
putPacket (Packet len seqN body)  = do
    putWord24le (fromIntegral len)
    putWord8 seqN
    putLazyByteString body
{-# INLINE putPacket #-}

getPacket :: Get Packet
getPacket = do
    len <- fromIntegral <$> getWord24le
    seqN <- getWord8
    body <- getLazyByteString len
    return (Packet len seqN body)
{-# INLINE getPacket #-}

instance Binary Packet where
    put = putPacket
    {-# INLINE put #-}
    get = getPacket
    {-# INLINE get #-}

isERR :: Packet -> Bool
isERR p = not (L.null (pBody p)) && L.head (pBody p) == 0xFF
{-# INLINE isERR #-}

isOK :: Packet -> Bool
isOK p = not (L.null (pBody p)) && L.head (pBody p) == 0x00
{-# INLINE isOK #-}

-- | Recognize a short legacy EOF. The 0xfe marker also starts an eight-byte
-- length-encoded row value, so checking its first byte alone would truncate
-- large rows. Negotiated OK terminators are handled by the connection layer.
isEOF :: Packet -> Bool
isEOF p = pLen p > 0 && pLen p < 9 && not (L.null (pBody p)) && L.head (pBody p) == 0xFE
{-# INLINE isEOF #-}

-- | Is this an AuthMoreData packet? (first byte 0x01)
-- Used during authentication handshake for caching_sha2_password.
isAuthMoreData :: Packet -> Bool
isAuthMoreData p = not (L.null (pBody p)) && L.head (pBody p) == 0x01
{-# INLINE isAuthMoreData #-}

-- | Is this an AuthSwitchRequest packet? (first byte 0xFE)
-- Same marker as EOF but used in authentication context.
isAuthSwitch :: Packet -> Bool
isAuthSwitch p = not (L.null (pBody p)) && L.head (pBody p) == 0xFE
{-# INLINE isAuthSwitch #-}

-- | Is there more packet to be read?
--
--  https://dev.mysql.com/doc/internals/en/status-flags.html
isThereMore :: OK -> Bool
isThereMore p  = okStatus p .&. 0x08 /= 0
{-# INLINE isThereMore #-}

-- | Decode a Binary payload in IO, permitting a separately parsed trailer.
-- Fixed row/metadata structures should use 'getFromPacketExact' instead.
decodeFromPacket :: Binary a => Packet -> IO a
decodeFromPacket = getFromPacket get
{-# INLINE decodeFromPacket #-}

-- | Decode with a supplied parser, permitting unconsumed bytes and forcing the
-- result to WHNF. Row readers additionally force their values under ownership;
-- WHNF alone does not force every element of a returned list.
getFromPacket :: Get a -> Packet -> IO a
getFromPacket g (Packet _ _ body) = case parseDetailLazy g body of
    Left  (buf, offset, errmsg) -> throwIO (DecodePacketFailed buf offset errmsg)
    Right (_,   _,      r     ) -> return $! r
{-# INLINE getFromPacket #-}

-- | A binary parser rejected a packet, with its buffered bytes, consumed offset
-- and parser message. Live command/stream guards retire an incomplete exchange;
-- low-level callers decide how to handle independent packet data.
data DecodePacketException = DecodePacketFailed ByteString ByteOffset String
  deriving (Typeable, Show)
instance Exception DecodePacketException

encodeToPacket :: Binary a => Word8 -> a -> Packet
encodeToPacket seqN payload =
    let s = encode payload
        l = L.length s
    in Packet l seqN s
{-# INLINE encodeToPacket #-}

putToPacket :: Word8 -> Put -> Packet
putToPacket seqN payload =
    let s = runPut payload
        l = L.length s
    in Packet l seqN s
{-# INLINE putToPacket #-}

--------------------------------------------------------------------------------
-- OK, ERR, EOF

-- | You may get interested in t'OK' packet because it provides information about
-- successful operations.
--
data OK = OK
    { okAffectedRows :: !Word64      -- ^ affected row number
    , okLastInsertID :: !Word64      -- ^ last insert's ID
    , okStatus       :: !Word16
    , okWarningCnt   :: !Word16
    } deriving (Show, Eq)

-- | Decode the fixed OK prefix after its marker has been identified. Optional
-- info/session-tracking trailers are consumed by the connection layer.
getOK :: Get OK
getOK = OK <$ skipN 1
           <*> getLenEncWord64
           <*> getLenEncWord64
           <*> getWord16le
           <*> getWord16le
{-# INLINE getOK #-}

-- | Encode the fixed OK prefix; negotiated tracking envelopes are separate.
putOK :: OK -> Put
putOK (OK row lid stat wcnt) = do
    putWord8 0x00
    putLenEncWord64 row
    putLenEncWord64 lid
    putWord16le stat
    putWord16le wcnt
{-# INLINE putOK #-}

instance Binary OK where
    get = getOK
    {-# INLINE get #-}
    put = putOK
    {-# INLINE put #-}

data ERR = ERR
    { errCode  :: !Word16
    , errState :: !ByteString
    , errMsg   :: !ByteString
    } deriving (Show, Eq)

getERR :: Get ERR
getERR = ERR <$  skipN 1
             <*> getWord16le
             <*  skipN 1
             <*> getByteString 5
             <*> getRemainingByteString
{-# INLINE getERR #-}

putERR :: ERR -> Put
putERR (ERR code stat msg) = do
    putWord8 0xFF
    putWord16le code
    putWord8 35 -- '#'
    putByteString stat
    putByteString msg
{-# INLINE putERR #-}

instance Binary ERR where
    get = getERR
    {-# INLINE get #-}
    put = putERR
    {-# INLINE put #-}

data EOF = EOF
    { eofWarningCnt :: !Word16
    , eofStatus     :: !Word16
    } deriving (Show, Eq)

getEOF :: Get EOF
getEOF = EOF <$  skipN 1
             <*> getWord16le
             <*> getWord16le
{-# INLINE getEOF #-}

putEOF :: EOF -> Put
putEOF (EOF wcnt stat) = do
    putWord8 0xFE
    putWord16le wcnt
    putWord16le stat
{-# INLINE putEOF #-}

instance Binary EOF where
    get = getEOF
    {-# INLINE get #-}
    put = putEOF
    {-# INLINE put #-}

--------------------------------------------------------------------------------
--  Helpers

getByteStringNul :: Get ByteString
getByteStringNul = L.toStrict <$> getLazyByteStringNul
{-# INLINE getByteStringNul #-}

getRemainingByteString :: Get ByteString
getRemainingByteString = L.toStrict <$> getRemainingLazyByteString
{-# INLINE getRemainingByteString #-}

putLenEncBytes :: ByteString -> Put
putLenEncBytes c = do
    putLenEncInt (B.length c)
    putByteString c
{-# INLINE putLenEncBytes #-}

getLenEncBytes :: Get ByteString
getLenEncBytes = getLenEncInt >>= getByteString
{-# INLINE getLenEncBytes #-}

-- | Decode a non-NULL unsigned length-encoded value. OK counters and insert IDs
-- use the full Word64 range even when the host's Int is narrower.
getLenEncWord64 :: Get Word64
getLenEncWord64 = do
    tag <- getWord8
    case tag of
        0xfc -> fromIntegral <$> getWord16le
        0xfd -> fromIntegral <$> getWord24le
        0xfe -> getWord64le
        _ | tag < 0xfb -> pure (fromIntegral tag)
          | otherwise -> fail "NULL or invalid non-null length integer"
{-# INLINE getLenEncWord64 #-}

-- | Decode a length that will index memory, rejecting values outside host Int.
getLenEncInt :: Get Int
getLenEncInt = getWord8 >>= getLenEncIntAfterTag

-- | Length decoder after a row parser has already consumed its NULL/length tag.
-- Sharing that read avoids a second peek and Get wrapper on every text field.
getLenEncIntAfterTag :: Word8 -> Get Int
getLenEncIntAfterTag tag
    | tag < 0xfb = pure (fromIntegral tag)
    | tag == 0xfc = fromIntegral <$> getWord16le
    | tag == 0xfd = fromIntegral <$> getWord24le
    | tag == 0xfe = do
        n <- getWord64le
        if n > fromIntegral (maxBound :: Int) then fail "length exceeds machine Int" else pure (fromIntegral n)
    | otherwise = fail "NULL or invalid non-null length integer"
{-# INLINE getLenEncIntAfterTag #-}
{-# INLINE getLenEncInt #-}

-- | Encode a non-NULL unsigned value using the shortest protocol representation.
putLenEncWord64 :: Word64 -> Put
putLenEncWord64 n
    | n < 251 = putWord8 (fromIntegral n)
    | n < 65536 = putWord8 0xfc >> putWord16le (fromIntegral n)
    | n < 16777216 = putWord8 0xfd >> putWord24le (fromIntegral n)
    | otherwise = putWord8 0xfe >> putWord64le n
{-# INLINE putLenEncWord64 #-}

putLenEncInt :: Int -> Put
putLenEncInt n | n < 0 = error "negative protocol length"
               | otherwise = putLenEncWord64 (fromIntegral n)
{-# INLINE putLenEncInt #-}

putWord24le :: Word32 -> Put
putWord24le v = do
    putWord16le $ fromIntegral v
    putWord8 $ fromIntegral (v `shiftR` 16)
{-# INLINE putWord24le #-}

getWord24le :: Get Word32
getWord24le = do
    a <- fromIntegral <$> getWord16le
    b <- fromIntegral <$> getWord8
    return $! a .|. (b `shiftL` 16)
{-# INLINE getWord24le #-}

putWord48le :: Word64 -> Put
putWord48le v = do
    putWord32le $ fromIntegral v
    putWord16le $ fromIntegral (v `shiftR` 32)
{-# INLINE putWord48le #-}

getWord48le :: Get Word64
getWord48le = do
    a <- fromIntegral <$> getWord32le
    b <- fromIntegral <$> getWord16le
    return $! a .|. (b `shiftL` 32)
{-# INLINE getWord48le #-}

getWord24be :: Get Word24
getWord24be = do
    a <- fromIntegral <$> getWord16be
    b <- fromIntegral <$> getWord8
    return $! b .|. (a `shiftL` 8)
{-# INLINE getWord24be #-}

getInt24be :: Get Int24
getInt24be = do
    a <- fromIntegral <$> getWord16be
    b <- fromIntegral <$> getWord8
    return $! fromIntegral $ (b .|. (a `shiftL` 8) :: Word24)
{-# INLINE getInt24be #-}

getWord40be, getWord48be, getWord56be :: Get Word64
getWord40be = do
    a <- fromIntegral <$> getWord32be
    b <- fromIntegral <$> getWord8
    return $! (a `shiftL` 8) .|. b
getWord48be = do
    a <- fromIntegral <$> getWord32be
    b <- fromIntegral <$> getWord16be
    return $! (a `shiftL` 16) .|. b
getWord56be = do
    a <- fromIntegral <$> getWord32be
    b <- fromIntegral <$> getWord24be
    return $! (a `shiftL` 24) .|. b
{-# INLINE getWord40be #-}
{-# INLINE getWord48be #-}
{-# INLINE getWord56be #-}

-- | Decode a fixed row/metadata structure with no trailing bytes. Compare the
-- consumed offset with the complete logical length: a parser may stop before
-- requesting a later lazy ByteString chunk, so its returned buffer alone cannot
-- establish full consumption. OK envelopes use their separate trailer parser.
getFromPacketExact :: Get a -> Packet -> IO a
getFromPacketExact parser (Packet lengthBytes _ body) = case parseDetailLazy parser body of
    Left (buffer,offset,message) -> throwIO (DecodePacketFailed buffer offset message)
    Right (_,offset,value)
        | offset == lengthBytes -> pure value
        | otherwise -> throwIO (DecodePacketFailed B.empty offset "trailing bytes in fixed protocol structure")
{-# INLINE getFromPacketExact #-}
