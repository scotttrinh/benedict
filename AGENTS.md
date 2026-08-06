# Project commands

- Run all tests: `nix run .#test`
- Run one test file: `nix run .#test -- test/path-to-some-file.el`
- Run multiple test files: `nix run .#test -- test/path-one.el test/path-two.el`
- Run lints: `nix run .#lint`

## Source of truth

`SPEC-001--Core_Architecture.md` is the single specification for this project.
It describes the system to be built, not the system that exists. When the code
and the spec disagree, one of them is wrong — say which, and fix it rather than
working around it.

New specs and plans are written as additional numbered documents. Do not
resurrect the older planning docs; they were deliberately removed and remain in
git history.

## Layout

Per SPEC-001 §12.1. Subdirectories are added to `load-path` by `Eask`'s
`load-paths` directive; file name prefixes stay globally unique, so the layout
is organizational rather than semantic.

```
core/       benedict.el, -message, -session, -tool, -provider, -core, -schema
support/    benedict-http.el, benedict-auth.el, benedict-log.el
api/        wire protocol adapters
providers/  service catalog entries
ext/        distro extensions (store, eval, files, approvals, ...)
ui/         chat frontend and render components
skills/     agent-facing skill files
test/       ERT suites
```

Dependency direction is strictly downward: no `core/` file may `require` a file
from `support/`, `api/`, `providers/`, `ext/`, or `ui/`. This is enforced by
`test/benedict-boundaries-test.el`, which constrains `require` only —
`declare-function` and upward `autoload` cookies create no load-time dependency
and are allowed.

## Coding style

- Headers & lexical-binding
  - All files start with `-*- lexical-binding: t; -*-`.
  - Provide a clear package header and `provide` symbol.
- Namespaces
  - Public functions: `module-name-...`; internal helpers: `module-name--...`.
  - Group functionality that changes together into logical modules with loose
    coupling between modules.
- Target Emacs 29.1+. Note `nix run` uses a newer Emacs, so the 29.1 floor is
  not actually exercised — check `Package-Requires` claims by hand.
- Autoloads & load order
  - Interactive commands that live outside `core/benedict.el` must be
    autoloaded from it.
  - Libraries may `(require 'benedict)` for shared defs (defgroup, root error).
    `core/benedict.el` itself is a leaf and requires nothing from the project.

## Docstrings are load-bearing

SPEC-001 §10.2 makes `describe-function` and `describe-variable` the API
documentation — the agent reads them instead of a docs directory, so they can
never drift. Concretely:

- Every public function, hook variable, and struct slot needs a docstring
  written for an agent reading it cold.
- Use `cl-defstruct` slot `:documentation`; it appends to the generated
  accessor docstring.
- Hook variable docstrings state the exact calling convention and what return
  values mean.
- Any function that mutates its arguments says so in its first sentence.
- Any function that signals names the condition.

## Commit/PR messaging

- Prefer messages that explain the "why" more than the "what".
- Group changes by phase/task; avoid mixing planning docs with code changes
  unless directly related.

## Example repos

`./example-repos/` holds symlinks to reference sources (gitignored, may be
absent):

- `emacs` — the user's Doom straight repos. `org-mode` in particular uses many
  patterns similar to ours.
- `pi-mono` — pi, the harness SPEC-001 §13 derives its architecture from and
  compares against.
