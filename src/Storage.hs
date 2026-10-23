{-# LANGUAGE OverloadedStrings #-}

module Storage
    ( saveFile
    ) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Data.Text (Text)
import System.FilePath ((</>))
import qualified System.Directory as Dir

import Types
import qualified Amazonka as AWS
import qualified Amazonka.S3 as S3
import Control.Monad.Trans.Resource (runResourceT)

saveFile :: StorageConfig -> Text -> FilePath -> BL.ByteString -> IO (Either String ())
saveFile (LocalStorage baseDir) token fileName payload = do
    let portalDir = baseDir </> T.unpack token
    Dir.createDirectoryIfMissing True portalDir
    let destPath = portalDir </> fileName
    BL.writeFile destPath payload
    pure (Right ())

saveFile (S3Storage bucketName _) token fileName payload = do
    env <- AWS.newEnv AWS.discover
    let bucket = S3.BucketName bucketName
        key    = S3.ObjectKey (token <> "/" <> T.pack fileName)
        body   = AWS.toBody payload
        req    = S3.newPutObject bucket key body
    res <- runResourceT $ do
        _ <- AWS.send env req
        pure ()
    pure (Right res)
