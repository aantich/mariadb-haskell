module Data.Connection where

import qualified Data.ByteString           as B
import qualified Data.ByteString.Lazy.Internal as L
import qualified System.IO.Streams         as S

-- | Low-level byte-stream transport. Application MariaDB code should use
-- the managed connection in "Database.MySQL.Base", which adds command leases,
-- framing, cancellation retirement and bounded cleanup.
--
-- The source supports io-streams pushback; reads may block until data/EOF.
-- Sending accepts lazy bytes so builders can supply chunks without flattening.
-- 'connExtraInfo' carries transport-specific metadata such as a socket address.
--
-- The caller owns this raw resource: bracket 'close', coordinate outstanding
-- reads/writes before closing, and never use the connection after close.
-- A peer disconnect or operation exception is not itself a generic guarantee
-- that every implementation of this record released its underlying resource.
--
data Connection a = Connection
    { source        :: {-# UNPACK #-} !(S.InputStream B.ByteString)   -- ^ receive data as 'S.InputStream'
    , send          :: L.ByteString -> IO ()                          -- ^ send data with connection
    , close         :: IO ()                                          -- ^ close connection
    , connExtraInfo :: a                                              -- ^ extra info
    }
