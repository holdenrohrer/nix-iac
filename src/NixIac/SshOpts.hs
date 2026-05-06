{-# LANGUAGE RecordWildCards #-}
-- | Common SSH option assembly for every nix-iac caller (Probe, Nixify,
-- Deploy, Reboot, the scp/ssh in Orchestrator's already-NixOS path).
--
-- Two invariants for *deploys*:
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
--
-- One documented exception: bootstrap of a host that wasn't provisioned
-- with iac's deploy key (no cloud-init equivalent — e.g. Hetzner Robot
-- dedis). The Probe + Nixify stages then run with 'sshAuthKey = Nothing',
-- which drops @-i@ and @IdentitiesOnly=yes@ and lets ssh resolve identity
-- through the operator's ambient agent / @~/.ssh@ config. This is
-- inherently non-reproducible (depends on operator state) and is the
-- price of bootstrapping such a box at all; once nixos-anywhere installs
-- the deploy key, every subsequent stage is back on the reproducible path.
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
  { sshAuthKey        :: Maybe FilePath
    -- ^ Private key for client authentication (the @<name>_ssh_priv@
    -- side; root authorized_keys on the box). 'Nothing' means
    -- "bootstrap mode": skip @-i@/@IdentitiesOnly=yes@ and let ssh
    -- consult the operator's ambient agent and @~/.ssh@. Allowed only
    -- on the Probe + Nixify stages of a host whose deploy key isn't
    -- yet installed; never on a post-bootstrap connection.
  , sshAuthKnownHosts :: FilePath
    -- ^ Per-deploy known_hosts file under the tmpdir.
  , sshAuthStrict     :: StrictMode
  }
  deriving (Eq, Show)

-- | Argv list for @ssh@/@scp@/@sftp@.
sshArgs :: SshAuth -> [String]
sshArgs SshAuth{..} =
  -- @-i@ and @IdentitiesOnly=yes@ go together: pinning a single key only
  -- helps when every other identity source is suppressed. In bootstrap
  -- mode (key = Nothing) we drop both AND @BatchMode=yes@ so the
  -- operator's agent / ~/.ssh resolution can prompt for a passphrase
  -- if needed.
  (case sshAuthKey of
     Just k  -> [ "-i", k, "-o", "IdentitiesOnly=yes"
                , "-o", "BatchMode=yes" ]
     Nothing -> [ "-o", "BatchMode=no" ]) ++
  [ "-o", "UserKnownHostsFile=" <> sshAuthKnownHosts
  , "-o", "GlobalKnownHostsFile=/dev/null"
  , "-o", "StrictHostKeyChecking=" <> case sshAuthStrict of
      Strict    -> "yes"
      AcceptNew -> "accept-new"
  , "-o", "ConnectTimeout=10"
  ]

-- | Single shell-quoted string of the same options, for tools that take
-- a single @--ssh-opts@ argument (deploy-rs).
sshOptString :: SshAuth -> String
sshOptString = intercalate " " . sshArgs
