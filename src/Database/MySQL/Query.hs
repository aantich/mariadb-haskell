{-# LANGUAGE BangPatterns #-}
-- | Session-aware MariaDB parameter rendering. The scanner identifies
-- placeholders, not a complete SQL grammar. Batch admission is deliberately
-- conservative because every statement is rendered before any is executed.
module Database.MySQL.Query where

import Control.Exception (Exception)
import Control.Monad
import Control.Arrow (first)
import Data.String (IsString(..))
import Data.Typeable
import Data.Char (toUpper, isAlphaNum)
import Data.List (intersperse, isSuffixOf)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Builder as BB
import Data.Binary.Put
import Database.MySQL.Protocol.MySQLValue

-- | SQL bytes in the connection's client encoding. String literals use UTF-8;
-- callers sending raw SQL under another charset must supply suitable bytes.
newtype Query = Query { fromQuery :: L.ByteString } deriving (Eq, Ord, Typeable)
instance Show Query where show = show . fromQuery
instance Read Query where readsPrec i = fmap (first Query) . readsPrec i
instance IsString Query where fromString = Query . BB.toLazyByteString . BB.stringUtf8

-- | A single value or a comma-separated expansion, for example inside IN (...).
-- An empty expansion renders NULL. Neither constructor supplies parentheses.
data Param = One MySQLValue | Many [MySQLValue]

-- | Session facts required to interpret templates and encode literals. Obtain
-- live snapshots under connection ownership; direct renderer callers must keep
-- their own snapshot current. MariaDB aliases charset/collation tracker entries,
-- so exact collation may be unknown after a charset change.
data RenderContext = RenderContext
    { renderSQLModes :: ![B.ByteString]
    , renderClientCharset :: !B.ByteString
    , renderConnectionCharset :: !B.ByteString
    , renderConnectionCollation :: !(Maybe B.ByteString)
    , renderServerVersion :: !Int
    } deriving (Show, Eq)

-- | UTF-8 fixture/offline context. This does not discover a live server's modes
-- or version and must not be used to repair an unknown connection context.
defaultRenderContext :: RenderContext
defaultRenderContext = RenderContext [] "utf8mb4" "utf8mb4" (Just "utf8mb4_unicode_ci") 0

-- | Rendering failures reported before any target command is written.
data ParameterError
    = InvalidParameterizedSQL String
    | UnsupportedRenderingContext String
    | UnencodableParameter String
    | ParameterCountMismatch
    | AmbiguousParameterizedBatch
    deriving (Show, Eq, Typeable)
instance Exception ParameterError
-- | Connected APIs preserve this arity exception for existing callers.
data WrongParamsCount = WrongParamsCount deriving (Show, Typeable)
instance Exception WrongParamsCount

-- | Trusted parameter encoders. An instance must produce one safe SQL value
-- (or a deliberate 'Many' expansion), respect the supplied context and return
-- validation errors through 'Left'. The driver cannot validate arbitrary SQL
-- emitted by a custom instance.
class QueryParam a where
    -- | Build a literal without performing I/O or changing the session.
    render :: RenderContext -> a -> Either ParameterError Put

instance QueryParam MySQLValue where
    render ctx (MySQLText value) = do
        bytes <- either (Left . UnencodableParameter) Right (encodeCharsetText (renderClientCharset ctx) value)
        pure (quoted ctx bytes)
    render _ (MySQLBytes value) = Right (binaryLiteral value)
    render _ (MySQLGeometry value) = Right (binaryLiteral value)
    render _ value = either (Left . UnencodableParameter) (const (Right (putTextField value))) (validateValue value)

instance QueryParam Param where
    render ctx (One value) = render ctx value
    render _ (Many []) = Right (putTextField MySQLNull)
    render ctx (Many values) = do
        puts <- traverse (render ctx) values
        pure (sequence_ (intersperse (putWord8 44) puts))

-- Hex literals preserve every byte independently of SQL mode/client charset.
binaryLiteral :: B.ByteString -> Put
binaryLiteral bytes = putByteString "X'" >> putBuilder (BB.byteStringHex bytes) >> putWord8 39

-- Quote doubling works in both backslash modes. Only backslash-enabled sessions
-- need the additional NUL/control/backslash escapes; ordinary runs are emitted
-- as ByteString slices to avoid allocating one builder per character.
quoted :: RenderContext -> B.ByteString -> Put
quoted ctx bytes = putWord8 39 >> chunks bytes >> putWord8 39
  where
    noBackslash = "NO_BACKSLASH_ESCAPES" `elem` renderSQLModes ctx
    special w = w==39 || (not noBackslash && w `elem` [0,10,13,26,92])
    chunks rest = do
        let (plain,tailBytes)=B.break special rest
        putByteString plain
        unless (B.null tailBytes) $ do
            let w=B.head tailBytes
            if w == 39
                then putByteString "''"
                else do
                    putWord8 92
                    putWord8 $ case w of
                        0 -> 48 -- NUL -> \0
                        10 -> 110 -- newline -> \n
                        13 -> 114 -- carriage return -> \r
                        26 -> 90 -- Ctrl-Z -> \Z
                        _ -> 92 -- backslash -> \\
            chunks (B.tail tailBytes)

-- | A per-template plan, reusable only with the context used for compilation.
-- Fragments preserve every original byte except actual placeholders. Safety
-- flags describe classification, not server acceptance or batch atomicity.
data QueryPlan = QueryPlan
    { planFragments :: ![L.ByteString]
    , planBatchSafe :: !Bool -- ^ No ambiguous parsing-context changes in a batch.
    , planOpaque :: !Bool -- ^ Execution may change facts tracking cannot establish.
    , planMultiple :: !Bool -- ^ More than one visible statement.
    , planTerminated :: !Bool -- ^ Last visible SQL token is a statement delimiter.
    } deriving Show

-- Allocation-light classification for short, flat ASCII SQL. Parentheses are
-- allowed only after a table target or a known built-in, so nested/qualified
-- user routine calls still take the conservative full-lexer path. Quoting,
-- block/hash comments and multi-statements take that path as well. A template
-- caller must also exclude '--' comments before interpreting question marks;
-- raw-state classification alone does not need to locate placeholders.
simpleStableQuery :: L.ByteString -> Bool
simpleStableQuery input = case L.toChunks input of
    [bytes] | B.length bytes<=512 -> simple bytes
    _ -> False
  where
    simple bytes = any (starts bytes) ["SELECT ","INSERT ","UPDATE ","DELETE ","REPLACE ","DO "]
        && B.all allowed bytes && scan bytes 0 False
    starts bytes word=B.length bytes>=B.length word && equalWord bytes 0 (B.length word) word
    allowed w = w>=48 && w<=57 || w>=65 && w<=90 || w>=97 && w<=122 || w `elem` [9,10,13,32,40,41,42,43,44,45,46,60,61,62,64,95]
    identifier w=w>=48 && w<=57 || w>=65 && w<=90 || w>=97 && w<=122 || w==95 || w==46 || w==36
    upper w=if w>=97 && w<=122 then w-32 else w
    equalWord bytes start end word = end-start==B.length word && loop 0
      where loop n=n==B.length word || upper (B.index bytes (start+n))==B.index word n && loop (n+1)
    scan bytes !i tableTarget
        | i>=B.length bytes=True
        | identifier (B.index bytes i)=
            let end=walk identifier i
                next=walk (\w -> w<=32) end
                wordIs=equalWord bytes i end
                call=next<B.length bytes && B.index bytes next==40
                known=any wordIs ["VALUES","VALUE","COUNT","SUM","AVG","MIN","MAX","COALESCE","IFNULL","ROW_COUNT","FOUND_ROWS","LAST_INSERT_ID","REPEAT","LENGTH","CAST","CONVERT"]
            in (not call || tableTarget || known) && scan bytes end (wordIs "INTO" || wordIs "INSERT" || wordIs "REPLACE")
        | otherwise=scan bytes (i+1) (if B.index bytes i<=32 then tableTarget else False)
      where
        walk predicate n | n<B.length bytes && predicate (B.index bytes n)=walk predicate (n+1)
                         | otherwise=n
{-# NOINLINE simpleStableQuery #-}

-- | Locate placeholders using MariaDB quoting, comments, modes and version
-- gates. Unknown routines and executable comments cannot establish batch safety.
compileQuery :: RenderContext -> Query -> Either ParameterError QueryPlan
compileQuery ctx (Query input)
  | fastTemplate = Right QueryPlan
        { planFragments = split (B.elemIndices 63 bytes) 0
        , planBatchSafe = True
        , planOpaque = False
        , planMultiple = False
        , planTerminated = False
        }
  | otherwise = do
    unless (renderClientCharset ctx `elem` ["utf8mb4","utf8mb3","utf8","ascii","latin1"]) (Left (UnsupportedRenderingContext "unsupported SQL template encoding"))
    holes <- scan 0 len []
    (visible,executable) <- visibleSQL 0 0 [] False
    let positions = reverse holes
        fragments = split positions 0
        code = BC.unpack visible
        tokens = tokenize code
        opaque = any (`elem` tokens) ["CALL","EXECUTE","PREPARE"] || any trackingControl tokens
        changes = opaque || any (`elem` tokens) ["SET","BEGIN","CREATE","ALTER","DROP"]
        -- A name followed by '(' can be a routine call or a table/type
        -- declaration. Unknown calls invalidate context and disallow batching;
        -- the allowlist below is an admission rule, not a full SQL parser.
        calls =
            [ name
            | (previous, name, "(") <- zip3 ("":tokens) tokens (drop 1 tokens)
            , previous `notElem`
                ["INTO", "INSERT", "REPLACE", "TABLE", "EXISTS", "KEY", "INDEX", "REFERENCES", "CONSTRAINT"]
            , case name of
                ch:_ -> isAlphaNum ch || ch == '_'
                [] -> False
            ]
        pureCalls =
            [ "VALUES", "VALUE", "IN", "NOT", "EXISTS", "AS", "SELECT"
            , "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "NULLIF", "IF"
            , "CAST", "CONVERT", "CONCAT", "CONCAT_WS", "ABS", "REPEAT", "LENGTH"
            , "OCTET_LENGTH", "CHAR_LENGTH", "CHARACTER_LENGTH", "HEX", "UNHEX"
            , "LOWER", "UPPER", "TRIM", "ROUND", "FLOOR", "CEIL", "MOD", "SLEEP"
            , "ROW_COUNT", "FOUND_ROWS", "LAST_INSERT_ID", "CONNECTION_ID", "VERSION", "DATABASE"
            , "NOW", "CURRENT_TIMESTAMP", "JSON_OBJECT", "JSON_ARRAY"
            , "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "DECIMAL", "NUMERIC"
            , "FLOAT", "DOUBLE", "BIT", "CHAR", "VARCHAR", "BINARY", "VARBINARY", "BLOB", "TEXT"
            , "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT"
            , "TIME", "DATETIME", "TIMESTAMP", "YEAR", "ENUM", "SET"
            ]
        unknownCalls = any (`notElem` pureCalls) calls
        statements = filter (not . null) (map words (splitStatements code))
        safe = not changes && not executable && not unknownCalls && all safeHead statements
    -- Active executable comments can contain complete statements, including
    -- tracking-control changes hidden from visibleSQL. Their effects are opaque
    -- even when the visible outer statement looks like a stable SELECT.
    pure QueryPlan
        { planFragments = fragments
        , planBatchSafe = safe
        , planOpaque = opaque || unknownCalls || executable
        , planMultiple = length statements > 1
        , planTerminated = case B.unsnoc (B.dropWhileEnd (<=32) visible) of
            Just (_, byte) -> byte == 59
            Nothing -> False
        }
  where
    -- No quoting/comments/multiple statements can enter this path. The same
    -- full-byte/call classification as raw SQL proves context stability; every
    -- question mark is therefore a placeholder. Complex templates retain the
    -- complete mode/version-aware lexer below.
    fastTemplate = renderClientCharset ctx `elem` ["utf8mb4","utf8mb3","utf8","ascii","latin1"]
        && B.length bytes<=512 && not ("--" `B.isInfixOf` bytes)
        && simpleStableQuery (L.fromStrict (B.map (\w -> if w==63 then 32 else w) bytes))
    trackingControl token = any (\name -> token==name || ("."++name) `isSuffixOf` token) ["SESSION_TRACK_SYSTEM_VARIABLES","SESSION_TRACK_STATE_CHANGE"]
    bytes = L.toStrict input
    len = B.length bytes
    at = B.index bytes
    has i x = i + B.length x <= len && x `B.isPrefixOf` B.drop i bytes
    noBackslash = "NO_BACKSLASH_ESCAPES" `elem` renderSQLModes ctx
    ansi = "ANSI_QUOTES" `elem` renderSQLModes ctx
    err = Left . InvalidParameterizedSQL
    split [] start = [L.fromStrict (B.drop start bytes)]
    split (i:is) start = L.fromStrict (B.take (i-start) (B.drop start bytes)) : split is (i+1)
    scan !i end acc
        | i >= end = Right acc
        | at i == 63 = scan (i+1) end (i:acc)
        | at i `elem` [39,34,96] = quote (at i) (i+1) end >>= \j -> scan j end acc
        | at i == 35 = scan (lineEnd (i+1) end) end acc
        | has i "--" && (i+2 == end || at (i+2) <= 32 || at (i+2)==127) = scan (lineEnd (i+2) end) end acc
        | has i "/*" = do
            (begin, active, nested) <- commentBody i
            close <- blockEnd nested (i+2) end
            acc' <- if active then scan begin close acc else Right acc
            scan (close+2) end acc'
        | otherwise = scan (i+1) end acc
    quote delimiter i end
        | i >= end = err "unterminated quoted token"
        | at i == delimiter = if i+1<end && at (i+1)==delimiter then quote delimiter (i+2) end else Right (i+1)
        | at i==92 && delimiter/=96 && (delimiter/=34 || not ansi) && not noBackslash = if i+1<end then quote delimiter (i+2) end else err "unfinished escape"
        | otherwise = quote delimiter (i+1) end
    lineEnd i end | i>=end || at i==10 || at i==13 = i
                  | otherwise = lineEnd (i+1) end
    -- MariaDB consumes exactly five or six version digits. Fewer digits belong
    -- to ordinary executable SQL; any seventh digit remains in that SQL too.
    -- Only skipped version comments tolerate one nested ordinary comment.
    -- Keep placeholder scanning and effect classification on the same rule.
    commentBody i
        | not executable = Right (i+2, False, False)
        | has begin "!" = Left (UnsupportedRenderingContext "reversed executable comments are not supported by the parameter renderer")
        | otherwise =
            let digits = B.takeWhile (\w -> w >= 48 && w <= 57) (B.take 6 (B.drop begin bytes))
                versioned = B.length digits >= 5
                gate = B.foldl' (\value digit -> value * 10 + fromIntegral (digit-48)) 0 digits
                active = not versioned || gate <= renderServerVersion ctx && (maria || gate < 50700 || gate > 99999)
            in Right (begin + if versioned then B.length digits else 0, active, versioned && not active)
      where
        maria = has i "/*M!"
        executable = maria || has i "/*!"
        begin = i + if maria then 4 else 3
    blockEnd nested i end
        | i+1 >= end = err "unterminated block comment"
        | has i "*/" = Right i
        | nested && has i "/*" = do
            inner <- blockEnd False (i+2) end
            blockEnd nested (inner+2) end
        | otherwise = blockEnd nested (i+1) end
    visibleSQL i start chunks executable
        | i >= len = Right (B.concat (reverse (B.drop start bytes:chunks)),executable)
        | at i `elem` [39,34,96] = do
            j <- quote (at i) (i+1) len
            let identifier=at i==96 || at i==34 && ansi
                rawName=BC.map toUpper (B.take (j-i-2) (B.drop (i+1) bytes))
                replacement=if identifier then
                    if rawName `elem` ["SESSION_TRACK_SYSTEM_VARIABLES","SESSION_TRACK_STATE_CHANGE"] then rawName else "__QUOTED_IDENTIFIER__"
                    else " "
            visibleSQL j j (replacement:B.take (i-start) (B.drop start bytes):chunks) executable
        | at i==35 || (has i "--" && (i+2==len || at (i+2)<=32 || at (i+2)==127)) = do
            let j=lineEnd (i+1) len
            visibleSQL j j (" ":B.take (i-start) (B.drop start bytes):chunks) executable
        | has i "/*" = do
            (_, active, nested) <- commentBody i
            close <- blockEnd nested (i+2) len
            let j=close+2
            visibleSQL j j (" ":B.take (i-start) (B.drop start bytes):chunks) (executable || active)
        | otherwise = visibleSQL (i+1) start chunks executable
    tokenize [] = []
    tokenize (ch:rest)
        | isAlphaNum ch || ch `elem` ("_$." :: String) = let (word,tail')=span (\x -> isAlphaNum x || x `elem` ("_$." :: String)) rest in map toUpper (ch:word):tokenize tail'
        | ch `elem` ("(),;" :: String) = [ch]:tokenize rest
        | otherwise = tokenize rest
    splitStatements str = case break (==';') str of (a,[]) -> [a];(a,_:rest)->a:splitStatements rest
    safeHead (x:_) = map toUpper x `elem` ["INSERT","UPDATE","DELETE","REPLACE","SELECT","DO"]
    safeHead [] = True

-- | Render a compiled plan with the same context and exactly one value per hole.
renderPlan :: QueryParam p => RenderContext -> QueryPlan -> [p] -> Either ParameterError Query
renderPlan ctx plan values = Query . runPut <$> renderPlanPut ctx plan values

-- | Builder form used to join a batch without encoding/copying every query twice.
renderPlanPut :: QueryParam p => RenderContext -> QueryPlan -> [p] -> Either ParameterError Put
renderPlanPut ctx plan values = fill (planFragments plan) values
  where
    fill [x] [] = Right (putLazyByteString x)
    fill (x:xs) (v:vs) = do
        value <- render ctx v
        rest <- fill xs vs
        pure (putLazyByteString x >> value >> rest)
    fill _ _ = Left ParameterCountMismatch

-- | Compile and render with explicitly supplied session facts. Connected APIs
-- acquire these facts under ownership; pure callers must establish them first.
renderParams :: QueryParam p => RenderContext -> Query -> [p] -> Either ParameterError Query
renderParams ctx qry values = compileQuery ctx qry >>= \plan -> renderPlan ctx plan values
