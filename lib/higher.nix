# Higher-order helpers: declarative host bindings + the orchestration script
# that ties terranix + sops + the four CLI tools together for the common case.

{ pkgs, system, deploy-rs, bundle, lib }:

let
  shellChecks = [ "SC2155" "SC2046" "SC2086" "SC2016" "SC2034" ];

  # --- Tagged source constructors -------------------------------------------
  # `sopsKey` is curried: bind a file once, then call repeatedly per key.
  #   infraSops = sopsKey ./secrets/infra.yaml;
  #   serverSecrets.github_token = infraSops "github_token";
  sopsKey       = file: key: { kind = "sops"; payload = { inherit file key; }; };
  tfStateOutput = name:       { kind = "tfstate"; payload = name; };
  literal       = val:        { kind = "literal"; payload = val; };
  cmd           = c:          { kind = "cmd"; payload = c; };

  # --- Generated-secret constructors ----------------------------------------
  # Each one is a "kind" stored in tfstate via terraform_data with
  # ignore_changes — generated on first apply, pinned forever after.
  #
  #   once   <command>           run command, capture stdout, store
  #   once'  <command>           same, but value is non-sensitive (public)
  #   derive <from> <command>    pipe `from` value through command, store
  #   derive' <from> <command>   same, sensitive
  once    = command:       { type = "once";   inherit command; sensitive = true;  };
  once'   = command:       { type = "once";   inherit command; sensitive = false; };
  derive  = from: command: { type = "derive"; inherit from command; sensitive = false; };
  derive' = from: command: { type = "derive"; inherit from command; sensitive = true; };

  # Render a tagged source as a bash expression that produces the value.
  renderSource = src:
    if      src.kind == "sops"
      then ''$(sops --config /dev/null -d --extract "[\"${src.payload.key}\"]" "${toString src.payload.file}")''
    else if src.kind == "tfstate"  then ''$(get_tf "${src.payload}")''
    else if src.kind == "literal"  then src.payload
    else if src.kind == "cmd"      then "$(${src.payload})"
    else throw "renderSource: unknown kind '${src.kind}'";

  # --- mkHost ---------------------------------------------------------------
  mkHost = {
    name,
    serverSecrets ? {},
    generators    ? {},
    ipOutput      ? "${name}_ip",
  }:
    let
      # Built-in generators every nixifiable host needs.
      # `2>/dev/null` suppresses age-keygen's "Public key:" banner on stderr.
      builtinGenerators = {
        age_priv = once "age-keygen 2>/dev/null";
        age_pub  = derive' "age_priv" "age-keygen -y /dev/stdin";
        ssh_priv = once ''
          f=$(mktemp)
          ssh-keygen -t ed25519 -N "" -C "${name}" -f "$f" >/dev/null
          cat "$f"
          rm -f "$f" "$f.pub"
        '';
        ssh_pub  = derive' "ssh_priv" "ssh-keygen -y -f /dev/stdin";
      };
      allGenerators = builtinGenerators // generators;

      outputs = {
        ip = ipOutput;
      } // builtins.mapAttrs (n: _: "${name}_${n}") allGenerators;
    in rec {
      inherit name serverSecrets outputs;
      generators = allGenerators;

      serverSecretsPath = "/var/lib/sops-nix/${name}-secrets.yaml";

      # Convenience: refer to a generated value as a tagged source.
      #   serverSecrets.api_token = buildfarm.use "api_token";
      use = key: tfStateOutput "${name}_${key}";

      # Terranix module: variable + terraform_data + outputs for each generator.
      # Variables and outputs are prefixed with the host name to avoid collisions
      # across hosts in a single-flake-multiple-hosts config.
      terranixModule = let
        prefix = "${name}_";
      in {
        variable = lib.mapAttrs' (n: g: lib.nameValuePair "${prefix}${n}" {
          type = "string";
          sensitive = g.sensitive;
          default = "ignored";
        }) allGenerators;

        # One terraform_data per generator — additive: introducing a new
        # generator doesn't disturb existing ones (each has its own
        # `ignore_changes = [input]` lifecycle and its own state row).
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

  # --- Orchestration script generator ---------------------------------------
  mkInfraApp = {
    flake,                   # consumer's `self`
    terranixConfig,          # rendered config.tf.json derivation
    deployEnv ? {},          # { ENV_VAR = sopsKey ...; ... }
    hosts,                   # [ (mkHost {...}) ... ]
    stateDir ? ".tf-state",
  }:
  let
    flakeRef = "${flake}";

    exportEnv = mapping: lib.concatStringsSep "\n" (
      lib.mapAttrsToList (var: src:
        ''export ${var}="${renderSource src}"''
      ) mapping);

    # Per-generator: skip if already in tfstate, else generate and export TF_VAR.
    # Iteration is alphabetical (Nix attrset order); derive generators must
    # sort AFTER their `from` deps (e.g. age_priv < age_pub) — true by default.
    genBlock = host: genName: gen:
      let
        outputName = "${host.name}_${genName}";
        varName    = "TF_VAR_${outputName}";
      in ''
        if existing=$(get_tf ${outputName} 2>/dev/null) && [ -n "$existing" ]; then
          ${genName}_val="$existing"
          export ${varName}=ignored
        else
          ${if gen.type == "once" then ''
            ${genName}_val="$(${gen.command})"
          '' else ''
            ${genName}_val="$(printf '%s' "${"$" + gen.from + "_val"}" | ${gen.command})"
          ''}
          export ${varName}="${"$" + genName + "_val"}"
        fi
      '';

    perHostPreApply = host: lib.concatStringsSep "\n" (
      lib.mapAttrsToList (genBlock host) host.generators);

    perHostDeploy = host:
      let
        secretLines = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (k: src: "${k}: ${renderSource src}") host.serverSecrets);
      in ''
        echo "==> ${host.name}: deploying"
        ip="$(get_tf ${host.outputs.ip})"
        age_pub="$(get_tf ${host.outputs.age_pub})"
        ssh_pub="$(get_tf ${host.outputs.ssh_pub})"

        # Materialize the key files (with trailing newline; libcrypto needs it)
        { get_tf ${host.outputs.ssh_priv}; printf '\n'; } > "$tmp/${host.name}.ssh.key"
        { get_tf ${host.outputs.age_priv}; printf '\n'; } > "$tmp/${host.name}.age.key"
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
      bundle
      pkgs.opentofu pkgs.sops pkgs.age
      pkgs.openssh pkgs.git pkgs.coreutils
    ];
    text = ''
      root="$(git rev-parse --show-toplevel)"
      tf_dir="$root/${stateDir}"
      tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

      get_tf() { tofu -chdir="$tf_dir" output -raw "$1"; }

      ${exportEnv deployEnv}

      mkdir -p "$tf_dir"
      install -m 644 ${terranixConfig} "$tf_dir/config.tf.json"
      tofu -chdir="$tf_dir" init -input=false -reconfigure >/dev/null

      ${lib.concatMapStringsSep "\n" perHostPreApply hosts}

      tofu -chdir="$tf_dir" apply -auto-approve -input=false

      ${lib.concatMapStringsSep "\n" perHostDeploy hosts}
    '';
  };

in {
  inherit
    sopsKey tfStateOutput literal cmd
    once once' derive derive'
    mkHost mkInfraApp;
}
