{-|
Module      : Database.MySQL.BinLog
Description : MariaDB CDC, GTID resume and controlled acknowledgements
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : Anton Antich <anton.antich@gmail.com>
Stability   : experimental
Portability : PORTABLE

Use 'openCDC' for a bounded, pull-driven row-based change stream. Configure
MariaDB binary logging, row format, retention and replication grants separately.
Choose a unique nonzero replica ID and dedicate one connection/thread to the
stream. Stream termination or failure closes/retires that connection.

'FromGtid' uses MariaDB @domain-server-sequence@ state, not UUID intervals.
Checkpoints describe completed decoded groups; they prove no destination
durability. Apply events and atomically persist destination changes with the
exported resume state before 'cdcAcknowledge'. The driver supplies neither
persistence nor an exactly-once destination protocol. Manual ACKs require
server semisync; legacy 'dumpBinLog' on-read ACKs mean receipt only.

Persist 'checkpointPosition' or 'checkpointGtids', never an opaque token's
@Show@ representation. Reopen a fresh connection after interruption and resume
from durable coordinates. Table metadata/event expansion are bounded; the
consumer must also avoid buffering unbounded transaction groups.

Advanced XA checkpointing, two-phase ALTER and storage-engine-binlog GTID
semisync are unsupported. Unknown non-ignorable events fail closed. Traditional
file dump starts have a 32-bit wire limit even though checkpoint positions are
64-bit. See the
<https://github.com/aantich/mariadb-haskell/blob/main/docs/USER_GUIDE.md CDC user guide>
and <https://github.com/aantich/mariadb-haskell/blob/main/examples/GuideExamples.hs consumer example>.
-}

module Database.MySQL.BinLog
    ( -- * binlog utilities
      SlaveID
    , BinLogTracker(..)
    , registerPesudoSlave
    , dumpBinLog
    , BinLogStart(..), AcknowledgementMode(..), CDCOptions(..), defaultCDCOptions
    , CDCStream(..), openCDC, resumeFromCheckpoint
    , module Database.MySQL.BinLogProtocol.CDC
    , RowBinLogEvent(..)
    , decodeRowBinLogEvent
    -- * helpers
    , getLastBinLogTracker
    , isCheckSumEnabled
    , isSemiSyncEnabled
    -- * re-export
    , module Database.MySQL.BinLogProtocol.BinLogEvent
    , module Database.MySQL.BinLogProtocol.BinLogValue
    , module Database.MySQL.BinLogProtocol.BinLogMeta
    ) where

import           Control.Exception                         (throwIO, mask, mask_, onException, finally)
import           Control.Monad
import           Data.ByteString                           (ByteString)
import           Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import           Database.MySQL.BinLogProtocol.CDC
import           Data.IORef                                (IORef, newIORef,
                                                            readIORef,
                                                            writeIORef)
import           Data.Text.Encoding                        (encodeUtf8)
import           Data.Word
import           Database.MySQL.Base
import           Database.MySQL.BinLogProtocol.BinLogEvent
import           Database.MySQL.BinLogProtocol.BinLogMeta
import           Database.MySQL.BinLogProtocol.BinLogValue
import           Database.MySQL.Connection
import           GHC.Generics                              (Generic)
import           System.IO.Streams                         (InputStream)
import qualified System.IO.Streams                         as Stream

-- | Unique nonzero replica server ID chosen by the application.
type SlaveID = Word32

