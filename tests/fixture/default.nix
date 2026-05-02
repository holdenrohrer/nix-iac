# Synthetic consumer used as the in-tree coherence test for nix-iac.
#
# Exercises every public DSL constructor against the `local` tofu backend
# so `nix build .#checks.<sys>.fixture-infra-builds` works without creds.
# Doesn't *run* tofu — that's a `nix run` smoke test.

{ iac, pkgs, system, flake }:

let
  # Two tfstates: one private-ish, one public-ish. Both local backend.
  private = iac.tfState {
    name = "private";
    backend.local = { path = "terraform.tfstate"; };
  };

  public = iac.tfState {
    name = "public";
    backend.local = { path = "terraform.tfstate"; };
  };

  fakeSops = pkgs.writeText "fake-secrets.yaml" ''
    fake_token: ENC[fake]
  '';

  # A literal output declared in 'public' tfstate, just to prove
  # cross-state declarations land in the right config.tf.json.
  greeting = public.output "greeting" {
    value = "hello-from-public-state";
  };

  # An inline generator declared at point of use in private state.
  fixturePassword = private.output "fixture_password"
    (iac.gen.once "printf 'static-fixture-password'");

  # iac.host bundles the four standard generators automatically.
  fixtureHost = iac.host {
    name     = "fixture";
    tfState  = private;
    ipOutput = private.output "fixture_ip" { value = "127.0.0.1"; };

    serverSecrets = {
      literal_secret  = iac.src.literal "literal-value";
      cmd_secret      = iac.src.cmd "printf cmd-derived-value";
      sops_secret     = iac.src.sops fakeSops "fake_token";
      generated_pw    = fixturePassword;
      cross_state_ref = greeting;
    };
  };

  app = iac.mkInfraApp {
    flake    = flake;
    hosts    = [ fixtureHost ];
    tfStates = [
      { state = private; modules = []; }
      { state = public;  modules = []; }
    ];
    deployEnv = {
      EXAMPLE_LITERAL = iac.src.literal "literal-env-value";
      EXAMPLE_CMD     = iac.src.cmd "printf cmd-env-value";
      EXAMPLE_SOPS    = iac.src.sops fakeSops "fake_token";
    };
    stateDir = ".tf-fixture";
  };

  # Tofu-only variant: empty hosts (so the deploy phase is a no-op),
  # no sops in deployEnv (so we don't need a real sops file). Exercises
  # the tfstate apply path end-to-end against the local backend.
  tofuOnlyPriv  = private.output "tofu_only_password" (iac.gen.once "printf 'static-pw-value'");
  tofuOnlyDeriv = private.output "tofu_only_password_doubled"
                    (iac.gen.derive' { from = tofuOnlyPriv; command = "tr -d '\\n' | sed 's/.*/&-derived/'"; });
  tofuOnlyPub   = public.output "tofu_only_greeting" { value = "hi-from-public-state"; };

  tofuOnlyApp = iac.mkInfraApp {
    flake    = flake;
    hosts    = [];
    tfStates = [
      { state = private; modules = []; }
      { state = public;  modules = []; }
    ];
    deployEnv = {
      EXAMPLE_LITERAL = iac.src.literal "literal-env-value";
      EXAMPLE_CMD     = iac.src.cmd "printf cmd-env-value";
    };
    extraSources = [ tofuOnlyPriv tofuOnlyDeriv tofuOnlyPub ];
    stateDir = ".tf-fixture-tofu-only";
  };
in {
  inherit app tofuOnlyApp;
}
