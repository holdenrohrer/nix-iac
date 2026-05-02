-- | The data types a per-consumer @Main.hs@ constructs and hands to
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
  , hServerSecrets     :: [(String, Source)]
  }
