-- | Test whether an SSH-reachable host is real NixOS.
--
-- "real NixOS" means: /etc/NIXOS exists AND root isn't tmpfs (the kexec'd
-- nixos-anywhere installer presents both `/etc/NIXOS` and a tmpfs root, so
-- we have to discriminate against that).
--
-- Three-way result: a host that we *can't talk to* must NEVER be treated
-- as "not NixOS" — that path triggers nixos-anywhere, which would wipe a
-- live host the moment ssh has a transient hiccup.
--
-- Probe always uses 'AcceptNew' against a private known_hosts: its
-- outcome is determined by the remote @/etc/NIXOS@ test, not by host-key
-- verification, and a pre-bootstrap host's key wouldn't match tfstate
-- anyway. Connections that *follow* a successful 'IsNixOS' probe use
-- 'Strict' (see 'NixIac.Orchestrator.deployHost').
module NixIac.Probe
  ( ProbeResult (..)
  , probeNixos
  ) where

import NixIac.Run     (captureExit)
import NixIac.SshOpts (SshAuth, sshArgs)
import System.Exit    (ExitCode (..))

-- | The remote test exits 0 iff NixOS, 1 iff (ssh OK but) not NixOS.
-- Anything else means ssh itself failed (255 on connect failure, etc.).
data ProbeResult
  = IsNixOS
  | IsNotNixOS
  | SshFailed Int
  deriving (Eq, Show)

probeNixos :: String  -- ^ host
           -> SshAuth -- ^ auth (caller picks Strict vs AcceptNew)
           -> IO ProbeResult
probeNixos host auth = do
  (ec, _) <- captureExit "ssh" $
    sshArgs auth ++
    [ "root@" <> host
    , "[ -e /etc/NIXOS ] && [ \"$(stat -f -c %T /)\" != \"tmpfs\" ]"
    ]
  pure $ case ec of
    ExitSuccess   -> IsNixOS
    ExitFailure 1 -> IsNotNixOS
    ExitFailure n -> SshFailed n
