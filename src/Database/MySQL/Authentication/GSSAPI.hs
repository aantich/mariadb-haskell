{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Internal platform provider. SQL transport and authentication policy remain
-- in Connection; this module owns only native context lifetime and token steps.
module Database.MySQL.Authentication.GSSAPI (GSSAPIError(..), withGSSAPI) where

import Control.Exception
import Data.ByteString (ByteString)

#ifndef mingw32_HOST_OS
import Control.Concurrent
import Control.Monad
import qualified Data.ByteString as B
import Foreign hiding (void)
import Foreign.C.Types

#endif

newtype GSSAPIError = GSSAPIError String deriving Show
instance Exception GSSAPIError

#ifdef mingw32_HOST_OS
-- Windows needs an SSPI provider; do not fail every ordinary-driver build by
-- attempting to link Unix GSSAPI libraries on that platform.
withGSSAPI :: ByteString -> Bool -> ((ByteString -> IO (Bool, ByteString)) -> IO a) -> IO a
withGSSAPI _ _ _ = throwIO (GSSAPIError "native GSSAPI requires a Unix platform provider")
#else
-- A worker is the sole owner of native state. Cancelling the connecting thread
-- enqueues Stop without waiting for a potentially blocking KDC request. The
-- worker finishes that request, releases its context and exits; it has no socket
-- access and cannot continue authentication after the caller's transport closes.
-- This also prevents a finalizer racing gss_init_sec_context in a safe FFI call.
data Request = Step ByteString (MVar (Either SomeException (Bool, ByteString))) | Stop
data NativeContext

foreign import ccall safe "mariadb_gss_open"
    nativeOpen :: Ptr CChar -> CSize -> CInt -> Ptr (Ptr NativeContext)
               -> Ptr Word32 -> Ptr Word32 -> IO CInt
foreign import ccall safe "mariadb_gss_step"
    nativeStep :: Ptr NativeContext -> Ptr CChar -> CSize -> Ptr (Ptr CChar)
               -> Ptr CSize -> Ptr CInt -> Ptr Word32 -> Ptr Word32 -> IO CInt
foreign import ccall safe "mariadb_gss_close"
    nativeClose :: Ptr NativeContext -> IO ()

-- | Internal provider boundary. One serialized step yields completion plus an
-- owned token copy. All output is bounded to 1 MiB. Native work already in
-- progress can outlive cancellation, subject to the OS Kerberos retry policy;
-- cancellation itself never waits for it and never exposes the socket to it.
withGSSAPI :: ByteString -> Bool -> ((ByteString -> IO (Bool, ByteString)) -> IO a) -> IO a
withGSSAPI principal negotiate action = mask $ \restore -> do
    -- A non-threaded RTS cannot run the timeout handler while another Haskell
    -- thread is inside a safe foreign call. Fail before acquiring credentials
    -- rather than silently weakening the connection deadline.
    unless rtsSupportsBoundThreads
        (throwIO (GSSAPIError "GSSAPI authentication requires an application built with -threaded"))
    requests <- newEmptyMVar
    ready <- newEmptyMVar
    _ <- forkIO $ do
        opened <- try (openContext principal negotiate)
        putMVar ready opened
        case opened of
            Left (_ :: SomeException) -> pure ()
            Right context -> worker requests context `finally` nativeClose context
    -- A cancelled caller can leave Step in the single-slot queue. Queue Stop
    -- from a helper rather than dropping it or blocking connection cleanup.
    let stop = void (forkIO (putMVar requests Stop))
        step token = do
            reply <- newEmptyMVar
            putMVar requests (Step token reply)
            takeMVar reply >>= either throwIO pure
    flip finally stop $ do
        restore (takeMVar ready) >>= either throwIO (const (pure ()))
        restore (action step)
  where
    worker requests context = do
        request <- takeMVar requests
        case request of
            Stop -> pure ()
            Step token reply -> do
                result <- try (stepContext context token)
                putMVar reply result
                worker requests context

openContext :: ByteString -> Bool -> IO (Ptr NativeContext)
openContext principal negotiate = B.useAsCStringLen principal $ \(name,size) ->
    alloca $ \result -> alloca $ \major -> alloca $ \minor -> do
        status <- nativeOpen name (fromIntegral size) (if negotiate then 1 else 0) result major minor
        checkNative status major minor
        peek result

stepContext :: Ptr NativeContext -> ByteString -> IO (Bool, ByteString)
stepContext context token = B.useAsCStringLen token $ \(input,size) ->
    alloca $ \output -> alloca $ \lengthPtr -> alloca $ \complete ->
    alloca $ \major -> alloca $ \minor -> do
        status <- nativeStep context input (fromIntegral size) output lengthPtr complete major minor
        checkNative status major minor
        count <- fromIntegral <$> peek lengthPtr
        bytes <- if count == 0 then pure B.empty else peek output >>= \ptr -> B.packCStringLen (ptr,count)
        done <- (/= 0) <$> peek complete
        pure (done,bytes)

checkNative :: CInt -> Ptr Word32 -> Ptr Word32 -> IO ()
checkNative status major minor = unless (status == 0) $ do
    majorCode <- peek major
    minorCode <- peek minor
    -- Numeric provider codes retain diagnostics without logging ticket bodies,
    -- credentials, cache names or server-controlled challenge text.
    throwIO (GSSAPIError ("GSSAPI authentication failed (status " ++ show status ++
        ", major " ++ show majorCode ++ ", minor " ++ show minorCode ++ ")"))

#endif
