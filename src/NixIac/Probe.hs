-- | Test whether an SSH-reachable host is real NixOS.
--
-- "real NixOS" means: /etc/NIXOS exists AND root isn't tmpfs (the kexec'd
-- nixos-anywhere installer presents both `/etc/NIXOS` and a tmpfs root, so
-- we have to discriminate against that).
--
-- Three-way result: a host that we *can't talk to* must NEVER be treated
-- as "not NixOS" — that path triggers nixos-anywhere, which would wipe a
-- live host the moment ssh has a transient hiccup.
module NixIac.Probe
  ( ProbeResult (..)
  , probeNixos
  ) where

import NixIac.Run (captureExit)
import System.Exit (ExitCode (..))

-- | The remote test exits 0 iff NixOS, 1 iff (ssh OK but) not NixOS.
-- Anything else means ssh itself failed (255 on connect failure, etc.).
data ProbeResult
  = IsNixOS
  | IsNotNixOS
  | SshFailed Int
  deriving (Eq, Show)

probeNixos :: String -- ^ host
           -> FilePath -- ^ ssh private key
           -> IO ProbeResult
probeNixos host sshKey = do
  (ec, _) <- captureExit "ssh"
    [ "-i", sshKey
    , "-o", "BatchMode=yes"
    , "-o", "ConnectTimeout=10"
    , "-o", "StrictHostKeyChecking=accept-new"
    , "root@" <> host
    , "[ -e /etc/NIXOS ] && [ \"$(stat -f -c %T /)\" != \"tmpfs\" ]"
    ]
  pure $ case ec of
    ExitSuccess   -> IsNixOS
    ExitFailure 1 -> IsNotNixOS
    ExitFailure n -> SshFailed n
