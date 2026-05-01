# nix-iac

Constrained Nix-native infrastructure orchestration: tofu + nixos-anywhere + colmena.

Generates a fixed-shape `apps` attrset for your flake. One command (`nix run .#infra`)
brings every host to the same target state regardless of starting point — provisions
cloud resources, bootstraps fresh hosts, updates existing ones, all idempotent.

## Usage

```nix
# In your flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nix-iac.url = "github:holdenrohrer/nix-iac";
    colmena.url = "github:zhaofengli/colmena";
    sops-nix.url = "github:Mic92/sops-nix";
    disko.url = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, nix-iac, colmena, sops-nix, disko, ... }: {
    # 1. Declare your hosts as ordinary nixosConfigurations
    nixosConfigurations.buildfarm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./hosts/buildfarm/disko.nix
        ./hosts/buildfarm/configuration.nix
      ];
    };

    # 2. Declare your colmena hive — use mkDeployment for the deployment block
    colmenaHive = colmena.lib.makeHive {
      meta.nixpkgs = import nixpkgs { system = "x86_64-linux"; };
      buildfarm = { ... }: {
        imports = [ ./hosts/buildfarm/configuration.nix /* ... */ ];
        deployment = nix-iac.lib.x86_64-linux.mkDeployment;
      };
    };

    # 3. Generate the infra apps
    apps.x86_64-linux = nix-iac.lib.x86_64-linux.mkApps {
      terranixModules = [ ./infra/main.nix ];
      stateDir = ".tf-state";

      hosts.buildfarm = {
        ipOutput = "buildfarm_ip";          # name of the terraform output for the IP
        sshKey = ./.buildfarm-key;          # private key to SSH as root
        bootstrapFiles = {                  # files dropped via nixos-anywhere on first install
          "var/lib/sops-nix/key.txt" = ./.buildfarm-age.key;
        };
      };

      # Optional: import legacy resources into the new tf state (one-time)
      importMap = {
        "aws_s3_bucket.foo" = "existing-bucket-name";
      };
    };
  };
}
```

## What you get

- `nix run .#infra` — bring all hosts to the declared state (umbrella)
- `nix run .#infra.<host>` — same, just one host
- `nix run .#infra.destroy` — `tofu destroy`
- `nix run .#infra.import` — present only if `importMap` is non-empty

Each host app is fully idempotent:
1. `tofu apply` (creates/updates cloud resources, no-op if up-to-date)
2. SSH probe: `test -e /etc/NIXOS` on the target
3. If NixOS is present: `colmena apply switch` (closure update, ~30s)
4. If not: `nixos-anywhere` (one-time bootstrap, ~5min)

## Constraints (intentional — don't add knobs)

- Bootstrap path is **always** `nixos-anywhere`. No image-snapshot path. No alternate SSH user.
- Update path is **always** `colmena apply`. No `nixos-rebuild` or `deploy-rs`.
- State backend is whatever your terranix modules declare. (Recommended: S3 with
  `use_lockfile = true`.)
- The colmena deployment block is **fixed** — it reads `COLMENA_TARGET_HOST` and
  `COLMENA_SSH_KEY` env vars set by `mkApps`. Don't override `targetHost` or
  `sshOptions` in your hive.

If your use case really doesn't fit, fork or send a PR — but resist adding parameters.
The contract is the value here.
