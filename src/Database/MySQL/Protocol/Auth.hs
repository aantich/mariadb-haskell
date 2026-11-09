{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}

{-|
Module      : Database.MySQL.Protocol.Auth
Description : Native MariaDB handshake and authentication packets
Copyright   : (c) Winterland, 2016
License     : BSD
Maintainer  : Anton Antich <anton.antich@gmail.com>
Stability   : experimental
Portability : PORTABLE

Auth related packet.

-}

module Database.MySQL.Protocol.Auth where

import           Control.Monad
import           Data.Binary
import           Data.Binary.Get
import           Data.Binary.Parser
import           Data.Binary.Put
import qualified Data.ByteString                as B
import           Data.ByteString.Char8          as BC
import           Data.Bits
import           Database.MySQL.Protocol.Packet

--------------------------------------------------------------------------------
-- Authentications

#define CLIENT_LONG_PASSWORD                  0x00000001
#define CLIENT_FOUND_ROWS                     0x00000002
#define CLIENT_LONG_FLAG                      0x00000004
#define CLIENT_CONNECT_WITH_DB                0x00000008
#define CLIENT_NO_SCHEMA                      0x00000010
#define CLIENT_COMPRESS                       0x00000020
#define CLIENT_ODBC                           0x00000040
#define CLIENT_LOCAL_FILES                    0x00000080
#define CLIENT_IGNORE_SPACE                   0x00000100
#define CLIENT_PROTOCOL_41                    0x00000200
#define CLIENT_INTERACTIVE                    0x00000400
#define CLIENT_SSL                            0x00000800
#define CLIENT_IGNORE_SIGPIPE                 0x00001000
#define CLIENT_TRANSACTIONS                   0x00002000
#define CLIENT_RESERVED                       0x00004000
#define CLIENT_SECURE_CONNECTION              0x00008000
#define CLIENT_MULTI_STATEMENTS               0x00010000
#define CLIENT_MULTI_RESULTS                  0x00020000
#define CLIENT_PS_MULTI_RESULTS               0x00040000
#define CLIENT_PLUGIN_AUTH                    0x00080000
#define CLIENT_CONNECT_ATTRS                  0x00100000
#define CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA 0x00200000

-- | Native MariaDB protocol-10 greeting. Capabilities retain both 32-bit words;
-- the salt fields are exact binary challenge bytes without a wire terminator.
data Greeting = Greeting
    { greetingProtocol :: !Word8
    , greetingVersion  :: !B.ByteString
    , greetingConnId   :: !Word32
    , greetingSalt1    :: !B.ByteString
    , greetingCaps     :: !Word64
    , greetingCharset  :: !Word8
    , greetingStatus   :: !Word16
    , greetingSalt2    :: !B.ByteString
    , greetingAuthPlugin :: !B.ByteString
    } deriving (Show, Eq)

-- | Encode the MariaDB greeting, including the upper capability word. Salt
-- fields contain exact challenge bytes, without the protocol terminator.
putGreeting :: Greeting -> Put
putGreeting (Greeting pv sv cid salt1 cap charset st salt2 plugin) = do
    putWord8 pv
    putByteString sv >> putWord8 0
    putWord32le cid
    putByteString salt1 >> putWord8 0
    putWord16le (fromIntegral cap)
    putWord8 charset
    putWord16le st
    putWord16le (fromIntegral (cap `shiftR` 16))
    putWord8 (fromIntegral (B.length salt1 + B.length salt2 + 1))
    replicateM_ 6 (putWord8 0)
    putWord32le (fromIntegral (cap `shiftR` 32))
    when (cap .&. CLIENT_SECURE_CONNECTION /= 0) (putByteString salt2 >> putWord8 0)
    when (cap .&. CLIENT_PLUGIN_AUTH /= 0) (putByteString plugin >> putWord8 0)

-- | Parse by the declared challenge length. A binary nonce may contain NUL;
-- only a plugin's known protocol terminator is removed, never an arbitrary byte.
getGreeting :: Get Greeting
getGreeting = do
    pv <- getWord8
    unless (pv == 10) (fail "unsupported MariaDB greeting protocol")
    sv <- getByteStringNul
    cid <- getWord32le
    salt1 <- getByteString 8
    skipN 1
    capL <- getWord16le
    charset <- getWord8
    status <- getWord16le
    capH <- getWord16le
    let low = fromIntegral capH `shiftL` 16 .|. fromIntegral capL
    challengeLength <- fromIntegral <$> getWord8
    skipN 6
    upper <- getWord32le
    let cap = low .|. if testBit low 0 then 0 else fromIntegral upper `shiftL` 32
    unless (cap .&. 0x88200 == 0x88200) (fail "MariaDB requires protocol-41, secure challenge and plugin authentication")
    salt2 <- if cap .&. CLIENT_SECURE_CONNECTION == 0 then pure B.empty
             else getByteString (if challengeLength >= 8 then challengeLength - 8 else 13)
    plugin <- if cap .&. CLIENT_PLUGIN_AUTH == 0 then pure "mysql_native_password"
              else getByteStringNul
    when (B.null plugin || B.length plugin > 128) (fail "invalid authentication plugin name")
    let exactLength = if plugin == "client_ed25519" || plugin == "parsec" then 32 else 20
        challenge = salt1 <> salt2
        exact = if B.length challenge == exactLength + 1 && B.last challenge == 0
                then B.init challenge else challenge
    pure (Greeting pv sv cid (B.take 8 exact) cap charset status (B.drop 8 exact) plugin)

