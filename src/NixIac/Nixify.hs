-- | nixos-anywhere wrapper. Runs unconditionally — call sites are
-- responsible for proving the host isn't already NixOS via Probe first.
-- This module deliberately doesn't probe again (the orchestrator does
-- that once and acts on the three-way result; double-probing would
-- silently mask SshFailed cases).
module NixIac.Nixify (nixify) where

import NixIac.Run (run)

nixify :: String   -- ^ flake attribute name (`<flake>#<name>`)
       -> String   -- ^ flake reference
       -> String   -- ^ host
       -> FilePath -- ^ ssh private key
       -> Maybe FilePath -- ^ extras dir to ship via --extra-files
       -> IO ()
nixify name flake host sshKey extras =
  run "nixos-anywhere" $
    [ "--flake", flake <> "#" <> name
    , "-i", sshKey
    ]
    <> maybe [] (\e -> ["--extra-files", e]) extras
    <> [ "root@" <> host ]
