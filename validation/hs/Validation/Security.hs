{-# LANGUAGE ScopedTypeVariables #-}
module Validation.Security (cases) where

import Control.Exception hiding (assert)
import Control.Monad
import Database.MySQL.Base
import qualified Database.MySQL.TLS as TLS
import qualified Network.TLS as WireTLS
import System.Environment
import Validation.Common

clientCertificate :: Bool -> Bool -> ConnectInfo -> IO MySQLConn
clientCertificate expired explicitHook ci=do
    ca <- getEnv "MB_TLS_CA"
    cert <- getEnv (if expired then "MB_TLS_EXPIRED_CERT" else "MB_TLS_CLIENT_CERT")
    key <- getEnv (if expired then "MB_TLS_EXPIRED_KEY" else "MB_TLS_CLIENT_KEY")
    params <- TLS.makeClientParams' cert [] key (TLS.CustomCAStore ca)
    configured <- if explicitHook then do
        credential <- WireTLS.credentialLoadX509 cert key >>= either (throwIO . userError) pure
        pure params {WireTLS.clientHooks=(WireTLS.clientHooks params)
            {WireTLS.onCertificateRequest = \_ -> pure (Just credential)}}
        else pure params
    TLS.connect ci (configured,"localhost")

cases :: [Case]
cases =
    [ Case "auth.mutual-tls-helper-client" "authentication" $ do
        ci <- config
        withConnect (clientCertificate False False ci {ciUser="mariadb_x509"}) healthy
    , Case "auth.mutual-tls-explicit-certificate-hook" "authentication" $ do
        ci <- config
        withConnect (clientCertificate False True ci {ciUser="mariadb_x509"}) healthy
    , Case "auth.mutual-tls-client-required" "authentication" $ do
        ci <- config
        expectRejection (withConnect (tlsConnect ci {ciUser="mariadb_x509"} "localhost") healthy)
    , Case "auth.mutual-tls-expired-client" "authentication" $ do
        ci <- config
        expectRejection (withConnect (clientCertificate True True ci {ciUser="mariadb_x509"}) healthy)
    , Case "auth.unix-socket-plugin" "authentication" $ do
        ci <- config; path <- socketPath
        withConnect (connectUnixSocket path ci {ciUser="mariadb_socket",ciPassword=""}) healthy
    , Case "auth.unix-socket-rejects-tcp" "authentication" $ do
        ci <- config
        expectERR [1045,1698] (withConnect (connect ci {ciUser="mariadb_socket",ciPassword=""}) healthy)
    , Case "connection.mozilla-ca-store-installed" "connection" $ void (TLS.makeClientParams TLS.MozillaCAStore)
    , Case "auth.pam-environment" "environment" $ throwIO (Unavailable "PAM helper from the Homebrew bottle could not acquire root ownership; no OS PAM login fixture is configured")
    , Case "auth.gssapi-environment" "environment" $ throwIO (Unavailable "no Kerberos realm, keytab or GSSAPI login fixture configured on this Mac")
    ]
