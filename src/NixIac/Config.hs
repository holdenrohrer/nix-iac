{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric     #-}
-- | The JSON schema `mkInfraApp` produces and `infra apply` consumes.
module NixIac.Config
  ( ApplyConfig (..)
  , HostSpec    (..)
  , Generator   (..)
  , Source      (..)
  , readConfig
  ) where

import qualified Data.Aeson         as A
import qualified Data.ByteString.Lazy as LBS
import           Data.Map.Strict    (Map)
import           GHC.Generics       (Generic)
import           NixIac.Run         (die)

-- | Tagged-union value source: sops file/key, existing tfstate output,
-- literal string, or a shell command whose stdout is the value.
data Source
  = SopsKey      { sopsFile :: FilePath, sopsKey :: String }
  | TfStateOutput String
  | Literal      String
  | Cmd          String
  deriving (Show)

instance A.FromJSON Source where
  parseJSON = A.withObject "Source" $ \o -> do
    kind <- o A..: "kind"
    case (kind :: String) of
      "sops"    -> SopsKey       <$> o A..: "file" <*> o A..: "key"
      "tfstate" -> TfStateOutput <$> o A..: "name"
      "literal" -> Literal       <$> o A..: "value"
      "cmd"     -> Cmd           <$> o A..: "command"
      x         -> fail ("unknown source kind: " <> x)

-- | A pinned-by-tfstate generated value.
data Generator
  = Once   { genCommand :: String, genSensitive :: Bool }
  | Derive { genFrom    :: String, genCommand   :: String, genSensitive :: Bool }
  deriving (Show)

instance A.FromJSON Generator where
  parseJSON = A.withObject "Generator" $ \o -> do
    t <- o A..: "type"
    case (t :: String) of
      "once"   -> Once   <$> o A..: "command" <*> o A..: "sensitive"
      "derive" -> Derive <$> o A..: "from"    <*> o A..: "command" <*> o A..: "sensitive"
      x        -> fail ("unknown generator type: " <> x)

data HostSpec = HostSpec
  { name              :: String
  , ipOutput          :: String
  , serverSecretsPath :: FilePath
  , generators        :: Map String Generator
  , serverSecrets     :: Map String Source
  } deriving (Show, Generic)

instance A.FromJSON HostSpec

data ApplyConfig = ApplyConfig
  { stateDir       :: FilePath
  , terranixConfig :: FilePath
  , flakeRef       :: String
  , deployEnv      :: Map String Source
  , hosts          :: [HostSpec]
  } deriving (Show, Generic)

instance A.FromJSON ApplyConfig

readConfig :: FilePath -> IO ApplyConfig
readConfig path = do
  bs <- LBS.readFile path
  case A.eitherDecode bs of
    Right c -> pure c
    Left  e -> die ("invalid apply config " <> path <> ": " <> e)
