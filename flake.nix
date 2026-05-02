{
  description = "nix-iac: typed-handle DSL for Nix-native infra orchestration";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    terranix.url    = "github:terranix/terranix";
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, terranix, nixos-anywhere, deploy-rs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # The Haskell library every per-consumer binary links against.
        nixIacLib = pkgs.haskellPackages.callCabal2nix "nix-iac" ./. {};

        iac = import ./lib/iac.nix {
          inherit pkgs system deploy-rs nixos-anywhere terranix nixIacLib;
          lib = pkgs.lib;
        };

        # In-tree fixture: synthetic consumer that exercises every DSL
        # primitive against the local terraform backend, no creds needed.
        fixture = import ./tests/fixture { inherit iac pkgs system; flake = self; };
      in {
        lib = iac;

        packages = {
          nix-iac-lib = nixIacLib;
        };

        apps = {
          fixture-infra        = fixture.app;
          fixture-tofu-only    = fixture.tofuOnlyApp;
        };

        checks = {
          # Build the fixture's per-consumer binary. Proves the whole
          # pipeline (DSL -> walk Sources -> generate Main.hs -> callCabal2nix)
          # is coherent end-to-end.
          fixture-infra-builds =
            pkgs.runCommand "fixture-infra-builds" {} ''
              ls -l ${fixture.app.program} > $out
            '';

          # Run the tofu-only fixture against the local backend. Verifies
          # the orchestrator actually drives tofu init + apply, materializes
          # both 'once' and 'derive' generators, and writes their values
          # into the local tfstate file.
          fixture-local-apply = pkgs.runCommand "fixture-local-apply" {
            nativeBuildInputs = [ pkgs.git pkgs.jq ];
          } ''
            export HOME=$TMPDIR
            mkdir -p $TMPDIR/repo
            cd $TMPDIR/repo
            git init -q
            git config user.email test@example.com
            git config user.name test
            git commit --allow-empty -q -m init

            ${fixture.tofuOnlyApp.program}

            test -f .tf-fixture-tofu-only/private/terraform.tfstate \
              || { echo "private tfstate missing"; exit 1; }
            test -f .tf-fixture-tofu-only/public/terraform.tfstate \
              || { echo "public tfstate missing"; exit 1; }

            pw=$(jq -r '.outputs.tofu_only_password.value' \
                   .tf-fixture-tofu-only/private/terraform.tfstate)
            [ "$pw" = "static-pw-value" ] \
              || { echo "expected once-generator value, got '$pw'"; exit 1; }

            doubled=$(jq -r '.outputs.tofu_only_password_doubled.value' \
                        .tf-fixture-tofu-only/private/terraform.tfstate)
            [ "$doubled" = "static-pw-value-derived" ] \
              || { echo "expected derive-generator value, got '$doubled'"; exit 1; }

            greeting=$(jq -r '.outputs.tofu_only_greeting.value' \
                         .tf-fixture-tofu-only/public/terraform.tfstate)
            [ "$greeting" = "hi-from-public-state" ] \
              || { echo "expected static public output, got '$greeting'"; exit 1; }

            echo OK > $out
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.cabal-install
            pkgs.haskellPackages.haskell-language-server
          ] ++ nixIacLib.env.nativeBuildInputs;
          inputsFrom = [ nixIacLib.env ];
        };
      });
}
