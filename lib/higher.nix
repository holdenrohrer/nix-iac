# Higher-order helpers: declarative host bindings + a tiny shim that
# renders the deploy plan as JSON and hands it to the Haskell `infra`
# binary, which does all of: tofu init/apply, generator memoize-or-run,
# sops blob delivery, nixos-anywhere bootstrap, deploy-rs activation,
# reboot-if-needed.

{ pkgs, system, deploy-rs, infra, lib }:

let
  # --- Tagged source constructors -----------------------------------------
  # Field names match the JSON the Haskell side parses. Each is opaque to
  # the consumer; they pass them through to `serverSecrets` / `deployEnv`.
  sopsKey       = file: key: { kind = "sops";    inherit file key; };
  tfStateOutput = name:       { kind = "tfstate"; inherit name;     };
  literal       = value:      { kind = "literal"; inherit value;    };
  cmd           = command:    { kind = "cmd";     inherit command;  };

  # --- Generated-secret constructors --------------------------------------
  # Each is stored in tfstate via terraform_data with ignore_changes —
  # generated on first apply, pinned forever after.
  once    = command:       { type = "once";   inherit command; sensitive = true;  };
  once'   = command:       { type = "once";   inherit command; sensitive = false; };
  derive  = from: command: { type = "derive"; inherit from command; sensitive = false; };
  derive' = from: command: { type = "derive"; inherit from command; sensitive = true;  };

  # --- mkHost -------------------------------------------------------------
  mkHost = {
    name,
    serverSecrets ? {},
    generators    ? {},
    ipOutput      ? "${name}_ip",
  }:
    let
      builtinGenerators = {
        age_priv = once "age-keygen 2>/dev/null";
        age_pub  = derive' "age_priv" "age-keygen -y /dev/stdin";
        ssh_priv = once ''
          f=$(mktemp -u)
          ssh-keygen -t ed25519 -N "" -C "${name}" -f "$f" >/dev/null
          cat "$f"
          rm -f "$f" "$f.pub"
        '';
        ssh_pub  = derive' "ssh_priv" "ssh-keygen -y -f /dev/stdin";
      };
      allGenerators = builtinGenerators // generators;

      outputs = { ip = ipOutput; }
        // builtins.mapAttrs (n: _: "${name}_${n}") allGenerators;
    in rec {
      inherit name serverSecrets outputs;
      generators = allGenerators;

      serverSecretsPath = "/var/lib/sops-nix/${name}-secrets.yaml";

      use = key: tfStateOutput "${name}_${key}";

      # Public, opaque references for use inside other terranix modules the
      # consumer composes alongside this host. Listed explicitly so a
      # generator rename can't silently leak a sensitive value into HCL.
      ssh_pub = "\${terraform_data.${name}_ssh_pub.output}";
      age_pub = "\${terraform_data.${name}_age_pub.output}";

      terranixModule = let
        prefix = "${name}_";
      in {
        variable = lib.mapAttrs' (n: g: lib.nameValuePair "${prefix}${n}" {
          type = "string";
          sensitive = g.sensitive;
          default = "ignored";
        }) allGenerators;

        resource.terraform_data = lib.mapAttrs' (n: _: lib.nameValuePair "${prefix}${n}" {
          input = "\${var.${prefix}${n}}";
          lifecycle = { ignore_changes = [ "input" ]; };
        }) allGenerators;

        output = lib.mapAttrs' (n: g: lib.nameValuePair "${prefix}${n}" {
          value = "\${terraform_data.${prefix}${n}.output}";
          sensitive = g.sensitive;
        }) allGenerators;
      };

      nixosModule = { ... }: {
        sops.age.sshKeyPaths   = [ ];
        sops.age.keyFile       = "/var/lib/sops-nix/key.txt";
        sops.defaultSopsFile   = serverSecretsPath;
        sops.validateSopsFiles = false;
        sops.secrets = builtins.mapAttrs (_: _: { }) serverSecrets;
      };

      deployNode = flake: {
        hostname = "_overridden_at_runtime_";
        sshUser  = "root";
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.${system}.activate.nixos
                   flake.nixosConfigurations.${name};
          autoRollback   = true;
          magicRollback  = true;
          confirmTimeout = 30;
        };
      };
    };

  # --- mkInfraApp ---------------------------------------------------------
  # Renders an ApplyConfig JSON document and produces a writeShellApp that
  # rewrites stateDir to be project-root-relative at runtime, then execs
  # `infra apply <config>`. All real logic lives in Haskell.
  mkInfraApp = {
    flake,
    terranixConfig,
    deployEnv ? {},
    hosts,
    stateDir ? ".tf-state",
  }:
  let
    flakeRef = "${flake}";

    hostJSON = host: {
      inherit (host) name serverSecrets serverSecretsPath generators;
      ipOutput = host.outputs.ip;
    };

    configJSON = pkgs.writeText "infra-config.json" (builtins.toJSON {
      inherit deployEnv flakeRef stateDir;
      terranixConfig = "${terranixConfig}";
      hosts          = map hostJSON hosts;
    });

  in pkgs.writeShellApplication {
    name = "infra";
    runtimeInputs = [ infra pkgs.git pkgs.jq ];
    text = ''
      root="$(git rev-parse --show-toplevel)"
      cfg="$(mktemp)"; trap 'rm -f "$cfg"' EXIT
      jq --arg root "$root" '.stateDir = ($root + "/" + .stateDir)' \
        ${configJSON} > "$cfg"
      exec infra apply "$cfg"
    '';
  };

in {
  inherit
    sopsKey tfStateOutput literal cmd
    once once' derive derive'
    mkHost mkInfraApp;
}
