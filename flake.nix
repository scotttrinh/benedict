{
  description = "Benedict - AI chat in Emacs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    propcheck = {
      url = "github:Wilfred/propcheck";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, propcheck }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Build propcheck package from GitHub source
        propcheckPkg = pkgs.runCommand "propcheck-0.1" {
          src = propcheck;
        } ''
          mkdir -p $out/share/emacs/site-lisp/elpa/propcheck-0.1
          cp $src/propcheck.el $out/share/emacs/site-lisp/elpa/propcheck-0.1/
          echo "(define-package \"propcheck\" \"0.1\" \"Property based testing\" '((dash \"2.12\")))" > $out/share/emacs/site-lisp/elpa/propcheck-0.1/propcheck-pkg.el
        '';

        # Custom Emacs with all test dependencies pre-installed
        myEmacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: with epkgs; [
          ert-async
          dash
          s
          package-lint
        ] ++ [ propcheckPkg ]);

      in
      {
        # Expose propcheck package for reference
        packages.propcheck = propcheckPkg;

        # Development shell with Emacs and dependencies
        devShells.default = pkgs.mkShell {
          buildInputs = [
            myEmacs
            pkgs.git
          ];
        };

        # Test app: run all tests
        apps.test = {
          type = "app";
          program = toString (pkgs.writeShellScript "run-tests" ''
            exec ${myEmacs}/bin/emacs -Q --batch -l test/run-tests.el "$@"
          '');
        };

        # Lint app: check code quality (scaffolding for future)
        apps.lint = {
          type = "app";
          program = toString (pkgs.writeShellScript "run-lint" ''
            exec ${myEmacs}/bin/emacs -Q --batch -l test/run-lint.el
          '');
        };

        # Default app is test
        defaultApp = self.apps.${system}.test;
      }
    );
}
