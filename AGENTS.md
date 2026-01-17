# Project commands

- Run all tests: `nix run .#test`
- Run one test file: `nix run .#test -- test/path-to-some-file.el`
- Run multiple test files: `nix run .#test -- test/path-one.el test/path-two.el`
- Run lints: `nix run .#lint`

Working notes for future agents contributing to Benedict. This doc explains our planning/devlogs flow, how we develop and test in Doom Emacs, and coding practices that keep the Elisp predictable in a live Emacs environment.

## Coding style

- Headers & lexical-binding
  - All files start with `-*- lexical-binding: t; -*-`.
  - Provide a clear package header and `provide` symbol.
- Namespaces
  - Public functions: `module-name-...`; internal helpers: `module-name--...`.
  - Group functionality that changes together into logical modules with loose coupling between modules
- Autoloads & load order
  - Interactive commands that live outside `benedict.el` must be autoloaded from `benedict.el`, e.g.:
    ```elisp
    (autoload 'benedict-chat "benedict-chat" "Open Benedict chat buffer." t)
    ```
  - Libraries may `(require 'benedict)` for shared defs (defgroup, faces, errors).
- Target Emacs 29.1+
- Use docstrings following Emacs Lisp convention

## Commit/PR Messaging

- Prefer messages that explain the "why" more than the "what".
- Group changes by phase/task; avoid mixing planning docs with code changes unless directly related.

## Example repos

If needed, there is a set of Emacs Lisp repos that are used by the current user in their Doom Emacs setup symlinked into `./example-repos/emacs` that you can use to look at the source code of well-written Emacs packages. Of special note is `org-mode` which has a lot of similar patterns to what we're doing here.

The source code for a similar agentic coding tool called OpenCode is available at `example-repos/opencode` and the Gemini OAuth plugin for OpenCode is available at `example-repos/opencode-gemini-auth`.
