-- | Push a NixOS closure to a host with deploy-rs magic-rollback.
--
-- We pass --skip-checks because deploy-rs's default pre-flight runs
-- `nix flake check` over the entire consumer flake, which fails on
-- unrelated outputs (xorg refactors, IFD jobs, etc.).
module NixIac.Deploy (deployWithRollback) where

import NixIac.Run     (run)
import NixIac.SshOpts (SshAuth, sshOptString)

deployWithRollback :: String   -- ^ flake reference
                   -> String   -- ^ flake attribute (becomes <flake>#<name>)
                   -> String   -- ^ host
                   -> SshAuth  -- ^ auth (Strict against tfstate-pinned known_hosts)
                   -> IO ()
deployWithRollback flake name host auth = run "deploy"
  [ flake <> "#" <> name
  , "--hostname", host
  , "--ssh-opts", sshOptString auth
  , "--skip-checks"
  ]
