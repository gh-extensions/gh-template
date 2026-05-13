{
  description = "gh-template development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    ccase-src = {
      url = "github:stringcase/ccase";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ccase-src,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ccase = pkgs.rustPlatform.buildRustPackage {
          pname = "ccase";
          version = "unstable";
          src = ccase-src;
          cargoLock = {
            lockFile = "${ccase-src}/Cargo.lock";
          };
          doCheck = false;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "gh-template";
          packages = with pkgs; [
            bash
            gh
            gum
            yq-go
            bats
            shellcheck
            perl
            file
            git
            ccase
          ];
        };
      }
    );
}
