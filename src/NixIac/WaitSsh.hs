-- | Poll SSH on a host until it accepts our deploy key.
--
-- nixos-anywhere returns the moment its install + reboot trigger
-- completes — the target box is mid-reboot at that point and its new
-- sshd hasn't bound port 22 yet. Without a wait step, Deploy.deployWithRollback
-- fires immediately and dies with "Connection timed out". This module
-- bridges that gap.
--
-- We use the strict 'pinned' auth on purpose: by the time we're called,
-- nixos-anywhere has already installed the tfstate-pinned host key via
-- extras. If the box comes up with a different key, that's a real
-- failure (mismatched extras, wrong host) and should fail loudly rather
-- than silently accept-new.
module NixIac.WaitSsh (waitSsh) where

import           NixIac.Run     (captureExit, die)
import           NixIac.SshOpts (SshAuth, sshArgs)
import           Control.Concurrent (threadDelay)
import           System.Exit    (ExitCode (..))
import qualified System.IO      as IO

-- | Poll @ssh root\@host true@ until it succeeds, or give up after
-- ~5 minutes. Each attempt has its own 10s ConnectTimeout (set in
-- 'sshArgs'), so we don't need a separate per-attempt timer.
waitSsh :: String -> SshAuth -> IO ()
waitSsh host auth = go (60 :: Int)
  where
    go 0 = die ("waitSsh: " <> host <> " never came up after install")
    go n = do
      (ec, _) <- captureExit "ssh" (sshArgs auth ++ [ "root@" <> host, "true" ])
      case ec of
        ExitSuccess   ->
          IO.hPutStrLn IO.stderr ("==> " <> host <> ": ssh up after reboot")
        ExitFailure _ -> do
          threadDelay 5_000_000   -- 5 s between attempts
          go (n - 1)
