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
    , UnconsumedResultSet(..)
    , ERRException(..)
    , UnexpectedPacket(..)
    , DecodePacketException(..)
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
import Data.Word (Word16)
import System.Timeout (timeout)
import           Data.Bits                          ((.&.))
import           Data.IORef                         (newIORef, readIORef, writeIORef, atomicModifyIORef')
import           Database.MySQL.Connection
import           Database.MySQL.Protocol.Auth
import           Database.MySQL.Protocol.ColumnDef
import           Database.MySQL.Protocol.Command
import           Database.MySQL.Protocol.MySQLValue
import           Database.MySQL.Protocol.Packet

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
            count <- getFromPacketExact getLenEncInt packet
            fields <- readColumns conn count
            let decode=if binary then decodeBinaryRow (prepareBinaryRow fields) else decodeTextRow (prepareTextRow fields)
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
        count <- getFromPacketExact getLenEncInt packet
        void (readColumns conn count)
        let skip = do
                next <- readConnPacket conn
                done <- isResultEnd conn next
                if done then consumeEnd conn next else if isERR next then serverError conn next else skip
        flags <- skip
        when (moreResults flags) (void (skipFurtherResults conn (isBinaryCommand cmd) True))
        finishResponse conn
        throwIO ExtraResultSets

executeCommand :: MySQLConn -> Command -> IO OK
executeCommand conn cmd = withCommand conn (executeCore conn cmd)

isBinaryCommand :: Command -> Bool
isBinaryCommand (COM_STMT_EXECUTE _ _ _) = True
isBinaryCommand _ = False

data QueryReply = WithoutResultSet | ResultSetColumns Int

readQueryReply :: MySQLConn -> IO QueryReply
readQueryReply conn = do
    packet <- readConnPacket conn
    if isERR packet then serverError conn packet
    else if isOK packet then do
        ok <- consumeOK conn packet
        if moreResults (okStatus ok) then readQueryReply conn else finishResponse conn >> pure WithoutResultSet
    else do
        count <- getFromPacketExact getLenEncInt packet
        when (count==0) (throwIO (ProtocolError "zero result column count"))
        pure (ResultSetColumns count)

queryCore :: MySQLConn -> Command -> Bool -> IO ([ColumnDef],InputStream [MySQLValue])
queryCore conn cmd binary = do
    sendCommand conn cmd
    reply <- readQueryReply conn
    case reply of
        WithoutResultSet -> (,) [] <$> Stream.nullInput
        ResultSetColumns count -> do
            fields <- readColumns conn count
            let decode=if binary then decodeBinaryRow (prepareBinaryRow fields) else decodeTextRow (prepareTextRow fields)
            stream <- resultSetRows conn binary decode
            pure (fields,stream)

queryVectorCore :: MySQLConn -> Command -> Bool -> IO (V.Vector ColumnDef,InputStream (V.Vector MySQLValue))
queryVectorCore conn cmd binary = do
    sendCommand conn cmd
    reply <- readQueryReply conn
    case reply of
        WithoutResultSet -> (,) V.empty <$> Stream.nullInput
        ResultSetColumns count -> do
            fieldList <- readColumns conn count
            let fields=V.fromList fieldList
                decodeList=if binary then decodeBinaryRow (prepareBinaryRow fieldList) else decodeTextRow (prepareTextRow fieldList)
                decode packet = V.fromListN count <$> decodeList packet
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
        count <- getFromPacketExact getLenEncInt packet
        void (readColumns conn count)
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
    cdefs <- readColumns conn columns
    pure (info,pdefs,cdefs)
-- | Release a statement. This command has no server reply and cannot run while
-- a result is pending. Raw IDs cannot detect reuse by a later server statement.
closeStmt :: MySQLConn -> StmtID -> IO ()
closeStmt conn ident = withCommand conn $ do
    sendCommand conn (COM_STMT_CLOSE ident)
    atomicModifyIORef' (connectionOpaqueStatements conn) (\ids -> (filter (/=ident) ids,()))
-- | Reset a statement and consume its own reply; pending rows must be read first.
resetStmt :: MySQLConn -> StmtID -> IO ()
resetStmt conn ident = void (command conn (COM_STMT_RESET ident))
-- | Execute with binary parameters. Text values require a known client charset;
-- numeric/binary values do not require a rendering snapshot.
executeStmt :: MySQLConn -> StmtID -> [MySQLValue] -> IO OK
executeStmt conn ident values = executeCommand conn (COM_STMT_EXECUTE ident values (makeNullMap values))
-- | Stream prepared binary rows under the ownership contract of 'query'.
queryStmt :: MySQLConn -> StmtID -> [MySQLValue] -> IO ([ColumnDef],InputStream [MySQLValue])
queryStmt conn ident values = withCommand conn (queryCore conn (COM_STMT_EXECUTE ident values (makeNullMap values)) True)
-- | Vector variant of 'queryStmt'.
queryStmtVector :: MySQLConn -> StmtID -> [MySQLValue] -> IO (V.Vector ColumnDef,InputStream (V.Vector MySQLValue))
queryStmtVector conn ident values = withCommand conn (queryVectorCore conn (COM_STMT_EXECUTE ident values (makeNullMap values)) True)

-- No exception thrown by cleanup replaces an ordinary application failure.
cleanupTransaction :: MySQLConn -> IO ()
cleanupTransaction conn = do
    phase <- connectionStatus conn
    when (phase `elem` [Ready,Streaming]) $ do
        cleaned <- timeout (cleanupTimeoutMicros (connectionOptions conn)) $ do
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
                    cleanupTransaction conn `catch` \(secondary :: SomeException) -> do
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
