-- | Bounded session observations carried by MariaDB OK packets. This module
-- owns retained bytes; callers never keep slices of a large receive buffer.
module Database.MySQL.Session where

import Control.Monad (foldM, unless, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as M
import Data.Word
import qualified Data.ByteString.Char8 as BC

-- | One server-reported change. Unknown kinds retain their length-delimited
-- payload rather than guessing a layout. Values can contain application data;
-- do not log session observations indiscriminately.
data SessionChange
    = SystemVariableChanged !ByteString !ByteString -- ^ Variable name and value.
    | SchemaChanged !ByteString -- ^ Empty bytes mean no selected database.
    | SessionStateChanged !Bool -- ^ The server's generic state-change marker.
    | TransactionCharacteristicsChanged !ByteString -- ^ Server-provided SQL text.
    | TransactionStateChanged !ByteString -- ^ Eight-byte MariaDB transaction state.
    | UnknownSessionChange !Word8 !ByteString -- ^ Unimplemented tracker kind and payload.
    deriving (Eq, Show)

-- | Current observations, not a complete inventory of server settings. 'Nothing'
-- means unknown; an absent variable has not been observed or is no longer tracked.
-- A snapshot reflects only replies consumed so far, including during streaming.
-- 'sessionLastChanges' is the latest tracking envelope, not an event queue: use
-- 'sessionChangeNumber' to recognize replacement, and snapshot fields for final
-- state after multiple results. Transaction flags also work without tracking.
data SessionState = SessionState
    { sessionSchema :: !(Maybe ByteString) -- ^ Known schema; Just empty means none.
    , sessionVariables :: !(M.Map ByteString ByteString) -- ^ Observed tracked variables.
    , sessionAutocommit :: !(Maybe Bool) -- ^ SERVER_STATUS_AUTOCOMMIT, not transaction activity.
    , sessionInTransaction :: !(Maybe Bool) -- ^ SERVER_STATUS_IN_TRANS.
    , sessionTransactionCharacteristics :: !(Maybe ByteString) -- ^ When the server tracks them.
    , sessionTransactionState :: !(Maybe ByteString) -- ^ When the server tracks it.
    , sessionLastChanges :: ![SessionChange] -- ^ Latest bounded tracker envelope, in wire order.
    , sessionChangeNumber :: !Word64 -- ^ Advances on a tracker envelope or invalidation.
    } deriving (Eq, Show)

-- Internal accounting avoids rescanning every tracked variable per update.
data SessionCache = SessionCache
    { sessionObservation :: !SessionState
    , sessionVariableBytes :: !Word64
    }

emptySessionCache :: Word64 -> SessionCache
emptySessionCache serial = SessionCache
    (SessionState Nothing M.empty Nothing Nothing Nothing Nothing [] serial) 0

-- The caller has already bounded the complete OK envelope. Additionally bound
-- item counts, even for zero-length payloads, and reject known malformed kinds.
decodeSessionChanges :: ByteString -> Either String [SessionChange]
decodeSessionChanges = items 0 []
  where
    items :: Int -> [SessionChange] -> ByteString -> Either String [SessionChange]
    items count acc bytes
        | B.null bytes = Right (reverse acc)
        | count >= 65535 = Left "too many session tracking items"
        | otherwise = do
            (payload, rest) <- lengthString (B.tail bytes)
            (next, changes) <- case B.head bytes of
                0 -> variables (count + 1) acc payload
                kind -> do
                    change <- case kind of
                        1 -> SchemaChanged <$> single payload
                        -- This tracker alone has a raw marker after the outer
                        -- length. There is no redundant inner string length.
                        2 -> case payload of
                            "0" -> pure (SessionStateChanged False)
                            "1" -> pure (SessionStateChanged True)
                            _ -> Left "invalid session state-change marker"
                        4 -> TransactionCharacteristicsChanged <$> single payload
                        5 -> do
                            value <- single payload
                            unless (B.length value == 8) (Left "invalid transaction state length")
                            pure (TransactionStateChanged value)
                        _ -> pure (UnknownSessionChange kind (B.copy payload))
                    pure (count + 1, change : acc)
            items next changes rest
    variables count acc bytes
        | B.null bytes = Right (count, acc)
        | count >= 65535 = Left "too many tracked variables"
        | otherwise = do
            (name, rest) <- lengthString bytes
            (value, remaining) <- lengthString rest
            when (B.null name) (Left "empty tracked variable name")
            variables (count + 1) (SystemVariableChanged (B.copy name) (B.copy value) : acc) remaining
    single payload = do
        (value, rest) <- lengthString payload
        unless (B.null rest) (Left "trailing session tracking payload")
        pure (B.copy value)

-- Non-NULL length-encoded strings, with arithmetic in Word64 before conversion.
lengthString :: ByteString -> Either String (ByteString, ByteString)
lengthString bytes = do
    when (B.null bytes) (Left "truncated length string")
    let tag = B.head bytes
        after = B.tail bytes
        takeLength width = do
            when (B.length after < width) (Left "truncated encoded length")
            let size = B.foldr (\byte acc -> acc * 256 + fromIntegral byte)
                            (0 :: Word64) (B.take width after)
            pure (size, B.drop width after)
    (count, rest) <- case tag of
        0xfc -> takeLength 2
        0xfd -> takeLength 3
        0xfe -> takeLength 8
        _ | tag < 0xfb -> Right (fromIntegral tag, after)
          | otherwise -> Left "invalid non-null string length"
    when (count > fromIntegral (B.length rest)) (Left "truncated length string body")
    pure (B.splitAt (fromIntegral count) rest)

applySessionStatus :: Word16 -> SessionCache -> SessionCache
applySessionStatus flags cache = cache {sessionObservation = state
    { sessionAutocommit = Just (flags .&. 2 /= 0)
    , sessionInTransaction = Just (flags .&. 1 /= 0)
    }}
  where state = sessionObservation cache

-- Replace the latest envelope, then apply deltas with incremental byte charges.
-- Both accumulated variables and the retained latest envelope share the budget.
applySessionChanges :: Word64 -> [SessionChange] -> SessionCache -> Either String SessionCache
applySessionChanges = applySessionObservations TrackingEnvelope

-- Helper SELECT/configuration observations update facts without creating a
-- tracker event. Charge the envelope actually retained, including an older one.
applySessionFacts :: Word64 -> [SessionChange] -> SessionCache -> Either String SessionCache
applySessionFacts = applySessionObservations SnapshotFacts

data ObservationSource = TrackingEnvelope | SnapshotFacts

applySessionObservations :: ObservationSource -> Word64 -> [SessionChange] -> SessionCache -> Either String SessionCache
applySessionObservations source limit changes cache = do
    -- MariaDB keys trackers by variable storage offset, so charset and
    -- collation aliases may report only one name. Neither value determines
    -- the other in general. Forget an unreported alias before applying the
    -- batch, releasing its charge even when the replacement is near the limit.
    -- Explicit deltas for both names remain valid in either wire order.
    let charsetReported = hasVariableChange "character_set_connection" changes
        collationReported = hasVariableChange "collation_connection" changes
        coherent = case (charsetReported, collationReported) of
            (True, False) -> forgetVariable "collation_connection" cache
            (False, True) -> forgetVariable "character_set_connection" cache
            _ -> cache
    applied <- foldM apply coherent changes
    -- A changed subscription invalidates values the server will no longer
    -- report. Recount only on this cold configuration path, never per query.
    let updated = case reverse [value | SystemVariableChanged "session_track_system_variables" value <- changes] of
            selected : _ | selected /= "*" ->
                let names = BC.split ',' selected
                    observed = sessionObservation applied
                    kept = M.filterWithKey (\name _ -> name `elem` names || name == "session_track_system_variables")
                               (sessionVariables observed)
                in applied {sessionObservation = observed {sessionVariables = kept},
                    sessionVariableBytes = sum [bytes key + bytes value | (key,value) <- M.toList kept]}
            _ -> applied
        state = sessionObservation updated
        prior = sessionObservation cache
        envelope = case source of TrackingEnvelope -> changes; SnapshotFacts -> sessionLastChanges prior
        serial = case source of TrackingEnvelope -> sessionChangeNumber prior + 1; SnapshotFacts -> sessionChangeNumber prior
        retained = sessionVariableBytes updated + sum (map changeBytes envelope)
            + maybeBytes (sessionSchema state)
            + maybeBytes (sessionTransactionCharacteristics state)
            + maybeBytes (sessionTransactionState state)
    when (retained > limit) (Left "retained session state exceeds metadata budget")
    pure updated {sessionObservation = state
        {sessionLastChanges = envelope, sessionChangeNumber = serial}}
  where
    apply current change = case change of
        SystemVariableChanged name value -> do
            let state = sessionObservation current
                variables = sessionVariables state
                old = maybe 0 (\prior -> bytes name + bytes prior) (M.lookup name variables)
                charge = sessionVariableBytes current - old + bytes name + bytes value
            when (charge > limit || M.size variables >= 65535 && M.notMember name variables)
                (Left "tracked variables exceed session budget")
            pure current {sessionVariableBytes = charge, sessionObservation = state
                {sessionVariables = M.insert name value variables,
                 sessionSchema = if name == "session_track_schema" && value `elem` ["0","OFF"]
                    then Nothing else sessionSchema state,
                 sessionTransactionState = if name == "session_track_transaction_info" && value == "OFF"
                    then Nothing else sessionTransactionState state,
                 sessionTransactionCharacteristics = if name == "session_track_transaction_info" && value /= "CHARACTERISTICS"
                    then Nothing else sessionTransactionCharacteristics state}}
        SchemaChanged value -> pure (modifyState (\s -> s {sessionSchema = Just value}) current)
        TransactionCharacteristicsChanged value -> pure (modifyState
            (\s -> s {sessionTransactionCharacteristics = Just value}) current)
        TransactionStateChanged value -> pure (modifyState
            (\s -> s {sessionTransactionState = Just value}) current)
        _ -> pure current
    forgetVariable name current = case M.lookup name (sessionVariables (sessionObservation current)) of
        Nothing -> current
        Just value -> current
            { sessionVariableBytes = sessionVariableBytes current - bytes name - bytes value
            , sessionObservation = (sessionObservation current)
                {sessionVariables = M.delete name (sessionVariables (sessionObservation current))}
            }
    modifyState change current = current {sessionObservation = change (sessionObservation current)}
    maybeBytes = maybe 0 bytes
    bytes = fromIntegral . B.length
    changeBytes change = case change of
        SystemVariableChanged name value -> bytes name + bytes value
        SchemaChanged value -> bytes value
        SessionStateChanged _ -> 1
        TransactionCharacteristicsChanged value -> bytes value
        TransactionStateChanged value -> bytes value
        UnknownSessionChange _ value -> bytes value

-- Inspect only tracking envelopes, never ordinary rows/replies without changes.
hasVariableChange :: ByteString -> [SessionChange] -> Bool
hasVariableChange name = any matches
  where
    matches (SystemVariableChanged changed _) = name == changed
    matches _ = False
