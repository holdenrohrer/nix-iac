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
          fixture-infra = fixture.app;
        };

        checks = {
          # Build the fixture's per-consumer binary. Proves the whole
          # pipeline (DSL -> walk Sources -> generate Main.hs -> callCabal2nix)
          # is coherent end-to-end.
          fixture-infra-builds =
            pkgs.runCommand "fixture-infra-builds" {} ''
              ls -l ${fixture.app.program} > $out
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
