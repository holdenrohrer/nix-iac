# nix-iac

Typed-handle DSL for Nix-native infra orchestration. Composes terranix
(declarative cloud resources), sops-nix (encrypted host secrets),
nixos-anywhere (first-time bootstrap), and deploy-rs (continuous deploy)
into one idempotent `nix run .#infra` per consumer.

## Surface (twelve names)

```
iac.tfState : { name; backend; } -> TfState
iac.host    : { name; tfState; ipOutput; serverSecrets ? {}; } -> Host
iac.mkInfraApp : { flake; hosts; tfStates; deployEnv ? {}; stateDir ? ".tf-state"; } -> app

# Source constructors:
iac.src.literal : String -> Source
iac.src.cmd     : String -> Source
iac.src.sops    : Path -> String -> Source

# Generator constructors (sensitive vs not):
iac.gen.once    : String -> Generator              # tfstate-pinned, computed once
iac.gen.once'   : String -> Generator              # not sensitive
iac.gen.derive  : { from : Source; command; } -> Generator
iac.gen.derive' : { from : Source; command; } -> Generator

# Methods on a TfState:
state.output : String -> Body -> Source            # declares + returns handle
state.read   : String -> Source                    # asserts exists; cross-flake escape hatch
```

`Body` is either a Generator or a terraform output attrset
(`{ value; sensitive ?; description ?; }`). `state.output` collects the
terranix declaration alongside the handle, so any `Source` reachable
from `hosts` or `deployEnv` automatically materializes its declaration
into the right tfstate.

A `Source` returned from `state.output` carries `.tfRef`, the
`${terraform_data.<name>.output}` interpolation string for use inside
terranix expressions. Non-tfstate Sources omit `.tfRef`.

## Usage

```nix
{
  inputs = {
    nixpkgs.url   = "github:NixOS/nixpkgs/nixos-25.11";
    nix-iac.url   = "github:holdenrohrer/nix-iac";
    sops-nix.url  = "github:Mic92/sops-nix";
    disko.url     = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, nix-iac, sops-nix, disko, ... }:
  let
    system = "x86_64-linux";
    iac    = nix-iac.lib.${system};
    infraSops = iac.src.sops ./secrets/infra.yaml;

    private = iac.tfState {
      name = "private";
      backend.s3 = {
        bucket = "acme-tfstate"; key = "infra.tfstate"; region = "us-east-1";
        encrypt = true; use_lockfile = true;
      };
    };

    aws       = import ./infra/aws.nix     { inherit private; };
    hetzner   = import ./infra/hetzner.nix { inherit private buildfarm; };

    buildfarm = iac.host {
      name     = "buildfarm";
      tfState  = private;
      ipOutput = hetzner.ip;
      serverSecrets = {
        github_token  = infraSops "github_token";
        ci_aws_id     = aws.ciAccessKeyId;
        ci_aws_secret = aws.ciSecretAccessKey;
        admin_pw      = private.output "buildfarm_admin_pw"
                          (iac.gen.once "head -c 24 /dev/urandom | base64 -w0");
      };
    };
  in {
    nixosConfigurations.buildfarm = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        buildfarm.nixosModule
        ./hosts/buildfarm/configuration.nix
      ];
    };

    apps.${system}.infra = iac.mkInfraApp {
      flake     = self;
      hosts     = [ buildfarm ];
      tfStates  = [ { state = private; modules = [ aws.terranixModule hetzner.terranixModule ]; } ];
      deployEnv = {
        AWS_ACCESS_KEY_ID     = infraSops "aws_access_key_id";
        AWS_SECRET_ACCESS_KEY = infraSops "aws_secret_access_key";
        HCLOUD_TOKEN          = infraSops "hcloud_token";
      };
    };
  };
}
```

A terranix wrapper (`infra/aws.nix` etc.) returns both a raw module and
typed-handle outputs:

```nix
{ private, ... }:
{
  terranixModule = {
    resource.aws_iam_user.ci.name      = "acme-ci";
    resource.aws_iam_access_key.ci.user = "\${aws_iam_user.ci.name}";
  };
  ciAccessKeyId     = private.output "ci_access_key_id"
                        { value = "\${aws_iam_access_key.ci.id}";     sensitive = true; };
  ciSecretAccessKey = private.output "ci_secret_access_key"
                        { value = "\${aws_iam_access_key.ci.secret}"; sensitive = true; };
}
```

`hetzner.nix` references `buildfarm.sshPub.tfRef` to pass the host's
generated ssh public key into a terraform `hcloud_ssh_key` resource.

## What `nix run .#infra` does

1. Resolve every `deployEnv` Source (sops/literal/cmd, *not* tfstate);
   export them.
2. For each tfstate in declaration order:
   1. Install the auto-generated `config.tf.json` and `tofu init`.
   2. For every generator: if tfstate already has its value, take it
      verbatim (the `terraform_data` + `ignore_changes` pin keeps it).
      Otherwise compute via shell, set `TF_VAR_<name>`.
   3. `tofu apply -auto-approve`.
3. For each host:
   1. Resolve `ip`, ssh key, age key, all `serverSecrets`.
   2. Build a sops-encrypted secrets blob for the host's age recipient.
   3. Stage the blob + age key + ssh authorized_keys into an extras dir.
   4. Probe: if NixOS, `scp` the new blob and `install` it in place;
      otherwise `nixos-anywhere --extra-files extras`.
   5. `deploy --skip-checks` for closure update with magic-rollback.
   6. Reboot iff `/run/booted-system/{kernel,initrd,kernel-modules}`
      diverged from `/run/current-system`.

## How it works (internal)

`mkInfraApp` walks every `Source` reachable from `hosts` and `deployEnv`,
collects per-tfstate declarations, hands them to `terranix` to produce
`config.tf.json`, then generates a per-consumer `Main.hs` that
constructs a `Plan` value and calls `NixIac.Orchestrator.orchestrate`.
`callCabal2nix` builds that into a binary linked against the `nix-iac`
library; `apps.infra.program` points at the wrapped result with
`tofu`/`sops`/`age`/`openssh`/`nixos-anywhere`/`deploy-rs` on `PATH`.

Consumers never write or read JSON, never parse args, never see shell
orchestration. Per-consumer compilation cost: one `callCabal2nix` plus
one tiny `ghc` build (≈10s warm).

## Constraints

- Bootstrap path is always `nixos-anywhere`. No image-snapshot path.
- Update path is always `deploy-rs`. No `nixos-rebuild` or `colmena`.
- State backend is whatever your `tfState.backend` block declares.
- Generator dependency cycles within a tfstate are not detected;
  derives must reach a non-derive eventually. Cross-state derives
  require the source state to come first in `tfStates`.
