{-|
Module      : Database.MySQL.Field
Description : Convert between Haskell values and 'MySQLValue' fields
Copyright   : (c) Jappie Klooster, 2026
License     : BSD3
Maintainer  : Anton Antich <anton.antich@gmail.com>
Stability   : experimental
Portability : PORTABLE

A single typeclass, 'Field', for converting an individual Haskell value
to and from a 'MySQLValue'. This is the extension point libraries such as
@beam-mysql@ need to marshal user column types generically: encoding is
total ('toField'), decoding returns 'DecodeError' on the 'Left'
('fromField').

Every instance must obey the roundtrip law:

@
'fromField' ('toField' x) == 'Right' x
@

Two caveats:

* 'Maybe' wrapped around a type that itself encodes to @MySQLNull@
  (@Maybe (Maybe a)@, @Maybe MySQLValue@): SQL cannot represent a
  @Just NULL@ distinct from @NULL@, so both collapse to 'Nothing' on the
  way back. Nullable columns want exactly one 'Maybe'.

* IEEE @NaN@ fails the equation literally because @NaN /= NaN@; the
  'Float' and 'Double' encodings are still lossless and decoding returns
  the same @NaN@.

All instances delegate to named top-level functions (@encodeInt8@,
@decodeInt8@, ...) so the conversions can be used, tested and grepped
without the class.

Decoding is strict and canonical: each Haskell type decodes only from the
constructor(s) carrying exactly its payload, with no implicit numeric
widening or narrowing. There are no instances for 'Int' and 'Word'
because their width is platform dependent; use 'Data.Int.Int64' or
'Data.Word.Word64'.
-}
module Database.MySQL.Field
    ( -- * The Field class
      Field (..)
      -- * Conversion errors
    , DecodeError (..)
    , ExpectedTypeName (..)
    , EncodeStringError (..)
      -- * Named conversions backing the instances
    , encodeInt8, decodeInt8
    , encodeWord8, decodeWord8
    , encodeInt16, decodeInt16
    , encodeWord16, decodeWord16
    , encodeInt32, decodeInt32
    , encodeWord32, decodeWord32
    , encodeInt64, decodeInt64
    , encodeWord64, decodeWord64
    , encodeFloat', decodeFloat'
    , encodeDouble, decodeDouble
    , encodeScientific, decodeScientific
    , encodeText, decodeText
    , encodeLazyText, decodeLazyText
    , encodeString, encodeStringOrCrash, decodeString
    , encodeByteString, decodeByteString
    , encodeLazyByteString, decodeLazyByteString
    , encodeDay, decodeDay
    , encodeLocalTime, decodeLocalTime
    , encodeTimeOfDay, decodeTimeOfDay
    , encodeBool, decodeBool
    , encodeMaybe, decodeMaybe
    ) where

import           Control.Exception                  (Exception)
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString.Lazy               as LazyByteString
import           Data.Int                           (Int16, Int32, Int64, Int8)
import           Data.Scientific                    (Scientific)
import           Data.Text                          (Text)
import qualified Data.Text                          as Text
import qualified Data.Text.Lazy                     as LazyText
import           Data.Time.Calendar                 (Day)
import           Data.Time.LocalTime                (LocalTime, TimeOfDay)
import           Data.Word                          (Word16, Word32, Word64,
                                                     Word8)
import           Database.MySQL.Protocol.MySQLValue (MySQLValue (..))

-- | The name of the Haskell type a decoder was trying to produce,
-- carried inside 'DecodeError' for error reporting.
newtype ExpectedTypeName = ExpectedTypeName Text
    deriving (Show, Eq)

-- | All the ways decoding a single field can fail.
data DecodeError
    = DecodeTypeMismatch !ExpectedTypeName !MySQLValue
      -- ^ The value's constructor does not match the requested Haskell
      -- type, e.g. asking for 'Int32' from a @MySQLText@.
    | DecodeUnexpectedNull !ExpectedTypeName
      -- ^ The value was @MySQLNull@ but the requested type is not
      -- 'Maybe'; wrap the type in 'Maybe' for nullable columns.
    deriving (Show, Eq)

