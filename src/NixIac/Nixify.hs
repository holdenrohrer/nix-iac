-- | Idempotently put a host onto NixOS.
--
-- If the host is already real NixOS, do nothing. Otherwise kexec-install
-- the target flake configuration via nixos-anywhere.
module NixIac.Nixify (nixify) where

import NixIac.Probe (probeNixos)
import NixIac.Run   (run)

nixify :: String   -- ^ flake attribute name (`<flake>#<name>`)
       -> String   -- ^ flake reference
       -> String   -- ^ host
       -> FilePath -- ^ ssh private key
       -> Maybe FilePath -- ^ extras dir to ship via --extra-files
       -> IO ()
nixify name flake host sshKey extras = do
  alreadyNixOS <- probeNixos host sshKey
  if alreadyNixOS
    then putStrLn ("==> " <> name <> ": already NixOS")
    else run "nixos-anywhere" $
         [ "--flake", flake <> "#" <> name
         , "-i", sshKey
         ]
         <> maybe [] (\e -> ["--extra-files", e]) extras
         <> [ "root@" <> host ]
