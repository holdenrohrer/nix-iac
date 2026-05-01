# Constrained interface for tofu+nixos-anywhere+colmena infra orchestration.
#
# Consumers should ONLY touch:
#   - their terranix modules (the infrastructure description)
#   - their nixosConfigurations / colmenaHive (the system declarations)
#   - the `hosts` attrset they pass to mkApps (which IP belongs to which host,
#     plus paths to per-host secrets)
#
# Everything else (state location, bootstrap path, app names, env-var contract
# between mkApps and mkDeployment) is FIXED. Don't add knobs unless this
# breaks for a real use case.

{ pkgs, system, terranix, colmena }:

let
  inherit (pkgs) lib;
  nixos-anywhere = "github:nix-community/nixos-anywhere";

  tfPreamble = stateDir: tfConfig: ''
    root="$(git rev-parse --show-toplevel)"
    tf_dir="$root/${stateDir}"
    mkdir -p "$tf_dir"
    install -m 644 ${tfConfig} "$tf_dir/config.tf.json"
    ( cd "$tf_dir" && tofu init -input=false -reconfigure >/dev/null )
  '';

  mkHostApp = { name, ipOutput, sshKey, bootstrapFiles, stateDir, tfConfig }:
    pkgs.writeShellApplication {
      name = "infra-${name}";
      runtimeInputs = [
        pkgs.opentofu pkgs.git pkgs.openssh pkgs.coreutils
        colmena.packages.${system}.colmena
      ];
      text = ''
        ${tfPreamble stateDir tfConfig}
        ( cd "$tf_dir" && tofu apply -auto-approve -input=false )
        ip="$(cd "$tf_dir" && tofu output -raw ${ipOutput})"
        echo "==> ${name}: $ip"

        export COLMENA_TARGET_HOST="$ip"
        export COLMENA_SSH_KEY="${toString sshKey}"

        if ssh -i "${toString sshKey}" \
               -o StrictHostKeyChecking=accept-new \
               -o UserKnownHostsFile="$tf_dir/known_hosts" \
               -o ConnectTimeout=10 \
               -o BatchMode=yes \
               "root@$ip" "test -e /etc/NIXOS" 2>/dev/null; then
          echo "==> NixOS detected — colmena update"
          cd "$root"
          colmena apply --on ${name} switch --impure
        else
          echo "==> Fresh host — bootstrapping with nixos-anywhere"
          extra="$(mktemp -d)"
          trap 'rm -rf "$extra"' EXIT
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (dst: src: ''
            install -D -m 600 "${toString src}" "$extra/${dst}"
          '') bootstrapFiles)}
          nix run ${nixos-anywhere} -- \
            --flake "$root#${name}" \
            --extra-files "$extra" \
            -i "${toString sshKey}" \
            "root@$ip"
        fi
      '';
    };

  mkDestroyApp = { stateDir, tfConfig }:
    pkgs.writeShellApplication {
      name = "infra-destroy";
      runtimeInputs = [ pkgs.opentofu pkgs.git pkgs.coreutils ];
      text = ''
        ${tfPreamble stateDir tfConfig}
        ( cd "$tf_dir" && tofu destroy -auto-approve )
      '';
    };

  mkImportApp = { stateDir, tfConfig, importMap }:
    pkgs.writeShellApplication {
      name = "infra-import";
      runtimeInputs = [ pkgs.opentofu pkgs.git pkgs.coreutils ];
      text = ''
        ${tfPreamble stateDir tfConfig}
        cd "$tf_dir"
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (resource: id:
          "tofu import '${resource}' '${id}' || true"
        ) importMap)}
      '';
    };

  mkUmbrellaApp = { hostNames, hostApps }:
    pkgs.writeShellApplication {
      name = "infra";
      runtimeInputs = [];
      text = lib.concatMapStringsSep "\n"
        (n: "${hostApps.${n}}/bin/infra-${n}")
        hostNames;
    };

in {

  # Returns an attrset suitable for `apps.${system}` (consumer just merges it in).
  # Generates: infra (umbrella) + infra.<host> per host + infra.destroy
  #            + infra.import (only if importMap is non-empty)
  mkApps = {
    terranixModules,
    hosts,                       # { <name> = { ipOutput, sshKey, bootstrapFiles ? {} }; }
    stateDir   ? ".tf-state",
    importMap  ? {},             # { "<tf-resource>" = "<existing-id>"; } — for migrating
  }:
    let
      tfConfig = terranix.lib.terranixConfiguration {
        inherit system;
        modules = terranixModules;
      };

      hostApps = lib.mapAttrs (name: cfg:
        mkHostApp ({
          inherit name stateDir tfConfig;
          bootstrapFiles = cfg.bootstrapFiles or {};
        } // (lib.removeAttrs cfg [ "bootstrapFiles" ]))
      ) hosts;

      destroyApp  = mkDestroyApp  { inherit stateDir tfConfig; };
      umbrellaApp = mkUmbrellaApp { hostNames = lib.attrNames hosts; inherit hostApps; };
      importApp   = mkImportApp   { inherit stateDir tfConfig importMap; };

      hostAppOutputs = lib.mapAttrs (n: drv: {
        type = "app";
        program = "${drv}/bin/infra-${n}";
      }) hostApps;

      maybeImport = lib.optionalAttrs (importMap != {}) {
        import = { type = "app"; program = "${importApp}/bin/infra-import"; };
      };
    in {
      infra = {
        type = "app";
        program = "${umbrellaApp}/bin/infra";
        destroy = { type = "app"; program = "${destroyApp}/bin/infra-destroy"; };
      } // hostAppOutputs // maybeImport;
    };

  # Use this for `deployment` in your colmenaHive node defs. Reads target host
  # + ssh key from env vars set by mkApps's per-host script. Don't override.
  mkDeployment = {
    targetHost = let h = builtins.getEnv "COLMENA_TARGET_HOST"; in
      if h == "" then null else h;
    targetUser = "root";
    sshOptions =
      let k = builtins.getEnv "COLMENA_SSH_KEY"; in
      lib.optionals (k != "") [ "-i" k ];
  };
}
