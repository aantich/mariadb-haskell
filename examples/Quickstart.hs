{-# LANGUAGE OverloadedStrings #-}

-- | A read-only example with no table/schema prerequisites. From a checkout:
--
-- @
-- cabal build lib:mariadb-haskell
-- cabal exec -- ghc -threaded -package mariadb-haskell examples/Quickstart.hs -o /tmp/mariadb-quickstart
-- @
--
-- Set MDB_USER, MDB_PASSWORD and MDB_DATABASE. Optional MDB_HOST/MDB_PORT
-- default to 127.0.0.1/3306. Set both MDB_TLS_CA and MDB_TLS_NAME for verified
-- TLS; otherwise this example uses TCP, suitable for a trusted local service.
module Main (main) where

import Control.Exception (bracket)
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Database.MySQL.Base as DB
import qualified Database.MySQL.TLS as TLS
import System.Environment (getEnv, lookupEnv)
import qualified System.IO.Streams as Streams
import Text.Read (readMaybe)

main :: IO ()
main = do
    host <- fromMaybe "127.0.0.1" <$> lookupEnv "MDB_HOST"
    portText <- fromMaybe "3306" <$> lookupEnv "MDB_PORT"
    port <- case readMaybe portText :: Maybe Integer of
        Just number | number >= 1 && number <= 65535 -> pure (fromInteger number)
        _ -> ioError (userError "MDB_PORT must be between 1 and 65535")
    user <- utf8 <$> getEnv "MDB_USER"
    password <- utf8 <$> getEnv "MDB_PASSWORD"
    database <- utf8 <$> getEnv "MDB_DATABASE"
    let ci = DB.defaultConnectInfo
            { DB.ciHost = host, DB.ciPort = port, DB.ciUser = user
            , DB.ciPassword = password, DB.ciDatabase = database
            }
    ca <- lookupEnv "MDB_TLS_CA"
    name <- lookupEnv "MDB_TLS_NAME"
    open <- case (ca, name) of
        (Nothing, Nothing) -> pure (DB.connect ci)
        (Just path, Just serverName) -> do
            params <- TLS.makeClientParams (TLS.CustomCAStore path)
            pure (TLS.connect ci (params, serverName))
        _ -> ioError (userError "Set both MDB_TLS_CA and MDB_TLS_NAME for TLS")
    bracket open DB.close $ \conn ->
        DB.withPreparedStatement conn "SELECT VERSION(), ?" $ \statement -> do
            (_, rows) <- DB.queryPrepared statement [DB.MySQLText "Hello, MariaDB 🌍"]
            Streams.foldM (\() row -> print row) () rows
  where
    utf8 = Text.encodeUtf8 . Text.pack
