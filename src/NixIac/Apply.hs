{-# LANGUAGE OverloadedStrings #-}
-- | The orchestration loop: read a config, drive tofu, ship secrets,
-- bootstrap hosts onto NixOS, deploy with rollback, reboot if needed.
--
-- Idempotent end-to-end: re-running mid-flight resumes from wherever the
-- previous run got to. Every step either no-ops (already-NixOS, secret
-- already in tfstate) or makes additive forward progress.
module NixIac.Apply (apply) where

import           Control.Monad      (forM_, when)
import qualified Data.Map.Strict    as Map
import           NixIac.Config
import qualified NixIac.Deploy      as Deploy
import qualified NixIac.Nixify      as Nixify
import qualified NixIac.Probe       as Probe
import qualified NixIac.Reboot      as Reboot
import           NixIac.Run         (capture, captureExit, die, run)
import qualified NixIac.Sops        as Sops
import           System.Directory   (copyFile, createDirectoryIfMissing)
import           System.Environment (setEnv)
import           System.Exit        (ExitCode (..))
import           System.FilePath    ((</>))
import qualified System.IO          as IO
import           System.IO.Temp     (withSystemTempDirectory)
import           System.Posix.Files (setFileMode)

apply :: FilePath -> IO ()
apply configPath = do
  cfg <- readConfig configPath

  IO.hPutStrLn IO.stderr "==> apply: setting deploy env"
  setDeployEnv cfg

  IO.hPutStrLn IO.stderr "==> apply: tofu init"
  installTerranix cfg
  run "tofu" ["-chdir=" <> stateDir cfg, "init", "-input=false", "-reconfigure"]

  forM_ (hosts cfg) $ \h -> do
    IO.hPutStrLn IO.stderr ("==> generators: " <> name h)
    runGenerators (stateDir cfg) h

  run "tofu" ["-chdir=" <> stateDir cfg, "apply", "-auto-approve", "-input=false"]

  forM_ (hosts cfg) $ \h -> do
    IO.hPutStrLn IO.stderr ("==> deploy: " <> name h)
    deployHost cfg h

setDeployEnv :: ApplyConfig -> IO ()
setDeployEnv cfg = forM_ (Map.toList (deployEnv cfg)) $ \(k, src) -> do
  v <- resolveSource src
  setEnv k v

installTerranix :: ApplyConfig -> IO ()
installTerranix cfg = do
  createDirectoryIfMissing True (stateDir cfg)
  copyFile (terranixConfig cfg) (stateDir cfg </> "config.tf.json")

resolveSource :: Source -> IO String
resolveSource (Literal v)        = pure v
resolveSource (Cmd c)            = capture "sh" ["-c", c]
resolveSource (SopsKey f k)      = Sops.decryptKey f k
resolveSource (TfStateOutput _)  = die "TfStateOutput resolve attempted before tofu apply; use resolveServerSecret"

runGenerators :: FilePath -> HostSpec -> IO ()
runGenerators dir h = do
  vals <- foldGens (Map.toAscList (generators h)) Map.empty
  forM_ (Map.toList vals) $ \(k, v) ->
    setEnv ("TF_VAR_" <> name h <> "_" <> k) v
  where
    foldGens []         acc = pure acc
    foldGens ((k,g):xs) acc = do
      v <- generatorValue dir h acc k g
      foldGens xs (Map.insert k v acc)

generatorValue :: FilePath -> HostSpec -> Map.Map String String
               -> String -> Generator -> IO String
generatorValue dir h prior k g = do
  let tfKey = name h <> "_" <> k
  (ec, existing) <- captureExit "tofu" ["-chdir=" <> dir, "output", "-raw", tfKey]
  if ec == ExitSuccess && not (null existing)
    then setEnv ("TF_VAR_" <> tfKey) "ignored" >> pure existing
    else case kind g of
      Once     -> capture "sh" ["-c", command g]
      Derive f -> case Map.lookup f prior of
        Nothing -> die ("derive generator '" <> k <> "' references unknown source '" <> f <> "'")
        Just v  -> capture "sh" ["-c", "printf '%s\\n' " <> shellSingle v <> " | " <> command g]

deployHost :: ApplyConfig -> HostSpec -> IO ()
deployHost cfg h = withSystemTempDirectory ("nix-iac-" <> name h) $ \tmp -> do
  let dir = stateDir cfg
  ip      <- tofuOut dir (ipOutput h)
  agePub  <- tofuOut dir (name h <> "_age_pub")
  sshPriv <- tofuOut dir (name h <> "_ssh_priv")
  agePriv <- tofuOut dir (name h <> "_age_priv")
  sshPub  <- tofuOut dir (name h <> "_ssh_pub")

  let sshKey = tmp </> (name h <> ".ssh.key")
      ageKey = tmp </> (name h <> ".age.key")
      blobIn  = tmp </> (name h <> ".blob.yaml")
      blobOut = tmp </> (name h <> ".blob.sops.yaml")
      extras  = tmp </> "extras"
  writeFile sshKey (sshPriv <> "\n"); setFileMode sshKey 0o600
  writeFile ageKey (agePriv <> "\n"); setFileMode ageKey 0o600

  blobLines <- mapM (resolveServerSecret dir) (Map.toAscList (serverSecrets h))
  writeFile blobIn (unlines blobLines)
  Sops.encryptToAge agePub blobIn blobOut

  createDirectoryIfMissing True (extras </> "var/lib/sops-nix")
  createDirectoryIfMissing True (extras </> "etc/ssh/authorized_keys.d")
  copyFile ageKey  (extras </> "var/lib/sops-nix/key.txt")
  setFileMode      (extras </> "var/lib/sops-nix/key.txt") 0o600
  copyFile blobOut (extras </> ("var/lib/sops-nix/" <> name h <> "-secrets.yaml"))
  setFileMode      (extras </> ("var/lib/sops-nix/" <> name h <> "-secrets.yaml")) 0o600
  writeFile        (extras </> "etc/ssh/authorized_keys.d/root") (sshPub <> "\n")
  setFileMode      (extras </> "etc/ssh/authorized_keys.d/root") 0o600

  alreadyNixOS <- Probe.probeNixos ip sshKey
  when alreadyNixOS $ do
    run "scp"
      [ "-i", sshKey
      , "-o", "StrictHostKeyChecking=accept-new"
      , blobOut
      , "root@" <> ip <> ":" <> serverSecretsPath h <> ".new"
      ]
    run "ssh"
      [ "-i", sshKey
      , "-o", "StrictHostKeyChecking=accept-new"
      , "root@" <> ip
      , "install -m 600 " <> serverSecretsPath h <> ".new " <> serverSecretsPath h
      ]

  Nixify.nixify (name h) (flakeRef cfg) ip sshKey (Just extras)
  Deploy.deployWithRollback (flakeRef cfg) (name h) ip sshKey
  Reboot.rebootIfBootCritical ip sshKey

resolveServerSecret :: FilePath -> (String, Source) -> IO String
resolveServerSecret dir (k, TfStateOutput n) = do
  v <- tofuOut dir n
  pure (k <> ": " <> v)
resolveServerSecret _   (k, src) = do
  v <- resolveSource src
  pure (k <> ": " <> v)

tofuOut :: FilePath -> String -> IO String
tofuOut dir o = capture "tofu" ["-chdir=" <> dir, "output", "-raw", o]

shellSingle :: String -> String
shellSingle s = "'" <> concatMap esc s <> "'"
  where esc '\'' = "'\\''"
        esc c    = [c]
