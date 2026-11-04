{
  description = "gh-template development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # The tools that the extension calls, in the PATH of its wrapper
        runtimeInputs = with pkgs; [
          bash
          gh
          gum
          yq-go
          perl
          file
          git
          ccase
        ];
      in
      {
        # The extension as gh reads it: a directory named after it with the executable in it. home-manager's
        # programs.gh.extensions links the bin/ of this package as that directory. The script finds its scripts next to
        # itself, so the repository is installed whole in libexec and the wrapper in bin/ only sets the PATH
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          pname = "gh-template";
          version = nixpkgs.lib.fileContents ./version.txt;
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/libexec/gh-template $out/bin
            cp -r . $out/libexec/gh-template
            rm -rf $out/libexec/gh-template/{tests,flake.nix,flake.lock,.envrc,.gitignore}
            chmod +x $out/libexec/gh-template/gh-template

            makeWrapper $out/libexec/gh-template/gh-template $out/bin/gh-template \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeInputs}

            runHook postInstall
          '';

          meta = {
            description = "Apply variable substitutions to a repository from a template config";
            homepage = "https://github.com/gh-extensions/gh-template";
            license = pkgs.lib.licenses.mit;
            mainProgram = "gh-template";
          };
        };

        devShells.default = pkgs.mkShell {
          name = "gh-template";
          packages =
            runtimeInputs
            ++ (with pkgs; [
              bats
              shellcheck
            ]);
        };
      }
    );
}
