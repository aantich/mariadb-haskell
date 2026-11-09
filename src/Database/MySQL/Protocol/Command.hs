{-# OPTIONS_GHC -funbox-strict-fields #-}

{-|
Module      : Database.MySQL.Protocol.Command
Description : MySQL commands
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : PORTABLE

Common MySQL commands supports.

-}

module Database.MySQL.Protocol.Command where

import           Control.Monad
import           Data.Binary
import           Data.Binary.Get
import           Data.Binary.Parser
import           Data.Binary.Put
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString.Lazy               as L
import           Database.MySQL.Protocol.MySQLValue
import           Database.MySQL.Protocol.Packet

--------------------------------------------------------------------------------
--  Commands

type StmtID = Word32

-- | One cell in a MariaDB binary bulk batch. NULL is 'BulkValue MySQLNull'.
-- DEFAULT and IGNORE are wire indicators, not SQL text; IGNORE means a default
-- on INSERT and leaves that column unchanged on UPDATE.
data BulkParameter = BulkValue !MySQLValue | BulkDefault | BulkIgnore
    deriving (Show, Eq)

-- | EXECUTE binding descriptors. Uploaded values carry a type but no inline
-- bytes. Preserve text versus binary semantics even though both upload through
-- COM_STMT_SEND_LONG_DATA; their server collations need not be the same.
data ExecuteParameter = ExecuteValue !MySQLValue | UploadedBytes | UploadedText
    deriving (Show, Eq)

-- | Type exemplar and NULL-bitmap value for an EXECUTE binding. Empty uploaded
-- parameters remain non-NULL; these exemplars are never sent as inline values.
executeParameterValue :: ExecuteParameter -> MySQLValue
executeParameterValue (ExecuteValue value) = value
executeParameterValue UploadedBytes = MySQLBytes ""
executeParameterValue UploadedText = MySQLText ""

-- | All support MySQL commands.
--
data Command
    = COM_QUIT                                    -- ^ 0x01
    | COM_INIT_DB        !ByteString              -- ^ 0x02
    | COM_QUERY          !L.ByteString            -- ^ 0x03
    | COM_PING                                    -- ^ 0x0E
    | COM_BINLOG_DUMP    !Word32 !Word16 !Word32 !ByteString -- ^ 0x12
            -- binlog-pos, flags(0x01), server-id, binlog-filename
    | COM_REGISTER_SLAVE !Word32 !ByteString !ByteString !ByteString !Word16 !Word32 !Word32 -- ^ 0x15
            -- server-id, slaves hostname, slaves user, slaves password,  slaves port, replication rank(ignored), master-id(usually 0)
    | COM_STMT_PREPARE   !L.ByteString            -- ^ 0x16 statement
    | COM_STMT_EXECUTE   !StmtID ![MySQLValue] !BitMap -- ^ 0x17 stmtId, params
    | COM_STMT_EXECUTE_EXT !StmtID !Word8 ![ExecuteParameter] !BitMap
      -- ^ 0x17: cursor flag and typed inline/uploaded parameters.
    | COM_STMT_SEND_LONG_DATA !StmtID !Word16 !ByteString
      -- ^ 0x18: statement, zero-based parameter index, one chunk; no reply.
    | COM_STMT_CLOSE     !StmtID                  -- ^ 0x19 stmtId
    | COM_STMT_RESET     !StmtID                  -- ^ 0x1A stmtId
    | COM_STMT_FETCH     !StmtID !Word32          -- ^ 0x1C: read-only cursor batch.
    | COM_RESET_CONNECTION                       -- ^ 0x1F; use the guarded reset API.
    | COM_STMT_BULK_EXECUTE !StmtID !Word16 ![MySQLValue] ![[BulkParameter]]
      -- ^ 0xFA: statement, flags, one type exemplar per column, batch rows.
    | COM_UNSUPPORTED
   deriving (Show, Eq)

putCommand :: Command -> Put
putCommand COM_QUIT              = putWord8 0x01
putCommand (COM_INIT_DB db)      = putWord8 0x02 >> putByteString db
putCommand (COM_QUERY q)         = putWord8 0x03 >> putLazyByteString q
putCommand COM_PING              = putWord8 0x0E
putCommand (COM_BINLOG_DUMP pos flags sid fname) = do
    putWord8 0x12
    putWord32le pos
    putWord16le flags
    putWord32le sid
    putByteString fname
putCommand (COM_REGISTER_SLAVE sid shost susr spass sport rrank mid) = do
    putWord8 0x15
    putWord32le sid
    putLenEncBytes shost
    putLenEncBytes susr
    putLenEncBytes spass
    putWord16le sport
    putWord32le rrank
    putWord32le mid
putCommand (COM_STMT_PREPARE stmt) = putWord8 0x16 >> putLazyByteString stmt
putCommand (COM_STMT_EXECUTE stid params nullmap) = do
    -- Preserve the ordinary encoder's direct value path: uploaded/cursor
    -- descriptors must not add a wrapper/list allocation to existing callers.
    putExecuteHeader stid 0
    unless (null params) $ do
        putByteString (fromBitMap nullmap)
        putWord8 1
        mapM_ putParamMySQLType params
        mapM_ putBinaryField params
putCommand (COM_STMT_EXECUTE_EXT stid flags params nullmap) =
    putExecute stid flags params nullmap
putCommand (COM_STMT_SEND_LONG_DATA ident parameter bytes) =
    putWord8 0x18 >> putWord32le ident >> putWord16le parameter >> putByteString bytes
putCommand (COM_STMT_FETCH ident count) = putWord8 0x1c >> putWord32le ident >> putWord32le count
putCommand (COM_STMT_CLOSE stid) = putWord8 0x19 >> putWord32le stid
putCommand (COM_STMT_RESET stid) = putWord8 0x1A >> putWord32le stid
putCommand COM_RESET_CONNECTION = putWord8 0x1f
putCommand (COM_STMT_BULK_EXECUTE ident flags types rows) = do
    putWord8 0xfa
    putWord32le ident
    putWord16le flags
    mapM_ putParamMySQLType types
    forM_ rows $ mapM_ $ \cell -> case cell of
        BulkValue MySQLNull -> putWord8 1
        BulkValue value -> putWord8 0 >> putBinaryField value
        BulkDefault -> putWord8 2
        BulkIgnore -> putWord8 3
putCommand _                     = error "unsupported command"

-- Uploaded parameters still have a type descriptor, but no inline value.
-- Their NULL bit must be clear, including when the uploaded value is empty.
putExecute :: StmtID -> Word8 -> [ExecuteParameter] -> BitMap -> Put
putExecute stid flags params nullmap = do
    putExecuteHeader stid flags
    unless (null params) $ do
        putByteString (fromBitMap nullmap)
        putWord8 0x01    -- always use new-params-bound-flag
        mapM_ (putParamMySQLType . executeParameterValue) params
        forM_ params $ \parameter -> case parameter of
            ExecuteValue value -> putBinaryField value
            _ -> pure ()

-- | Fixed EXECUTE header shared without wrapping ordinary scalar parameters.
putExecuteHeader :: StmtID -> Word8 -> Put
putExecuteHeader ident flags = putWord8 0x17 >> putWord32le ident >>
    putWord8 flags >> putWord32le 1

--------------------------------------------------------------------------------
--  Prepared statment related

-- | call 'isOK' with this packet return true
data StmtPrepareOK = StmtPrepareOK
    { stmtId        :: !StmtID
    , stmtColumnCnt :: !Int
    , stmtParamCnt  :: !Int
    , stmtWarnCnt   :: !Int
    } deriving (Show, Eq)

getStmtPrepareOK :: Get StmtPrepareOK
getStmtPrepareOK = do
    skipN 1 -- OK byte
    stmtid <- getWord32le
    cc <- fromIntegral <$> getWord16le
    pc <- fromIntegral <$> getWord16le
    skipN 1 -- reserved
    wc <- fromIntegral <$> getWord16le
    return (StmtPrepareOK stmtid cc pc wc)
{-# INLINE getStmtPrepareOK #-}
