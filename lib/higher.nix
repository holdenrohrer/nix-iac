# Higher-order helpers: declarative host bindings + the orchestration script
# that ties terranix + sops + the four CLI tools together for the common case.
#
# Public surface:
#   sopsKey, tfStateOutput, literal, cmd  -- tagged constructors
#   mkHost { name, serverSecrets }        -- bind a host name to its outputs/modules
#   mkInfraApp { ... }                    -- one-shot deploy orchestrator

{ pkgs, system, deploy-rs, bundle, lib }:

let
  shellChecks = [ "SC2155" "SC2046" "SC2086" "SC2016" ];

  # --- Tagged source constructors -------------------------------------------
  sopsKey       = key:  { kind = "sops";     payload = key; };
  tfStateOutput = name: { kind = "tfstate";  payload = name; };
  literal       = val:  { kind = "literal";  payload = val; };
  cmd           = c:    { kind = "cmd";      payload = c; };

  # Render a tagged source as a bash expression that produces the value.
  # Assumes get_sops / get_tf bash functions are in scope.
  renderSource = src:
    if      src.kind == "sops"     then ''$(get_sops "${src.payload}")''
    else if src.kind == "tfstate"  then ''$(get_tf   "${src.payload}")''
    else if src.kind == "literal"  then src.payload
    else if src.kind == "cmd"      then "$(${src.payload})"
    else throw "renderSource: unknown kind '${src.kind}'";

  # --- mkHost: bind a host name to all its derived attributes ---------------
  mkHost = { name, serverSecrets ? {}, ipOutput ? "${name}_ip" }:
    let outputs = {
          ip      = ipOutput;
          sshPriv = "${name}_ssh_priv";
          sshPub  = "${name}_ssh_pub";
          agePriv = "${name}_age_priv";
          agePub  = "${name}_age_pub";
        };
    in rec {
      inherit name serverSecrets outputs;
      serverSecretsPath = "/var/lib/sops-nix/${name}-secrets.yaml";

      # Terranix module emitting variables (set via TF_VAR at deploy), the
      # terraform_data resource that pins them across applies, and the
      # outputs the orchestrator reads back. The consumer's terranix
      # config still owns the actual cloud resource (hcloud_server etc) and
      # the `output.${ipOutput}` referencing it.
      terranixModule = {
        variable."${name}_age_priv" = { type = "string"; sensitive = true; default = "ignored"; };
        variable."${name}_age_pub"  = { type = "string"; default = "ignored"; };
        variable."${name}_ssh_priv" = { type = "string"; sensitive = true; default = "ignored"; };
        variable."${name}_ssh_pub"  = { type = "string"; default = "ignored"; };

        resource.terraform_data."${name}_keys" = {
          input = {
            age_priv = "\${var.${name}_age_priv}";
            age_pub  = "\${var.${name}_age_pub}";
            ssh_priv = "\${var.${name}_ssh_priv}";
            ssh_pub  = "\${var.${name}_ssh_pub}";
          };
          lifecycle = { ignore_changes = [ "input" ]; };
        };

        output = {
          "${outputs.agePriv}" = { value = "\${terraform_data.${name}_keys.output.age_priv}"; sensitive = true; };
          "${outputs.agePub}"  = { value = "\${terraform_data.${name}_keys.output.age_pub}"; };
          "${outputs.sshPriv}" = { value = "\${terraform_data.${name}_keys.output.ssh_priv}"; sensitive = true; };
          "${outputs.sshPub}"  = { value = "\${terraform_data.${name}_keys.output.ssh_pub}"; };
        };
      };

      # NixOS module wiring sops-nix for this host's serverSecrets. Consumer
      # imports this into nixosConfigurations.${name}.modules.
      nixosModule = { ... }: {
        sops.age.sshKeyPaths = [ ];
        sops.age.keyFile     = "/var/lib/sops-nix/key.txt";
        sops.defaultSopsFile = serverSecretsPath;
        sops.validateSopsFiles = false;  # path is on the target, not in the store
        sops.secrets = builtins.mapAttrs (_: _: { }) serverSecrets;
      };

      # deploy-rs node spec. Takes the consumer's `self` (flake) so it can
      # reference nixosConfigurations.${name} without nix-iac knowing about
      # the consumer's flake structure.
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

  # --- Orchestration script generator ---------------------------------------
  mkInfraApp = {
    flake,                   # consumer's `self` (a flake)
    terranixConfig,          # derivation: the rendered config.tf.json
    sopsFile,                # path to operator sops file
    deployEnv ? {},          # { ENV_VAR = sopsKey "..."; ... }
    hosts,                   # [ (mkHost {...}) ... ]
    stateDir ? ".tf-state",
  }:
  let
    flakeRef = "${flake}";  # store path of the flake

    # Bash to populate process env from sops/tfstate/etc.
    exportEnv = mapping: lib.concatStringsSep "\n" (
      lib.mapAttrsToList (var: src:
        ''export ${var}="${renderSource src}"''
      ) mapping);

    # Pre-apply: per host, generate keypairs if not yet in tfstate.
    preApply = host: ''
      if ! tofu -chdir="$tf_dir" output -raw ${host.outputs.agePriv} >/dev/null 2>&1; then
        echo "==> ${host.name}: first apply, generating keypairs"
        age-keygen -o "$tmp/${host.name}.age" 2>/dev/null
        ssh-keygen -t ed25519 -N "" -C "${host.name}" -f "$tmp/${host.name}.ssh" >/dev/null
        export TF_VAR_${host.name}_age_priv="$(cat "$tmp/${host.name}.age")"
        export TF_VAR_${host.name}_age_pub="$(age-keygen -y "$tmp/${host.name}.age")"
        export TF_VAR_${host.name}_ssh_priv="$(cat "$tmp/${host.name}.ssh")"
        export TF_VAR_${host.name}_ssh_pub="$(cat "$tmp/${host.name}.ssh.pub")"
      else
        for v in age_priv age_pub ssh_priv ssh_pub; do
          export "TF_VAR_${host.name}_$v=ignored"
        done
      fi
    '';

    # Post-apply: per host, build blob, ship, nixify, deploy, reboot.
    perHostDeploy = host:
      let
        secretLines = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (k: src: "${k}: ${renderSource src}") host.serverSecrets);
      in ''
        echo "==> ${host.name}: deploying"
        ip="$(get_tf ${host.outputs.ip})"
        age_pub="$(get_tf ${host.outputs.agePub})"
        ssh_pub="$(get_tf ${host.outputs.sshPub})"
        get_tf ${host.outputs.sshPriv} > "$tmp/${host.name}.ssh.key"
        get_tf ${host.outputs.agePriv} > "$tmp/${host.name}.age.key"
        chmod 600 "$tmp/${host.name}.ssh.key" "$tmp/${host.name}.age.key"

        cat > "$tmp/${host.name}.blob.yaml" <<EOF
        ${secretLines}
        EOF
        sops --config /dev/null --encrypt \
             --input-type yaml --output-type yaml \
             --age "$age_pub" "$tmp/${host.name}.blob.yaml" \
             > "$tmp/${host.name}.blob.sops.yaml"

        extras="$(mktemp -d)"
        install -D -m 600 "$tmp/${host.name}.age.key" "$extras/var/lib/sops-nix/key.txt"
        install -D -m 600 "$tmp/${host.name}.blob.sops.yaml" \
                          "$extras${host.serverSecretsPath}"
        printf '%s\n' "$ssh_pub" \
          | install -D -m 600 /dev/stdin "$extras/etc/ssh/authorized_keys.d/root"

        if probe-nixos "$ip" "$tmp/${host.name}.ssh.key"; then
          scp -i "$tmp/${host.name}.ssh.key" -o StrictHostKeyChecking=accept-new \
              "$tmp/${host.name}.blob.sops.yaml" \
              "root@$ip:${host.serverSecretsPath}.new"
          ssh -i "$tmp/${host.name}.ssh.key" -o StrictHostKeyChecking=accept-new \
              "root@$ip" "install -m 600 ${host.serverSecretsPath}{.new,}"
        fi

        nixify "${host.name}" "${flakeRef}" "$ip" "$tmp/${host.name}.ssh.key" "$extras"
        deploy-with-rollback "${flakeRef}" "${host.name}" "$ip" "$tmp/${host.name}.ssh.key"
        reboot-if-boot-critical "$ip" "$tmp/${host.name}.ssh.key"
      '';

  in pkgs.writeShellApplication {
    name = "infra";
    excludeShellChecks = shellChecks;
    runtimeInputs = [
      bundle  # nix-iac CLI tools
      pkgs.opentofu pkgs.sops pkgs.age
      pkgs.openssh pkgs.git pkgs.coreutils
    ];
    text = ''
      root="$(git rev-parse --show-toplevel)"
      tf_dir="$root/${stateDir}"
      tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

      get_sops() { sops --config /dev/null -d --extract "[\"$1\"]" "${toString sopsFile}"; }
      get_tf()   { tofu -chdir="$tf_dir" output -raw "$1"; }

      ${exportEnv deployEnv}

      mkdir -p "$tf_dir"
      install -m 644 ${terranixConfig} "$tf_dir/config.tf.json"
      tofu -chdir="$tf_dir" init -input=false -reconfigure >/dev/null

      ${lib.concatMapStringsSep "\n" preApply hosts}

      tofu -chdir="$tf_dir" apply -auto-approve -input=false

      ${lib.concatMapStringsSep "\n" perHostDeploy hosts}
    '';
  };

in {
  inherit sopsKey tfStateOutput literal cmd mkHost mkInfraApp;
}
