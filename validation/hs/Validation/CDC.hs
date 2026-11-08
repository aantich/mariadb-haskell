{-# LANGUAGE ScopedTypeVariables #-}
module Validation.CDC (cases) where

import Control.Concurrent
import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Data.Word
import Database.MySQL.Base
import Database.MySQL.BinLog
import qualified System.IO.Streams as S
import Validation.Common
import qualified Validation.Stage5 as Stage5

format :: FormatDescription
format=FormatDescription 4 "12.3.3-MariaDB" 0 (B.replicate 171 8)

make :: BinLogEventType -> L.ByteString -> BinLogPacket
make typ body=BinLogPacket 0 typ 1 (fromIntegral (19+L.length body)) 4 0 body False

tableMap :: Word64 -> BinLogPacket
tableMap tid=make BINLOG_TABLE_MAP_EVENT $ runPut $ do
    putWord48le tid; putWord16le 0
    putWord8 1; putByteString "d"; putWord8 0
    putWord8 1; putByteString "t"; putWord8 0
    putLenEncInt 1; putWord8 3; putLenEncInt 0; putWord8 0

writeRow :: Word64 -> Int -> BinLogPacket
writeRow tid n=make BINLOG_WRITE_ROWS_EVENTv1 $ runPut $ do
    putWord48le tid; putWord16le 0; putLenEncInt 1; putWord8 1; putWord8 0; putWord32le (fromIntegral n)

decodeEvents :: [BinLogPacket] -> IO [RowBinLogEvent]
decodeEvents packets=do
    ref <- newIORef "mariadb-bin.000001"
    input <- S.fromList packets
    decodeRowBinLogEvent (format,ref,input) >>= S.toList

cases :: [Case]
cases =
    [ Case "cdc.single-table-map" "cdc" $ do
        actual <- decodeEvents [tableMap 1,writeRow 1 7]
        equal "single row event" 1 (length actual)
    , Case "cdc.multiple-table-maps" "cdc" $ do
        actual <- decodeEvents [tableMap 1,tableMap 2,writeRow 1 7,writeRow 2 8]
        equal "both mapped row events" 2 (length actual)
    , Case "cdc.repeated-row-events" "cdc" $ do
        actual <- decodeEvents [tableMap 1,writeRow 1 7,writeRow 1 8]
        equal "map reused for both row events" 2 (length actual)
    , Case "cdc.table-id-mismatch" "cdc" $ do
        result <- try (decodeEvents [tableMap 1,writeRow 2 7]) :: IO (Either SomeException [RowBinLogEvent])
        case result of
            Left _ -> pure ()
            Right events -> forM_ events $ \e -> case e of
                RowWriteEvent _ _ tm wr -> equal "row matched correct table ID" (tmTableId tm) (writeTableId wr)
                _ -> pure ()
    , Case "cdc.crc32-corruption-rejected" "cdc" $ do
        let body=runPut $ do
                putWord8 0; putWord32le 0; putWord8 16; putWord32le 1
                putWord32le 31; putWord32le 4; putWord16le 0
                putWord64le 7; putWord32le 0xdeadbeef
        expectRejection (getFromPacket (getBinLogPacket True False) (Packet (L.length body) 1 body))
    , Case "cdc.live-row-insert" "cdc" $ withConn $ \source -> do
        exec source "DROP TABLE IF EXISTS mb_cdc_live"
        exec source "CREATE TABLE mb_cdc_live(id INT PRIMARY KEY,n INT) ENGINE=InnoDB"
        tracker <- getLastBinLogTracker source >>= maybe (throwIO (Unavailable "binary log position unavailable")) pure
        stream <- dumpBinLog source 610124 tracker False >>= decodeRowBinLogEvent
        _ <- forkIO $ do
            threadDelay 50000
            withConn (\writer -> exec writer "INSERT INTO mb_cdc_live VALUES(1,7)")
        event <- S.read stream
        case event of
            Just (RowWriteEvent _ _ _ row) -> equal "live insert image" [[BinLogLong 1,BinLogLong 7]] (writeRowData row)
            _ -> throwIO (userError ("missing live row event: " ++ show event))
    , Case "cdc.gtid-resume" "cdc" $ Stage5.gtidResumeFeature
    , Case "cdc.durable-ack-control" "cdc" $ Stage5.manualAckFeature
    ] ++
    [ Case ("cdc.native-event-" ++ show typ) "cdc" $ do
        let body=runPut $ do
                putWord8 0; putWord32le 0; putWord8 typ; putWord32le 1
                putWord32le 19; putWord32le 4; putWord16le 0
        result <- try $ do
            p <- getFromPacket (getBinLogPacket False False) (Packet (L.length body) 1 body)
            evaluate (length (show (blEventType p)))
        case result of
            Left e | Just (_ :: DecodePacketException) <- fromException e -> pure ()
            Left (e :: SomeException) -> throwIO (userError ("partial event decoder: " ++ displayException e))
            Right _ -> pure ()
    | typ <- [160..171]
    ]
