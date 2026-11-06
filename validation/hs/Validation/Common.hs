{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Common where

import Control.Exception hiding (assert)
import Control.Monad
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Data.String (fromString)
import qualified Data.Text as T
import Data.Typeable
import Database.MySQL.Base
import qualified Database.MySQL.TLS as TLS
import System.Environment
import qualified System.IO.Streams as S
import System.Timeout

data Case = Case { caseId :: String, caseArea :: String, caseRun :: IO () }
data Unavailable = Unavailable String deriving (Show, Typeable)
instance Exception Unavailable
data Unsupported = Unsupported String deriving (Show, Typeable)
instance Exception Unsupported

assert :: Bool -> String -> IO ()
assert ok msg = unless ok (throwIO (userError msg))

equal :: (Eq a, Show a) => String -> a -> a -> IO ()
equal label expected actual = assert (expected == actual)
    (label ++ ": expected " ++ take 2000 (show expected) ++ ", got " ++ take 2000 (show actual))

env :: String -> String -> IO String
env name fallback = maybe fallback id <$> lookupEnv name

config :: IO ConnectInfo
config = do
    host <- env "MB_HOST" "127.0.0.1"
    port <- read <$> env "MB_PORT" "3306"
    db <- BC.pack <$> env "MB_DATABASE" "mariadb_haskell_validation"
    user <- BC.pack <$> env "MB_USER" "mariadb_haskell_test"
    pass <- BC.pack <$> env "MB_PASSWORD" ""
    pure defaultConnectInfoMB4 { ciHost=host, ciPort=port, ciDatabase=db, ciUser=user, ciPassword=pass }

socketPath :: IO FilePath
socketPath = env "MB_SOCKET" "/tmp/mysql.sock"

tlsConnect :: ConnectInfo -> String -> IO MySQLConn
tlsConnect ci name = do
    ca <- getEnv "MB_TLS_CA"
    params <- TLS.makeClientParams (TLS.CustomCAStore ca)
    TLS.connect ci (params, name)

quietClose :: MySQLConn -> IO ()
quietClose c = void (timeout 1000000 (close c)) `catch` \(_ :: SomeException) -> pure ()

withConnect :: IO MySQLConn -> (MySQLConn -> IO a) -> IO a
withConnect open = bracket open quietClose

withConn :: (MySQLConn -> IO a) -> IO a
withConn action = config >>= \ci -> withConnect (connect ci) action

withTLS :: (MySQLConn -> IO a) -> IO a
withTLS action = do
    ci <- config
    name <- env "MB_TLS_NAME" "localhost"
    withConnect (tlsConnect ci name) action

sql :: String -> Query
sql = fromString

exec :: MySQLConn -> String -> IO ()
exec c = void . execute_ c . sql

rows :: MySQLConn -> String -> IO [[MySQLValue]]
rows c q = query_ c (sql q) >>= S.toList . snd

preparedRows :: MySQLConn -> String -> [MySQLValue] -> IO [[MySQLValue]]
preparedRows c q ps = bracket (prepareStmt c (sql q)) (closeStmt c) $ \st ->
    queryStmt c st ps >>= S.toList . snd

number :: MySQLValue -> Integer
number v = case v of
    MySQLInt8U x -> fromIntegral x
    MySQLInt8 x -> fromIntegral x
    MySQLInt16U x -> fromIntegral x
    MySQLInt16 x -> fromIntegral x
    MySQLInt32U x -> fromIntegral x
    MySQLInt32 x -> fromIntegral x
    MySQLInt64U x -> fromIntegral x
    MySQLInt64 x -> fromIntegral x
    MySQLDecimal x -> truncate x
    MySQLFloat x -> truncate x
    MySQLDouble x -> truncate x
    _ -> error ("not a numeric value: " ++ show v)

scalar :: MySQLConn -> String -> IO MySQLValue
scalar c q = do
    result <- rows c q
    case result of
        [[x]] -> pure x
        _ -> throwIO (userError ("expected one cell: " ++ take 500 (show result)))

scalarInt :: MySQLConn -> String -> IO Integer
scalarInt c q = number <$> scalar c q

textOf :: MySQLValue -> T.Text
textOf (MySQLText t) = t
textOf (MySQLBytes b) = T.pack (BC.unpack b)
textOf x = error ("not text: " ++ show x)

assertQuery :: String -> String -> [[Integer]] -> Case
assertQuery ident queryText expected = Case ident "sql" $ withConn $ \c -> do
    actual <- map (map number) <$> rows c queryText
    equal queryText expected actual

expectERR :: [Int] -> IO a -> IO ()
expectERR codes action = do
    result <- try action
    case result of
        Left (ERRException e) -> assert (null codes || fromIntegral (errCode e) `elem` codes)
            ("unexpected server error " ++ show e)
        Right _ -> throwIO (userError "expected a server ERR packet")

expectRejection :: IO a -> IO ()
expectRejection action = do
    result <- try action
    case result of
        Left (_ :: SomeException) -> pure ()
        Right _ -> throwIO (userError "operation unexpectedly succeeded")

healthy :: MySQLConn -> IO ()
healthy c = scalarInt c "SELECT 937" >>= equal "following query" 937

preflight :: IO ()
preflight = withConn $ \c -> do
    version <- T.unpack . textOf <$> scalar c "SELECT VERSION()"
    assert ("MariaDB" `isInfixOf` version) ("expected MariaDB, got " ++ version)
    ci <- config
    assert (ciDatabase ci == "mariadb_haskell_validation") "refusing to run outside the reserved validation database"
    maxPacket <- scalarInt c "SELECT @@max_allowed_packet"
    assert (maxPacket >= 300*1024*1024) "set max_allowed_packet >= 300 MiB for the inherited suite"
    equal "row binlog required" "ROW" . textOf =<< scalar c "SELECT @@binlog_format"
    equal "binary logging required" 1 =<< scalarInt c "SELECT @@log_bin"
    equal "server session timezone" "+00:00" . textOf =<< scalar c "SELECT @@time_zone"
    putStrLn ("MariaDB preflight passed: " ++ version)
