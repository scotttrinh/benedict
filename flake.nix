{
  description = "Benedict - Agent in Emacs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        easkOverlay = (final: prev: {
          eask-cli = prev.eask-cli.overrideAttrs (old:
            let
              src' = prev.fetchFromGitHub {
                owner = "scotttrinh";
                repo = "eask-cli";
                rev = "14d9da6d7751dd605f0d31e26e224fe0ef58c537";
                hash = "sha256-ZA20pNiyw8hyGtYCUIRq2JmHMlnqAnhzzP3jPdALz8M=";
              };
              depsHash = "sha256-IIAG1ITEJ5Q0Ox0tZp6dM5DvahtB1qUFH54UUyOzjg4=";
            in {
            version = "0.11.8-fix-elsa-format-string";
            src = src';
            npmDepsHash = depsHash;
            npmDeps = prev.fetchNpmDeps {
              src = src';
              hash = depsHash;
            };
          });
        });

        pkgs = import nixpkgs {
          inherit system;
          overlays = [ easkOverlay ];
        };

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

        # Exercises a REAL provider, with real credentials, and spends real
        # money.  Deliberately not a test: `nix run .#test' is offline and
        # credential-free and stays that way (SPEC-001 12.5, D21).
        apps.live = {
          type = "app";
          program = toString (runWithEask "run-live" ''
            exec ${eask}/bin/eask exec ${emacs}/bin/emacs --batch \
              -l scripts/live-smoke.el -f benedict-live-smoke "$@"
          '');
        };

        apps.lint = {
          type = "app";
          program = toString (runWithEask "run-lint" ''
            # Run both linters and report a combined status.  `set -e' would
            # short-circuit on the first failure, and `exec' would replace the
            # shell so the second never ran at all.
            status=0
            ${eask}/bin/eask lint checkdoc "$@" || status=1
            ${eask}/bin/eask exec ${emacs}/bin/emacs --batch -L packages \
              -l scripts/lint-packages.el -f benedict-package-lint-batch || status=1
            exit $status
          '');
        };

        defaultApp = self.apps.${system}.test;
      }
    );
}
