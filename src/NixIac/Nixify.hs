-- | nixos-anywhere wrapper. Runs unconditionally — call sites are
-- responsible for proving the host isn't already NixOS via Probe first.
-- This module deliberately doesn't probe again (the orchestrator does
-- that once and acts on the three-way result; double-probing would
-- silently mask SshFailed cases).
--
-- Uses 'AcceptNew' because the target box hasn't had its tfstate-pinned
-- host key installed yet (that happens via the extras dir on this very
-- invocation). After nixify completes, the deterministic key is in
-- place and subsequent connections can use 'Strict'.
module NixIac.Nixify (nixify) where

import NixIac.Run     (run)
import NixIac.SshOpts (SshAuth (..), sshAuthKey, sshAuthKnownHosts)

nixify :: String   -- ^ flake attribute name (`<flake>#<name>`)
       -> String   -- ^ flake reference
       -> String   -- ^ host
       -> SshAuth  -- ^ auth (AcceptNew; pre-bootstrap host has no tfstate key yet)
       -> Maybe FilePath -- ^ extras dir to ship via --extra-files
       -> IO ()
nixify name flake host auth extras =
  run "nixos-anywhere" $
    [ "--flake", flake <> "#" <> name ]
    -- With a tfstate-pinned key we pass `-i` and `IdentitiesOnly=yes`.
    -- In bootstrap mode (auth key = Nothing) we omit both and let
    -- nixos-anywhere fall through to ssh-agent / ~/.ssh resolution.
    <> maybe []
             (\k -> [ "-i", k, "--ssh-option", "IdentitiesOnly=yes" ])
             (sshAuthKey auth)
    -- Pass our private known_hosts through; without these flags
    -- nixos-anywhere writes to ~/.ssh/known_hosts via accept-new.
    <> [ "--ssh-option", "UserKnownHostsFile=" <> sshAuthKnownHosts auth
       , "--ssh-option", "GlobalKnownHostsFile=/dev/null"
       , "--ssh-option", "StrictHostKeyChecking=accept-new"
       ]
    <> maybe [] (\e -> ["--extra-files", e]) extras
    <> [ "root@" <> host ]
