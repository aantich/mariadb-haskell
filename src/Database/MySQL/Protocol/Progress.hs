-- | MariaDB progress envelopes use a reserved ERR number without completing
-- the command. Parsing remains separate from callback/lifecycle policy.
module Database.MySQL.Protocol.Progress
    ( Progress(..), isProgressPacket, getProgress ) where

import Control.Monad (unless)
import Data.Binary.Parser
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Word
import Database.MySQL.Protocol.Packet

-- | One server stage. 'progressThousandths' ranges from zero to 100000 (100%);
-- stages are one-based. Description bytes use the server encoding and are
-- copied out of the wire buffer. A report does not guarantee eventual success.
data Progress = Progress
    { progressStage :: !Word8
    , progressStageCount :: !Word8
    , progressThousandths :: !Word32
    , progressInfo :: !B.ByteString
    } deriving (Eq, Show)

-- | Recognize the reserved marker without flattening an ordinary packet.
isProgressPacket :: Packet -> Bool
isProgressPacket packet = L.take 3 (pBody packet) == L.pack [255,255,255]

-- | Parse the single-description wire format. Use an exact packet parser to
-- reject trailers; unknown description counts and invalid ranges fail closed.
getProgress :: Get Progress
getProgress = do
    marker <- getByteString 3
    unless (marker == B.pack [255,255,255]) (fail "invalid progress marker")
    strings <- getWord8
    unless (strings == 1) (fail "unsupported progress description count")
    stage <- getWord8
    stages <- getWord8
    a <- fromIntegral <$> getWord8
    b <- fromIntegral <$> getWord8
    c <- fromIntegral <$> getWord8
    let amount = a .|. (b `shiftL` 8) .|. (c `shiftL` 16)
    unless (stage > 0 && stage <= stages && amount <= 100000)
        (fail "invalid progress stage or percentage")
    info <- B.copy <$> getLenEncBytes
    pure (Progress stage stages amount info)
