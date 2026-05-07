{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
-- | The top-level apply loop. Idempotent end-to-end: every step either
-- no-ops (already-NixOS, generator already pinned) or makes additive
-- forward progress.
module NixIac.Orchestrator
  ( orchestrate
  , DeployOpts (..)
  , defaultDeployOpts
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
import           NixIac.SshOpts             (SshAuth (..), StrictMode (..), sshArgs)
import qualified NixIac.WaitSsh             as WaitSsh
import           System.Directory           (copyFile, createDirectoryIfMissing)
import           System.Environment         (setEnv)
import           System.Exit                (ExitCode (..))
import           System.FilePath            ((</>))
import qualified System.IO                  as IO
import           System.IO.Temp             (withSystemTempDirectory)
import           System.Posix.Files         (setFileMode)

-- | Per-invocation knobs from the @deploy@ subcommand. Each is a
-- targeted override of the default "all hosts, no force" behaviour.
data DeployOpts = DeployOpts
  { doHostFilter :: Maybe [String]
    -- ^ When 'Just', only act on hosts whose 'hName' is in the list.
    -- 'Nothing' means every host in 'planHosts' (the historical
    -- behaviour). Tfstates always apply in full regardless — they're
    -- shared substrate, not per-host.
  , doReinstall  :: Bool
    -- ^ When 'True', skip the IsNixOS short-circuit and run nixos-anywhere
    -- regardless of the probe result. Used to reformat a host whose
    -- disko config has changed (e.g. moving from a single-disk layout
    -- to a multi-disk RAID0). The probe still gates on SSH reachability,
    -- so an unreachable host still aborts. The host's data is wiped.
  }

defaultDeployOpts :: DeployOpts
defaultDeployOpts = DeployOpts { doHostFilter = Nothing, doReinstall = False }

-- | Entry point. Drives every tfstate to convergence, then deploys the
-- selected hosts. See module header for invariants.
orchestrate :: DeployOpts -> Plan -> IO ()
orchestrate opts p = do
  IO.hPutStrLn IO.stderr "==> orchestrate: deployEnv"
  setDeployEnv (planDeployEnv p)

  forM_ (planTfStates p) $ \s -> do
    IO.hPutStrLn IO.stderr ("==> tfstate: " <> tfsName s)
    applyState (planStateDir p) s

  let selected = case doHostFilter opts of
        Nothing    -> planHosts p
        Just names ->
          let want    = [n | n <- names]
              present = [hName h | h <- planHosts p]
              missing = filter (`notElem` present) want
          in if not (null missing)
             then error ("--host: unknown host(s): " <> unwords missing
                          <> " (available: " <> unwords present <> ")")
             else filter (\h -> hName h `elem` want) (planHosts p)

  forM_ selected $ \h -> do
    IO.hPutStrLn IO.stderr ("==> deploy: " <> hName h)
    deployHost (doReinstall opts) (planStateDir p) (planFlakeRef p) h

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

deployHost :: Bool -> FilePath -> String -> HostCfg -> IO ()
deployHost reinstall root flakeRef h = withSystemTempDirectory ("nix-iac-" <> hName h) $ \tmp -> do
  ip          <- resolvePostApply root (hIp h)
  agePub      <- resolvePostApply root (hAgePub h)
  agePriv     <- resolvePostApply root (hAgePriv h)
  sshPriv     <- resolvePostApply root (hSshPriv h)
  sshPub      <- resolvePostApply root (hSshPub h)
  hostKeyPriv <- resolvePostApply root (hHostKeyPriv h)
  hostKeyPub  <- resolvePostApply root (hHostKeyPub h)

  let sshKey      = tmp </> (hName h <> ".ssh.key")
      ageKey      = tmp </> (hName h <> ".age.key")
      blobIn      = tmp </> (hName h <> ".blob.yaml")
      blobOut     = tmp </> (hName h <> ".blob.sops.yaml")
      extras      = tmp </> "extras"
      -- Two known_hosts files. `pinned` carries the tfstate-pinned host
      -- pubkey for strict checks; `tofu` is empty and lets first-contact
      -- ssh (Probe, Nixify) accept-new without polluting ~/.ssh.
      knownHostsPinned = tmp </> "known_hosts.pinned"
      knownHostsTofu   = tmp </> "known_hosts.tofu"
  writeFile sshKey (sshPriv <> "\n"); setFileMode sshKey 0o600
  writeFile ageKey (agePriv <> "\n"); setFileMode ageKey 0o600
  -- known_hosts entry: alias,IP <space> pubkey. Listing both lets
  -- ssh root@<ip> verify against the same key as ssh root@<name>.
  writeFile knownHostsPinned
    (hName h <> "," <> ip <> " " <> hostKeyPub <> "\n")
  writeFile knownHostsTofu ""

  let pinned = SshAuth { sshAuthKey = Just sshKey
                       , sshAuthKnownHosts = knownHostsPinned
                       , sshAuthStrict = Strict }
      -- 'tofu' is the AcceptNew-known_hosts variant of pinned. Used for
      -- Probe (host key may not match yet) and Nixify (the install
      -- itself is what plants the pinned host key).
      tofu   = SshAuth { sshAuthKey = Just sshKey
                       , sshAuthKnownHosts = knownHostsTofu
                       , sshAuthStrict = AcceptNew }
      -- 'bootstrapAuth' falls back to the operator's ambient SSH config
      -- (agent / ~/.ssh). Used only as a probe/nixify fallback for hosts
      -- that opted in via 'bootstrap = true' AND haven't yet had iac's
      -- deploy key installed (ie a fresh dedi). Once the install plants
      -- the deploy key via extras, ambient SSH is unnecessary and we
      -- never fall back to it again.
      bootstrapAuth = SshAuth { sshAuthKey = Nothing
                              , sshAuthKnownHosts = knownHostsTofu
                              , sshAuthStrict = AcceptNew }

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
  -- Server host key. NixOS activation only generates a missing key file;
  -- shipping ours via extras pins the host identity to tfstate, so
  -- subsequent connects can use StrictHostKeyChecking=yes against the
  -- known_hosts populated by `iac exec`.
  writeFile        (extras </> "etc/ssh/ssh_host_ed25519_key") (hostKeyPriv <> "\n")
  setFileMode      (extras </> "etc/ssh/ssh_host_ed25519_key") 0o600
  writeFile        (extras </> "etc/ssh/ssh_host_ed25519_key.pub") (hostKeyPub <> "\n")
  setFileMode      (extras </> "etc/ssh/ssh_host_ed25519_key.pub") 0o644

  -- Three-way probe: only nixos-anywhere when we *positively confirm*
  -- the host is not yet NixOS. Any ssh failure aborts; we never
  -- silently treat an unreachable host as "needs bootstrap".
  --
  -- Probe runs with AcceptNew on a fresh known_hosts: its outcome is
  -- determined by the remote /etc/NIXOS test, not by host-key
  -- verification. Pre-bootstrap hosts wouldn't match tfstate's host key
  -- anyway. Connections that *follow* a successful IsNixOS go strict
  -- against the tfstate-pinned known_hosts, so a key mismatch fails the
  -- deploy at a clean point with a loud SSH error.
  --
  -- @reinstall@ overrides the IsNixOS short-circuit: even on a healthy
  -- NixOS box, force the bootstrap path so nixos-anywhere reformats per
  -- the current disko config. The probe still gates on SSH reachability
  -- — a wedged host won't get reformatted.
  --
  -- For 'bootstrap = True' hosts, the deploy key may not be installed
  -- yet (fresh dedi). We try iac's key first; if SSH fails AND we have
  -- bootstrapAuth available, retry once with ambient ssh. After
  -- nixos-anywhere plants the deploy key, the ambient fallback is no
  -- longer needed and won't be exercised on subsequent runs.
  let probeOnce = Probe.probeNixos ip
  (probe, nixifyAuth) <- do
    first <- probeOnce tofu
    case (first, hBootstrap h) of
      (Probe.SshFailed _, True) -> do
        -- Fresh dedi: deploy key not yet installed, retry with ambient.
        r <- probeOnce bootstrapAuth
        pure (r, bootstrapAuth)
      _ -> pure (first, tofu)
  case probe of
    Probe.SshFailed n ->
      die ("probe: ssh to " <> ip <> " failed (exit " <> show n
           <> "); refusing to bootstrap a host we can't reach")
    Probe.IsNixOS | not reinstall -> do
      IO.hPutStrLn IO.stderr ("==> " <> hName h <> ": already NixOS, shipping new sops blob")
      run "scp" $
        sshArgs pinned ++
        [ blobOut
        , "root@" <> ip <> ":" <> hServerSecretsPath h <> ".new"
        ]
      run "ssh" $
        sshArgs pinned ++
        [ "root@" <> ip
        , "install -m 600 " <> hServerSecretsPath h <> ".new " <> hServerSecretsPath h
        ]
    _ -> do
      IO.hPutStrLn IO.stderr ("==> " <> hName h
        <> (if reinstall then ": --reinstall, forcing nixos-anywhere"
                         else ": not NixOS, bootstrapping via nixos-anywhere"))
      -- Nixify is pre-bootstrap → AcceptNew. After it completes the box
      -- has the tfstate-pinned host key from extras, so subsequent ops
      -- (Deploy/Reboot below) verify strictly.
      Nixify.nixify (hName h) flakeRef ip nixifyAuth (Just extras)
      -- nixos-anywhere returns the moment it triggers the post-install
      -- reboot; the new sshd hasn't bound yet. Wait for it before any
      -- subsequent SSH-driven step (Deploy/Reboot) so we don't race
      -- a "Connection timed out" against a still-rebooting host.
      WaitSsh.waitSsh ip pinned

  Deploy.deployWithRollback flakeRef (hName h) ip pinned
  Reboot.rebootIfBootCritical ip pinned

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
