{
  description = "Constrained Nix-native infra orchestration: tofu + nixos-anywhere + colmena";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    terranix.url = "github:terranix/terranix";
    colmena.url = "github:zhaofengli/colmena";
  };

  outputs = { self, nixpkgs, flake-utils, terranix, colmena }:
    flake-utils.lib.eachDefaultSystem (system: {
      lib = import ./lib {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit system terranix colmena;
      };
    });
}