-- | File-based start coordinate. The next-position field is 64-bit to preserve
-- observed positions; opening the legacy dump command rejects values over its
-- 32-bit start limit rather than truncating them.
data BinLogTracker = BinLogTracker
    { btFileName :: {-# UNPACK #-} !ByteString
    , btNextPos  :: {-# UNPACK #-} !Word64
    } deriving (Show, Eq, Generic)

-- | Register a replica with MariaDB using COM_REGISTER_SLAVE. The historical
-- function name is retained for API compatibility. Registration is optional
-- for a dump connection; choose a unique nonzero replica ID either way.
registerPesudoSlave :: MySQLConn -> SlaveID -> IO OK
registerPesudoSlave conn sid = command conn (COM_REGISTER_SLAVE sid "" "" "" 0 0 0)

-- | Dedicate the connection to binlog listening. Consume the returned stream on
-- the calling thread; other commands are rejected while it is 'Replicating'.
-- Setup/stream failures retire the connection. End-of-stream closes it, because
-- replication has a distinct packet-sequence policy from ordinary commands.
--
dumpBinLog :: MySQLConn               -- ^ connection to be listened
           -> SlaveID                 -- ^ a number for our pesudo slave.
           -> BinLogTracker           -- ^ binlog position
           -> Bool                    -- ^ if master support semi-ack, do we want to enable it?
                                      -- if master doesn't support, this parameter will be ignored.
           -> IO (FormatDescription, IORef ByteString, InputStream BinLogPacket)
                -- ^ t'FormatDescription', 'IORef' contains current binlog filename, t'BinLogPacket' stream.
dumpBinLog conn sid tracker wantAck = do
    let mode = if wantAck then AcknowledgeOnRead else AcknowledgementsDisabled
    (fmt, ref, packets, _) <- openPackets conn sid
        (defaultCDCOptions (FromBinLog tracker)) { cdcAcknowledgements = mode }
    legacy <- Stream.makeInputStream $ do
        value <- Stream.read packets
        case value of
            Nothing -> close conn >> pure Nothing
            Just event -> pure (Just event)
    pure (fmt, ref, legacy)

-- | Explicit start position. GTID sets contain only previously completed
-- transactions; the server selects the next available group, including across
-- file rotations. Purged history is an error, never a silent fallback.
data BinLogStart = FromBinLog !BinLogTracker | FromGtid !GtidSet deriving (Eq, Show)

-- | Manual mode never acknowledges during reading. The legacy on-read mode
-- acknowledges receipt only and must not be used as a durability guarantee.
data AcknowledgementMode = AcknowledgementsDisabled | AcknowledgeManually | AcknowledgeOnRead
    deriving (Eq, Show)

-- | Replication setup and decoding bounds. Nonblocking mode finishes at the
-- server's current log end; ordinary blocking streams wait for further work.
data CDCOptions = CDCOptions
    { cdcStart :: !BinLogStart
      -- ^ Proven file coordinate or completed MariaDB GTID state.
    , cdcAcknowledgements :: !AcknowledgementMode
      -- ^ Disabled by default. 'openCDC' accepts manual or disabled mode only.
    , cdcNonBlocking :: !Bool
      -- ^ End at the server's current log end instead of waiting for new events.
    , cdcDecodeLimits :: !DecodeLimits
      -- ^ Independent retained-table-metadata and event-expansion budgets.
    , cdcBootstrapEventLimit :: !Int
      -- ^ Maximum setup events before format/checksum state is established.
    } deriving (Eq, Show)

-- | Blocking, no acknowledgements, bounded decoding and at most 1024 setup
-- events. Register a unique nonzero replica server ID at the application level.
defaultCDCOptions :: BinLogStart -> CDCOptions
defaultCDCOptions start = CDCOptions start AcknowledgementsDisabled False defaultDecodeLimits 1024

-- | Choose the proven resume mechanism for a completed checkpoint. File-started
-- streams retain file coordinates; GTID-started streams retain their full domain
-- state. Call 'openCDC' on a fresh connection; this helper performs no I/O.
resumeFromCheckpoint :: CDCCheckpoint -> BinLogStart
resumeFromCheckpoint token = case checkpointGtids token of
    Just gtids -> FromGtid gtids
    Nothing -> let position = checkpointPosition token
               in FromBinLog (BinLogTracker (binlogFile position) (binlogNextPosition position))

-- | Single-thread-owned change stream. 'cdcLatestCheckpoint' observes a
-- decoded complete-group boundary while the stream is active, not application durability. Persist it
-- atomically with destination changes before calling 'cdcAcknowledge'. Closing
-- is terminal; reopening/resuming always uses a fresh connection.
data CDCStream = CDCStream
    { cdcEvents :: !(InputStream CDCEvent)
      -- ^ Consume once on the opening thread; backpressure is controlled by reads.
    , cdcLatestCheckpoint :: !(IO (Maybe CDCCheckpoint))
      -- ^ Latest complete decoded group, independent of destination durability.
    , cdcAcknowledge :: !(CDCCheckpoint -> IO ())
      -- ^ Acknowledge a durable active-stream checkpoint; never an arbitrary token.
    , cdcClose :: !(IO ())
      -- ^ Terminal close of the dedicated connection, also used by brackets.
    }

-- | Dedicate a connection to MariaDB CDC. Stream decoding and acknowledgement
-- failures retire the transport. Cancellation never retries SQL or advances a
-- checkpoint. Manual acknowledgements require server semisync to be enabled;
-- acknowledgement tokens belong to this stream and cannot refer to future or
-- incomplete transactions. Semisync acknowledges replica receipt, not an
-- exactly-once destination commit protocol.
openCDC :: MySQLConn -> SlaveID -> CDCOptions -> IO CDCStream
openCDC conn sid options = mask $ \restore -> do
    when (cdcAcknowledgements options == AcknowledgeOnRead)
        (throwIO (CDCInvalidConfiguration "openCDC requires manual or disabled acknowledgements"))
    (fd, ref, packets, generation) <- restore (openPackets conn sid options)
    initialFile <- readIORef ref
    let initialGtids = case cdcStart options of
            FromGtid entries -> Just entries
            FromBinLog _ -> Nothing
    (decoded, latest) <- newCDCDecoder (cdcDecodeLimits options) initialGtids fd initialFile packets
        `onException` abortConnection conn False
    finished <- newIORef False
    guarded <- Stream.makeInputStream $ do
        done <- readIORef finished
        if done then pure Nothing else streamGuard conn generation $ do
            value <- Stream.read decoded
            case value of
                Nothing -> writeIORef finished True >> close conn >> pure Nothing
                Just event -> pure (Just event)
    acknowledged <- newIORef Nothing
    let acknowledge token = do
            streamGuard conn generation (pure ())
            -- Invalid tokens are local misuse: reject without poisoning a
            -- healthy replication session or transmitting bytes.
            unless (cdcAcknowledgements options == AcknowledgeManually)
                (throwIO (CDCInvalidCheckpoint "manual acknowledgements are disabled"))
            current <- latest
            unless (maybe False (`validCheckpoint` token) current)
                (throwIO (CDCInvalidCheckpoint "checkpoint does not belong to delivered stream history"))
            prior <- readIORef acknowledged
            case prior of
                Just previous | previous == token -> pure ()
                Just previous | not (validCheckpoint token previous) ->
                    throwIO (CDCInvalidCheckpoint "checkpoint would move acknowledgement backwards")
                _ -> streamGuard conn generation $ mask_ $ do
                    let position = checkpointPosition token
                    sendSemiAck conn (binlogNextPosition position) (binlogFile position)
                    writeIORef acknowledged (Just token)
    pure (CDCStream guarded (streamGuard conn generation latest) acknowledge (close conn))

-- Semisync ACKs are independent no-reply exchanges, even when compressed.
-- Reset only the outgoing frame counter: buffered incoming bytes must survive.
-- openPackets installs the replication receive policy before reading events.
sendSemiAck :: MySQLConn -> Word64 -> ByteString -> IO ()
sendSemiAck conn position file = do
    connectionCompressionReset conn
    mysqlWrite conn (putToPacket 0 (putSemiAckResp position file))

-- Both legacy and transaction-aware interfaces use the same checked wire
-- reader. The low capability value deliberately avoids advertising MariaDB
-- storage-engine-binlog/GTID semisync extensions that this file-position ACK
-- implementation does not support.
openPackets :: MySQLConn -> SlaveID -> CDCOptions
            -> IO (FormatDescription, IORef ByteString, InputStream BinLogPacket, Word64)
openPackets conn sid options = do
    let limits = cdcDecodeLimits options
    when (sid == 0 || cdcBootstrapEventLimit options <= 0 || maxTableMaps limits <= 0
          || maxTableMapBytes limits <= 0 || maxExpandedEventBytes limits <= 0)
        (throwIO (CDCInvalidConfiguration "invalid CDC server ID/resource limits"))
    (initialFile, initialPosition) <- case cdcStart options of
        FromBinLog (BinLogTracker file position) -> do
            when (B.null file || B.length file > 512 || B.elem 0 file || position < 4
                  || position > fromIntegral (maxBound :: Word32))
                (throwIO (CDCInvalidConfiguration "invalid/out-of-range COM_BINLOG_DUMP position"))
            pure (file, fromIntegral position)
        FromGtid entries -> do
            when (B.length (renderGtidSet entries) > 65535)
                (throwIO (CDCInvalidConfiguration "GTID connect state is too large"))
            pure ("", 4)
    mask $ \restore -> do
        guardUnconsumed conn
        beginTransactionLease conn
        (restore (setup initialFile initialPosition limits) `onException` abortConnection conn False)
            `finally` endTransactionLease conn
  where
    setup initialFile initialPosition limits = do
        semi <- if cdcAcknowledgements options == AcknowledgementsDisabled then pure False else isSemiSyncEnabled conn
        when (cdcAcknowledgements options == AcknowledgeManually && not semi)
            (throwIO (CDCUnsupportedFeature "manual ACK requested but MariaDB semisync is not enabled"))
        let needAck = semi && cdcAcknowledgements options /= AcknowledgementsDisabled
        -- One SET restores all replication setup variables atomically. GTID
        -- text is generated exclusively from validated numeric identities, so
        -- the SQL is ASCII-only and cannot depend on an unknown client charset
        -- or SQL mode. No user-provided SQL bytes are interpolated here.
        let connectState = case cdcStart options of
                FromGtid entries -> "'" <> renderGtidSet entries <> "'"
                FromBinLog _ -> "NULL"
            setupSQL = "SET @mariadb_slave_capability=4,@slave_gtid_strict_mode=1,@slave_gtid_ignore_duplicates=0,@slave_connect_state="
                <> connectState <> ",@master_binlog_checksum='CRC32',@rpl_semi_sync_slave=" <> if needAck then "1" else "0"
        void $ execute_ conn (Query (L.fromStrict setupSQL))
        -- Declaring CRC32 support also makes the artificial initial ROTATE
        -- checksummed. Subsequent files choose their mode in their own FDE,
        -- which can differ from the server's current global setting.
        checksumState <- newIORef True
        -- Apply the CDC ceiling while assembling a logical message, so an
        -- oversized first fragment cannot make us read more continuations.
        -- Word64 arithmetic also permits maxBound Int without signed overflow.
        -- Physical bodies remain bounded before reading by ConnectionOptions.
        let wireLimit = min (maximumMessageBytes (connectionOptions conn))
                (fromIntegral (maxExpandedEventBytes limits) + 1024)
        withCommand conn $ do
            let flags = (if cdcNonBlocking options then 1 else 0) .|. 2
            sendCommand conn (COM_BINLOG_DUMP initialPosition flags sid initialFile)
            generation <- markResponseStream conn Replicating
            setExchangeSequence conn 256
            when needAck (connectionCompressionAllowReplicationResets conn)
            let readEvent = do
                    packet <- readPacketWithLimit wireLimit (mysqlRead conn)
                    if | isOK packet -> do
                           checksum <- readIORef checksumState
                           event <- getFromPacket (getBinLogPacket checksum needAck) packet
                           when (blEventType event == BINLOG_FORMAT_DESCRIPTION_EVENT) $ do
                               -- FDE always carries a CRC, even when its
                               -- descriptor turns checksums off for this file.
                               void (getFromBinLogPacket getFormatDescription event)
                               writeIORef checksumState (L.last (blBody event) == 1)
                           pure (Just event)
                       | isEOF packet -> pure Nothing
                       | isERR packet -> decodeFromPacket packet >>= throwIO . ERRException
                       | otherwise -> throwIO (UnexpectedPacket packet)
                findType remaining typ = do
                    when (remaining <= 0) (throwIO (CDCResourceLimit "CDC bootstrap event limit exceeded"))
                    packet <- readEvent
                    case packet of
                        Nothing -> throwIO NetworkException
                        Just value | blEventType value == typ -> pure value
                                   | blEventType value `elem` [BINLOG_HEARTBEAT_EVENT,BINLOG_IGNORABLE_EVENT]
                                   || blFlags value .&. 0x80 /= 0 -> findType (remaining - 1) typ
                               | otherwise -> throwIO (CDCDecodeError "unexpected data event during CDC bootstrap")
            rotationPacket <- findType (cdcBootstrapEventLimit options) BINLOG_ROTATE_EVENT
            rotation <- getFromBinLogPacket getRotateEvent rotationPacket
            ref <- newIORef (B.copy (rFileName rotation))
            formatPacket <- findType (cdcBootstrapEventLimit options) BINLOG_FORMAT_DESCRIPTION_EVENT
            fd <- getFromBinLogPacket getFormatDescription formatPacket
            let autoAck packet = when (needAck && blSemiAck packet && cdcAcknowledgements options == AcknowledgeOnRead) $ do
                    file <- readIORef ref
                    sendSemiAck conn (blLogPos packet) file
            autoAck formatPacket
            finished <- newIORef False
            packets <- Stream.makeInputStream $ do
                done <- readIORef finished
                if done then pure Nothing else streamGuard conn generation $ do
                    next <- readEvent
                    case next of
                        Nothing -> writeIORef finished True >> pure Nothing
                        Just event -> do
                            when (blEventType event == BINLOG_ROTATE_EVENT) $ do
                                value <- getFromBinLogPacket getRotateEvent event
                                writeIORef ref (B.copy (rFileName value))
                            autoAck event
                            pure (Just event)
            pure (fd, ref, packets, generation)

-- | Legacy row-only view. Trackers after individual rows are not transaction
-- checkpoints: persisting one may resume in the middle of a transaction.
-- Use 'openCDC' for transaction boundaries, MariaDB annotations and safe resume.
-- The first field is the server event timestamp in seconds.
data RowBinLogEvent
    = RowQueryEvent  {-# UNPACK #-} !Word32 !BinLogTracker !QueryEvent'
    | RowDeleteEvent {-# UNPACK #-} !Word32 !BinLogTracker !TableMapEvent !DeleteRowsEvent
    | RowWriteEvent  {-# UNPACK #-} !Word32 !BinLogTracker !TableMapEvent !WriteRowsEvent
    | RowUpdateEvent {-# UNPACK #-} !Word32 !BinLogTracker !TableMapEvent !UpdateRowsEvent
  deriving (Show, Eq, Generic)

-- | Decode the legacy row-only view with bounded table-ID metadata. The input
-- is single-consumer. Bracket the connection lifetime: semantic decoding errors
-- propagate from this offline adapter, which has no connection to retire.
-- Byte-valued row fields may share event storage; copy small retained fields
-- when keeping them beyond consumption of their containing event.
decodeRowBinLogEvent :: (FormatDescription, IORef ByteString, InputStream BinLogPacket)
                     -> IO (InputStream RowBinLogEvent)
decodeRowBinLogEvent (fd, ref, input) = do
    file <- readIORef ref
    (events, _) <- newCDCDecoder defaultDecodeLimits Nothing fd file input
    let next = do
            event <- Stream.read events
            case event of
                Nothing -> pure Nothing
                Just value -> do
                    let BinLogPosition name position = cdcEventPosition value
                        tracker = BinLogTracker name position
                        stamp = cdcEventTimestamp value
                    case cdcEventPayload value of
                        CDCRowQuery rowQuery -> pure (Just (RowQueryEvent stamp tracker rowQuery))
                        CDCWrite table row -> pure (Just (RowWriteEvent stamp tracker table row))
                        CDCUpdate table row -> pure (Just (RowUpdateEvent stamp tracker table row))
                        CDCDelete table row -> pure (Just (RowDeleteEvent stamp tracker table row))
                        _ -> next
    Stream.makeInputStream next

-- | Get latest master's binlog filename and position.
--
getLastBinLogTracker :: MySQLConn -> IO (Maybe BinLogTracker)
getLastBinLogTracker conn = do
    (_, is) <- query_ conn "SHOW MASTER STATUS"
    row <- Stream.read is
    Stream.skipToEof is
    case row of
        Just (MySQLText fn : MySQLInt64U pos : _) -> return . Just $ BinLogTracker (encodeUtf8 fn) pos
        _                                         -> return Nothing

-- | Return True if binlog_checksum = CRC32. MariaDB CRC32 mode
--
isCheckSumEnabled :: MySQLConn -> IO Bool
isCheckSumEnabled conn = do
    (_, is) <- query_ conn "SHOW GLOBAL VARIABLES LIKE 'binlog_checksum'"
    row <- Stream.read is
    Stream.skipToEof is
    case row of
        Just [_, MySQLText "CRC32"] -> return True
        _                           -> return False

-- | Return True if rpl_semi_sync_master_enabled = ON. MariaDB semisynchronous replication
--
isSemiSyncEnabled :: MySQLConn -> IO Bool
isSemiSyncEnabled conn = do
    (_, is) <- query_ conn "SHOW VARIABLES LIKE 'rpl_semi_sync_master_enabled'"
    row <- Stream.read is
    Stream.skipToEof is
    case row of
        Just [_, MySQLText "ON"] -> return True
        _                        -> return False
