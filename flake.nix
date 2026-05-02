{
  description = "Bundle of idempotent-by-contract CLI tools for NixOS deploy orchestration";

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
        tools = import ./lib { inherit pkgs system nixos-anywhere deploy-rs; };
      in {
        # Each tool individually
        packages = tools // {
          # Bundle: add to runtimeInputs/buildInputs to get all four on PATH.
          default = pkgs.symlinkJoin {
            name = "nix-iac";
            paths = builtins.attrValues tools;
          };
        };
      });
}
