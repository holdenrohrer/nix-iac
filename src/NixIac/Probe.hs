-- | Test whether an SSH-reachable host is real NixOS.
--
-- "real NixOS" means: /etc/NIXOS exists AND root isn't tmpfs (the kexec'd
-- nixos-anywhere installer presents both `/etc/NIXOS` and a tmpfs root, so
-- we have to discriminate against that).
module NixIac.Probe (probeNixos) where

import NixIac.Run (captureExit)
import System.Exit (ExitCode (..))

probeNixos :: String -- ^ host
           -> FilePath -- ^ ssh private key
           -> IO Bool
probeNixos host sshKey = do
  (ec, _) <- captureExit "ssh"
    [ "-i", sshKey
    , "-o", "BatchMode=yes"
    , "-o", "ConnectTimeout=10"
    , "-o", "StrictHostKeyChecking=accept-new"
    , "root@" <> host
    , "[ -e /etc/NIXOS ] && [ \"$(stat -f -c %T /)\" != \"tmpfs\" ]"
    ]
  pure (ec == ExitSuccess)
