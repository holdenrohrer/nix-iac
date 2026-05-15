{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The data types a per-consumer plan constructs and hands to
-- 'NixIac.Orchestrator.orchestrate'.
--
-- The Nix DSL (@lib/iac.nix@) is the source of truth for what these mean —
-- this module is just the Haskell-side mirror.
module NixIac.Plan
  ( Plan      (..)
  , TfStateCfg(..)
  , HostCfg   (..)
  , Source    (..)
  , Generator (..)
  , GenSpec   (..)
  ) where

import qualified Data.Aeson      as A
import           Data.Aeson      ((.:))
import qualified Data.Aeson.Key  as AK
import qualified Data.Aeson.KeyMap as AKM
import           Data.Aeson.Types (Parser)
import qualified Data.Text       as T

-- | Top-level orchestration input. Built once by the generated Main.
data Plan = Plan
  { planStateDir :: FilePath
    -- ^ Working directory where per-tfstate subdirs live.
    -- mkInfraApp sets this to a project-relative path; Main resolves
    -- it against the git toplevel before calling 'orchestrate'.
  , planFlakeRef :: String
    -- ^ Flake reference used as @<flakeRef>#<host>@ for nixify/deploy.
  , planTfStates :: [TfStateCfg]
    -- ^ Tfstates in apply order.
  , planDeployEnv :: [(String, Source)]
    -- ^ Environment variables exported before any tofu invocation.
    -- 'TfOut' is rejected here at runtime since tofu has not run yet.
  , planHosts :: [HostCfg]
    -- ^ Hosts to deploy after all tfstates have applied.
  }

-- | One tfstate's runtime config.
data TfStateCfg = TfStateCfg
  { tfsName       :: String
  , tfsConfigFile :: FilePath
    -- ^ Path to a generated @config.tf.json@ that includes the consumer's
    -- terranix modules plus declarations contributed by all reachable
    -- typed-handle Sources targeting this state.
  , tfsGenerators :: [GenSpec]
    -- ^ All generators whose values land in this state. In dependency
    -- order: a 'Derive' may only reference earlier entries (or sources
    -- in already-applied states).
  }

-- | One generator: its tfstate output name plus how to compute it.
data GenSpec = GenSpec
  { gsOutputName :: String
  , gsGenerator  :: Generator
  }

-- | A value that resolves at apply time. Mirrors @lib/iac.nix@'s 'Source'.
data Source
  = Literal String
  | Cmd     String
  | Sops    FilePath String
  | TfOut   String String
    -- ^ @TfOut stateName outputName@ — read raw output from the named
    -- tfstate. Only legal in contexts that run after that state's apply.

-- | A generator body. The @from@ field of 'Derive' is a 'Source' rather
-- than a string, mirroring the typed-handle DSL: at codegen time you
-- cannot wire to a non-existent generator.
data Generator
  = Once
      { genSensitive :: Bool
      , genCommand   :: String
      }
  | Derive
      { genSensitive :: Bool
      , genFrom      :: Source
      , genCommand   :: String
      }

-- | One host's runtime config.
data HostCfg = HostCfg
  { hName              :: String
  , hServerSecretsPath :: FilePath
  , hIp                :: Source
  , hSshPriv           :: Source
  , hSshPub            :: Source
  , hAgePriv           :: Source
  , hAgePub            :: Source
  , hHostKeyPriv       :: Source
    -- ^ Server's SSH host key (private). Shipped to the target via
    -- nixos-anywhere extras at /etc/ssh/ssh_host_ed25519_key.
  , hHostKeyPub        :: Source
    -- ^ Server's SSH host key (public). Used to populate the
    -- per-invocation known_hosts in 'Exec'.
  , hServerSecrets     :: [(String, Source)]
  }

instance A.FromJSON Plan where
  parseJSON = A.withObject "Plan" $ \o ->
    Plan <$> o .: "stateDir"
         <*> o .: "flakeRef"
         <*> o .: "tfStates"
         <*> objectPairs o "deployEnv"
         <*> o .: "hosts"

instance A.FromJSON TfStateCfg where
  parseJSON = A.withObject "TfStateCfg" $ \o ->
    TfStateCfg <$> o .: "name"
               <*> o .: "configFile"
               <*> o .: "genSpecs"

instance A.FromJSON GenSpec where
  parseJSON = A.withObject "GenSpec" $ \o ->
    GenSpec <$> o .: "name"
            <*> o .: "gen"

instance A.FromJSON Source where
  parseJSON = A.withObject "Source" $ \o ->
    (o .: "kind" :: Parser T.Text) >>= \case
      "literal"        -> Literal <$> o .: "value"
      "cmd"            -> Cmd     <$> o .: "command"
      "sops"           -> Sops    <$> o .: "file" <*> o .: "key"
      "tfstate-output" -> TfOut   <$> o .: "state" <*> o .: "outputName"
      other            -> fail ("unknown Source kind: " <> T.unpack other)

instance A.FromJSON Generator where
  parseJSON = A.withObject "Generator" $ \o ->
    (o .: "type" :: Parser T.Text) >>= \case
      "once"   -> Once   <$> o .: "sensitive" <*> o .: "command"
      "derive" -> Derive <$> o .: "sensitive" <*> o .: "from" <*> o .: "command"
      other    -> fail ("unknown Generator type: " <> T.unpack other)

instance A.FromJSON HostCfg where
  parseJSON = A.withObject "HostCfg" $ \o ->
    HostCfg <$> o .: "name"
            <*> o .: "serverSecretsPath"
            <*> o .: "ip"
            <*> o .: "sshPriv"
            <*> o .: "sshPub"
            <*> o .: "agePriv"
            <*> o .: "agePub"
            <*> o .: "hostKeyPriv"
            <*> o .: "hostKeyPub"
            <*> objectPairs o "serverSecrets"

objectPairs :: A.FromJSON v => A.Object -> AK.Key -> Parser [(String, v)]
objectPairs o key = do
  obj <- o .: key
  pure [ (AK.toString k, v) | (k, v) <- AKM.toList obj ]
