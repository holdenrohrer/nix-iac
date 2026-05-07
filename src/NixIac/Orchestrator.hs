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
  , doBootstrap  :: Bool
    -- ^ When 'True', the pre-NixOS stages (Probe, Nixify) may fall back
    -- to the operator's ambient SSH configuration if the iac deploy
    -- key fails. Required only for the very first install of a host
    -- that wasn't provisioned with iac's key at boot (Hetzner Robot
    -- dedi via order page). Once nixos-anywhere plants the deploy key
    -- via extras, the flag is no longer needed and would be a no-op.
    -- Per-deploy-run rather than per-host so it doesn't ossify into
    -- a permanent declaration of a one-time concern.
  , doRotate     :: [String]
    -- ^ Output names whose backing 'gen.once' values should be
    -- regenerated this run. Implementation: between phase 2
    -- (warmMaster, which still sees the OLD pinned values and opens
    -- a TCP through them) and phase 3 (apply), each named
    -- @terraform_data.<name>@ is dropped from state via
    -- @tofu state rm@. Apply then has nothing to read for those names
    -- and runs gen.once afresh, pinning a new value. Phase 4's
    -- deployHost ssh's attach to the warmed master, so even when the
    -- rotated value is the deploy key itself the host can be reached.
  }

defaultDeployOpts :: DeployOpts
defaultDeployOpts = DeployOpts
  { doHostFilter = Nothing
  , doReinstall  = False
  , doBootstrap  = False
  , doRotate     = []
  }

-- | Entry point. Drives every tfstate to convergence, then deploys the
-- selected hosts. See module header for invariants.
orchestrate :: DeployOpts -> Plan -> IO ()
orchestrate opts p = withSystemTempDirectory "nix-iac-deploy" $ \deployTmp -> do
  IO.hPutStrLn IO.stderr "==> orchestrate: deployEnv"
  setDeployEnv (planDeployEnv p)

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

  -- Phase 1: init every tfstate so we can read its current pinned values
  -- before any apply rewrites them. Idempotent — apply re-inits anyway.
  forM_ (planTfStates p) $ \s -> do
    IO.hPutStrLn IO.stderr ("==> init: " <> tfsName s)
    initStateDir (planStateDir p) s

  -- Phase 2: warm an SSH ControlMaster per host using PRE-apply
  -- credentials. Each master's TCP survives @tofu apply@ rewriting
  -- tfstate; subsequent ssh's that share the ControlPath attach to it
  -- without re-auth, which is what makes mid-deploy ssh-key / host-key
  -- rotation safe (new client priv vs. old authorized_keys, new pinned
  -- host pub vs. old served host key — the master bridges both
  -- discontinuities). Hosts without already-pinned creds (fresh dedi
  -- pre-bootstrap) silently skip warming and use the regular flow.
  forM_ selected $ \h -> warmMaster (planStateDir p) deployTmp h

  -- Phase 2.5: rotate. After warming masters but BEFORE apply, drop
  -- the named @terraform_data.<output>@ resources from every tfstate
  -- they appear in. Apply then sees empty state for those slots and
  -- runs the corresponding gen.once afresh, pinning new values. The
  -- masters from phase 2 are alive on the OLD identity, so phase 4's
  -- ssh's attach without re-auth even when one of the rotated values
  -- is the deploy key itself.
  --
  -- @tofu state rm@ exits non-zero when the resource isn't in this
  -- particular state — we ignore that and try the next state. Each
  -- output name is expected to live in exactly one state.
  when (not (null (doRotate opts))) $
    forM_ (doRotate opts) $ \name ->
      forM_ (planTfStates p) $ \s -> do
        let dir = planStateDir p </> tfsName s
        (ec, _) <- captureExit "tofu"
          [ "-chdir=" <> dir, "state", "rm", "terraform_data." <> name ]
        case ec of
          ExitSuccess   -> IO.hPutStrLn IO.stderr
            ("==> rotate: " <> name <> " (in " <> tfsName s <> ")")
          ExitFailure _ -> pure ()

  -- Phase 3: apply each tfstate. May rewrite gen.once values for
  -- anything dropped in phase 2.5. The masters from phase 2 keep
  -- working through this.
  forM_ (planTfStates p) $ \s -> do
    IO.hPutStrLn IO.stderr ("==> apply: " <> tfsName s)
    applyStateAfterInit (planStateDir p) s

  -- Phase 4: per-host deploy. Uses the warmed master if present.
  forM_ selected $ \h -> do
    IO.hPutStrLn IO.stderr ("==> deploy: " <> hName h)
    deployHost opts (planStateDir p) (planFlakeRef p) deployTmp h

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

-- | Materialize a tfstate's working directory and run @tofu init@. Split
-- out from 'applyStateAfterInit' so callers (the warm-master phase) can
-- read pinned outputs from the BACKEND before any apply rewrites them.
-- Idempotent — running it twice is fine.
initStateDir :: FilePath -> TfStateCfg -> IO ()
initStateDir root s = do
  let dir = root </> tfsName s
  createDirectoryIfMissing True dir
  copyFile (tfsConfigFile s) (dir </> "config.tf.json")
  run "tofu" ["-chdir=" <> dir, "init", "-input=false", "-reconfigure"]

applyStateAfterInit :: FilePath -> TfStateCfg -> IO ()
applyStateAfterInit root s = do
  let dir = root </> tfsName s

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

-- ------------------------------------- per-host SSH ControlMaster warm-up

