# nix-iac DSL v2 — typed-handle, tfstate-as-applicator.
#
# See ../README.md for the surface; this file implements:
#   iac.tfState, iac.host, iac.mkInfraApp,
#   iac.gen.{once, once', derive, derive'},
#   iac.src.{literal, cmd, sops}.
#
# A 'Source' is the typed handle that flows through serverSecrets,
# deployEnv, and (via .tfRef) terranix interpolation. Every reference is
# also a declaration: tfState.output collects the terranix fragment
# alongside the handle so mkInfraApp can fold it into the right state.

{ pkgs, system, deploy-rs, nixos-anywhere, terranix, nixIacLib, lib }:

let
  # ---------------------------------------------------------------- internals

  # Tags so we can recognize our own values when walking config.
  tagSource    = s: s    // { __nixIacSource    = true; };
  tagGenerator = g: g    // { __nixIacGenerator = true; };
  tagTfState   = s: s    // { __nixIacTfState   = true; };
  tagHost      = h: h    // { __nixIacHost      = true; };

  isSource    = v: builtins.isAttrs v && v.__nixIacSource    or false;
  isGenerator = v: builtins.isAttrs v && v.__nixIacGenerator or false;
  isTfState   = v: builtins.isAttrs v && v.__nixIacTfState   or false;
  isHost      = v: builtins.isAttrs v && v.__nixIacHost      or false;

  # ------------------------------------------------------------------- src.*

  # Non-tfstate sources omit `tfRef` entirely. Accessing `.tfRef` on one
  # of these yields a normal Nix "attribute missing" error at the call
  # site, which is informative enough.
  src = {
    literal = value: tagSource {
      kind = "literal"; tfState = null; payload = { inherit value; };
    };
    cmd = command: tagSource {
      kind = "cmd"; tfState = null; payload = { inherit command; };
    };
    sops = file: key: tagSource {
      kind = "sops"; tfState = null; payload = { inherit file key; };
    };
  };

  # ------------------------------------------------------------------- gen.*

  gen = {
    once    = command: tagGenerator { type = "once";   sensitive = true;  inherit command; };
    once'   = command: tagGenerator { type = "once";   sensitive = false; inherit command; };
    derive  = { from, command }:
      assert isSource from || throw "iac.gen.derive 'from' must be a Source";
      tagGenerator { type = "derive"; sensitive = true;  inherit from command; };
    derive' = { from, command }:
      assert isSource from || throw "iac.gen.derive' 'from' must be a Source";
      tagGenerator { type = "derive"; sensitive = false; inherit from command; };
  };

  # --------------------------------------------------------------- tfState.*

  # An output declaration: variable + terraform_data + output triple, so
  # the value is pinned across re-applies via ignore_changes on input.
  generatorDeclaration = name: g: {
    variable.${name} = {
      type      = "string";
      sensitive = g.sensitive;
      default   = "ignored";
    };
    resource.terraform_data.${name} = {
      input     = "\${var.${name}}";
      lifecycle = { ignore_changes = [ "input" ]; };
    };
    output.${name} = {
      value     = "\${terraform_data.${name}.output}";
      sensitive = g.sensitive;
    };
  };

  staticOutputDeclaration = name: body: {
    output.${name} =
      { inherit (body) value; sensitive = body.sensitive or false; }
      // (lib.optionalAttrs (body ? description) { inherit (body) description; });
  };

  tfState = { name, backend }:
    let
      stateRec = tagTfState rec {
        inherit name backend;
        backendModule = { terraform.backend = backend; };

        # Declares an output AND returns its handle.
        # body is either a Generator or { value; sensitive ?; description ?; }.
        output = outputName: body:
          if isGenerator body then tagSource {
            kind        = "tfstate-output";
            tfState     = stateRec;
            inherit outputName;
            payload     = { generator = body; };
            declaration = generatorDeclaration outputName body;
            tfRef       = "\${terraform_data.${outputName}.output}";
          } else tagSource {
            kind        = "tfstate-output";
            tfState     = stateRec;
            inherit outputName;
            payload     = { static = body; };
            declaration = staticOutputDeclaration outputName body;
            tfRef       = "\${" + (body.tfRefExpr or "output.${outputName}") + "}";
          };

        # Asserts an output is declared elsewhere; returns a handle. Use only
        # for cross-flake refs or when a terranix module declares the output
        # without going through the DSL.
        read = outputName: tagSource {
          kind        = "tfstate-output";
          tfState     = stateRec;
          inherit outputName;
          payload     = { read = true; };
          declaration = null;
          tfRef       = "\${output.${outputName}}";
        };
      };
    in stateRec;

  # ------------------------------------------------------------------- host

  host = { name, tfState, ipOutput, serverSecrets ? {} }:
    assert (isTfState tfState) || throw "iac.host: tfState must be from iac.tfState";
    assert (isSource ipOutput) || throw "iac.host: ipOutput must be a Source";
    let
      sshPriv = tfState.output "${name}_ssh_priv" (gen.once ''
        f=$(mktemp -u)
        ssh-keygen -t ed25519 -N "" -C "${name}" -f "$f" >/dev/null
        cat "$f"
        rm -f "$f" "$f.pub"
      '');
      sshPub  = tfState.output "${name}_ssh_pub"
                 (gen.derive' { from = sshPriv; command = "ssh-keygen -y -f /dev/stdin"; });
      agePriv = tfState.output "${name}_age_priv" (gen.once "age-keygen 2>/dev/null");
      agePub  = tfState.output "${name}_age_pub"
                 (gen.derive' { from = agePriv; command = "age-keygen -y /dev/stdin"; });
      # Server-side SSH host key. Generated once and pinned in tfstate; the
      # private half is shipped to the target via nixos-anywhere extras at
      # /etc/ssh/ssh_host_ed25519_key. Public half is what `iac exec` writes
      # into the per-invocation known_hosts so StrictHostKeyChecking=yes is
      # safe by construction (no TOFU window, no fingerprint surprises on
      # rebuild — the same key is reinstalled from tfstate every time).
      hostKeyPriv = tfState.output "${name}_host_priv" (gen.once ''
        f=$(mktemp -u)
        ssh-keygen -t ed25519 -N "" -C "${name}-host" -f "$f" >/dev/null
        cat "$f"
        rm -f "$f" "$f.pub"
      '');
      hostKeyPub  = tfState.output "${name}_host_pub"
                     (gen.derive' { from = hostKeyPriv; command = "ssh-keygen -y -f /dev/stdin"; });

      serverSecretsPath = "/var/lib/sops-nix/${name}-secrets.yaml";

      hostRec = tagHost {
        inherit name tfState serverSecrets serverSecretsPath;
        ip = ipOutput;
        inherit sshPriv sshPub agePriv agePub hostKeyPriv hostKeyPub;

        nixosModule = { ... }: {
          sops.age.sshKeyPaths   = [ ];
          sops.age.keyFile       = "/var/lib/sops-nix/key.txt";
          sops.defaultSopsFile   = serverSecretsPath;
          sops.validateSopsFiles = false;
          sops.secrets = builtins.mapAttrs (_: _: { }) serverSecrets;

          # Pin the host key to the one in tfstate. NixOS activation only
          # generates a missing key file; nixos-anywhere ships the file via
          # extras, so activation finds it and skips generation. By listing
          # only ed25519 we suppress the default rsa key too — modern only.
          services.openssh.hostKeys = [{
            type = "ed25519";
            path = "/etc/ssh/ssh_host_ed25519_key";
          }];
        };

        deployNode = flake: {
          hostname = "_overridden_at_runtime_";
          sshUser  = "root";
          profiles.system = {
            user           = "root";
            path           = deploy-rs.lib.${system}.activate.nixos
                               flake.nixosConfigurations.${name};
            autoRollback   = true;
            magicRollback  = true;
            confirmTimeout = 30;
          };
        };
      };
    in hostRec;

  # -------------------------------------------------------- Source -> JSON

  sourceJSON = s:
    if s.kind == "literal" then {
      kind = "literal";
      value = s.payload.value;
    } else if s.kind == "cmd" then {
      kind = "cmd";
      command = s.payload.command;
    } else if s.kind == "sops" then {
      kind = "sops";
      file = toString s.payload.file;
      key = s.payload.key;
    } else if s.kind == "tfstate-output" then {
      kind = "tfstate-output";
      state = s.tfState.name;
      outputName = s.outputName;
    } else throw "sourceJSON: unknown kind ${s.kind}";

  generatorJSON = g:
    if g.type == "once" then {
      type = "once";
      inherit (g) sensitive command;
    } else if g.type == "derive" then {
      type = "derive";
      inherit (g) sensitive command;
      from = sourceJSON g.from;
    } else throw "generatorJSON: unknown type ${g.type}";

  # ------------------------------------------------------- mkInfraApp

  # Walk an arbitrary Nix value, returning all Sources reachable through
  # attrset/list traversal. We DON'T descend into Sources themselves
  # (a Source's payload may itself contain another Source, e.g. Derive's
  # 'from'; we surface those via 'sourceClosure' below).
  collectSources = v:
    if isSource v       then [ v ]
    else if isHost v    then collectSources (
        { inherit (v) ip sshPriv sshPub agePriv agePub hostKeyPriv hostKeyPub serverSecrets; })
    else if builtins.isAttrs v then
      lib.concatLists (lib.mapAttrsToList (_: collectSources) v)
    else if builtins.isList v then
      lib.concatLists (map collectSources v)
    else [];

  # Stable string key for a Source — used for dedup and closure tracking.
  # Wrapped in unsafeDiscardStringContext because the result becomes an
  # attribute name (which can't carry store-path context) and we only
  # use it for identity comparison.
  sourceKey = s: builtins.unsafeDiscardStringContext (
    if      s.kind == "literal"        then "literal:"  + s.payload.value
    else if s.kind == "cmd"            then "cmd:"      + s.payload.command
    else if s.kind == "sops"           then "sops:"     + toString s.payload.file
                                                       + ":" + s.payload.key
    else if s.kind == "tfstate-output" then "tfout:"    + s.tfState.name
                                                       + "/" + s.outputName
    else throw "sourceKey: unknown kind ${s.kind}");

  # Transitive closure under Derive's 'from'.
  sourceClosure = sources:
    let
      step = s:
        if s.kind == "tfstate-output"
           && (s.payload ? generator)
           && s.payload.generator.type == "derive"
        then [ s.payload.generator.from ]
        else [];
      go = seenAttrs: queue:
        if queue == [] then lib.attrValues seenAttrs
        else let
          h = builtins.head queue;
          t = builtins.tail queue;
          k = sourceKey h;
        in if seenAttrs ? ${k}
           then go seenAttrs t
           else go (seenAttrs // { ${k} = h; }) (t ++ step h);
    in go {} sources;

  # Dedupe tfstate-output Sources by (stateName, outputName) so identical
  # declarations don't get merged twice into the same terranix config.
  uniqueByOutput = sources: lib.foldl' (acc: s:
    if !(s.kind == "tfstate-output") then acc
    else let key = s.tfState.name + "/" + s.outputName; in
      if acc ? ${key} then acc else acc // { ${key} = s; }
  ) {} sources;

  # Produce the per-tfstate runtime config: (configFile, generators-in-order).
  perStateConfig = allSources: { state, modules }:
    let
      mySources = lib.filter
        (s: s.kind == "tfstate-output" && s.tfState.name == state.name)
        (lib.attrValues (uniqueByOutput allSources));

      declarations = lib.filter (m: m != null) (map (s: s.declaration) mySources);
      generators   = lib.filter (s: s.payload ? generator) mySources;

      tfJson = terranix.lib.terranixConfiguration {
        inherit system;
        modules = [ state.backendModule ] ++ modules ++ declarations;
      };
    in {
      inherit (state) name;
      configFile = tfJson;
      genSpecs   = map (s: { name = s.outputName; gen = s.payload.generator; }) generators;
    };

  # ----------------------------------------------------------- mkInfraApp

  # `extraSources` is for declarations that should land in tfstate but
  # aren't consumed by any host's serverSecrets or by deployEnv —
  # typically outputs published for an external flake to read.
  mkInfraApp = { flake, hosts, tfStates, deployEnv ? {}, stateDir ? ".tf-state", extraSources ? [], deployApp ? "infra-deploy" }:
    let
      flakeRef = "${flake}";

      # Validate inputs.
      _ = lib.forEach hosts (h:
        assert isHost h || throw "mkInfraApp.hosts: every entry must be from iac.host"; null);
      _2 = lib.forEach tfStates (e:
        assert (e ? state && isTfState e.state)
          || throw "mkInfraApp.tfStates: every entry must be { state = iac.tfState {...}; modules = [...]; }";
        null);

      # Closed set of all Sources that flow through the orchestration.
      reachable = sourceClosure (
           collectSources hosts
        ++ collectSources deployEnv
        ++ extraSources
      );

      tfStateCfgs = map (perStateConfig reachable) tfStates;

      hostPlan = {
        inherit stateDir flakeRef;
        deployEnv = builtins.mapAttrs (_: sourceJSON) deployEnv;
        hosts = map (h: {
          inherit (h) name serverSecretsPath;
          ip = sourceJSON h.ip;
          sshPriv = sourceJSON h.sshPriv;
          sshPub = sourceJSON h.sshPub;
          agePriv = sourceJSON h.agePriv;
          agePub = sourceJSON h.agePub;
          hostKeyPriv = sourceJSON h.hostKeyPriv;
          hostKeyPub = sourceJSON h.hostKeyPub;
          serverSecrets = builtins.mapAttrs (_: sourceJSON) h.serverSecrets;
        }) hosts;
      };

      execPlanFile = pkgs.writeText "infra-exec-plan.json" (builtins.toJSON (
        hostPlan // {
          # `infra exec` only resolves deployEnv + host material from already
          # applied tfstates. Keeping deploy tfstate configs out of the fast
          # wrapper avoids evaluating unrelated deploy-only modules such as
          # NixOS image metadata.
          tfStates = [];
        }
      ));

      deployPlanFile = pkgs.writeText "infra-deploy-plan.json" (builtins.toJSON (
        hostPlan // {
          tfStates = map (c: {
            inherit (c) name;
            configFile = toString c.configFile;
            genSpecs = map (g: {
              inherit (g) name;
              gen = generatorJSON g.gen;
            }) c.genSpecs;
          }) tfStateCfgs;
        }
      ));

      execTools = [
        pkgs.opentofu pkgs.sops pkgs.openssh pkgs.rsync
        pkgs.git pkgs.coreutils
      ];

      deployTools = execTools ++ [
        pkgs.age pkgs.curl pkgs.gnused
        nixos-anywhere.packages.${system}.default
        deploy-rs.packages.${system}.default
      ];

      deployWrapped = pkgs.runCommand "infra-deploy" {
        nativeBuildInputs = [ pkgs.makeWrapper ];
      } ''
        mkdir -p $out/bin
        makeWrapper ${nixIacLib}/bin/nix-iac $out/bin/infra \
          --add-flags "--plan ${deployPlanFile}" \
          --prefix PATH : ${pkgs.lib.makeBinPath deployTools} \
          --set LANG C.UTF-8 \
          --set LC_ALL C.UTF-8
      '';

      wrapped = pkgs.runCommand "infra" {
        nativeBuildInputs = [ pkgs.makeWrapper ];
      } ''
        mkdir -p $out/bin
        makeWrapper ${nixIacLib}/bin/nix-iac $out/bin/infra-real \
          --add-flags "--plan ${execPlanFile}" \
          --prefix PATH : ${pkgs.lib.makeBinPath execTools} \
          --set LANG C.UTF-8 \
          --set LC_ALL C.UTF-8

        cat > $out/bin/infra <<'EOF'
        #!${pkgs.runtimeShell}
        set -e
        export PATH=${pkgs.lib.makeBinPath execTools}:$PATH
        case "''${1-}" in
          ""|deploy)
            echo "infra: deploy uses the heavy deploy app; run ${deployApp} instead" >&2
            exit 64
            ;;
          *)
            exec "$0-real" "$@"
            ;;
        esac
        EOF
        chmod +x $out/bin/infra
      '';
    in {
      type = "app";
      program = "${wrapped}/bin/infra";
      # Expose the underlying derivation so consumers can include it as
      # a Hydra job (or any other place that wants a derivation rather
      # than the `nix run` indirection).
      package = wrapped;
      deploy = {
        type = "app";
        program = "${deployWrapped}/bin/infra";
        package = deployWrapped;
      };
      deployPackage = deployWrapped;
    };

in {
  inherit src gen tfState host mkInfraApp;
}
