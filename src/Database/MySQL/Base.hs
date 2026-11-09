{-# LANGUAGE ScopedTypeVariables #-}
{-|
Module      : Database.MySQL.Base
Description : Public MariaDB connection, query and transaction API
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : PORTABLE

One connection admits one command or unfinished result stream at a time. Read a
stream on the thread that created it and consume it before issuing another
command. Use separate connections for concurrent work.

A complete 'ERRException' leaves the wire synchronized, but invalidates cached
session facts. Explicitly call 'refreshSessionState' before rendering further
text parameters. Transport failures, malformed replies and cancellation during
I/O retire the connection; inspect 'connectionStatus' and open a new connection.

'WrongParamsCount' reports placeholder arity errors. 'ExtraResultSets' means a
single-result API drained results that it could not return. 'withTransaction'
documents rollback and uncertain-COMMIT behavior separately.

-}
module Database.MySQL.Base
    ( -- * Setting up and control connection
      MySQLConn
    , ConnectInfo(..)
    , ConnectionOptions(..)
    , defaultConnectionOptions
    , connectWithOptions
    , connectDetailWithOptions
    , connectUnixSocketWithOptions
    , connectUnixSocketDetailWithOptions
    , ConnectionStatus(..)
    , ConnectionFailure(..)
    , ConnectionError(..)
    , connectionStatus
    , connectionFailure
    , Progress(..)
    , setProgressCallback
    , resetConnection
    , resetConnectionWith
    , getSessionState
    , SessionState(..)
    , SessionChange(..)
    , refreshSessionState
    , getRenderContext
    , RenderContext(..)
    , defaultRenderContext
    , ParameterError(..)
    , defaultConnectInfo
    , defaultConnectInfoMB4
    , connect
    , connectDetail
    , connectUnixSocket
    , connectUnixSocketDetail
    , close
    , ping
      -- * Direct query
    , execute
    , executeMany
    , executeMany_
    , execute_
    , query_
    , queryVector_
    , query
    , queryVector
    , queryMulti_
    , queryMulti
    , StatementResult(..)
      -- * Prepared query statement
    , prepareStmt
    , prepareStmtDetail
    , executeStmt
    , queryStmt
    , queryStmtVector
    , closeStmt
    , resetStmt
    , PreparedStatement
    , StatementException(..)
    , prepareStatement
    , withPreparedStatement
    , preparedMetadata
    , closePrepared
    , resetPrepared
    , queryPrepared
    , executePrepared
    , PreparedParameter(..)
    , executePreparedStream
    , queryPreparedStream
    , queryPreparedStreamMulti
    , PreparedCursor
    , openCursor
    , openCursorStream
    , fetchCursor
    , closeCursor
    , cursorExhausted
    , withCursor
    , withCursorStream
    , queryStmtMulti
    , queryPreparedMulti
    , PreparedResult(..)
    , executeBulk
    , executeBulkUnitResults
    , BulkUnitResult(..)
      -- * Helpers
    , withTransaction
    , QueryParam(..)
    , Param (..)
    , Query(..)
    , renderParams
    , command
    , Stream.skipToEof
      -- * Exceptions
    , NetworkException(..)
    , AuthException(..)
    , UnconsumedResultSet(..)
    , ERRException(..)
    , UnexpectedPacket(..)
    , DecodePacketException(..)
    , CompressionException(..)
    , WrongParamsCount(..)
    , ExtraResultSets(..)
      -- * MySQL protocol
    , module  Database.MySQL.Protocol.Auth
    , module  Database.MySQL.Protocol.Command
    , module  Database.MySQL.Protocol.ColumnDef
    , module  Database.MySQL.Protocol.Packet
    , module  Database.MySQL.Protocol.MySQLValue
    ) where

import           Control.Exception
import           Control.Monad
import           Data.Binary                        (Get)
import Data.Binary.Put (runPut, putWord8)
import Data.Word (Word8, Word16, Word32, Word64)
import qualified Data.ByteString as B
import qualified Data.Text as T
import Control.Concurrent (myThreadId)
import qualified Data.IntMap.Strict as IM
import Data.List (transpose, find)
import System.Timeout (timeout)
import           Data.Bits                          ((.&.))
import           Data.IORef                         (IORef, newIORef, readIORef, writeIORef, atomicModifyIORef')
import           Database.MySQL.Connection
import           Database.MySQL.Protocol.Auth
import           Database.MySQL.Protocol.ColumnDef
import           Database.MySQL.Protocol.Command
import           Database.MySQL.Protocol.MySQLValue
import           Database.MySQL.Protocol.Packet
import           Database.MySQL.Protocol.Progress (Progress(..))
import           Database.MySQL.Protocol.Compression (CompressionException(..))

import           Database.MySQL.Session (SessionState(..), SessionChange(..))
import           Database.MySQL.Query
import           System.IO.Streams                  (InputStream)
import qualified System.IO.Streams                  as Stream
import qualified Data.Vector                        as V

--------------------------------------------------------------------------------


-- | Render parameters with the connection's current session context and execute
-- one statement. Unexpected row results are drained before 'ExtraResultSets'.
execute :: QueryParam p => MySQLConn -> Query -> [p] -> IO OK
execute conn qry values = withCommand conn $ do
    rendered <- connectedRender conn qry values
    executeCore conn (COM_QUERY (fromQuery rendered))
-- | Execute SQL bytes without parameter rendering. The caller owns SQL quoting.
execute_ :: MySQLConn -> Query -> IO OK
execute_ conn (Query qry) = withCommand conn (executeCore conn (COM_QUERY qry))
-- | Execute raw multi-statement SQL and return its OK replies. Row results are
-- drained before reporting 'ExtraResultSets'; this operation is not atomic.
executeMany_ :: MySQLConn -> Query -> IO [OK]
executeMany_ conn (Query qry) = withCommand conn $ do
    sendCommand conn (COM_QUERY qry)
    readStatementResults conn False >>= onlyOKs
-- | Compile a stable template once and send every parameter set in one command.
-- Ambiguous context-changing templates and invalid values fail before writing.
-- A later server error can leave earlier statements executed; use an explicit
-- transaction when all-or-nothing execution is required. Every server OK reply
-- is returned, including an empty/comment-only result after a final delimiter.
executeMany :: QueryParam p => MySQLConn -> Query -> [[p]] -> IO [OK]
executeMany _ _ [] = pure []
executeMany conn qry values = withCommand conn $ do
    ctx <- getRenderContext conn
    plan <- checked (compileQuery ctx qry)
    unless (planBatchSafe plan) (throwIO AmbiguousParameterizedBatch)
    writeIORef (connectionQueryEffect conn) (Just False)
    rendered <- traverse (checked . renderPlanPut ctx plan) values
    let separator
            | planTerminated plan = putWord8 10
            | otherwise = putWord8 10 >> putWord8 59
        joinBatch []=pure ()
        joinBatch [one]=one
        -- End any trailing line comment before writing the statement separator.
        -- Without the leading newline, '-- ...' or '# ...' can swallow the
        -- separator and all subsequent statements in an otherwise valid batch.
        -- A template may already end with ';', followed by an optional comment.
        -- Preserve that delimiter instead of creating an empty middle statement.
        joinBatch (one:rest)=one >> separator >> joinBatch rest
        bytes=runPut (joinBatch rendered)
    sendCommand conn (COM_QUERY bytes)
    readStatementResults conn False >>= onlyOKs

checked :: Either ParameterError a -> IO a
checked (Left ParameterCountMismatch) = throwIO WrongParamsCount
checked (Left err) = throwIO err
checked (Right value) = pure value

connectedRender :: QueryParam p => MySQLConn -> Query -> [p] -> IO Query
connectedRender conn qry values = do
    ctx <- getRenderContext conn
    plan <- checked (compileQuery ctx qry)
    -- A multi-statement template must have a stable rendering context throughout.
    when (not (planBatchSafe plan) && planMultiple plan) (throwIO AmbiguousParameterizedBatch)
    writeIORef (connectionQueryEffect conn) (Just (planOpaque plan))
    checked (renderPlan ctx plan values)

-- | Stream the first row result using checked text parameters. The stream owns
-- the connection until EOF and must be consumed on the calling thread. Later
-- row results are drained before 'ExtraResultSets'; use 'queryMulti' to keep them.
query :: QueryParam p => MySQLConn -> Query -> [p] -> IO ([ColumnDef], InputStream [MySQLValue])
query conn qry values = withCommand conn $ do
    rendered <- connectedRender conn qry values
    queryCore conn (COM_QUERY (fromQuery rendered)) False
-- | Raw-SQL variant of 'query', with the same stream ownership contract.
query_ :: MySQLConn -> Query -> IO ([ColumnDef],InputStream [MySQLValue])
query_ conn (Query qry) = withCommand conn (queryCore conn (COM_QUERY qry) False)
-- | Vector variant of 'query'; rows share the checked list decoder.
queryVector :: QueryParam p => MySQLConn -> Query -> [p] -> IO (V.Vector ColumnDef,InputStream (V.Vector MySQLValue))
queryVector conn qry values = withCommand conn $ do
    rendered <- connectedRender conn qry values
    queryVectorCore conn (COM_QUERY (fromQuery rendered)) False
-- | Raw-SQL vector stream, with the same ownership contract as 'query'.
queryVector_ :: MySQLConn -> Query -> IO (V.Vector ColumnDef,InputStream (V.Vector MySQLValue))
queryVector_ conn (Query qry) = withCommand conn (queryVectorCore conn (COM_QUERY qry) False)

-- | Results have been drained, but the selected API could not return their shape.
data ExtraResultSets = ExtraResultSets deriving (Show)
instance Exception ExtraResultSets

-- | One fully materialized statement result. Multi-result APIs retain all rows
-- in memory; use the streaming APIs for large individual result sets.
data StatementResult = StatementOK OK | StatementRows [ColumnDef] [[MySQLValue]] deriving (Show,Eq)
-- | Render a stable multi-statement template and collect every result.
queryMulti :: QueryParam p => MySQLConn -> Query -> [p] -> IO [StatementResult]
queryMulti conn qry values = withCommand conn $ do
    rendered <- connectedRender conn qry values
    sendCommand conn (COM_QUERY (fromQuery rendered))
    readStatementResults conn False
-- | Collect every result of raw multi-statement SQL, retaining its rows in memory.
queryMulti_ :: MySQLConn -> Query -> IO [StatementResult]
queryMulti_ conn (Query qry) = withCommand conn $ sendCommand conn (COM_QUERY qry) >> readStatementResults conn False

moreResults :: Word16 -> Bool
moreResults flags = flags .&. 8 /= 0

readStatementResults :: MySQLConn -> Bool -> IO [StatementResult]
readStatementResults conn binary = loop []
  where
    loop earlier = do
        packet <- readConnPacket conn
        if isERR packet then serverError conn packet
        else if isOK packet then do
            ok <- consumeOK conn packet
            let results=StatementOK ok:earlier
            if moreResults (okStatus ok) then loop results else finishResponse conn >> pure (reverse results)
        else do
            columns <- readResultColumns conn packet
            let fields = cachedFields columns
                decode=if binary then decodeBinaryRow (cachedBinaryDecoder columns) else decodeTextRow (prepareTextRow fields)
                rows acc = do
                    next <- readConnPacket conn
                    done <- isResultEnd conn next
                    if done then (,) (reverse acc) <$> consumeEnd conn next
                    else if isERR next then serverError conn next else decode next >>= \row -> rows (row:acc)
            (values,flags) <- rows []
            let results=StatementRows fields values:earlier
            if moreResults flags then loop results else finishResponse conn >> pure (reverse results)

onlyOKs :: [StatementResult] -> IO [OK]
onlyOKs = traverse $ \result -> case result of StatementOK ok -> pure ok; _ -> throwIO ExtraResultSets

executeCore :: MySQLConn -> Command -> IO OK
executeCore conn cmd = do
    sendCommand conn cmd
    packet <- readConnPacket conn
    if isERR packet then serverError conn packet
    else if isOK packet then do
        ok <- consumeOK conn packet
        extra <- if moreResults (okStatus ok) then skipFurtherResults conn (isBinaryCommand cmd) False else pure False
        finishResponse conn
        when extra (throwIO ExtraResultSets)
        pure ok
    else do
        void (readResultColumns conn packet)
        let skip = do
                next <- readConnPacket conn
                done <- isResultEnd conn next
                if done then consumeEnd conn next else if isERR next then serverError conn next else skip
        flags <- skip
        when (moreResults flags) (void (skipFurtherResults conn (isBinaryCommand cmd) True))
        finishResponse conn
        throwIO ExtraResultSets

isBinaryCommand :: Command -> Bool
isBinaryCommand (COM_STMT_EXECUTE _ _ _) = True
isBinaryCommand (COM_STMT_EXECUTE_EXT _ _ _ _) = True
isBinaryCommand (COM_STMT_BULK_EXECUTE _ _ _ _) = True
isBinaryCommand _ = False

data QueryReply = WithoutResultSet | ResultSetColumns CachedColumns

readQueryReply :: MySQLConn -> IO QueryReply
readQueryReply conn = do
    packet <- readConnPacket conn
    if isERR packet then serverError conn packet
    else if isOK packet then do
        ok <- consumeOK conn packet
        if moreResults (okStatus ok) then readQueryReply conn else finishResponse conn >> pure WithoutResultSet
    else do
        ResultSetColumns <$> readResultColumns conn packet

queryCore :: MySQLConn -> Command -> Bool -> IO ([ColumnDef],InputStream [MySQLValue])
queryCore conn cmd binary = do
    sendCommand conn cmd
    reply <- readQueryReply conn
    case reply of
        WithoutResultSet -> (,) [] <$> Stream.nullInput
        ResultSetColumns columns -> do
            let fields = cachedFields columns
                decode=if binary then decodeBinaryRow (cachedBinaryDecoder columns) else decodeTextRow (prepareTextRow fields)
            stream <- resultSetRows conn binary decode
            pure (fields,stream)

queryVectorCore :: MySQLConn -> Command -> Bool -> IO (V.Vector ColumnDef,InputStream (V.Vector MySQLValue))
queryVectorCore conn cmd binary = do
    sendCommand conn cmd
    reply <- readQueryReply conn
    case reply of
        WithoutResultSet -> (,) V.empty <$> Stream.nullInput
        ResultSetColumns columns -> do
            let fieldList = cachedFields columns
                fields=V.fromList fieldList
                decodeList=if binary then decodeBinaryRow (cachedBinaryDecoder columns) else decodeTextRow (prepareTextRow fieldList)
                decode packet = V.fromListN (cachedColumnCount columns) <$> decodeList packet
            stream <- resultSetRows conn binary decode
            pure (fields,stream)

-- The generation and owner protect both ordinary reads and rollback draining.
-- Draining validates framing/terminators but deliberately avoids decoding rows
-- that the application will never inspect. No row buffers are retained here.
resultSetRows :: MySQLConn -> Bool -> (Packet -> IO row) -> IO (InputStream row)
resultSetRows conn binary decode = do
    modern <- usesOKTerminator conn
    generation <- markStreaming conn
    finished <- newIORef False
    stream <- Stream.makeInputStream $ do
        done <- readIORef finished
        if done then pure Nothing else streamGuard conn generation $ do
            packet <- readConnPacket conn
            let ending = isResultEndFor modern packet
            if ending then do
                writeIORef finished True
                flags <- consumeEnd conn packet
                extra <- if moreResults flags then skipFurtherResults conn binary False else pure False
                finishResponse conn
                when extra (throwIO ExtraResultSets)
                pure Nothing
            else if isERR packet then writeIORef finished True >> serverError conn packet
            else Just <$> decode packet
    let drain = do
            done <- readIORef finished
            unless done $ streamGuard conn generation $ do
                packet <- readConnPacket conn
                let ending = isResultEndFor modern packet
                if ending then do
                    flags <- consumeEnd conn packet
                    when (moreResults flags) (void (skipFurtherResults conn binary False))
                    writeIORef finished True
                    finishResponse conn
                else if isERR packet then writeIORef finished True >> serverError conn packet else drain
    writeIORef (connectionDrain conn) (Just drain)
    pure stream

skipFurtherResults :: MySQLConn -> Bool -> Bool -> IO Bool
skipFurtherResults conn binary seen = do
    packet <- readConnPacket conn
    if isERR packet then serverError conn packet
    else if isOK packet then do
        ok <- consumeOK conn packet
        if moreResults (okStatus ok) then skipFurtherResults conn binary seen else pure seen
    else do
        void (readResultColumns conn packet)
        let skip = do
                row <- readConnPacket conn
                end <- isResultEnd conn row
                if end then consumeEnd conn row else if isERR row then serverError conn row else skip
        flags <- skip
        if moreResults flags then skipFurtherResults conn binary True else pure True

decodeBinaryRow :: Get [MySQLValue] -> Packet -> IO [MySQLValue]
decodeBinaryRow decoder packet = if isOK packet then decodeTextRow decoder packet else throwIO (UnexpectedPacket packet)

decodeTextRow :: Get [MySQLValue] -> Packet -> IO [MySQLValue]
decodeTextRow parser packet = do
    values <- getFromPacketExact parser packet
    -- Each constructor has strict payloads. Force the whole spine and every
    -- constructor here so invalid UTF-8/numbers fail while streamGuard still
    -- owns the response, rather than as a delayed exception in application code.
    _ <- evaluate (forceValues values)
    pure values
  where
    forceValues []=()
    forceValues (value:rest)=value `seq` forceValues rest
{-# INLINE decodeTextRow #-}

-- | Prepare server-side SQL. Statement IDs belong to this connection; close
-- them explicitly with 'closeStmt' after consuming their results.
prepareStmt :: MySQLConn -> Query -> IO StmtID
prepareStmt conn qry = do
    (StmtPrepareOK ident _ _ _,_,_) <- prepareStmtDetail conn qry
    pure ident
-- | Prepare SQL and return parameter metadata followed by result metadata.
prepareStmtDetail :: MySQLConn -> Query -> IO (StmtPrepareOK,[ColumnDef],[ColumnDef])
prepareStmtDetail conn (Query stmt) = withCommand conn $ do
    states <- statementMap conn
    when (IM.size states >= maximumPreparedStatements (connectionOptions conn))
        (throwIO (ProtocolError "prepared statement registry exceeds client limit"))
    sendCommand conn (COM_STMT_PREPARE stmt)
    packet <- readConnPacket conn
    when (isERR packet) (serverError conn packet)
    info@(StmtPrepareOK _ columns params _) <- getFromPacketExact getStmtPrepareOK packet
    let StmtPrepareOK ident _ _ _=info
    effect <- readIORef (connectionQueryEffect conn)
    prior <- readIORef (connectionOpaqueStatements conn)
    let rest=filter (/=ident) prior
    when (effect==Just True && length rest>=maximumColumns (connectionOptions conn))
        (throwIO (ProtocolError "opaque prepared statement registry exceeds bound"))
    writeIORef (connectionOpaqueStatements conn) (if effect==Just True then ident:rest else rest)
    -- Preparing alone has not executed the statement's session effects.
    writeIORef (connectionQueryEffect conn) (Just False)
    pdefs <- readColumns conn params
    metadata <- readColumnBlock conn columns
    next <- atomicModifyIORef' (connectionStatementSerial conn) $ \n ->
        if n == maxBound then (n, Nothing) else (n + 1, Just (n + 1))
    serial <- maybe (throwIO (ProtocolError "statement registration generation exhausted")) pure next
    registerStatement conn ident serial params
    retained <- storeStatementColumns conn ident 0 metadata
    pure (info,pdefs,cachedFields retained)
-- | Release a statement. This command has no server reply and cannot run while
-- a result is pending. Raw IDs cannot detect reuse by a later server statement.
closeStmt :: MySQLConn -> StmtID -> IO ()
closeStmt conn ident = withCommand conn $ do
    sendCommand conn (COM_STMT_CLOSE ident)
    forgetStatement conn ident
    atomicModifyIORef' (connectionOpaqueStatements conn) (\ids -> (filter (/=ident) ids,()))
-- | Reset a statement and consume its own reply; pending rows must be read first.
resetStmt :: MySQLConn -> StmtID -> IO ()
resetStmt conn ident = void (command conn (COM_STMT_RESET ident))
-- | Execute with binary parameters. Text values require a known client charset;
-- numeric/binary values do not require a rendering snapshot.
executeStmt :: MySQLConn -> StmtID -> [MySQLValue] -> IO OK
executeStmt conn ident values = withCommand conn $ do
    validateStmtArity conn ident values
    executeCore conn (COM_STMT_EXECUTE ident values (makeNullMap values))
-- | Stream prepared binary rows under the ownership contract of 'query'.
queryStmt :: MySQLConn -> StmtID -> [MySQLValue] -> IO ([ColumnDef],InputStream [MySQLValue])
queryStmt conn ident values = withCommand conn $ do
    validateStmtArity conn ident values
    queryCore conn (COM_STMT_EXECUTE ident values (makeNullMap values)) True
-- | Vector variant of 'queryStmt'.
queryStmtVector :: MySQLConn -> StmtID -> [MySQLValue] -> IO (V.Vector ColumnDef,InputStream (V.Vector MySQLValue))
queryStmtVector conn ident values = withCommand conn $ do
    validateStmtArity conn ident values
    queryVectorCore conn (COM_STMT_EXECUTE ident values (makeNullMap values)) True

-- | A statement bound to its creating connection and registration generation.
-- The constructor is private: a handle cannot accidentally be executed on a
-- different session, or close a new statement that reused an old numeric ID.
-- Consume streams before close/reset; terminal connection failure invalidates
-- every handle. Raw-ID functions remain available for compatibility.
data PreparedStatement = PreparedStatement !MySQLConn !StmtID !Word64

-- | Statement/parameter misuse. Closed handles, invalid fetch sizes and pending
-- batches fail before writing. 'InvalidCursorUse' can also follow a synchronized
-- non-row reply. A streamed-parameter error arising after upload begins retires
-- its incomplete connection before throwing.
data StatementException = StatementClosed | InvalidBulkBatch String
                        | InvalidPreparedParameter String | InvalidCursorUse String
    deriving (Show)
instance Exception StatementException

-- | Prepare a connection-owned handle. Its initial metadata is available through
-- 'preparedMetadata'; MariaDB may replace that metadata during later execution.
prepareStatement :: MySQLConn -> Query -> IO PreparedStatement
prepareStatement conn queryText = mask_ $ do
    (info, _, _) <- prepareStmtDetail conn queryText
    states <- statementMap conn
    case IM.lookup (fromIntegral (stmtId info)) states of
        Nothing -> throwIO StatementClosed
        Just state -> pure (PreparedStatement conn (stmtId info) (statementSerial state))

-- | Bracket a server statement. Closing a retired connection's handle is a
-- local no-op, so cleanup does not replace the query's transport exception.
-- Abandoned rows and close share one cleanup deadline. Timed I/O restores the
-- caller's masking state; lifetime transitions and failure handling stay masked.
withPreparedStatement :: MySQLConn -> Query -> (PreparedStatement -> IO a) -> IO a
withPreparedStatement conn queryText action = mask $ \restore -> do
    statement <- prepareStatement conn queryText
    outcome <- try (restore (action statement))
    case outcome of
        Right value -> cleanupPrepared restore statement >> pure value
        Left (primary :: SomeException) -> do
            cleanupPrepared restore statement `catch` \(secondary :: SomeException) -> do
                when (isCancellation secondary) (throwIO secondary)
                atomicModifyIORef' (connectionFailureRef conn)
                    (\failure -> (fmap (\f -> f {secondaryCleanupFailure=True}) failure, ()))
            throwIO primary

-- One deadline covers abandoned rows and close. A stalled or malformed drain
-- retires the transport; a new asynchronous cancellation keeps its identity.
-- Restore the caller's masking state only inside the protected timed action:
-- otherwise a continuously buffered result can run past timeout without ever
-- reaching an interruptible wait. Retirement and exception selection stay masked.
cleanupPrepared :: (IO () -> IO ()) -> PreparedStatement -> IO ()
cleanupPrepared restore statement@(PreparedStatement conn _ _) = do
    result <- try $ timeout (cleanupTimeoutMicros (connectionOptions conn)) $ restore $ do
        pending <- readIORef (connectionDrain conn)
        maybe (pure ()) id pending
        closePrepared statement
    case result of
        Right (Just ()) -> pure ()
        Right Nothing -> abortConnection conn False >> throwIO CleanupDeadlineExceeded
        Left (err :: SomeException) -> abortConnection conn False >> throwIO err

checkedStatement :: PreparedStatement -> IO StatementState
checkedStatement (PreparedStatement conn ident serial) = do
    states <- statementMap conn
    case IM.lookup (fromIntegral ident) states of
        Just state | statementSerial state == serial -> pure state
        _ -> throwIO StatementClosed

validateStmtArity :: MySQLConn -> StmtID -> [MySQLValue] -> IO ()
validateStmtArity conn ident values = do
    states <- statementMap conn
    forM_ (IM.lookup (fromIntegral ident) states) $ \state -> validateStatementValues state values

validateStatementValues :: StatementState -> [MySQLValue] -> IO ()
validateStatementValues state values =
    unless (lengthWithin (statementArity state) values == Just (statementArity state))
        (throwIO WrongParamsCount)

-- | Latest first-result metadata, including unknown MariaDB extension tags.
-- Reading metadata performs no I/O. A subsequent execution/reprepare can replace
-- it; the returned immutable snapshot remains valid for the caller.
preparedMetadata :: PreparedStatement -> IO [ColumnMetadata]
preparedMetadata statement = do
    state <- checkedStatement statement
    pure (maybe [] cachedDetails (IM.lookup 0 (statementResults state)))

-- | Idempotently release this handle only. It never closes a later registration
-- that happens to reuse the same raw statement ID.
closePrepared :: PreparedStatement -> IO ()
closePrepared statement@(PreparedStatement conn ident _) = do
    state <- try (checkedStatement statement)
    case state of
        Left StatementClosed -> pure ()
        Left err -> throwIO err
        Right _ -> withCommand conn $ do
            void (checkedStatement statement)
            sendCommand conn (COM_STMT_CLOSE ident)
            forgetStatement conn ident
            atomicModifyIORef' (connectionOpaqueStatements conn) (\ids -> (filter (/= ident) ids, ()))

-- | Clear parameter/cursor state after consuming pending rows. MariaDB retains
-- the statement's metadata-omission state on COM_STMT_RESET, so its matching
-- decoder must also remain cached. Connection reset is a different operation.
resetPrepared :: PreparedStatement -> IO ()
resetPrepared statement@(PreparedStatement conn ident _) = withCommand conn $ do
    void (checkedStatement statement)
    sendCommand conn (COM_STMT_RESET ident)
    readConnPacket conn >>= consumeCommandOK conn >> pure ()

-- | Stream the first binary row set; later row sets are drained and reported as
-- 'ExtraResultSets'. Use 'queryPreparedMulti' to retain procedure OUT/results.
queryPrepared :: PreparedStatement -> [MySQLValue] -> IO ([ColumnDef], InputStream [MySQLValue])
queryPrepared statement@(PreparedStatement conn ident _) values = withCommand conn $ do
    state <- checkedStatement statement
    validateStatementValues state values
    queryCore conn (COM_STMT_EXECUTE ident values (makeNullMap values)) True

-- | Execute a non-row statement. Unexpected row results are completely drained
-- before 'ExtraResultSets', preserving a synchronized connection.
executePrepared :: PreparedStatement -> [MySQLValue] -> IO OK
executePrepared statement@(PreparedStatement conn ident _) values = withCommand conn $ do
    state <- checkedStatement statement
    validateStatementValues state values
    executeCore conn (COM_STMT_EXECUTE ident values (makeNullMap values))

-- | A scalar binding or a one-shot source for a large binary/text parameter.
-- Text chunks use the current client charset; chunk boundaries need not match
-- wire boundaries. Sources remain owned by the caller and are never replayed
-- or closed by the driver. Empty sources bind an empty, non-NULL value with
-- the corresponding binary or text type/collation.
data PreparedParameter
    = PreparedValue !MySQLValue
    | PreparedBytes !(InputStream B.ByteString)
    | PreparedText !(InputStream T.Text)

-- Upload and EXECUTE hold the same command lease. A no-reply upload command
-- cannot acknowledge server acceptance: MariaDB can defer its error to EXECUTE.
-- Any source/encoding/cancellation failure after upload starts retires the
-- connection, preventing partially accumulated parameters from leaking into a
-- later execution. Limit arithmetic uses subtraction before adding each chunk.
uploadParameters :: PreparedStatement -> [PreparedParameter] -> IO ([ExecuteParameter], BitMap)
uploadParameters statement@(PreparedStatement conn ident _) parameters = do
    state <- checkedStatement statement
    unless (lengthWithin (statementArity state) parameters == Just (statementArity state))
        (throwIO WrongParamsCount)
    let values = map scalar parameters
        scalar (PreparedValue value) = ExecuteValue value
        scalar (PreparedBytes _) = UploadedBytes
        scalar (PreparedText _) = UploadedText
        bitmap = makeNullMap (map executeParameterValue values)
    forM_ [value | ExecuteValue value <- values] $
        either (throwIO . UnencodableParameter) pure . validateValue
    charset <- if any needsCharset parameters then renderClientCharset <$> getRenderContext conn else pure "utf8mb4"
    -- Validate ordinary text too, before consuming any one-shot input.
    forM_ values $ \value -> case value of
        ExecuteValue (MySQLText text) -> void (either (throwIO . UnencodableParameter) pure (encodeCharsetText charset text))
        _ -> pure ()
    serverLimit <- readIORef (connectionServerPacketLimit conn)
    let messageLimit = min serverLimit (maximumMessageBytes (connectionOptions conn))
        totalLimit = min serverLimit (maximumLongDataBytes (connectionOptions conn))
    when (messageLimit <= 7) (throwIO (InvalidPreparedParameter "message limit cannot hold a long-data chunk"))
    remaining <- newIORef totalLimit
    let chunkSize = fromIntegral (min 65536 (messageLimit - 7))
        send index bytes = do
            left <- readIORef remaining
            when (fromIntegral (B.length bytes) > left)
                (throwIO (InvalidPreparedParameter "streamed parameters exceed byte limit"))
            writeIORef remaining (left - fromIntegral (B.length bytes))
            sendCommand conn (COM_STMT_SEND_LONG_DATA ident index bytes)
        upload index source = do
            -- Even a source with no chunks must set MariaDB's long-data state.
            send index B.empty
            -- A source's chunk size is an application detail. Coalesce small
            -- chunks to avoid one command/builder allocation per tiny read,
            -- while bounding retained payload to 64 KiB and segment metadata
            -- to 1024 entries. Large input chunks are sliced without copying.
            let flush [one] = send index one
                flush chunks = send index (B.concat (reverse chunks))
                fill used segments chunks = do
                    next <- Stream.read source
                    case next of
                        Nothing -> unless (used == 0) (flush chunks)
                        Just bytes -> push used segments chunks bytes
                push used segments chunks bytes
                    | B.null bytes = fill used segments chunks
                    | B.length bytes >= chunkSize-used = do
                        let (part,rest) = B.splitAt (chunkSize-used) bytes
                        flush (part:chunks)
                        if B.null rest then fill 0 0 [] else push 0 0 [] rest
                    | segments >= (1023 :: Int) = flush (bytes:chunks) >> fill 0 0 []
                    | otherwise = fill (used+B.length bytes) (segments+1) (bytes:chunks)
            fill 0 0 []
    forM_ (zip [0..] parameters) $ \(index,parameter) -> case parameter of
        PreparedValue _ -> pure ()
        PreparedBytes source -> upload index source
        PreparedText source -> do
            pending <- newIORef T.empty
            let encodePart text = do
                    let (part,rest) = T.splitAt 8192 text
                    writeIORef pending rest
                    Just <$> either (throwIO . UnencodableParameter) pure (encodeCharsetText charset part)
                next = do
                    rest <- readIORef pending
                    if T.null rest then Stream.read source >>= maybe (pure Nothing) encodePart
                        else encodePart rest
            encoded <- Stream.makeInputStream next
            upload index encoded
    pure (values,bitmap)
  where
    needsCharset (PreparedText _) = True
    needsCharset (PreparedValue (MySQLText _)) = True
    needsCharset _ = False

uploadCommand :: PreparedStatement -> Word8 -> [PreparedParameter] -> IO Command
uploadCommand statement@(PreparedStatement _ ident _) flags parameters = do
    (values,bitmap) <- uploadParameters statement parameters
    pure (COM_STMT_EXECUTE_EXT ident flags values bitmap)

-- | Upload bounded one-shot parameters and execute a non-row statement.
-- Server packet/parameter limits still apply; chunking reduces client buffering,
-- not MariaDB's accumulated-value limits. Use a transaction for atomic writes.
executePreparedStream :: PreparedStatement -> [PreparedParameter] -> IO OK
executePreparedStream statement@(PreparedStatement conn _ _) parameters = withCommand conn $ do
    cmd <- uploadCommand statement 0 parameters
    executeCore conn cmd

-- | Stream the first binary row result with uploaded parameters. The returned
-- result has the same owner, lifetime and extra-result rules as 'queryPrepared'.
queryPreparedStream :: PreparedStatement -> [PreparedParameter] -> IO ([ColumnDef], InputStream [MySQLValue])
queryPreparedStream statement@(PreparedStatement conn _ _) parameters = withCommand conn $ do
    cmd <- uploadCommand statement 0 parameters
    queryCore conn cmd True

-- | Upload parameters and collect complete prepared results, including OUT
-- parameters. This materializes result rows, as 'queryPreparedMulti' does.
queryPreparedStreamMulti :: PreparedStatement -> [PreparedParameter] -> IO [PreparedResult]
queryPreparedStreamMulti statement@(PreparedStatement conn _ _) parameters = withCommand conn $ do
    cmd <- uploadCommand statement 0 parameters
    sendCommand conn cmd
    readPreparedResults conn

data CursorPhase = CursorOpen | CursorFetching | CursorFinished deriving Eq

-- | An exclusive, read-only server cursor. Its creating thread owns the
-- connection until the cursor is exhausted or closed. Each fetch returns an
-- incremental stream; finish that batch before requesting another. MariaDB may
-- materialize the result on the server. A cursor is not a snapshot guarantee.
data PreparedCursor = PreparedCursor
    { cursorStatement :: !PreparedStatement
    , cursorGeneration :: !Word64
    , cursorColumns :: !CachedColumns
    , cursorPhase :: !(IORef CursorPhase)
    , cursorBatchDrain :: !(IORef (Maybe (IO ())))
    }

-- | Open a read-only cursor on a prepared SELECT. The metadata cache is shared
-- with ordinary executions. Other SQL commands, including reset/close of the
-- statement, are rejected until exhaustion or 'closeCursor'. The cursor flag
-- does not prove that arbitrary SQL is read-only: use this API with SELECTs;
-- MariaDB can execute other SQL before reporting that no cursor was opened.
openCursor :: PreparedStatement -> [MySQLValue] -> IO ([ColumnDef], PreparedCursor)
openCursor statement@(PreparedStatement conn _ _) values = withCommand conn (openCursorCore statement values)

openCursorCore :: PreparedStatement -> [MySQLValue] -> IO ([ColumnDef], PreparedCursor)
openCursorCore statement@(PreparedStatement _ ident _) values = do
    state <- checkedStatement statement
    validateStatementValues state values
    openCursorCommand statement (COM_STMT_EXECUTE_EXT ident 1 (map ExecuteValue values) (makeNullMap values))

-- | Open a read-only cursor with streamed binary/text parameters. Upload and
-- cursor execution share one lease, with the same one-shot and byte-limit
-- contracts as 'queryPreparedStream'. Consume or close the cursor before reuse.
openCursorStream :: PreparedStatement -> [PreparedParameter] -> IO ([ColumnDef], PreparedCursor)
openCursorStream statement@(PreparedStatement conn _ _) parameters = withCommand conn (openCursorStreamCore statement parameters)

openCursorStreamCore :: PreparedStatement -> [PreparedParameter] -> IO ([ColumnDef], PreparedCursor)
openCursorStreamCore statement parameters = do
    cmd <- uploadCommand statement 1 parameters
    openCursorCommand statement cmd

openCursorCommand :: PreparedStatement -> Command -> IO ([ColumnDef], PreparedCursor)
openCursorCommand statement@(PreparedStatement conn _ _) cmd = do
    sendCommand conn cmd
    packet <- readConnPacket conn
    when (isERR packet) (serverError conn packet)
    when (isOK packet) $ do
        ok <- consumeOK conn packet
        when (moreResults (okStatus ok)) (void (skipFurtherResults conn True False))
        finishResponse conn
        throwIO (InvalidCursorUse "statement did not return a cursor result")
    columns <- readResultColumns conn packet
    modern <- usesOKTerminator conn
    flags <- if modern then readConnPacket conn >>= consumeEnd conn
        else maybe (throwIO (ProtocolError "cursor metadata has no status")) pure =<< readIORef (connectionServerStatus conn)
    unless (flags .&. 64 /= 0 && flags .&. 8 == 0)
        (throwIO (ProtocolError "server did not open a read-only cursor"))
    generation <- markStreaming conn
    phase <- newIORef CursorOpen
    drain <- newIORef Nothing
    let cursor = PreparedCursor statement generation columns phase drain
    writeIORef (connectionDrain conn) (Just (closeCursor cursor))
    pure (cachedFields columns,cursor)

-- | Whether the server has exhausted the cursor, or the caller has closed it.
-- This observation sends no command and does not claim connection ownership.
cursorExhausted :: PreparedCursor -> IO Bool
cursorExhausted cursor = (== CursorFinished) <$> readIORef (cursorPhase cursor)

checkCursorOwner :: PreparedCursor -> IO ()
checkCursorOwner cursor = do
    let PreparedStatement conn _ _ = cursorStatement cursor
    callbackActive <- readIORef (connectionCallbackActive conn)
    when callbackActive (throwIO ConcurrentConnectionUse)
    runtime <- readIORef (connectionRuntime conn)
    tid <- myThreadId
    unless (runtimeGeneration runtime == cursorGeneration cursor) (throwIO StaleResultStream)
    unless (runtimeStatus runtime == Streaming) (throwIO (ConnectionUnavailable (runtimeStatus runtime)))
    unless (runtimeOwner runtime == Just tid) (throwIO ConcurrentConnectionUse)

-- | Request at most this many rows, bounded by 'maximumCursorFetchRows'. Rows
-- are decoded one at a time. An exact-sized final batch may need one final
-- empty fetch before MariaDB reports exhaustion. Zero/excessive counts and an
-- unfinished preceding batch fail locally without sending bytes.
fetchCursor :: PreparedCursor -> Word32 -> IO (InputStream [MySQLValue])
fetchCursor cursor count = do
    let PreparedStatement conn ident _ = cursorStatement cursor
    when (count == 0 || count > maximumCursorFetchRows (connectionOptions conn))
        (throwIO (InvalidCursorUse "invalid cursor fetch size"))
    checkCursorOwner cursor
    phase <- readIORef (cursorPhase cursor)
    unless (phase == CursorOpen) (throwIO (InvalidCursorUse "cursor batch is pending or cursor is closed"))
    streamGuard conn (cursorGeneration cursor) $ do
        sendCommand conn (COM_STMT_FETCH ident count)
        writeIORef (cursorPhase cursor) CursorFetching
        finished <- newIORef False
        received <- newIORef (0 :: Word32)
        let next decode = do
                done <- readIORef finished
                if done then pure Nothing else streamGuard conn (cursorGeneration cursor) $ do
                    packet <- readConnPacket conn
                    ending <- isResultEnd conn packet
                    if ending then do
                        flags <- consumeEnd conn packet
                        unless (flags .&. 8 == 0 && flags .&. 192 `elem` [64,128])
                            (throwIO (ProtocolError "invalid cursor batch status"))
                        writeIORef finished True
                        writeIORef (cursorBatchDrain cursor) Nothing
                        let exhausted = flags .&. 128 /= 0
                        writeIORef (cursorPhase cursor) (if exhausted then CursorFinished else CursorOpen)
                        when exhausted (finishResponse conn)
                        pure Nothing
                    else if isERR packet then do
                        writeIORef (cursorPhase cursor) CursorFinished
                        serverError conn packet
                    else do
                        n <- readIORef received
                        when (n >= count) (throwIO (ProtocolError "cursor sent more rows than requested"))
                        writeIORef received (n+1)
                        Just <$> decode packet
            drain = next (const (pure ())) >>= maybe (pure ()) (const drain)
        writeIORef (cursorBatchDrain cursor) (Just drain)
        Stream.makeInputStream (next (decodeBinaryRow (cachedBinaryDecoder (cursorColumns cursor))))

-- | Drain only an outstanding batch, then reset the statement to release the
-- remaining server cursor without fetching it. One cleanup deadline bounds
-- draining/reset. Repeated close is a local no-op; interruption retires the
-- connection. Metadata remains cached, matching MariaDB's statement reset.
closeCursor :: PreparedCursor -> IO ()
closeCursor cursor = mask $ \restore -> cleanupCursor restore cursor

-- The bracket must enter this helper masked, just as explicit close does.
-- Restoring around the helper call would let a pending second cancellation
-- escape before its failure handler can retire the unfinished connection.
-- Restore only the timed I/O, retaining the caller's original masking state.
cleanupCursor :: (IO () -> IO ()) -> PreparedCursor -> IO ()
cleanupCursor restore cursor = do
    let PreparedStatement conn ident _ = cursorStatement cursor
    status <- connectionStatus conn
    when (status `elem` [Broken,Closed]) $ do
        writeIORef (cursorPhase cursor) CursorFinished
        writeIORef (cursorBatchDrain cursor) Nothing
    done <- cursorExhausted cursor
    unless done $ do
        checkCursorOwner cursor
        result <- try $ timeout (cleanupTimeoutMicros (connectionOptions conn)) $ restore $ streamGuard conn (cursorGeneration cursor) $ do
            pending <- readIORef (cursorBatchDrain cursor)
            maybe (pure ()) id pending
            exhausted <- cursorExhausted cursor
            unless exhausted $ do
                sendCommand conn (COM_STMT_RESET ident)
                ok <- readConnPacket conn >>= consumeCommandOK conn
                when (moreResults (okStatus ok)) (throwIO (ProtocolError "cursor reset returned extra results"))
                writeIORef (cursorPhase cursor) CursorFinished
                finishResponse conn
        case result of
            Right (Just ()) -> pure ()
            Right Nothing -> abortConnection conn False >> throwIO CleanupDeadlineExceeded
            Left (err :: SomeException) -> abortConnection conn False >> throwIO err

-- | Bracket an exclusive cursor, releasing unfinished batches/server state on
-- return or an application exception. A primary exception keeps its identity;
-- a new asynchronous cancellation during cleanup still propagates.
withCursor :: PreparedStatement -> [MySQLValue] -> (PreparedCursor -> IO a) -> IO a
withCursor statement@(PreparedStatement conn _ _) values = withOpenedCursor conn (openCursorCore statement values)

-- | Bracket 'openCursorStream', releasing unfinished batches and the server
-- cursor on return or exception. Caller-owned parameter sources are not closed.
withCursorStream :: PreparedStatement -> [PreparedParameter] -> (PreparedCursor -> IO a) -> IO a
withCursorStream statement@(PreparedStatement conn _ _) parameters = withOpenedCursor conn (openCursorStreamCore statement parameters)

withOpenedCursor :: MySQLConn -> IO ([ColumnDef], PreparedCursor) -> (PreparedCursor -> IO a) -> IO a
withOpenedCursor conn open action = mask $ \restore -> do
    -- Restore acquisition only inside withCommand's failure handler. A fully
    -- buffered one-shot source must remain cancellable, while the return to
    -- bracket bookkeeping stays masked so no cursor can escape its finalizer.
    (_,cursor) <- withCommand conn (restore open)
    result <- try (restore (action cursor))
    case result of
        Right value -> cleanupCursor restore cursor >> pure value
        Left (err :: SomeException) -> do
            cleanupCursor restore cursor `catch` \(secondary :: SomeException) -> when (isCancellation secondary) (throwIO secondary)
            throwIO err

-- | Complete prepared results in wire order. OUT parameters are identified by
-- SERVER_PS_OUT_PARAMS on their terminator, not guessed from column names.
-- These APIs materialize rows; use 'queryPrepared' for large individual streams.
data PreparedResult
    = PreparedOK !OK
    | PreparedRows ![ColumnMetadata] ![[MySQLValue]]
    | PreparedOutParameters ![ColumnMetadata] ![MySQLValue]
    deriving (Show, Eq)

-- | Raw-ID variant of 'queryPreparedMulti'. Unknown/closed IDs are diagnosed by
-- MariaDB, preserving the legacy raw API's server-error contract.
queryStmtMulti :: MySQLConn -> StmtID -> [MySQLValue] -> IO [PreparedResult]
queryStmtMulti conn ident values = withCommand conn $ do
    validateStmtArity conn ident values
    sendCommand conn (COM_STMT_EXECUTE ident values (makeNullMap values))
    readPreparedResults conn

-- | Collect every prepared result, including OUT parameters and trailing OK.
queryPreparedMulti :: PreparedStatement -> [MySQLValue] -> IO [PreparedResult]
queryPreparedMulti statement@(PreparedStatement conn ident _) values = withCommand conn $ do
    state <- checkedStatement statement
    validateStatementValues state values
    sendCommand conn (COM_STMT_EXECUTE ident values (makeNullMap values))
    readPreparedResults conn

readPreparedResults :: MySQLConn -> IO [PreparedResult]
readPreparedResults conn = loop []
  where
    loop earlier = do
        packet <- readConnPacket conn
        if isERR packet then serverError conn packet
        else if isOK packet then do
            ok <- consumeOK conn packet
            next (okStatus ok) (PreparedOK ok : earlier)
        else do
            columns <- readResultColumns conn packet
            let rows acc = do
                    row <- readConnPacket conn
                    ending <- isResultEnd conn row
                    if ending then (,) (reverse acc) <$> consumeEnd conn row
                    else if isERR row then serverError conn row
                    else decodeBinaryRow (cachedBinaryDecoder columns) row >>= \value -> rows (value : acc)
            (values, flags) <- rows []
            result <- if flags .&. 0x1000 == 0
                then pure (PreparedRows (cachedDetails columns) values)
                else case values of
                    [out] -> pure (PreparedOutParameters (cachedDetails columns) out)
                    _ -> throwIO (ProtocolError "prepared OUT result must contain exactly one row")
            next flags (result : earlier)
    next flags results
        | moreResults flags = loop results
        | otherwise = finishResponse conn >> pure (reverse results)

-- | Per-operation bulk feedback returned by MariaDB, in server order. Aggregate
-- execution instead returns one OK with its total count and first generated ID.
data BulkUnitResult = BulkUnitResult
    { bulkInsertId :: !Word64
    , bulkAffectedRows :: !Word64
    } deriving (Show, Eq)

-- One type per column is a bulk wire invariant. Reject mixed signedness/types
-- before sending; do not silently split into independently committed batches.
bulkCommand :: PreparedStatement -> Word16 -> [[BulkParameter]] -> IO Command
bulkCommand statement@(PreparedStatement conn ident _) flags rows = do
    state <- checkedStatement statement
    let width = statementArity state
        invalid = InvalidBulkBatch "empty/zero-parameter batch or row limit exceeded"
    count <- maybe (throwIO invalid) pure
        (lengthWithin (maximumBulkRows (connectionOptions conn)) rows)
    unless (width > 0 && count > 0) (throwIO invalid)
    ensureBulkMinimumFits conn width count
    forM_ rows $ \row -> unless (lengthWithin width row == Just width)
        (throwIO WrongParamsCount)
    let exemplar column = case find present column of
            Just (BulkValue value) -> value
            _ -> MySQLNull
        present (BulkValue MySQLNull) = False
        present (BulkValue _) = True
        present _ = False
        types = map exemplar (transpose rows)
    pure (COM_STMT_BULK_EXECUTE ident flags types rows)

-- | Execute exactly one bounded native MariaDB binary bulk command. NULL,
-- DEFAULT and IGNORE use native parameter indicators. Errors are not replayed
-- and can follow partial server work: use an explicit transaction for atomicity.
-- Empty batches, mixed column wire types and oversized messages fail locally.
executeBulk :: PreparedStatement -> [[BulkParameter]] -> IO OK
executeBulk statement@(PreparedStatement conn _ _) rows = withCommand conn $ do
    cmd <- bulkCommand statement 128 rows
    executeCore conn cmd

-- | Request MariaDB's negotiated per-operation generated IDs/counts. This is a
-- distinct command mode, not fabricated feedback from an aggregate OK.
executeBulkUnitResults :: PreparedStatement -> [[BulkParameter]] -> IO [BulkUnitResult]
executeBulkUnitResults statement@(PreparedStatement conn _ _) rows = withCommand conn $ do
    cmd <- bulkCommand statement 192 rows
    sendCommand conn cmd
    results <- readPreparedResults conn
    case [values | PreparedRows _ values <- results] of
        [values] | all ordinary results -> mapM unit values
        _ -> throwIO (ProtocolError "unexpected bulk unit-result shape")
  where
    ordinary (PreparedOK _) = True
    ordinary (PreparedRows columns _) = length columns == 2
    ordinary _ = False
    unit [ident, affected] = BulkUnitResult <$> unsigned ident <*> unsigned affected
    unit _ = throwIO (ProtocolError "invalid bulk unit-result row")
    -- The server describes these as BIGINT and stores their unsigned bit pattern.
    unsigned (MySQLInt64U value) = pure value
    unsigned (MySQLInt64 value) = pure (fromIntegral value)
    unsigned _ = throwIO (ProtocolError "invalid bulk unit-result integer")

-- No exception thrown by cleanup replaces an ordinary application failure.
-- As with statement cleanup, restore only the timed I/O. The lease and failure
-- diagnostics remain protected while buffered draining is interruptible.
cleanupTransaction :: (IO () -> IO ()) -> MySQLConn -> IO ()
cleanupTransaction restore conn = do
    phase <- connectionStatus conn
    when (phase `elem` [Ready,Streaming]) $ do
        cleaned <- timeout (cleanupTimeoutMicros (connectionOptions conn)) $ restore $ do
            pending <- readIORef (connectionDrain conn)
            maybe (pure ()) id pending
            void (execute_ conn "ROLLBACK")
        when (cleaned==Nothing) (abortConnection conn False >> throwIO CleanupDeadlineExceeded)

-- | Own the connection across BEGIN, the body and completion. Nested/manual
-- transactions are rejected. Unread rows or a body exception trigger draining
-- and rollback within one cleanup deadline; cleanup preserves the primary
-- exception unless a new cancellation arrives.
--
-- Lost COMMIT acknowledgement raises 'CommitOutcomeUnknown' for synchronous
-- failures. Cancellation is rethrown unchanged and uncertainty is recorded in
-- 'connectionFailure'. The helper never retries COMMIT or replays the body.
withTransaction :: MySQLConn -> IO a -> IO a
withTransaction conn body = mask $ \restore -> do
    beginTransactionLease conn
    let run = do
            guardUnconsumed conn
            flags <- readIORef (connectionServerStatus conn)
            active <- case flags of
                Just value -> pure (value .&. 1 /= 0)
                Nothing -> do
                    (_,stream) <- query_ conn "SELECT @@in_transaction"
                    values <- Stream.toList stream
                    pure (values `notElem` [[[MySQLInt64 0]],[[MySQLInt8 0]],[[MySQLInt32 0]],[[MySQLInt64U 0]],[[MySQLInt8U 0]],[[MySQLInt32U 0]]])
            when active (throwIO NestedTransactionUnsupported)
            void (execute_ conn "BEGIN")
            outcome <- try (restore body >>= \value -> guardUnconsumed conn >> pure value)
            case outcome of
                Left (primary :: SomeException) -> do
                    cleanupTransaction restore conn `catch` \(secondary :: SomeException) -> do
                        abortConnection conn False
                        atomicModifyIORef' (connectionFailureRef conn) (\failure -> (fmap (\f -> f {secondaryCleanupFailure=True}) failure,()))
                        when (isCancellation secondary) (throwIO secondary)
                    throwIO primary
                Right value -> do
                    commitGeneration <- runtimeGeneration <$> readIORef (connectionRuntime conn)
                    _ <- execute_ conn "COMMIT" `catch` \(err :: SomeException) -> do
                        runtime <- readIORef (connectionRuntime conn)
                        progress <- readIORef (connectionExchangeProgress conn)
                        if runtimeStatus runtime `elem` [Broken,Closed] && runtimeGeneration runtime/=commitGeneration && progress==WireInFlight then do
                            atomicModifyIORef' (connectionFailureRef conn) (\failure ->
                                let marked=case failure of Nothing -> ConnectionFailure Executing True False
                                                           Just previous -> previous {commitOutcomeUncertain=True}
                                in (Just marked,()))
                            if isCancellation err then throwIO err else throwIO (CommitOutcomeUnknown err)
                        else throwIO err
                    pure value
    run `finally` endTransactionLease conn
