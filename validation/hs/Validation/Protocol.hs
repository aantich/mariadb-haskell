{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Protocol (cases) where

import Control.Exception hiding (assert)
import Control.Monad
import Data.Binary (encode)
import Data.Binary.Get
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Database.MySQL.Base
import qualified Database.MySQL.Connection as C
import qualified System.IO.Streams as S
import Validation.Common

mkColumn :: FieldType -> ColumnDef
mkColumn typ = ColumnDef "" "" "" "v" "" 63 100 typ 0 0

packetCase :: String -> IO () -> Case
packetCase name = Case ("protocol." ++ name) "protocol"

cases :: [Case]
cases =
    [ packetCase ("length-" ++ show n) $ equal "length round trip" n
        (runGet getLenEncInt (runPut (putLenEncInt n)))
    | n <- [0,1,250,251,255,256,65535,65536,16777215,16777216,2147483647]
    ] ++
    [ packetCase ("packet-size-" ++ show n) $ do
        let p=Packet n 7 (L.replicate n 65)
        equal "packet round trip" p (runGet getPacket (encode p))
    | n <- [0,1,255,256,65535]
    ] ++
    [ packetCase ("fragment-split-" ++ show n) $ do
        let body="fragmented-packet"
            encoded=L.toStrict (encode (Packet (L.length body) 1 body))
        input <- S.fromList (filter (not . B.null) [B.take n encoded,B.drop n encoded])
        stream <- C.decodeInputStream input
        equal "fragmented packet" (Packet (L.length body) 1 body) =<< C.readPacket stream
    | n <- [1..20]
    ] ++
    [ packetCase "coalesced-packets" $ do
        let a=Packet 1 1 "A"; b=Packet 1 2 "B"
        input <- S.fromList [L.toStrict (encode a <> encode b)]
        stream <- C.decodeInputStream input
        equal "first packet" a =<< C.readPacket stream
        equal "second packet" b =<< C.readPacket stream
    , packetCase "truncated-header" $ do
        input <- S.fromList [B.pack [1,0]]
        stream <- C.decodeInputStream input
        expectRejection (C.readPacket stream)
    , packetCase "truncated-body" $ do
        input <- S.fromList [B.pack [3,0,0,1,65]]
        stream <- C.decodeInputStream input
        expectRejection (C.readPacket stream)
    , packetCase "continuation-sequence-rejected" $ do
        input <- S.fromList [Packet 16777215 1 (L.replicate 16777215 65),Packet 0 99 L.empty]
        expectRejection (C.readPacket input)
    , packetCase "continuation-sequence-wrap" $ do
        input <- S.fromList [Packet 16777215 255 (L.replicate 16777215 65),Packet 1 0 "B"]
        result <- C.readPacket input
        equal "joined payload size" 16777216 (pLen result)
        equal "last payload byte" 66 (L.last (pBody result))
    , packetCase "large-row-is-not-eof" $ do
        let body=runPut (putWord8 0xFE >> putWord64le 16777216 >> putLazyByteString (L.replicate 16777216 65))
        assert (not (isEOF (Packet (L.length body) 1 body))) "valid 16 MiB text field classified as EOF"
    , packetCase "unsigned-last-insert-id" $ do
        let body=runPut (putWord8 0 >> putWord8 0 >> putWord8 0xFE >> putWord64le maxBound >> putWord16le 2 >> putWord16le 0)
        result <- getFromPacket getOK (Packet (L.length body) 1 body)
        equal "unsigned ID" (18446744073709551615 :: Integer) (fromIntegral (okLastInsertID result))
    , packetCase "column-definition-roundtrip" $ do
        let col=mkColumn mySQLTypeLong
        result <- decodeFromPacket (encodeToPacket 1 col)
        equal "column definition" col result
    , packetCase "binary-plugin-challenge" $ do
        let nonce=B.pack ([1..9] ++ [0] ++ [11..32])
            body=runPut $ do
                putWord8 10; putByteString "13.2.0-MariaDB"; putWord8 0
                putWord32le 1; putByteString (B.take 8 nonce); putWord8 0
                putWord16le 0x8200; putWord8 45; putWord16le 2; putWord16le 8
                putWord8 32; putByteString (B.replicate 10 0)
                putByteString (B.drop 8 nonce); putByteString "client_ed25519"; putWord8 0
        greeting <- getFromPacket getGreeting (Packet (L.length body) 0 body)
        equal "binary challenge" nonce (greetingSalt1 greeting <> greetingSalt2 greeting)
        equal "plugin identity" "client_ed25519" (greetingAuthPlugin greeting)
    , packetCase "unknown-plugin-rejected" $
        expectRejection (evaluate (B.length (C.scrambleForPlugin "unknown_mariadb_plugin" "12345678901234567890" "password")))
    , packetCase "native-extension-handshake" $
        assert (not (testBit clientCap 0)) "CLIENT_MYSQL legacy marker is still advertised"
    , packetCase "prepared-out-capability" $
        assert (testBit clientCap 18) "CLIENT_PS_MULTI_RESULTS is absent"
    , packetCase "empty-packet-predicate" $ do
        outcome <- try (evaluate (isEOF (Packet 0 1 L.empty)))
        case outcome of
            Left (_ :: SomeException) -> throwIO (userError "empty packet crashes classifier")
            Right value -> equal "empty is not EOF" False value
    , packetCase "text-field-trailing-data" $ do
        let p=putToPacket 1 (putLenEncBytes "1x")
        expectRejection (getFromPacket (getTextField (mkColumn mySQLTypeLong)) p)
    , packetCase "text-field-integer-overflow" $ do
        let p=putToPacket 1 (putLenEncBytes "256")
        expectRejection (getFromPacket (getTextField (mkColumn mySQLTypeTiny)) p)
    , packetCase "reset-does-not-consume-pending-row" $ do
        consumed <- newIORef False
        input <- S.fromList [Packet 5 4 (L.pack [0,0,1,0,0]), encodeToPacket 5 (EOF 0 2), encodeToPacket 1 (OK 0 0 2 0)]
        let conn=C.MySQLConn input (const (pure ())) (pure ()) consumed
        result <- try (resetStmt conn 1) :: IO (Either SomeException ())
        case result of
            Left _ -> pure ()
            Right () -> do
                pending <- S.toList input
                assert (null pending) "reset marked connection reusable with prior result/reset packets still unread"
    ] ++
    [ packetCase ("null-bitmap-" ++ show n) $ do
        let values=take n (cycle [MySQLNull,MySQLInt32 7])
            bitmap=makeNullMap values
        forM_ (zip [0..] values) $ \(i,v) -> equal "parameter NULL bit" (v==MySQLNull) (isColumnSet bitmap i)
    | n <- [0,1,2,7,8,9,15,16,17,63,64,65]
    ]
