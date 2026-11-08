{-# LANGUAGE BangPatterns #-}
-- | Streaming CDC workloads. Fixture encoding is outside decoder timing; the
-- framing/CRC profile deliberately includes encoding fresh, varying messages.
-- Live profiles include connect/setup, decoding and checkpoint observation, with
-- source log creation outside timing. All row values contribute to a checksum.
module Validation.Stage5Bench (run) where

import Control.Exception (evaluate)
import Control.Monad
import qualified Codec.Compression.Zlib as Z
import Data.Binary.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.List (intercalate)
import qualified Data.Text.Encoding as TE
import Data.Word
import Database.MySQL.Base
import Database.MySQL.BinLog
import GHC.Clock
import GHC.Stats
import System.Mem
import qualified System.IO.Streams as S
import Validation.Common

run :: String -> Int -> IO ()
run ident count
    | count <= 0 = fail "positive CDC benchmark count required"
    | ident == "cdc.decode.single-table" = measure ident count $ decodeRows
        (mapping 1 : [row 1 n | n <- [1..count]])
    | ident == "cdc.decode.interleaved" = measure ident count $ decodeRows
        ([mapping tid | tid <- [1..64]] ++ [row (fromIntegral (n `mod` 64 + 1)) n | n <- [1..count]])
    | ident == "cdc.decode.sparse-update" = measure ident count $ do
        let metadata=make BINLOG_TABLE_MAP_EVENT $ do
                putWord48le 1 >> putWord16le 0
                putWord8 1 >> putByteString "d" >> putWord8 0
                putWord8 1 >> putByteString "t" >> putWord8 0
                putLenEncInt 64 >> putByteString (B.replicate 64 3) >> putLenEncInt 0 >> putWord64le 0
            update n = make BINLOG_UPDATE_ROWS_EVENTv1 $ do
                putWord48le 1 >> putWord16le 0 >> putLenEncInt 64
                putWord64le 1 >> putWord64le 0x8000000000000000
                putWord8 0 >> putWord32le (fromIntegral (negate n))
                putWord8 0 >> putWord32le (fromIntegral n)
        decodeRows (metadata : map update [1..count])
    | ident == "cdc.decode.compressed" = measure ident count $ decodeRows
        (mapping 1 : [compressedRow n | n <- [1..count]])
    | ident == "cdc.framing.crc32" = measure ident count $ do
        total <- foldM (\ !acc n -> do
            let event=row 1 n
                raw=runPut $ do
                    putWord32le 0 >> putWord8 23 >> putWord32le 1
                    putWord32le (fromIntegral (23 + L.length (blBody event))) >> putWord32le 100 >> putWord16le 0
                    putLazyByteString (blBody event)
                framed=putToPacket 1 (putWord8 0 >> putLazyByteString raw >> putWord32le (binLogCRC32 raw))
            checked <- getFromPacket (getBinLogPacket True False) framed
            unless (blBody checked == blBody event) (fail "CRC fixture roundtrip")
            pure (acc + 1)) (0 :: Integer) [1..count]
        pure total
    | ident == "cdc.retention" = measure ident count $ do
        cursor <- newIORef (0 :: Int)
        input <- S.makeInputStream $ do
            n <- atomicModifyIORef' cursor (\value -> (value+1,value))
            pure (if n==0 then Just (mapping 1) else if n<=count then Just (row 1 n) else Nothing)
        gtids <- either fail pure (gtidSet [])
        (events,_) <- newCDCDecoder defaultDecodeLimits (Just gtids) fixtureFormat "bin.1" input
        let loop :: Int -> Integer -> IO Integer
            loop !n !total = do
                event <- S.read events
                case event of
                    Nothing -> pure total
                    Just value -> do
                        addition <- case cdcEventPayload value of
                            CDCWrite _ image -> case writeRowData image of
                                [[BinLogLong valueNumber]] -> pure (toInteger valueNumber)
                                _ -> fail "retention image mismatch"
                            _ -> fail "retention event mismatch"
                        let next=n+1
                        when (next `elem` [1000,10000,100000,1000000]) $ do
                            performGC
                            stats <- getRTSStats
                            putStrLn (intercalate "\t" ["STAGE5_HEAP",show next,show (gcdetails_live_bytes (gc stats))])
                        loop next (total+addition)
        loop 0 0
    | ident == "cdc.live.rows" || ident == "cdc.live.checkpoints" = withConn $ \writer -> do
        exec writer "DROP TABLE IF EXISTS mb_stage5_bench"
        exec writer "CREATE TABLE mb_stage5_bench(id INT PRIMARY KEY,n INT) ENGINE=InnoDB"
        (_,stateStream) <- query_ writer "SELECT @@global.gtid_binlog_pos"
        state <- S.toList stateStream
        start <- case state of
            [[MySQLText value]] -> either fail pure (parseGtidSet (TE.encodeUtf8 value))
            _ -> fail "CDC benchmark GTID state"
        if ident == "cdc.live.rows" then withTransaction writer $ insertRows writer count
        else forM_ [1..count] $ \n -> withTransaction writer $ void $ execute writer
            "INSERT INTO mb_stage5_bench VALUES(?,1)" [MySQLInt32 (fromIntegral n)]
        measure ident count $ withConn $ \source -> do
            stream <- openCDC source 610130 (defaultCDCOptions (FromGtid start)) {cdcNonBlocking=True}
            (checksum,checkpoints) <- consume (cdcEvents stream)
            equal "live checkpoint count" (if ident=="cdc.live.rows" then 1 else count) checkpoints
            pure checksum
    | otherwise = fail "unknown CDC benchmark profile"
  where
    insertRows conn n = forM_ [1..n] $ \key -> void $ execute conn
        "INSERT INTO mb_stage5_bench VALUES(?,1)" [MySQLInt32 (fromIntegral key)]

fixtureFormat :: FormatDescription
fixtureFormat = FormatDescription 4 "12.3.3-MariaDB" 0 (B.replicate 172 8)

make :: BinLogEventType -> Put -> BinLogPacket
make typ builder = BinLogPacket 0 typ 1 (fromIntegral (19+L.length body)) 100 0 body False
  where body=runPut builder

mapping :: Word64 -> BinLogPacket
mapping tid = make BINLOG_TABLE_MAP_EVENT $ do
    putWord48le tid >> putWord16le 0
    putWord8 1 >> putByteString "d" >> putWord8 0
    putWord8 1 >> putByteString "t" >> putWord8 0
    putLenEncInt 1 >> putWord8 3 >> putLenEncInt 0 >> putWord8 0

row :: Word64 -> Int -> BinLogPacket
row tid n = make BINLOG_WRITE_ROWS_EVENTv1 $ do
    putWord48le tid >> putWord16le 0 >> putLenEncInt 1 >> putWord8 1 >> putWord8 0
    putWord32le (fromIntegral n)

compressedRow :: Int -> BinLogPacket
compressedRow n = let event=row 1 n in event {blEventType=MARIADB_WRITE_ROWS_COMPRESSED_EVENTv1,
    blBody=L.take 10 (blBody event) <> L.pack [0x81,5] <> Z.compress (L.drop 10 (blBody event))}

decodeRows :: [BinLogPacket] -> IO Integer
decodeRows packets = do
    input <- S.fromList packets
    gtids <- either fail pure (gtidSet [])
    (events,_) <- newCDCDecoder defaultDecodeLimits (Just gtids) fixtureFormat "bin.1" input
    fst <$> consume events

consume :: S.InputStream CDCEvent -> IO (Integer,Int)
consume input = loop 0 0
  where
    loop !total !checkpoints = do
        value <- S.read input
        case value of
            Nothing -> pure (total,checkpoints)
            Just event -> do
                let count=case cdcEventPayload event of
                        CDCWrite _ rowsEvent -> sum [toInteger n | image <- writeRowData rowsEvent,
                            BinLogLong n <- [last image]]
                        CDCUpdate _ updateEvent -> sum [toInteger after | ([BinLogLong before],[BinLogLong after]) <- updateRowData updateEvent,
                            before == negate after]
                        _ -> 0
                    commits=maybe 0 (const 1) (cdcEventCheckpoint event)
                loop (total+count) (checkpoints+commits)

measure :: String -> Int -> IO Integer -> IO ()
measure ident units operation = do
    void operation
    void operation
    performGC
    before <- getRTSStats
    start <- getMonotonicTimeNSec
    checksum <- operation >>= evaluate
    end <- getMonotonicTimeNSec
    performGC
    after <- getRTSStats
    let expected | ident `elem` ["cdc.decode.single-table","cdc.decode.interleaved","cdc.decode.compressed","cdc.decode.sparse-update","cdc.retention"] = toInteger units*(toInteger units+1) `div` 2
                 | otherwise = toInteger units
    equal "CDC benchmark checksum" expected checksum
    putStrLn (intercalate "\t" ["STAGE5",ident,show units,show (end-start),
        show (allocated_bytes after-allocated_bytes before),show (cpu_ns after-cpu_ns before),
        show (gc_cpu_ns after-gc_cpu_ns before),show checksum])
