-- | Explicit external authentication settings. PAM replies are cleartext and
-- require TLS or a Unix socket. GSSAPI uses existing system credentials, never
-- the SQL password, and requires an exact expected server principal.
module Database.MySQL.Authentication
    ( AuthenticationOptions(..)
    , defaultAuthenticationOptions
    , DialogPrompt(..)
    , passwordDialog
    ) where

import Data.ByteString (ByteString)

-- | Authentication-only settings, discarded after establishment. Callbacks run
-- on the connecting thread under the connection deadline; exceptions propagate
-- and close the transport. Do not log their replies or the SQL credentials.
data AuthenticationOptions = AuthenticationOptions
    { authenticationDialog :: Maybe (DialogPrompt -> IO ByteString)
      -- ^ Opt in to PAM/dialog and clear-password replies. No terminal fallback.
    , authenticationGSSAPIPrincipal :: Maybe ByteString
      -- ^ Require GSSAPI with this exact service principal, including realm.
      -- Password-only success and alternate plugin switches are rejected;
      -- no initial password proof is emitted before GSSAPI negotiation.
      -- Native GSSAPI requires an application built with @-threaded@ so a KDC
      -- call cannot prevent the connection deadline or cancellation handler.
    }

-- | Disable external credential use until the application opts in explicitly.
defaultAuthenticationOptions :: AuthenticationOptions
defaultAuthenticationOptions = AuthenticationOptions Nothing Nothing

-- | One MariaDB dialog question. Text is the server's uninterpreted prompt,
-- without its terminal NUL. Round numbers start at zero. A final question still
-- requires the server's OK before authentication succeeds.
data DialogPrompt = DialogPrompt
    { dialogText :: !ByteString
    , dialogEcho :: !Bool
    , dialogLast :: !Bool
    , dialogRound :: !Int
    } deriving (Eq, Show)

-- | A noninteractive single-password PAM callback. Only the first hidden prompt
-- is accepted; a PIN, username or second factor needs an application callback.
-- Embedded NUL and response-size checks are applied by the authentication loop.
passwordDialog :: ByteString -> DialogPrompt -> IO ByteString
passwordDialog password prompt
    | not (dialogEcho prompt) && dialogRound prompt == 0 = pure password
    | otherwise = ioError (userError "PAM requires an application dialog callback")

