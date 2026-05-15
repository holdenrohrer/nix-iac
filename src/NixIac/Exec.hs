{-# LANGUAGE LambdaCase #-}
-- | The `exec` subcommand: materialize an SSH environment from tfstate
-- and run an arbitrary command under it.
--
-- For every host in the Plan we resolve (post-apply) the IP, our private
-- SSH key, and the server's public host key. We render:
--
--   * one private-key file per host, mode 0600
--   * one combined known_hosts file, with the host's expected pubkey
--   * one ssh_config with a Host stanza per host (HostName, User, IdentityFile,
--     UserKnownHostsFile, IdentitiesOnly yes, StrictHostKeyChecking yes)
--   * a bin/ directory with shim scripts for ssh / scp / sftp / rsync that
--     prefix `-F <ssh_config>` (rsync via `-e`) before the user's args
--
-- The shim bin/ goes on the front of PATH; GIT_SSH_COMMAND is set so git
-- transports work too. Everything lives under $XDG_RUNTIME_DIR/iac-XXXX
-- (per-user tmpfs) and is removed on any exit path.
--
-- Nothing is written to ~/.ssh, no agent is required, and StrictHostKeyChecking
-- can stay yes because the known_hosts entry comes from the same tfstate
-- output that nixos-anywhere installed on the box.
module NixIac.Exec
  ( execEnv
  ) where

import           Control.Exception        (bracket_)
import           Control.Monad            (forM_)
import qualified Data.Aeson               as A
import qualified Data.Aeson.Key           as AK
import qualified Data.Aeson.KeyMap        as AKM
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Map.Strict          as Map
import qualified Data.Text                as T
import           Data.IORef               (IORef, newIORef, readIORef, modifyIORef')
import           NixIac.Plan
import qualified NixIac.Sops              as Sops
import           NixIac.Run               (capture, die)
import qualified System.Directory
import           System.Directory         (createDirectoryIfMissing,
                                            removePathForcibly,
                                            findExecutable)
import           System.Environment       (lookupEnv, getEnvironment, setEnv)
import           System.Exit              (ExitCode (..), exitWith)
import           System.FilePath          ((</>))
import qualified System.IO                as IO
import           System.IO.Temp           (createTempDirectory)
import           System.Posix.Files       (setFileMode)
import           System.Process           (CreateProcess (..), StdStream (..),
                                            createProcess, proc, waitForProcess)

data ExecCtx = ExecCtx
  { sopsCache :: IORef (Map.Map FilePath (Map.Map String String))
  , tofuCache :: IORef (Map.Map FilePath (Map.Map String String))
  }

-- | Resolve every host in the plan and run `cmd : args` in an environment
-- where `ssh <host>` (etc.) Just Works. `cmd` is searched on the
-- *non-shimmed* PATH so users can invoke any binary; openssh tools get
-- shimmed so they pick up our config.
execEnv :: Plan -> [String] -> IO ()
execEnv _    []           = die "exec: needs a command, e.g. `infra exec ssh <host> ...`"
execEnv plan (cmd : args) = do
  ctx <- ExecCtx <$> newIORef Map.empty <*> newIORef Map.empty

  -- Resolve every deployEnv binding (sops/literal/cmd, *not* tfstate) and
  -- export them, so tofu sees the same backend creds the deploy path uses.
  -- Without this, S3-backed tfstates fail to read with "no credentials
  -- found." TfOut sources are illegal here for the same reason as in
  -- Orchestrator.resolvePreApply: if a deployEnv var came from tfstate,
  -- you're in a chicken-and-egg with the very tofu call we're about to
  -- make.
  forM_ (planDeployEnv plan) $ \(k, src) -> do
    v <- resolveDeployEnv ctx k src
    setEnv k v

  -- Stage everything under $XDG_RUNTIME_DIR (per-user tmpfs). Falls back
  -- to /tmp if the runtime dir is unset (rare; non-systemd hosts).
  base <- runtimeDirBase
  createDirectoryIfMissing True base
  tmp  <- createTempDirectory base "exec"
  bracket_ (pure ()) (removePathForcibly tmp) $ do
    setFileMode tmp 0o700

    -- Resolve and write per-host material.
    hostStanzas <- mapM (writeHostMaterial ctx (planStateDir plan) tmp) (planHosts plan)

    let knownHosts = tmp </> "known_hosts"
        sshConfig  = tmp </> "ssh_config"
    writeFile knownHosts (concatMap snd hostStanzas)
    writeFile sshConfig
      (defaultStanza sshConfig knownHosts <> concatMap fst hostStanzas)
    setFileMode knownHosts 0o600
    setFileMode sshConfig  0o600

    -- Bin shims that inject `-F <ssh_config>`. We resolve the real openssh
    -- binaries up-front and bake the path into each shim, so the shims are
    -- self-contained even with our bin dir on PATH (no recursion risk).
    binDir <- buildBinDir tmp sshConfig
    parentEnv <- getEnvironment
    let env' = ("PATH",            binDir <> ":" <> envOr parentEnv "PATH" "/usr/bin:/bin")
             : ("GIT_SSH_COMMAND", "ssh -F " <> sshConfig)
             : [ kv | kv <- parentEnv, fst kv `notElem` ["PATH", "GIT_SSH_COMMAND"] ]

    -- Resolve cmd against the augmented PATH (binDir first). The Haskell
    -- process lib's execvp does path lookup against the parent's
    -- environment regardless of CreateProcess.env, so passing cmd bare
    -- bypasses the shim. Look it up ourselves and pass the absolute path.
    let envPath = binDir <> ":" <> envOr parentEnv "PATH" "/usr/bin:/bin"
    resolved <- resolveOnPath envPath cmd
    let absCmd = case resolved of
          Just p  -> p
          Nothing -> cmd  -- let exec fail loudly with a clear "not found"

    (_, _, _, ph) <- createProcess (proc absCmd args)
                       { env       = Just env'
                       , std_in    = Inherit
                       , std_out   = Inherit
                       , std_err   = Inherit
                       , delegate_ctlc = True
                       }
    ec <- waitForProcess ph
    case ec of
      ExitSuccess   -> pure ()
      ExitFailure _ -> exitWith ec

-- | Materialize one host's key + return (ssh_config-stanza, known_hosts-line).
writeHostMaterial :: ExecCtx -> FilePath -> FilePath -> HostCfg
                  -> IO (String, String)
writeHostMaterial ctx root tmp h = do
  ip          <- resolveSrc ctx root (hIp h)
  sshPriv     <- resolveSrc ctx root (hSshPriv h)
  hostKeyPub  <- resolveSrc ctx root (hHostKeyPub h)

  let keyPath = tmp </> (hName h <> ".key")
  writeFile keyPath (sshPriv <> "\n")
  setFileMode keyPath 0o600

  let stanza = unlines
        [ "Host " <> hName h
        , "    HostName " <> ip
        , "    User root"
        , "    IdentityFile " <> keyPath
        , "    IdentitiesOnly yes"
        , "    StrictHostKeyChecking yes"
        , ""
        ]
      -- known_hosts entry: hostnames-list <space> pubkey-line. We list
      -- both the host alias and its IP so direct-IP connects also verify.
      knownLine = hName h <> "," <> ip <> " " <> hostKeyPub <> "\n"
  pure (stanza, knownLine)

-- | Default Host stanza: pin known_hosts globally, even for explicit IPs.
defaultStanza :: FilePath -> FilePath -> String
defaultStanza _ kh = unlines
  [ "# Generated by nix-iac exec. Do not edit; this file is recreated on every run."
  , "Host *"
  , "    UserKnownHostsFile " <> kh
  , "    GlobalKnownHostsFile /dev/null"
  , "    PasswordAuthentication no"
  , "    KbdInteractiveAuthentication no"
  , ""
  ]

-- | Render the bin/ shim directory. Each shim execs the absolute path of
-- the real binary with our -F flag injected.
buildBinDir :: FilePath -> FilePath -> IO FilePath
buildBinDir tmp cfg = do
  let bin = tmp </> "bin"
  createDirectoryIfMissing True bin

  ssh   <- requireExe "ssh"
  scp   <- requireExe "scp"
  sftp  <- requireExe "sftp"
  rsync <- requireExe "rsync"

  -- ssh, scp, sftp accept `-F <file>` directly.
  writeShim (bin </> "ssh")  ("exec " <> ssh  <> " -F " <> q cfg <> " \"$@\"")
  writeShim (bin </> "scp")  ("exec " <> scp  <> " -F " <> q cfg <> " \"$@\"")
  writeShim (bin </> "sftp") ("exec " <> sftp <> " -F " <> q cfg <> " \"$@\"")
  -- rsync uses an `-e` transport string. Quoting matters: rsync splits on
  -- whitespace inside -e but keeps the whole thing as one transport spec.
  writeShim (bin </> "rsync")
    ("exec " <> rsync <> " -e " <> q (ssh <> " -F " <> cfg) <> " \"$@\"")
  pure bin
  where
    writeShim path body = do
      writeFile path ("#!/bin/sh\n" <> body <> "\n")
      setFileMode path 0o755
    q s = "'" <> concatMap escSq s <> "'"
    escSq '\'' = "'\\''"
    escSq c    = [c]

-- | Locate a binary on the parent PATH. Fail loudly if missing — every
-- mkInfraApp wrapper pins openssh + rsync into runtimeTools, so absence
-- means a bad packaging change, not a user problem.
requireExe :: String -> IO FilePath
requireExe name = findExecutable name >>= \case
  Just p  -> pure p
  Nothing -> die ("exec: cannot find " <> name <> " on PATH (mkInfraApp runtimeTools should provide it)")

-- | Resolve a Source assuming all tfstates have already applied. Mirrors
-- Orchestrator.resolvePostApply but lives here so we don't import
-- Orchestrator (which has heavier deps).
resolveSrc :: ExecCtx -> FilePath -> Source -> IO String
resolveSrc ctx root = \case
  Literal v  -> pure v
  Cmd c      -> capture "sh" ["-c", c]
  Sops f k   -> cachedSopsKey ctx f k
  TfOut s k  -> cachedTofuOutput ctx (root </> s) k

-- | Resolve a Source from planDeployEnv. Refuses TfOut for the same reason
-- as Orchestrator.resolvePreApply: tfstate-output values can't be read
-- before tofu has the credentials we're trying to set up *here*.
resolveDeployEnv :: ExecCtx -> String -> Source -> IO String
resolveDeployEnv _   _   (Literal v)  = pure v
resolveDeployEnv _   _   (Cmd c)      = capture "sh" ["-c", c]
resolveDeployEnv ctx _   (Sops f k)   = cachedSopsKey ctx f k
resolveDeployEnv _   key (TfOut s _) = die
  ("exec: deployEnv binding " <> key <> " references tfstate " <> s
   <> "; only literal/cmd/sops are legal here")

cachedSopsKey :: ExecCtx -> FilePath -> String -> IO String
cachedSopsKey ctx file key = do
  cache <- readIORef (sopsCache ctx)
  values <- case Map.lookup file cache of
    Just v  -> pure v
    Nothing -> do
      v <- Sops.decryptFile file
      modifyIORef' (sopsCache ctx) (Map.insert file v)
      pure v
  case Map.lookup key values of
    Just v  -> pure v
    Nothing -> die ("sops: key " <> key <> " not found in " <> file)

cachedTofuOutput :: ExecCtx -> FilePath -> String -> IO String
cachedTofuOutput ctx dir key = do
  cache <- readIORef (tofuCache ctx)
  values <- case Map.lookup dir cache of
    Just v  -> pure v
    Nothing -> do
      v <- readTofuOutputs dir
      modifyIORef' (tofuCache ctx) (Map.insert dir v)
      pure v
  case Map.lookup key values of
    Just v  -> pure v
    Nothing -> die ("tofu output: key " <> key <> " not found in " <> dir)

readTofuOutputs :: FilePath -> IO (Map.Map String String)
readTofuOutputs dir = do
  jsonText <- capture "tofu" ["-chdir=" <> dir, "output", "-json"]
  case A.eitherDecode (L8.pack jsonText) of
    Left err             -> die ("tofu output: failed to parse JSON from " <> dir <> ": " <> err)
    Right (A.Object obj) -> pure $ Map.fromList
      [ (AK.toString k, jsonAsString v)
      | (k, A.Object inner) <- AKM.toList obj
      , Just v <- [AKM.lookup (AK.fromString "value") inner]
      ]
    Right _              -> die ("tofu output: expected JSON object from " <> dir)

jsonAsString :: A.Value -> String
jsonAsString = \case
  A.String t -> T.unpack t
  other      -> L8.unpack (A.encode other)

-- | Look up a bare command name against an explicit PATH string. Returns
-- the absolute path of the first executable file found, or Nothing.
-- Slash-bearing names are returned as-is. We can't use Directory.findExecutable
-- here because it consults the process's current PATH env var, ignoring
-- whatever PATH we'd like to search.
resolveOnPath :: String -> String -> IO (Maybe FilePath)
resolveOnPath _    cmd | '/' `elem` cmd = pure (Just cmd)
resolveOnPath path cmd = go (splitOn ':' path)
  where
    go []     = pure Nothing
    go (d:ds) = do
      let p = (if null d then "." else d) </> cmd
      ok <- isExecutableFileSafe p
      if ok then pure (Just p) else go ds

isExecutableFileSafe :: FilePath -> IO Bool
isExecutableFileSafe p = do
  e <- System.Directory.doesFileExist p
  if not e then pure False else do
    perms <- System.Directory.getPermissions p
    pure (System.Directory.executable perms)

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (h, []) -> [h]
  (h, _:t) -> h : splitOn c t

runtimeDirBase :: IO FilePath
runtimeDirBase = do
  m <- lookupEnv "XDG_RUNTIME_DIR"
  case m of
    Just d  -> pure d
    Nothing -> do
      IO.hPutStrLn IO.stderr
        "warning: $XDG_RUNTIME_DIR not set; falling back to /tmp (less private)"
      pure "/tmp"

envOr :: [(String, String)] -> String -> String -> String
envOr env k d = maybe d id (lookup k env)
