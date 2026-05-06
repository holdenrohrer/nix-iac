# nix-iac

Bespoke Nix- and Haskell-based IaC with orchestration primitives across
auth systems and a highly-opinionated `mkInfraApp` provider.

One `nix run .#infra` per consumer, end-to-end: terranix renders cloud
resources, sops-nix re-encrypts host secrets to deterministic age keys,
nixos-anywhere bootstraps fresh hosts, deploy-rs ships closures with
magic-rollback. Every long-lived secret — SSH client keys, SSH host
keys, age keys, generated passwords — lives in tfstate as a typed
handle, materialized to disk only at the moment a tool needs it.

## Why this exists

Most "IaC plus secrets plus deploy" stacks are several CLIs duct-taped
with shell. nix-iac collapses the duct-tape into one binary per
consumer:

- **Single source of truth.** Every value flowing between systems
  (Hetzner / AWS / sops file / generator output) is a `Source`. The DSL
  walks the closure of Sources reachable from your hosts and deployEnv,
  so anything you reference automatically lands in the right tfstate.
- **No JSON, no `awk`, no `bash` glue.** A per-consumer `Main.hs` is
  generated from your nix expression, linked against `NixIac` once, and
  exposed as `apps.<system>.infra`.
- **Idempotent end-to-end.** Reapplying converges; rerunning with no
  changes is a no-op.
- **No surprise lock-in.** Backend is whatever your `tfState.backend`
  declares; bootstrap is always `nixos-anywhere`; update is always
  `deploy-rs`.

## What you get for free

- Per-host SSH client key (`<name>_ssh_priv` / `_ssh_pub`) generated
  once in tfstate. The public half is exported to terranix for
  `hcloud_ssh_key` etc.
- Per-host SSH **server** key (`<name>_host_priv` / `_host_pub`)
  generated once in tfstate. The private half is shipped to the target
  via nixos-anywhere extras at `/etc/ssh/ssh_host_ed25519_key`. The
  public half populates a per-invocation `known_hosts` for `iac exec`,
  so `StrictHostKeyChecking=yes` is safe by construction — no TOFU
  window, no fingerprint surprises on rebuild.
- Per-host age keypair. The private half lands at
  `/var/lib/sops-nix/key.txt`; the public half is the recipient your
  server-side sops blobs are re-encrypted to.
- `services.openssh.hostKeys` pinned in the host's `nixosModule`.

## Subcommands

```
infra                    # default — same as `infra deploy`
infra deploy             # apply tfstates, then deploy every host
infra exec <cmd> [args]  # run <cmd> with ssh/scp/sftp/rsync wrapped to
                         # resolve every host by name (HostName,
                         # IdentityFile, UserKnownHostsFile preconfigured
                         # from tfstate)
```

### `infra exec` — the SSH environment

`exec` materializes per-host bits under `$XDG_RUNTIME_DIR/iac-XXXX`
(per-user tmpfs, mode 0700) and runs your command with `PATH` prefixed
by a shim `bin/`:

- One `<host>.key` file per host, mode 0600.
- One `known_hosts` populated from `<host>_host_pub` tfstate outputs.
- One `ssh_config` with a `Host <name>` stanza per host (`HostName`,
  `User`, `IdentityFile`, `UserKnownHostsFile`,
  `IdentitiesOnly yes`, `StrictHostKeyChecking yes`).
- Shim scripts for `ssh`, `scp`, `sftp`, `rsync` that inject `-F` (or
  `-e "ssh -F …"` for rsync). `GIT_SSH_COMMAND` is set the same way.

Real `ssh` flags pass through:

```
nix run .#infra -- exec ssh buildfarm df -h
nix run .#infra -- exec ssh -L 5432:localhost:5432 buildfarm
nix run .#infra -- exec rsync -av buildfarm:/var/log/foo ./logs/
nix run .#infra -- exec $SHELL                  # interactive subshell
```

The shim dir is on `PATH` only inside the exec'd process; nothing is
written to `~/.ssh`, no agent is required, and the entire tmpdir is
removed on any exit path. `IdentitiesOnly yes` keeps your existing
agent's identities from being silently offered to nix-iac hosts.

## Surface (twelve names)

```
iac.tfState : { name; backend; } -> TfState
iac.host    : { name; tfState; ipOutput; serverSecrets ? {}; } -> Host
iac.mkInfraApp : { flake; hosts; tfStates; deployEnv ? {}; stateDir ? ".tf-state"; extraSources ? []; } -> app

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

## What `infra deploy` does

1. Resolve every `deployEnv` Source (sops/literal/cmd, *not* tfstate);
   export them.
2. For each tfstate in declaration order:
   1. Install the auto-generated `config.tf.json` and `tofu init`.
   2. For every generator: if tfstate already has its value, take it
      verbatim (the `terraform_data` + `ignore_changes` pin keeps it).
      Otherwise compute via shell, set `TF_VAR_<name>`.
   3. `tofu apply -auto-approve`.
3. For each host:
   1. Resolve `ip`, client SSH key, server SSH host key, age key, all
      `serverSecrets`.
   2. Build a sops-encrypted secrets blob for the host's age recipient.
   3. Stage the blob + age key + ssh authorized_keys + server host
      key into an extras dir.
   4. Probe: if NixOS, `scp` the new blob and `install` it in place;
      otherwise `nixos-anywhere --extra-files extras`.
   5. `deploy --skip-checks` for closure update with magic-rollback.
   6. Reboot iff `/run/booted-system/{kernel,initrd,kernel-modules}`
      diverged from `/run/current-system`.

## How it works (internal)

`mkInfraApp` walks every `Source` reachable from `hosts` and
`deployEnv`, collects per-tfstate declarations, hands them to terranix
to produce `config.tf.json`, then generates a per-consumer `Main.hs`
that constructs a `Plan` value and dispatches on `argv[0]`:
`deploy` → `NixIac.Orchestrator.orchestrate`, `exec` →
`NixIac.Exec.execEnv`. `callCabal2nix` builds that into a binary linked
against the `nix-iac` library; `apps.infra.program` points at the
wrapped result with `tofu` / `sops` / `age` / `openssh` / `rsync` /
`nixos-anywhere` / `deploy-rs` on `PATH`.

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
- Server SSH host key is `ed25519`-only. Listing it explicitly in
  `services.openssh.hostKeys` suppresses the default RSA key generation.
