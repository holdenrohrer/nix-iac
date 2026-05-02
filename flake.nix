{
  description = "NixOS deploy orchestration: idempotent CLI tools + declarative host bindings";

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
        packages = cliTools // { default = bundle; };
        lib = higherOrder;
      });
}
