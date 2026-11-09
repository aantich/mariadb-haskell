{-# LANGUAGE OverloadedStrings #-}

-- | Configuration diagnostics must never inspect or reveal password bytes.
module ConnectInfo (tests) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.List (isInfixOf)
import Database.MySQL.Base
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "connection diagnostics"
    [ testCase "redact empty, textual and arbitrary binary passwords" $
        forM_ [B.empty, "private-password-42", B.pack [0..255]] $ \password -> do
            let ci = defaultConnectInfo {ciPassword = password}
                rendered = show ci
            assertBool "password placeholder" ("ciPassword = <redacted>" `isInfixOf` rendered)
            if B.null password then pure () else
                assertBool "password representation is absent" (not (show password `isInfixOf` rendered))
            ciPassword ci @?= password
    , testCase "redaction does not evaluate a password" $ do
        let ci = defaultConnectInfo {ciPassword = error "password was inspected"}
        _ <- evaluate (length (show ci))
        pure ()
    , testCase "retain useful endpoint and account diagnostics" $ do
        let ci = defaultConnectInfo
                {ciHost = "db.example.com", ciPort = 3307, ciUser = "app", ciDatabase = "sample"}
        show ci @?= "ConnectInfo {ciHost = \"db.example.com\", ciPort = 3307, ciDatabase = \"sample\", ciUser = \"app\", ciPassword = <redacted>, ciCharset = 224}"
    , testCase "respect Show precedence without exposing credentials" $
        showsPrec 11 defaultConnectInfo "tail" @?= "(" ++ show defaultConnectInfo ++ ")tail"
    ]