instance Exception DecodeError

-- | Convert a single Haskell value to and from a 'MySQLValue'.
--
-- Instances must obey: @'fromField' ('toField' x) == 'Right' x@.
-- (Caveats: nested 'Maybe' collapses through @NULL@, and IEEE @NaN@
-- fails the literal equation; see the module header.)
class Field a where
    -- | Encode a value without SQL quoting. Most instances are total; the
    -- 'String' instance throws on lone surrogates. Use 'encodeString' when
    -- encoding untrusted 'String' input and handle its explicit error.
    toField :: a -> MySQLValue
    -- | Decode only the documented wire constructors. Nullable columns need
    -- 'Maybe'; type/NULL mismatch is returned without numeric coercion.
    fromField :: MySQLValue -> Either DecodeError a

-- | Build the error for a value whose constructor does not match,
-- mapping @MySQLNull@ to 'DecodeUnexpectedNull' and everything else to
-- 'DecodeTypeMismatch'.
decodeFailure :: ExpectedTypeName -> MySQLValue -> Either DecodeError a
decodeFailure expected MySQLNull = Left (DecodeUnexpectedNull expected)
decodeFailure expected value     = Left (DecodeTypeMismatch expected value)

-- | Construct @MySQLInt8@ without SQL rendering.
encodeInt8 :: Int8 -> MySQLValue
encodeInt8 = MySQLInt8

-- | Accept only @MySQLInt8@; NULL/type mismatch returns 'DecodeError'.
decodeInt8 :: MySQLValue -> Either DecodeError Int8
decodeInt8 (MySQLInt8 n) = Right n
decodeInt8 value         = decodeFailure (ExpectedTypeName "Int8") value

instance Field Int8 where
    toField = encodeInt8
    fromField = decodeInt8

-- | Construct @MySQLInt8U@ without SQL rendering.
encodeWord8 :: Word8 -> MySQLValue
encodeWord8 = MySQLInt8U

-- | Accept only @MySQLInt8U@; NULL/type mismatch returns 'DecodeError'.
decodeWord8 :: MySQLValue -> Either DecodeError Word8
decodeWord8 (MySQLInt8U n) = Right n
decodeWord8 value          = decodeFailure (ExpectedTypeName "Word8") value

instance Field Word8 where
    toField = encodeWord8
    fromField = decodeWord8

-- | Construct @MySQLInt16@ without SQL rendering.
encodeInt16 :: Int16 -> MySQLValue
encodeInt16 = MySQLInt16

-- | Accept only @MySQLInt16@; NULL/type mismatch returns 'DecodeError'.
decodeInt16 :: MySQLValue -> Either DecodeError Int16
decodeInt16 (MySQLInt16 n) = Right n
decodeInt16 value          = decodeFailure (ExpectedTypeName "Int16") value

instance Field Int16 where
    toField = encodeInt16
    fromField = decodeInt16

-- | Construct @MySQLInt16U@ without SQL rendering.
encodeWord16 :: Word16 -> MySQLValue
encodeWord16 = MySQLInt16U

-- | Accept only @MySQLInt16U@; NULL/type mismatch returns 'DecodeError'.
decodeWord16 :: MySQLValue -> Either DecodeError Word16
decodeWord16 (MySQLInt16U n) = Right n
decodeWord16 value           = decodeFailure (ExpectedTypeName "Word16") value

instance Field Word16 where
    toField = encodeWord16
    fromField = decodeWord16

-- | Construct @MySQLInt32@ without SQL rendering.
encodeInt32 :: Int32 -> MySQLValue
encodeInt32 = MySQLInt32

-- | Accept only @MySQLInt32@; NULL/type mismatch returns 'DecodeError'.
decodeInt32 :: MySQLValue -> Either DecodeError Int32
decodeInt32 (MySQLInt32 n) = Right n
decodeInt32 value          = decodeFailure (ExpectedTypeName "Int32") value

instance Field Int32 where
    toField = encodeInt32
    fromField = decodeInt32

-- | Construct @MySQLInt32U@ without SQL rendering.
encodeWord32 :: Word32 -> MySQLValue
encodeWord32 = MySQLInt32U

