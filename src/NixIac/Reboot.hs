-- | Reboot a host iff its booted kernel/initrd/modules differ from current.
--
-- After a deploy-rs activation that updates boot-critical paths, the
-- kernel image, initrd, or modules in /run/booted-system point at older
-- store paths than /run/current-system. A reboot is required for the new
-- ones to take effect — but only in that case.
module NixIac.Reboot (rebootIfBootCritical) where

import NixIac.Run (run)

rebootIfBootCritical :: String -> FilePath -> IO ()
rebootIfBootCritical host sshKey = run "ssh"
  [ "-i", sshKey
  , "-o", "BatchMode=yes"
  , "-o", "ConnectTimeout=10"
  , "-o", "StrictHostKeyChecking=accept-new"
  , "root@" <> host
  , unlines
      [ "set -e"
      , "booted=$(readlink -f /run/booted-system/{kernel,initrd,kernel-modules})"
      , "current=$(readlink -f /run/current-system/{kernel,initrd,kernel-modules})"
      , "if [ \"$booted\" != \"$current\" ]; then"
      , "  echo '[reboot] boot-critical paths changed; rebooting'"
      , "  systemctl reboot"
      , "fi"
      ]
  ]
