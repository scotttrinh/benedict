# Project commands

- Run all tests: `nix run .#test`
- Run one test file: `nix run .#test -- test/path-to-some-file.el`
- Run multiple test files: `nix run .#test -- test/path-one.el test/path-two.el`
- Run lints: `nix run .#lint`
- Exercise a real provider: `nix run .#live`

`nix run .#test` is offline and credential-free, and every suite in it runs
unconditionally — no skips, no tags, no environment probes. Anything needing a
key is a script under `scripts/`, run by `nix run .#live`. SPEC-001 §12.5 and
D21 say why.

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
distro/     aggregate package entry point (no implementation policy)
packages/   first-party package artifact manifest
skills/     agent-facing skill files
test/       ERT suites
```

Dependency direction is strictly downward: no `core/` file may `require` a file
from `support/`, `api/`, `providers/`, `ext/`, or `ui/`. This is enforced by
`test/benedict-boundaries-test.el`, which constrains `require` only —
`declare-function` and upward `autoload` cookies create no load-time dependency
and are allowed.

Within `core/`, the graph is `benedict.el` (a leaf) ← `benedict-message.el`,
`benedict-schema.el` ← `benedict-tool.el`, `benedict-provider.el` ←
`benedict-session.el` ← `benedict-core.el`. The hook variables live in
`benedict-session.el` rather than with the reducer that fires them; SPEC-001
§15 D15 says why.

## Tests

`test/test-helper.el` carries the shared fixtures. The reducer and the fake
provider both defer through `benedict-core-defer-function`, so
`benedict-test-with-manual-defer` takes both off the wall clock —
`benedict-test-step` runs one transition, `benedict-test-drain` runs to
quiescence and fails loudly on a runaway. Prefer that over timers and `sit-for`;
a state machine test that depends on timing is not testing the state machine.

Wrap anything that registers a tool, a provider, or a global hook in
`benedict-test-with-clean-registries`. Those registries are global, so a test
that leaves one dirty changes what the next test means.

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
