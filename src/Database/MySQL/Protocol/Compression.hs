{-# LANGUAGE BangPatterns #-}
-- | Optional MariaDB zlib framing, below ordinary packet framing and above the
-- raw TCP/TLS byte transport. Compressed frames may contain several packets or
-- just part of one. Ordinary exchanges share a modulo-256 sequence; semisync
-- replication needs a separate policy because its two directions interleave.
module Database.MySQL.Protocol.Compression
    ( CompressionTransport(..), CompressionException(..), newCompressionTransport ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (unless, when)
import qualified Codec.Compression.Zlib as Zlib
import qualified Codec.Compression.Zlib.Internal as Z
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.Word
import qualified System.IO.Streams as S

-- | Invalid compressed framing or expansion. The enclosing connection retires
-- its transport; decompression errors never become a clean end-of-stream.
data CompressionException = CompressionException String deriving Show
instance Exception CompressionException

-- | Start only after successful plugin authentication. Reset once before each
-- ordinary command, never between its continuation packets or reply packets.
data CompressionTransport = CompressionTransport
    { compressionInput :: !(S.InputStream B.ByteString)
    , compressionSend :: !(L.ByteString -> IO ())
    , compressionStart :: !(IO ())
    , compressionReset :: !(IO ())
    , compressionAllowReplicationResets :: !(IO ())
    }

-- | Construct a disabled transport. Inbound compressed and expanded frames are
-- independently bounded by the smaller of the supplied byte limit and 16 MiB-1.
-- Outbound frames contain at most 64 KiB of ordinary wire bytes. Small or
-- incompressible frames use the protocol's uncompressed representation.
newCompressionTransport :: Word64 -> Int -> S.InputStream B.ByteString
                        -> (L.ByteString -> IO ()) -> IO CompressionTransport
newCompressionTransport limit threshold input output = do
    enabled <- newIORef False
    sequenceNumber <- newIORef (0 :: Word8)
    replicationResets <- newIORef False
    pending <- newIORef []
    let bad = throwIO . CompressionException
        ceilingBytes = fromIntegral (min 16777215 (min limit (fromIntegral (maxBound :: Int))))
        advance actual = do
            expected <- readIORef sequenceNumber
            allowReset <- readIORef replicationResets
            -- MariaDB's semisync sender resets after synchronizing flushes,
            -- while ACKs travel independently in the reverse direction. As in
            -- Connector/C's pkt_nr_can_be_reset policy, no shared expected
            -- sequence exists in that dedicated stream. Ordinary commands and
            -- replication without ACKs retain the strict check.
            unless (allowReset || actual == expected) (bad "unexpected compressed packet sequence")
            writeIORef sequenceNumber (actual + 1)
        readFrame = do
            header <- S.readExactly 7 input
            let packed = word24 header 0
                expanded = word24 header 4
            when (packed == 0 || packed > ceilingBytes || expanded > ceilingBytes)
                (bad "compressed frame exceeds client limit or is empty")
            advance (B.index header 3)
            bytes <- S.readExactly packed input
            if expanded == 0 then pure [bytes]
                else L.toChunks <$> inflateExact expanded bytes
        readCompressed = do
            chunks <- readIORef pending
            case chunks of
                first:rest -> writeIORef pending rest >> pure (Just first)
                [] -> do
                    chunks' <- readFrame
                    case chunks' of
                        [] -> bad "compressed frame produced no bytes"
                        first:rest -> writeIORef pending rest >> pure (Just first)
        sendFrames bytes
            | L.null bytes = pure ()
            | otherwise = do
                let (part,rest) = L.splitAt 65536 bytes
                    count = fromIntegral (L.length part)
                    compressed = if count >= threshold then Zlib.compress part else part
                    savesBytes = count >= threshold && L.length compressed < fromIntegral count
                    payload = if savesBytes then compressed else part
                    expanded = if savesBytes then count else 0
                sequenceN <- readIORef sequenceNumber
                writeIORef sequenceNumber (sequenceN + 1)
                output (runPut (put24 (fromIntegral (L.length payload)) >> putWord8 sequenceN >>
                    put24 expanded >> putLazyByteString payload))
                sendFrames rest
    source <- S.makeInputStream $ do
        active <- readIORef enabled
        if active then readCompressed else S.read input
    let send bytes = readIORef enabled >>= \active -> if active then sendFrames bytes else output bytes
        start = writeIORef sequenceNumber 0 >> writeIORef enabled True
        reset = writeIORef sequenceNumber 0
        allowReplicationResets = writeIORef replicationResets True
    pure (CompressionTransport source send start reset allowReplicationResets)
  where
    word24 :: B.ByteString -> Int -> Int
    word24 bytes offset = fromIntegral (B.index bytes offset) .|.
        (fromIntegral (B.index bytes (offset+1)) `shiftL` 8) .|.
        (fromIntegral (B.index bytes (offset+2)) `shiftL` 16)
    put24 :: Int -> Put
    put24 n = putWord8 (fromIntegral n) >> putWord8 (fromIntegral (n `shiftR` 8)) >>
        putWord8 (fromIntegral (n `shiftR` 16))

-- Streaming zlib inspection bounds output before retaining it and checks both
-- the advertised length and compressed stream termination. The lazy pure
-- decompressor alone cannot distinguish a false length or trailing stream.
inflateExact :: Int -> B.ByteString -> IO L.ByteString
inflateExact expected input = go 0 [] [input] (Z.decompressIO Z.zlibFormat Z.defaultDecompressParams)
  where
    bad = throwIO . CompressionException
    go !size chunks pending stream = case stream of
        Z.DecompressInputRequired next -> case pending of
            [] -> next B.empty >>= go size chunks []
            first:rest -> next first >>= go size chunks rest
        Z.DecompressOutputAvailable chunk next -> do
            let total = size + B.length chunk
            when (total > expected) (bad "zlib output exceeds advertised frame length")
            next >>= go total (chunk:chunks) pending
        Z.DecompressStreamEnd trailing -> do
            unless (size == expected && B.null trailing && all B.null pending)
                (bad "zlib frame length or trailing data mismatch")
            pure (L.fromChunks (reverse chunks))
        Z.DecompressStreamError err -> bad ("invalid zlib frame: " ++ show err)