instance Binary Greeting where
    get = getGreeting
    put = putGreeting

-- | Client response. Only implemented, server-offered capabilities belong here;
-- the upper word is emitted in reserved bytes 28..31 for a native client.
data Auth = Auth
    { authCaps      :: !Word64
    , authMaxPacket :: !Word32
    , authCharset   :: !Word8
    , authName      :: !ByteString
    , authPassword  :: !ByteString
    , authSchema    :: !ByteString
    , authPlugin    :: !ByteString
    } deriving (Show, Eq)

-- | Decode the fixed client header. The extension word occupies bytes 28..31 of both client handshake forms.
-- Legacy-marked peers use zero reserved bytes instead of an extension word.
getClientHeader :: Get (Word64, Word32, Word8)
getClientHeader = do
    low <- getWord32le
    size <- getWord32le
    charset <- getWord8
    skipN 19
    upper <- getWord32le
    pure (fromIntegral low .|. if testBit low 0 then 0 else fromIntegral upper `shiftL` 32, size, charset)

-- | Encode the fixed header shared by Auth and SSLRequest. Native extension
-- bits occupy bytes 28..31; legacy-marked packets leave that word zero.
putClientHeader :: Word64 -> Word32 -> Word8 -> Put
putClientHeader caps size charset = do
    putWord32le (fromIntegral caps)
    putWord32le size
    putWord8 charset
    replicateM_ 19 (putWord8 0)
    putWord32le (if testBit caps 0 then 0 else fromIntegral (caps `shiftR` 32))

-- | Decode this client's secure-connection response format. The password
-- response is one-byte length-delimited; database/plugin fields follow flags.
getAuth :: Get Auth
getAuth = do
    (caps, size, charset) <- getClientHeader
    name <- getByteStringNul
    len <- fromIntegral <$> getWord8
    password <- getByteString len
    schema <- if testBit caps 3 then getByteStringNul else pure B.empty
    plugin <- if testBit caps 19 then getByteStringNul else pure B.empty
    pure (Auth caps size charset name password schema plugin)

-- | Encode a response with a password payload of at most 255 bytes. The
-- connected plugin dispatcher produces bounded payloads and negotiates flags.
putAuth :: Auth -> Put
putAuth (Auth caps size charset name password schema plugin) = do
    putClientHeader caps size charset
    putByteString name >> putWord8 0
    putWord8 (fromIntegral (B.length password))
    putByteString password
    when (testBit caps 3) (putByteString schema >> putWord8 0)
    when (testBit caps 19) (putByteString plugin >> putWord8 0)

instance Binary Auth where
    get = getAuth
    put = putAuth

-- | The 32-byte pre-TLS request uses the same capability layout as Auth.
-- Its bits must agree with the following authenticated TLS response.
data SSLRequest = SSLRequest
    { sslReqCaps      :: !Word64
    , sslReqMaxPacket :: !Word32
    , sslReqCharset   :: !Word8
    } deriving (Show, Eq)

-- | Decode the complete fixed portion of the pre-TLS request. Callers
-- validating an envelope should require exact packet consumption.
getSSLRequest :: Get SSLRequest
getSSLRequest = do
    (caps, size, charset) <- getClientHeader
    pure (SSLRequest caps size charset)

-- | Encode the 32-byte request sent before starting the TLS handshake.
putSSLRequest :: SSLRequest -> Put
putSSLRequest (SSLRequest caps size charset) = putClientHeader caps size charset

instance Binary SSLRequest where
    get = getSSLRequest
    put = putSSLRequest

--------------------------------------------------------------------------------
-- default Capability Flags

-- | Implemented ordinary capabilities before intersection with the server.
-- Native extension features remain off until their readers are implemented.
clientCap :: Word64
-- Bit zero is MariaDB's legacy-client marker. Clearing it enables the
-- extension-word layout; unimplemented high-word features stay disabled.
clientCap =  CLIENT_LONG_FLAG
                .|. CLIENT_CONNECT_WITH_DB
                .|. CLIENT_IGNORE_SPACE
                .|. CLIENT_PROTOCOL_41
                .|. CLIENT_TRANSACTIONS
                .|. CLIENT_MULTI_STATEMENTS
                .|. CLIENT_MULTI_RESULTS
                .|. CLIENT_PS_MULTI_RESULTS
                .|. CLIENT_SECURE_CONNECTION
                .|. CLIENT_PLUGIN_AUTH

-- | Historical low-level default; connected APIs advertise the configured
-- logical-message limit from ConnectionOptions instead.
clientMaxPacketSize :: Word32
clientMaxPacketSize = 0x00ffffff :: Word32


-- | Whether the greeting offers TLS, without enabling it or downgrading.
supportTLS :: Word64 -> Bool
supportTLS x = (x .&. CLIENT_SSL) /= 0

-- | Low-level default request builder. Live constructors instead intersect
-- capabilities with their server and use the configured packet limit.
sslRequest :: Word8 -> SSLRequest
sslRequest charset = SSLRequest (clientCap .|. CLIENT_SSL) clientMaxPacketSize charset
