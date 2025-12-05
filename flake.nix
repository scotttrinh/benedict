{
  description = "Benedict - AI chat in Emacs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        emacs = pkgs.emacs;
        eask = pkgs.eask-cli;

        envExports = ''
          export EASK_EMACS=${emacs}/bin/emacs
          export EASK_NONINTERACTIVE=1
        '';

        runWithEask = name: script:
          pkgs.writeShellScript name ''
            set -euo pipefail
            ${envExports}
            ${script}
          '';

      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            emacs
            eask
            pkgs.git
          ];
          shellHook = ''
            export EASK_EMACS=${emacs}/bin/emacs
            export EASK_NONINTERACTIVE=1
          '';
        };

        apps.test = {
          type = "app";
          program = toString (runWithEask "run-tests" ''
            exec ${eask}/bin/eask test ert-runner "$@"
          '');
        };

        apps.lint = {
          type = "app";
          program = toString (runWithEask "run-lint" ''
            exec ${eask}/bin/eask lint checkdoc
            exec ${eask}/bin/eask lint package
          '');
        };

        defaultApp = self.apps.${system}.test;
      }
    );
}
