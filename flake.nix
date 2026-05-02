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

        higherOrder = import ./lib/higher.nix {
          inherit pkgs system deploy-rs infra;
          lib = pkgs.lib;
        };
      in {
        packages.default = infra;
        packages.infra   = infra;
        lib              = higherOrder;

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