-- | Accept only @MySQLInt32U@; NULL/type mismatch returns 'DecodeError'.
decodeWord32 :: MySQLValue -> Either DecodeError Word32
decodeWord32 (MySQLInt32U n) = Right n
decodeWord32 value           = decodeFailure (ExpectedTypeName "Word32") value

instance Field Word32 where
    toField = encodeWord32
    fromField = decodeWord32

-- | Construct @MySQLInt64@ without SQL rendering.
encodeInt64 :: Int64 -> MySQLValue
encodeInt64 = MySQLInt64

-- | Accept only @MySQLInt64@; NULL/type mismatch returns 'DecodeError'.
decodeInt64 :: MySQLValue -> Either DecodeError Int64
decodeInt64 (MySQLInt64 n) = Right n
decodeInt64 value          = decodeFailure (ExpectedTypeName "Int64") value

instance Field Int64 where
    toField = encodeInt64
    fromField = decodeInt64

-- | Construct @MySQLInt64U@ without SQL rendering.
encodeWord64 :: Word64 -> MySQLValue
encodeWord64 = MySQLInt64U

-- | Accept only @MySQLInt64U@; NULL/type mismatch returns 'DecodeError'.
decodeWord64 :: MySQLValue -> Either DecodeError Word64
decodeWord64 (MySQLInt64U n) = Right n
decodeWord64 value           = decodeFailure (ExpectedTypeName "Word64") value

instance Field Word64 where
    toField = encodeWord64
    fromField = decodeWord64

-- | Named with a prime because "Prelude" already exports
-- 'Prelude.encodeFloat'.
encodeFloat' :: Float -> MySQLValue
encodeFloat' = MySQLFloat

-- | Accept only @MySQLFloat@, preserving IEEE values including NaN.
decodeFloat' :: MySQLValue -> Either DecodeError Float
decodeFloat' (MySQLFloat x) = Right x
decodeFloat' value          = decodeFailure (ExpectedTypeName "Float") value

instance Field Float where
    toField = encodeFloat'
    fromField = decodeFloat'

-- | Construct @MySQLDouble@ without SQL rendering.
encodeDouble :: Double -> MySQLValue
encodeDouble = MySQLDouble

-- | Accept only @MySQLDouble@; NULL/type mismatch returns 'DecodeError'.
decodeDouble :: MySQLValue -> Either DecodeError Double
decodeDouble (MySQLDouble x) = Right x
decodeDouble value           = decodeFailure (ExpectedTypeName "Double") value

instance Field Double where
    toField = encodeDouble
    fromField = decodeDouble

-- | Construct @MySQLDecimal@ without SQL rendering.
encodeScientific :: Scientific -> MySQLValue
encodeScientific = MySQLDecimal

-- | Accept only @MySQLDecimal@; NULL/type mismatch returns 'DecodeError'.
decodeScientific :: MySQLValue -> Either DecodeError Scientific
decodeScientific (MySQLDecimal n) = Right n
decodeScientific value            = decodeFailure (ExpectedTypeName "Scientific") value

instance Field Scientific where
    toField = encodeScientific
    fromField = decodeScientific

-- Decision: 'Text' decodes only from @MySQLText@, not from @MySQLBytes@.
-- A @MySQLBytes@ comes from a binary-collated column and need not be valid
-- UTF-8; guessing an encoding here would be a silent failure waiting to
-- happen. Read binary columns as 'ByteString' and decode explicitly.
-- | Construct @MySQLText@ without SQL rendering.
encodeText :: Text -> MySQLValue
encodeText = MySQLText

-- | Accept only @MySQLText@; NULL/type mismatch returns 'DecodeError'.
decodeText :: MySQLValue -> Either DecodeError Text
decodeText (MySQLText t) = Right t
decodeText value         = decodeFailure (ExpectedTypeName "Text") value

instance Field Text where
    toField = encodeText
    fromField = decodeText

-- | Construct @MySQLText@ without SQL rendering. Materializes the lazy input.
encodeLazyText :: LazyText.Text -> MySQLValue
encodeLazyText = MySQLText . LazyText.toStrict