-- | Path to the per-host ssh ControlMaster socket. Lives under the
-- shared deploy tmpdir so its lifetime exactly matches one
-- 'orchestrate' call. Path length matters here — Linux unix socket
-- paths are capped at 108 bytes; the deployTmp is short ("/tmp/...")
-- and the socket name is bounded.
controlPathFor :: FilePath -> HostCfg -> FilePath
controlPathFor deployTmp h = deployTmp </> ("cm-" <> hName h <> ".sock")

-- | Open an ssh ControlMaster against the host using its CURRENTLY-pinned
-- credentials. Run *before* @tofu apply@ so that even if apply rewrites
-- @<host>_ssh_priv@ / @<host>_host_priv@, the master's TCP keeps working.
-- Best-effort: if the host has no pinned creds yet (fresh dedi) or is
-- unreachable, log and move on — the regular probe/bootstrap path still
-- handles these cases.
warmMaster :: FilePath -> FilePath -> HostCfg -> IO ()
warmMaster root deployTmp h = do
  let ctl = controlPathFor deployTmp h
  -- Resolve pre-apply: this reads from already-init'd state via tofu
  -- output. If the value isn't pinned (first install), tofuOutAt errors
  -- and we skip warming. We catch via @captureExit@-style idiom below.
  ePriv     <- tryResolve (hSshPriv h)
  eHostPub  <- tryResolve (hHostKeyPub h)
  eIp       <- tryResolve (hIp h)
  case (ePriv, eHostPub, eIp) of
    (Just sshPriv, Just hostPub, Just ip) -> do
      let keyFile  = deployTmp </> ("warm-" <> hName h <> ".key")
          khFile   = deployTmp </> ("warm-" <> hName h <> ".kh")
      writeFile keyFile (sshPriv <> "\n"); setFileMode keyFile 0o600
      writeFile khFile (hName h <> "," <> ip <> " " <> hostPub <> "\n")
      -- -M: become master; -N: no command; -f: background after auth.
      -- ControlPersist=600 keeps it alive even if -f's child exits.
      (ec, _) <- captureExit "ssh"
        [ "-M", "-N", "-f"
        , "-i", keyFile, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"
        , "-o", "UserKnownHostsFile=" <> khFile
        , "-o", "GlobalKnownHostsFile=/dev/null"
        , "-o", "StrictHostKeyChecking=yes"
        , "-o", "ConnectTimeout=10"
        , "-o", "ControlPath=" <> ctl
        , "-o", "ControlPersist=600"
        , "root@" <> ip
        ]
      case ec of
        ExitSuccess   -> IO.hPutStrLn IO.stderr
          ("==> warm-master: " <> hName h <> " ok (" <> ctl <> ")")
        ExitFailure n -> IO.hPutStrLn IO.stderr
          ("==> warm-master: " <> hName h <> " skipped (ssh exit " <> show n
            <> "); regular flow will handle.")
    _ -> IO.hPutStrLn IO.stderr
      ("==> warm-master: " <> hName h
       <> " skipped (creds not pinned yet, fresh install).")
  where
    -- Return Nothing instead of dying when a TfOut isn't pinned in the
    -- backend yet (first install). Reads via @output -json@ rather than
    -- @-raw@ because the latter emits a warning to stdout on missing
    -- keys (with exit 0), which is unsafe to interpret as a value.
    tryResolve :: Source -> IO (Maybe String)
    tryResolve = \case
      Literal v -> pure (Just v)
      Cmd c     -> Just <$> capture "sh" ["-c", c]
      Sops f k  -> Just <$> Sops.decryptKey f k
      TfOut st k -> Map.lookup k <$> readPinnedOutputs (root </> st)

-- ------------------------------------------------------------------ per-host

deployHost :: DeployOpts -> FilePath -> String -> FilePath -> HostCfg -> IO ()
deployHost opts root flakeRef deployTmp h = withSystemTempDirectory ("nix-iac-" <> hName h) $ \tmp -> do
  let reinstall = doReinstall opts
      bootstrap = doBootstrap opts
      ctl       = controlPathFor deployTmp h
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
                       , sshAuthStrict = Strict
                       , sshAuthControlPath = Just ctl
                       -- ^ All post-bootstrap traffic shares this master.
                       -- Warmed pre-apply by 'warmMaster' so mid-deploy
                       -- ssh-key / host-key rotation doesn't lock us out.
                       }
      -- 'tofu' is the AcceptNew-known_hosts variant of pinned. Used for
      -- Probe (host key may not match yet) and Nixify (the install
      -- itself is what plants the pinned host key).
      tofu   = SshAuth { sshAuthKey = Just sshKey
                       , sshAuthKnownHosts = knownHostsTofu
                       , sshAuthStrict = AcceptNew
                       , sshAuthControlPath = Nothing
                       -- ^ Probe/Nixify are exploratory and the host key
                       -- they accept may not be the final pinned one;
                       -- don't share their TCP with strict-mode peers.
                       }
      -- 'bootstrapAuth' falls back to the operator's ambient SSH config
      -- (agent / ~/.ssh). Used only as a probe/nixify fallback for hosts
      -- that opted in via 'bootstrap = true' AND haven't yet had iac's
      -- deploy key installed (ie a fresh dedi). Once the install plants
      -- the deploy key via extras, ambient SSH is unnecessary and we
      -- never fall back to it again.
      bootstrapAuth = SshAuth { sshAuthKey = Nothing
                              , sshAuthKnownHosts = knownHostsTofu
                              , sshAuthStrict = AcceptNew
                              , sshAuthControlPath = Nothing
                              }

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
    case (first, bootstrap) of
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
