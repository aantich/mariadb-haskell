-- | Client endpoints for the disposable PAM/Kerberos fixture. Keep these
-- shared benchmark paths independent of changes to correctness case inventories.
module Validation.ExternalAuthFixture (authConfig, pamConnect, gssapiConnect) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Database.MySQL.Base
import qualified Database.MySQL.TLS as TLS
import System.Environment

-- The manager supplies only fixture-specific variables. Ordinary validation
-- and benchmark credentials continue to target the managed host MariaDB.
authConfig :: B.ByteString -> IO ConnectInfo
authConfig user = do
    host <- getEnv "MB_AUTH_HOST"
    port <- read <$> getEnv "MB_AUTH_PORT"
    pure defaultConnectInfoMB4 {ciHost=host,ciPort=port,
        ciDatabase="mariadb_haskell_validation",ciUser=user,ciPassword=""}

pamConnect :: B.ByteString -> (DialogPrompt -> IO B.ByteString) -> IO MySQLConn
pamConnect user callback = do
    ci <- authConfig user
    ca <- getEnv "MB_AUTH_TLS_CA"
    params <- TLS.makeClientParams (TLS.CustomCAStore ca)
    TLS.connectWithAuthentication defaultConnectionOptions
        defaultAuthenticationOptions {authenticationDialog=Just callback} ci (params,"localhost")

gssapiConnect :: IO MySQLConn
gssapiConnect = do
    ci <- authConfig "mariadb_gssapi"
    principal <- BC.pack <$> getEnv "MB_AUTH_GSSAPI_PRINCIPAL"
    connectWithAuthentication defaultConnectionOptions
        defaultAuthenticationOptions {authenticationGSSAPIPrincipal=Just principal} ci