-- | Accept only @MySQLText@; NULL/type mismatch returns 'DecodeError'.
decodeLazyText :: MySQLValue -> Either DecodeError LazyText.Text
decodeLazyText (MySQLText t) = Right (LazyText.fromStrict t)
decodeLazyText value         = decodeFailure (ExpectedTypeName "lazy Text") value

instance Field LazyText.Text where
    toField = encodeLazyText
    fromField = decodeLazyText

-- | All the ways encoding a 'String' can fail.
data EncodeStringError
    = EncodeStringLoneSurrogate !String
      -- ^ The 'String' contained a lone surrogate code point (@\\xD800@
      -- to @\\xDFFF@), which is not valid Unicode text and cannot be
      -- represented in MariaDB's UTF-8 wire format. @Text.pack@ would
      -- silently replace it with @U+FFFD@, corrupting the data.
    deriving (Show, Eq)

instance Exception EncodeStringError

-- | Validate Unicode scalar values and construct @MySQLText@; lone surrogates return an error.
encodeString :: String -> Either EncodeStringError MySQLValue
encodeString string =
    if any isLoneSurrogate string
        then Left (EncodeStringLoneSurrogate string)
        else Right (MySQLText (Text.pack string))

isLoneSurrogate :: Char -> Bool
isLoneSurrogate character = '\xD800' <= character && character <= '\xDFFF'

-- | Backs the 'Field' 'String' instance: the class fixes
-- @toField :: a -> MySQLValue@, so the 'EncodeStringLoneSurrogate'
-- failure from 'encodeString' crashes here instead of being returned.
encodeStringOrCrash :: String -> MySQLValue
encodeStringOrCrash string = case encodeString string of
    Right value -> value
    Left (EncodeStringLoneSurrogate offending) ->
        error ("Database.MySQL.Field.encodeString: \
               \lone surrogate code point in String: " <> show offending
               <> ". This String is not valid Unicode, so the bug is \
                  \in whatever produced it (truncated UTF-16 or bad \
                  \decoding upstream). Fix that producer, or filter \
                  \the surrogates out before calling toField.")

-- | Unpack @MySQLText@; bytes are not guessed to be UTF-8.
decodeString :: MySQLValue -> Either DecodeError String
decodeString (MySQLText t) = Right (Text.unpack t)
decodeString value         = decodeFailure (ExpectedTypeName "String") value

instance Field String where
    toField = encodeStringOrCrash
    fromField = decodeString

-- | Construct @MySQLBytes@ without SQL rendering.
encodeByteString :: ByteString -> MySQLValue
encodeByteString = MySQLBytes

-- | Accept only @MySQLBytes@; NULL/type mismatch returns 'DecodeError'.
decodeByteString :: MySQLValue -> Either DecodeError ByteString
decodeByteString (MySQLBytes bs) = Right bs
decodeByteString value           = decodeFailure (ExpectedTypeName "ByteString") value

instance Field ByteString where
    toField = encodeByteString
    fromField = decodeByteString

-- | Construct @MySQLBytes@ without SQL rendering. Materializes the lazy input.
encodeLazyByteString :: LazyByteString.ByteString -> MySQLValue
encodeLazyByteString = MySQLBytes . LazyByteString.toStrict

-- | Accept only @MySQLBytes@; NULL/type mismatch returns 'DecodeError'.
decodeLazyByteString :: MySQLValue -> Either DecodeError LazyByteString.ByteString
decodeLazyByteString (MySQLBytes bs) = Right (LazyByteString.fromStrict bs)
decodeLazyByteString value           = decodeFailure (ExpectedTypeName "lazy ByteString") value

instance Field LazyByteString.ByteString where
    toField = encodeLazyByteString
    fromField = decodeLazyByteString

-- | Construct @MySQLDate@ without SQL rendering.
encodeDay :: Day -> MySQLValue
encodeDay = MySQLDate

-- | Accept only @MySQLDate@; NULL/type mismatch returns 'DecodeError'.
decodeDay :: MySQLValue -> Either DecodeError Day
decodeDay (MySQLDate d) = Right d
decodeDay value         = decodeFailure (ExpectedTypeName "Day") value

