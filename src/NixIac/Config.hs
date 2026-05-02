{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric     #-}
-- | The JSON schema `mkInfraApp` produces and `infra apply-config` consumes.
--
-- Designed to be readable and to round-trip cleanly via Aeson's generic
-- instances; field names match the JSON exactly (no key massaging).
module NixIac.Config
  ( ApplyConfig (..)
  , HostSpec    (..)
  , Generator   (..)
  , GenKind     (..)
  , Source      (..)
  , readConfig
  ) where

import qualified Data.Aeson         as A
import qualified Data.ByteString.Lazy as LBS
import           Data.Map.Strict    (Map)
import           GHC.Generics       (Generic)
import           NixIac.Run         (die)

-- | Tagged-union value source: either a sops file/key, an existing tfstate
-- output, a literal string, or a shell command whose stdout is the value.
-- Mirrors the constructors in nix-iac's lib/higher.nix.
data Source
  = SopsKey      { file  :: FilePath, key :: String }
  | TfStateOutput String
  | Literal      String
  | Cmd          String
  deriving (Show, Generic)

instance A.FromJSON Source where
  parseJSON = A.withObject "Source" $ \o -> do
    kind <- o A..: "kind"
    case (kind :: String) of
      "sops"    -> SopsKey      <$> o A..: "file" <*> o A..: "key"
      "tfstate" -> TfStateOutput <$> o A..: "name"
      "literal" -> Literal      <$> o A..: "value"
      "cmd"     -> Cmd          <$> o A..: "command"
      x         -> fail ("unknown source kind: " <> x)

data GenKind = Once | Derive { from :: String } deriving (Show, Generic)

instance A.FromJSON GenKind where
  parseJSON = A.withObject "GenKind" $ \o -> do
    t <- o A..: "type"
    case (t :: String) of
      "once"   -> pure Once
      "derive" -> Derive <$> o A..: "from"
      x        -> fail ("unknown generator type: " <> x)

-- | A pinned-by-tfstate generated value (matches the `once`/`derive`
-- constructors). `sensitive` controls whether the resulting tfstate
-- output is marked sensitive; no functional difference at apply time.
data Generator = Generator
  { kind      :: GenKind
  , command   :: String
  , sensitive :: Bool
  } deriving (Show, Generic)

instance A.FromJSON Generator

-- | One target host.
data HostSpec = HostSpec
  { name              :: String
  , ipOutput          :: String
  , serverSecretsPath :: FilePath          -- where the encrypted blob lands
  , generators        :: Map String Generator
  , serverSecrets     :: Map String Source -- contents of the blob
  } deriving (Show, Generic)

instance A.FromJSON HostSpec

-- | Top-level deploy configuration.
data ApplyConfig = ApplyConfig
  { stateDir       :: FilePath
  , terranixConfig :: FilePath  -- the rendered config.tf.json
  , flakeRef       :: String    -- consumer flake reference
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
