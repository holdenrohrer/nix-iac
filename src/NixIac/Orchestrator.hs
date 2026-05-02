{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
-- | The top-level apply loop. Idempotent end-to-end: every step either
-- no-ops (already-NixOS, generator already pinned) or makes additive
-- forward progress.
module NixIac.Orchestrator
  ( orchestrate
  , module NixIac.Plan
  ) where

import qualified Data.Aeson                 as A
import qualified Data.Aeson.Key             as AK
import qualified Data.Aeson.KeyMap          as AKM
import qualified Data.ByteString.Lazy.Char8 as L8
import           Control.Monad              (forM_, when)
import           Data.IORef
import qualified Data.Map.Strict            as Map
import qualified Data.Text                  as T
import           NixIac.Plan
import qualified NixIac.Deploy              as Deploy
import qualified NixIac.Nixify              as Nixify
import qualified NixIac.Probe               as Probe
import qualified NixIac.Reboot              as Reboot
import           NixIac.Run                 (capture, captureExit, die, run)
import qualified NixIac.Sops                as Sops
import           System.Directory           (copyFile, createDirectoryIfMissing)
import           System.Environment         (setEnv)
import           System.Exit                (ExitCode (..))
import           System.FilePath            ((</>))
import qualified System.IO                  as IO
import           System.IO.Temp             (withSystemTempDirectory)
import           System.Posix.Files         (setFileMode)

-- | Entry point. Drives every tfstate to convergence, then deploys every
-- host. See module header for invariants.
orchestrate :: Plan -> IO ()
orchestrate p = do
  IO.hPutStrLn IO.stderr "==> orchestrate: deployEnv"
  setDeployEnv (planDeployEnv p)

  forM_ (planTfStates p) $ \s -> do
    IO.hPutStrLn IO.stderr ("==> tfstate: " <> tfsName s)
    applyState (planStateDir p) s

  forM_ (planHosts p) $ \h -> do
    IO.hPutStrLn IO.stderr ("==> deploy: " <> hName h)
    deployHost (planStateDir p) (planFlakeRef p) h

-- ------------------------------------------------------------------ deployEnv

setDeployEnv :: [(String, Source)] -> IO ()
setDeployEnv pairs = forM_ pairs $ \(k, s) -> do
  v <- resolvePreApply s
  setEnv k v

-- | Sources legal before any tofu apply has run.
resolvePreApply :: Source -> IO String
resolvePreApply = \case
  Literal v   -> pure v
  Cmd c       -> capture "sh" ["-c", c]
  Sops f k    -> Sops.decryptKey f k
  TfOut s _   -> die ("deployEnv source references tfstate " <> s
                      <> " before any apply; only literal/cmd/sops are legal here")

-- ----------------------------------------------------------- per-tfstate apply

applyState :: FilePath -> TfStateCfg -> IO ()
applyState root s = do
  let dir = root </> tfsName s
  createDirectoryIfMissing True dir
  copyFile (tfsConfigFile s) (dir </> "config.tf.json")
  run "tofu" ["-chdir=" <> dir, "init", "-input=false", "-reconfigure"]

  -- Read all already-pinned outputs from this state in one shot; tofu
  -- output -json on an empty state returns "{}" with exit 0 — `-raw` per
  -- key returns exit 0 with the warning text on stdout, which is unsafe
  -- to interpret as the value.
  pinned <- readPinnedOutputs dir

  let genMap = Map.fromList [ (gsOutputName gs, gsGenerator gs) | gs <- tfsGenerators s ]
  cache <- newIORef (pinned :: Map.Map String String)
  let resolveSrc :: Source -> IO String
      resolveSrc = \case
        Literal v -> pure v
        Cmd c     -> capture "sh" ["-c", c]
        Sops f k  -> Sops.decryptKey f k
        TfOut st k
          | st == tfsName s -> resolveInState k
          | otherwise       -> tofuOutAt (root </> st) k
      resolveInState k = do
        m <- readIORef cache
        case Map.lookup k m of
          Just v  -> pure v
          Nothing -> do
            v <- case Map.lookup k genMap of
              Just g  -> materializeGenerator resolveSrc g
              Nothing -> tofuOutAt dir k
            modifyIORef' cache (Map.insert k v)
            pure v

  forM_ (tfsGenerators s) $ \(GenSpec name _) -> do
    v <- resolveInState name
    setEnv ("TF_VAR_" <> name) v

  run "tofu" ["-chdir=" <> dir, "apply", "-auto-approve", "-input=false"]

-- | One-shot read of every output already present in a tfstate. Empty
-- state returns an empty map (not an error).
readPinnedOutputs :: FilePath -> IO (Map.Map String String)
readPinnedOutputs dir = do
  (ec, jsonText) <- captureExit "tofu" ["-chdir=" <> dir, "output", "-json"]
  case ec of
    ExitFailure _ -> pure Map.empty
    ExitSuccess   -> case A.eitherDecode (L8.pack jsonText) of
      Left _              -> pure Map.empty
      Right (A.Object km) -> pure $ Map.fromList
        [ (AK.toString k, jsonAsString v)
        | (k, A.Object inner) <- AKM.toList km
        , Just v <- [AKM.lookup "value" inner]
        ]
      Right _             -> pure Map.empty

jsonAsString :: A.Value -> String
jsonAsString (A.String t) = T.unpack t
jsonAsString v            = L8.unpack (A.encode v)

-- | Compute a fresh generator value (output not pinned in tfstate).
materializeGenerator
  :: (Source -> IO String)   -- ^ how to resolve a Source in this context
  -> Generator
  -> IO String
materializeGenerator resolveSrc g = case g of
  Once   _ c     -> capture "sh" ["-c", c]
  Derive _ src c -> do
    v <- resolveSrc src
    capture "sh" ["-c", "printf '%s\\n' " <> shellSingle v <> " | " <> c]

-- ------------------------------------------------------------------ per-host

deployHost :: FilePath -> String -> HostCfg -> IO ()
deployHost root flakeRef h = withSystemTempDirectory ("nix-iac-" <> hName h) $ \tmp -> do
  ip      <- resolvePostApply root (hIp h)
  agePub  <- resolvePostApply root (hAgePub h)
  agePriv <- resolvePostApply root (hAgePriv h)
  sshPriv <- resolvePostApply root (hSshPriv h)
  sshPub  <- resolvePostApply root (hSshPub h)

  let sshKey  = tmp </> (hName h <> ".ssh.key")
      ageKey  = tmp </> (hName h <> ".age.key")
      blobIn  = tmp </> (hName h <> ".blob.yaml")
      blobOut = tmp </> (hName h <> ".blob.sops.yaml")
      extras  = tmp </> "extras"
  writeFile sshKey (sshPriv <> "\n"); setFileMode sshKey 0o600
  writeFile ageKey (agePriv <> "\n"); setFileMode ageKey 0o600

  blobLines <- mapM (\(k, src) -> do
                       v <- resolvePostApply root src
                       pure (k <> ": " <> v))
                    (hServerSecrets h)
  writeFile blobIn (unlines blobLines)
  Sops.encryptToAge agePub blobIn blobOut

  createDirectoryIfMissing True (extras </> "var/lib/sops-nix")
  createDirectoryIfMissing True (extras </> "etc/ssh/authorized_keys.d")
  copyFile ageKey  (extras </> "var/lib/sops-nix/key.txt")
  setFileMode      (extras </> "var/lib/sops-nix/key.txt") 0o600
  copyFile blobOut (extras </> ("var/lib/sops-nix/" <> hName h <> "-secrets.yaml"))
  setFileMode      (extras </> ("var/lib/sops-nix/" <> hName h <> "-secrets.yaml")) 0o600
  writeFile        (extras </> "etc/ssh/authorized_keys.d/root") (sshPub <> "\n")
  setFileMode      (extras </> "etc/ssh/authorized_keys.d/root") 0o600

  -- Three-way probe: only nixos-anywhere when we *positively confirm*
  -- the host is not yet NixOS. Any ssh failure aborts; we never
  -- silently treat an unreachable host as "needs bootstrap".
  probe <- Probe.probeNixos ip sshKey
  case probe of
    Probe.SshFailed n ->
      die ("probe: ssh to " <> ip <> " failed (exit " <> show n
           <> "); refusing to bootstrap a host we can't reach")
    Probe.IsNotNixOS -> do
      IO.hPutStrLn IO.stderr ("==> " <> hName h <> ": not NixOS, bootstrapping via nixos-anywhere")
      Nixify.nixify (hName h) flakeRef ip sshKey (Just extras)
    Probe.IsNixOS -> do
      IO.hPutStrLn IO.stderr ("==> " <> hName h <> ": already NixOS, shipping new sops blob")
      run "scp"
        [ "-i", sshKey
        , "-o", "StrictHostKeyChecking=accept-new"
        , blobOut
        , "root@" <> ip <> ":" <> hServerSecretsPath h <> ".new"
        ]
      run "ssh"
        [ "-i", sshKey
        , "-o", "StrictHostKeyChecking=accept-new"
        , "root@" <> ip
        , "install -m 600 " <> hServerSecretsPath h <> ".new " <> hServerSecretsPath h
        ]

  Deploy.deployWithRollback flakeRef (hName h) ip sshKey
  Reboot.rebootIfBootCritical ip sshKey

-- | Sources legal once every tfstate has applied. All four kinds OK.
resolvePostApply :: FilePath -> Source -> IO String
resolvePostApply root = \case
  Literal v  -> pure v
  Cmd c      -> capture "sh" ["-c", c]
  Sops f k   -> Sops.decryptKey f k
  TfOut s k  -> tofuOutAt (root </> s) k

-- ------------------------------------------------------------------ helpers

tofuOutAt :: FilePath -> String -> IO String
tofuOutAt dir k = capture "tofu" ["-chdir=" <> dir, "output", "-raw", k]

shellSingle :: String -> String
shellSingle s = "'" <> concatMap esc s <> "'"
  where esc '\'' = "'\\''"
        esc c    = [c]