instance Field Day where
    toField = encodeDay
    fromField = decodeDay

-- Decision: t'LocalTime' decodes from both @MySQLDateTime@ and
-- @MySQLTimeStamp@, since both carry a t'LocalTime' payload and which one
-- arrives depends on the column type, not on the Haskell type. Encoding
-- canonically produces @MySQLDateTime@; the roundtrip law still holds.
-- | Construct @MySQLDateTime@ without applying a time-zone conversion.
encodeLocalTime :: LocalTime -> MySQLValue
encodeLocalTime = MySQLDateTime

-- | Accept @MySQLDateTime@ or @MySQLTimeStamp@ in the session's time zone; raw dates fail.
decodeLocalTime :: MySQLValue -> Either DecodeError LocalTime
decodeLocalTime (MySQLDateTime t)  = Right t
decodeLocalTime (MySQLTimeStamp t) = Right t
decodeLocalTime value              = decodeFailure (ExpectedTypeName "LocalTime") value

instance Field LocalTime where
    toField = encodeLocalTime
    fromField = decodeLocalTime

-- | Construct a non-negative SQL TIME payload. The wire representation can
-- carry hours above 23; this helper does not validate a clock-time range.
-- Parameter binding subsequently checks MariaDB's range and precision.
-- For negative durations match/construct @MySQLTime@ directly.
encodeTimeOfDay :: TimeOfDay -> MySQLValue
encodeTimeOfDay = MySQLTime 0

-- | Accept a non-negative @MySQLTime@ payload; validate hours separately when a clock time is required.
decodeTimeOfDay :: MySQLValue -> Either DecodeError TimeOfDay
decodeTimeOfDay (MySQLTime sign t) =
    if sign == 0
        then Right t
        else decodeFailure (ExpectedTypeName "TimeOfDay") (MySQLTime sign t)
decodeTimeOfDay value = decodeFailure (ExpectedTypeName "TimeOfDay") value

instance Field TimeOfDay where
    toField = encodeTimeOfDay
    fromField = decodeTimeOfDay

-- Decision: 'Bool' maps to @TINYINT@, mirroring MariaDB where
-- @BOOLEAN@ is an alias for @TINYINT(1)@ and any nonzero value is true.
-- Both the signed and unsigned tiny constructors are accepted because the
-- column may be declared either way.
-- | Encode as signed @TINYINT@ zero or one, matching MariaDB's BOOLEAN alias.
encodeBool :: Bool -> MySQLValue
encodeBool True  = MySQLInt8 1
encodeBool False = MySQLInt8 0

-- | Accept signed/unsigned TINYINT; zero is False and every nonzero value is True.
decodeBool :: MySQLValue -> Either DecodeError Bool
decodeBool (MySQLInt8 n)  = Right (n /= 0)
decodeBool (MySQLInt8U n) = Right (n /= 0)
decodeBool value          = decodeFailure (ExpectedTypeName "Bool") value

instance Field Bool where
    toField = encodeBool
    fromField = decodeBool

-- | Encode Nothing as SQL NULL, otherwise delegate to 'toField'. Avoid nested nullable types.
encodeMaybe :: Field a => Maybe a -> MySQLValue
encodeMaybe Nothing      = MySQLNull
encodeMaybe (Just value) = toField value

-- | Decode NULL as Nothing; non-NULL values use the underlying 'fromField' instance.
decodeMaybe :: Field a => MySQLValue -> Either DecodeError (Maybe a)
decodeMaybe MySQLNull = Right Nothing
decodeMaybe value     = fmap Just (fromField value)

-- | @NULL@ maps to 'Nothing'; use this instance for nullable columns.
-- Do not nest it: SQL cannot distinguish @Just NULL@ from @NULL@, so
-- @Just Nothing@ decodes back as 'Nothing' and the roundtrip law breaks.
instance Field a => Field (Maybe a) where
    toField = encodeMaybe
    fromField = decodeMaybe

-- | The identity instance, an escape hatch for code that wants to handle
-- the raw protocol value in an otherwise 'Field'-polymorphic setting.
instance Field MySQLValue where
    toField = id
    fromField = Right
