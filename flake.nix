{
  description = "NixOS deploy orchestration: Haskell binary + Nix-side terranix helpers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, nixos-anywhere, deploy-rs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # The Haskell orchestration binary. Built once; wrapped at runtime
        # with PATH containing every external tool it shells out to.
        infraUnwrapped = pkgs.haskellPackages.callCabal2nix "nix-iac" ./. {};

        runtimeTools = [
          pkgs.opentofu pkgs.sops pkgs.age pkgs.openssh
          pkgs.curl pkgs.jq pkgs.git pkgs.coreutils pkgs.gnused
          nixos-anywhere.packages.${system}.default
          deploy-rs.packages.${system}.default
        ];

        infra = pkgs.runCommand "infra" {
          nativeBuildInputs = [ pkgs.makeWrapper ];
        } ''
          mkdir -p $out/bin
          makeWrapper ${infraUnwrapped}/bin/infra $out/bin/infra \
            --prefix PATH : ${pkgs.lib.makeBinPath runtimeTools}
        '';

        # Backwards-compat: the bash CLIs and the higher-order `mkHost` /
        # `mkInfraApp` API still live in lib/. mkInfraApp will migrate to
        # invoking the Haskell binary in M5; until then it keeps working.
        cliTools = import ./lib/cli.nix { inherit pkgs system nixos-anywhere deploy-rs; };

        bundle = pkgs.symlinkJoin {
          name = "nix-iac";
          paths = builtins.attrValues cliTools;
        };

        higherOrder = import ./lib/higher.nix {
          inherit pkgs system deploy-rs bundle;
          lib = pkgs.lib;
        };
      in {
        packages = cliTools // { default = bundle; inherit infra; };
        lib = higherOrder;

        apps.infra = {
          type = "app";
          program = "${infra}/bin/infra";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.cabal-install pkgs.haskellPackages.haskell-language-server ]
            ++ infraUnwrapped.env.nativeBuildInputs;
          inputsFrom = [ infraUnwrapped.env ];
        };
      });
}
