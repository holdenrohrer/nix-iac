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

      serverSecretsPath = "/var/lib/sops-nix/${name}-secrets.yaml";

      hostRec = tagHost {
        inherit name tfState serverSecrets serverSecretsPath;
        ip = ipOutput;
        inherit sshPriv sshPub agePriv agePub;

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

  # ----------------------------------------------------- Source -> Haskell

  # Quote a Haskell string literal.
  hsString = s:
    let
      esc = c:
        if      c == "\\" then "\\\\"
        else if c == "\"" then "\\\""
        else if c == "\n" then "\\n"
        else if c == "\r" then "\\r"
        else if c == "\t" then "\\t"
        else c;
    in "\"" + lib.concatStrings (map esc (lib.stringToCharacters s)) + "\"";

  # Render a Source as a Haskell expression of type Source.
  sourceExpr = s:
    if      s.kind == "literal"        then "Literal " + hsString s.payload.value
    else if s.kind == "cmd"            then "Cmd "     + hsString s.payload.command
    else if s.kind == "sops"           then "Sops "    + hsString (toString s.payload.file)
                                              + " "    + hsString s.payload.key
    else if s.kind == "tfstate-output" then "TfOut "   + hsString s.tfState.name
                                              + " "    + hsString s.outputName
    else throw "sourceExpr: unknown kind ${s.kind}";

  # Render a Generator as a Haskell expression of type Generator.
  generatorExpr = g:
    let sens = if g.sensitive then "True" else "False"; in
    if g.type == "once"   then "Once "   + sens + " " + hsString g.command
    else if g.type == "derive" then
      "Derive " + sens + " (" + sourceExpr g.from + ") " + hsString g.command
    else throw "generatorExpr: unknown type ${g.type}";

  # ------------------------------------------------------- mkInfraApp

  # Walk an arbitrary Nix value, returning all Sources reachable through
  # attrset/list traversal. We DON'T descend into Sources themselves
  # (a Source's payload may itself contain another Source, e.g. Derive's
  # 'from'; we surface those via 'sourceClosure' below).
  collectSources = v:
    if isSource v       then [ v ]
    else if isHost v    then collectSources (
        { inherit (v) ip sshPriv sshPub agePriv agePub serverSecrets; })
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

  # Generate the per-consumer Main.hs.
  renderMain = { stateDir, flakeRef, deployEnv, tfStateCfgs, hosts }:
    let
      kvList = pairs:
        "[" + lib.concatStringsSep ", "
          (map (kv: "(" + hsString kv.name + ", " + kv.expr + ")") pairs) + "]";

      envList = lib.mapAttrsToList
        (k: v: { name = k; expr = sourceExpr v; })
        deployEnv;

      tfStateExpr = c:
        let
          gens = "[" + lib.concatStringsSep ", "
            (map (g: "GenSpec " + hsString g.name + " (" + generatorExpr g.gen + ")")
                 c.genSpecs) + "]";
        in "TfStateCfg { tfsName = " + hsString c.name
           + ", tfsConfigFile = " + hsString (toString c.configFile)
           + ", tfsGenerators = " + gens + " }";

      hostExpr = h:
        let
          kv = pairs: "[" + lib.concatStringsSep ", "
            (lib.mapAttrsToList (k: v: "(" + hsString k + ", " + sourceExpr v + ")") pairs) + "]";
        in "HostCfg { hName = " + hsString h.name
           + ", hServerSecretsPath = " + hsString h.serverSecretsPath
           + ", hIp = " + sourceExpr h.ip
           + ", hSshPriv = " + sourceExpr h.sshPriv
           + ", hSshPub = "  + sourceExpr h.sshPub
           + ", hAgePriv = " + sourceExpr h.agePriv
           + ", hAgePub = "  + sourceExpr h.agePub
           + ", hServerSecrets = " + kv h.serverSecrets
           + " }";
    in ''
      {-# LANGUAGE OverloadedStrings #-}
      -- GENERATED by iac.mkInfraApp. Do not edit.
      module Main where

      import           NixIac.Orchestrator
      import qualified System.Process as P
      import           System.IO      (hPutStrLn, stderr)

      main :: IO ()
      main = do
        root <- gitRoot
        let plan = Plan
              { planStateDir  = root <> "/" <> ${hsString stateDir}
              , planFlakeRef  = ${hsString flakeRef}
              , planTfStates  = [${lib.concatStringsSep ", " (map tfStateExpr tfStateCfgs)}]
              , planDeployEnv = ${kvList envList}
              , planHosts     = [${lib.concatStringsSep ", " (map hostExpr hosts)}]
              }
        hPutStrLn stderr ("==> nix-iac: stateDir = " <> planStateDir plan)
        orchestrate plan

      gitRoot :: IO String
      gitRoot = do
        out <- P.readProcess "git" ["rev-parse", "--show-toplevel"] ""
        pure (reverse (dropWhile (== '\n') (reverse out)))
    '';

  # ----------------------------------------------------------- mkInfraApp

  mkInfraApp = { flake, hosts, tfStates, deployEnv ? {}, stateDir ? ".tf-state" }:
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
      );

      tfStateCfgs = map (perStateConfig reachable) tfStates;

      mainHs = pkgs.writeText "Main.hs" (renderMain {
        inherit stateDir flakeRef deployEnv tfStateCfgs hosts;
      });

      cabalFile = pkgs.writeText "infra-consumer.cabal" ''
        cabal-version: 2.2
        name: infra-consumer
        version: 0.1.0.0
        build-type: Simple

        executable infra
          main-is:          Main.hs
          build-depends:    base, nix-iac, process
          default-language: GHC2021
      '';

      consumerSrc = pkgs.runCommand "infra-consumer-src" {} ''
        mkdir -p $out
        cp ${cabalFile} $out/infra-consumer.cabal
        cp ${mainHs}    $out/Main.hs
      '';

      consumerPkg = pkgs.haskellPackages.callCabal2nix "infra-consumer" consumerSrc {
        nix-iac = nixIacLib;
      };

      runtimeTools = [
        pkgs.opentofu pkgs.sops pkgs.age pkgs.openssh
        pkgs.curl pkgs.git pkgs.coreutils pkgs.gnused
        nixos-anywhere.packages.${system}.default
        deploy-rs.packages.${system}.default
      ];

      wrapped = pkgs.runCommand "infra" {
        nativeBuildInputs = [ pkgs.makeWrapper ];
      } ''
        mkdir -p $out/bin
        makeWrapper ${consumerPkg}/bin/infra $out/bin/infra \
          --prefix PATH : ${pkgs.lib.makeBinPath runtimeTools}
      '';
    in {
      type = "app";
      program = "${wrapped}/bin/infra";
    };

in {
  inherit src gen tfState host mkInfraApp;
}
