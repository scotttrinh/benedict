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

        # Custom Emacs with all test dependencies pre-installed
        myEmacs = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages (epkgs: with epkgs; [
          ert-async
          dash
          s
          package-lint
        ]);

      in
      {
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
            exec ${myEmacs}/bin/emacs -Q --batch -l test/run-tests.el
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
