{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Types where

import Data.Aeson (FromJSON(..), ToJSON(..), genericToJSON, genericParseJSON, defaultOptions)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

data CreatePortalRequest = CreatePortalRequest
    { reqMaxFiles      :: Int
    , reqMaxFileSizeMB :: Int
    , reqMaxUses       :: Int
    , reqExpiresAt     :: Maybe UTCTime
    } deriving (Show, Generic)

instance ToJSON CreatePortalRequest where toJSON = genericToJSON defaultOptions
instance FromJSON CreatePortalRequest where parseJSON = genericParseJSON defaultOptions

data CreatePortalResponse = CreatePortalResponse
    { uploadToken  :: Text
    , uploadUrl    :: Text
    , receiveToken :: Text
    , receiveUrl   :: Text
    , portalOtp    :: Text
    } deriving (Show, Generic)

instance ToJSON CreatePortalResponse where toJSON = genericToJSON defaultOptions
instance FromJSON CreatePortalResponse where parseJSON = genericParseJSON defaultOptions

data AuthRequest = AuthRequest
    { authOtp :: Text
    } deriving (Show, Generic)

instance ToJSON AuthRequest where toJSON = genericToJSON defaultOptions
instance FromJSON AuthRequest where parseJSON = genericParseJSON defaultOptions

data UploadedFileMeta = UploadedFileMeta
    { fileNameStr :: Text
    , fileSize    :: Int
    } deriving (Show, Generic)

instance ToJSON UploadedFileMeta where toJSON = genericToJSON defaultOptions
instance FromJSON UploadedFileMeta where parseJSON = genericParseJSON defaultOptions

data PortalState = PortalState
    { psMaxFiles      :: Int
    , psMaxFileSizeMB :: Int
    , psMaxUses       :: Int
    , psCurrentUses   :: Int
    , psFiles         :: [UploadedFileMeta]
    , psOtp           :: Text
    , psExpiresAt     :: Maybe UTCTime
    } deriving (Show, Generic)

instance ToJSON PortalState where toJSON = genericToJSON defaultOptions
instance FromJSON PortalState where parseJSON = genericParseJSON defaultOptions

data StorageConfig
    = LocalStorage FilePath
    | S3Storage Text Text
    deriving (Show, Generic)
