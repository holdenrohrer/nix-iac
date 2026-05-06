{-# LANGUAGE RecordWildCards #-}
-- | Common SSH option assembly for every nix-iac caller (Probe, Nixify,
-- Deploy, Reboot, the scp/ssh in Orchestrator's already-NixOS path).
--
-- Two invariants:
--
--  1. Never touch the user's @~/.ssh@. Every deploy uses a private
--     known_hosts file under the per-deploy tmpdir, populated from the
--     tfstate-pinned @<host>_host_pub@. @GlobalKnownHostsFile=/dev/null@
--     suppresses any system-wide knowledge.
--
--  2. Default to @StrictHostKeyChecking=yes@. Only @AcceptNew@ slips that
--     guard, and only at two well-defined moments: (a) the probe step,
--     since its outcome is determined by the @/etc/NIXOS@ exit code not
--     by host-key verification, and (b) nixos-anywhere on a fresh box
--     whose host key hasn't been installed yet. Every connection *after*
--     the box is known-NixOS goes through strict against the tfstate key.
module NixIac.SshOpts
  ( SshAuth (..)
  , StrictMode (..)
  , sshArgs
  , sshOptString
  ) where

import           Data.List (intercalate)

data StrictMode = Strict | AcceptNew
  deriving (Eq, Show)

data SshAuth = SshAuth
  { sshAuthKey        :: FilePath
    -- ^ Private key for client authentication (the @<name>_ssh_priv@
    -- side; root authorized_keys on the box).
  , sshAuthKnownHosts :: FilePath
    -- ^ Per-deploy known_hosts file under the tmpdir.
  , sshAuthStrict     :: StrictMode
  }
  deriving (Eq, Show)

-- | Argv list for @ssh@/@scp@/@sftp@.
sshArgs :: SshAuth -> [String]
sshArgs SshAuth{..} =
  [ "-i", sshAuthKey
  , "-o", "IdentitiesOnly=yes"
  , "-o", "UserKnownHostsFile=" <> sshAuthKnownHosts
  , "-o", "GlobalKnownHostsFile=/dev/null"
  , "-o", "StrictHostKeyChecking=" <> case sshAuthStrict of
      Strict    -> "yes"
      AcceptNew -> "accept-new"
  , "-o", "BatchMode=yes"
  , "-o", "ConnectTimeout=10"
  ]

-- | Single shell-quoted string of the same options, for tools that take
-- a single @--ssh-opts@ argument (deploy-rs).
sshOptString :: SshAuth -> String
sshOptString = intercalate " " . sshArgs
