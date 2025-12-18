# AGENT.md

Working notes for future agents contributing to Benedict. This doc explains our planning/devlogs flow, how we develop and test in Doom Emacs, and coding practices that keep the Elisp predictable in a live Emacs environment.

## Workflow: Efforts & Agents

We no longer use ad-hoc `devlogs/` plan/notes files for new work. All non-trivial work is organized into **Efforts** driven by three primary agents:

- Research agent (`efforts/<effort-slug>/research.md`)
  - Documents the current state of the codebase and data flows.
  - Answers "what exists today" with `path:line` references.
- Planning agent (`efforts/<effort-slug>/plan.md`)
  - Turns the research into a concrete, testable implementation plan.
  - Phases, success criteria, and verification strategy live here.
- Build agent (`efforts/<effort-slug>/log.md`)
  - Executes the plan and records what actually happened.
  - Uses this AGENTS.md as its primary guide for logging.

### Effort directory layout

For a given `effort-slug` (kebab-case summary of the task):

- `efforts/<effort-slug>/research.md` — Current state analysis (input to planning).
- `efforts/<effort-slug>/plan.md` — Implementation plan (input to build/execution).
- `efforts/<effort-slug>/log.md` — Chronological log of work performed and decisions made.

If you find yourself stuck with syntax issues, primarily issues with balancing parentheses, please summarize what you're trying to do, stop the agentic loop, and ask for help from the user.

## Elisp Conventions (Project-Specific)

- Headers & lexical-binding
  - All files start with `-*- lexical-binding: t; -*-`.
  - Provide a clear package header and `provide` symbol.
- Namespaces
  - Public functions: `benedict-...`; internal helpers: `benedict--...`.
  - One feature per file; file provides its feature name.
- Keybindings
  - Default prefix is `C-c C-b` (customizable via `benedict-keymap-prefix`).
  - Bind a prefix keymap (e.g., `benedict-prefix-map`) under the customizable prefix.
  - Avoid `C-c <letter>`; that space is reserved for users.
- Autoloads & load order
  - Interactive commands that live outside `benedict.el` must be autoloaded from `benedict.el`, e.g.:
    ```elisp
    (autoload 'benedict-chat "benedict-chat" "Open Benedict chat buffer." t)
    ```
  - Libraries may `(require 'benedict)` for shared defs (defgroup, faces, errors).
- Faces & errors
  - Faces: `benedict-chat-user`, `benedict-chat-assistant`, `benedict-chat-system`.
  - Error hierarchy: base `benedict-error`; derive as needed (e.g., `benedict-provider-error`).
- Modes
  - `benedict-mode` (minor mode) installs the prefix map.
  - `benedict-chat-mode` is derived from `special-mode`; keep UI non-blocking and simple.
- Compatibility
  - Target Emacs 27.1+; streaming UX improves on 28+.
- Docs & comments
  - Write helpful docstrings and minimal comments before complex blocks. Keep code self-explanatory.

## Testing & Quality Gates

### Nix Setup: Reproducible Dependencies

The `flake.nix` file defines a reproducible testing environment with Emacs and all dependencies pre-installed. This ensures tests run the same way locally, in CI, and for other contributors.

#### Running Tests

- **With Nix (always use this):**
  ```sh
  nix run .#test
  ```
  - You can filter with an ERT selector:
    ```sh
    nix run .#test -- benedict-chat-stream-insertion
    ```
  - **Do not** call `ert-run-tests-batch(-and-exit)` inside individual test files; the runner in `test/run-tests.el` loads all `*-test.el` files and handles exit status.

- **When adding new tests**: Ensure they run in batch mode (no interactive prompts, no buffers left behind).

#### Running Lints

- **Check all linters** (strict mode for CI):
  ```sh
  nix run .#lint
  ```

- **Allow warnings during development**:
  ```sh
  LINT_WARNINGS_ONLY=1 nix run .#lint
  ```

Linters run checkdoc (docstring style), package-lint (packaging best practices), and bytecomp (syntax/compilation errors). Temporary compilation happens in a sandboxed directory to avoid polluting the source tree.

### Test Architecture

Tests use **ERT** (Emacs' standard test runner) with support for **ert-async** (non-blocking tests). This is documented in `test/run-tests.el`.

#### Standard unit tests (ERT)

Use `ert-deftest` for deterministic, synchronous tests:

```elisp
(ert-deftest benedict-chat-opens ()
  "Chat buffer should open and be ready for input."
  (let ((buf (benedict-chat)))
    (should (buffer-live-p buf))
    (should (string-match-p "Chat:" (buffer-name buf)))))
```

Assertions: `should`, `should-not`, `should-error`, and others all report full backtraces on failure.

#### Async tests (ert-async)

For code involving timers or deferred execution, use `ert-deftest-async`:

```elisp
(ert-deftest-async benedict-stream-timeout (done)
  "Streaming should handle timeout gracefully."
  (let ((start-time (current-time)))
    (benedict-stream-with-timeout 0.5
      (run-with-timer 0.3 nil
                      (lambda ()
                        (should (< (float-time (time-subtract (current-time) start-time)) 1.0))
                        (funcall done))))))
```

The `done` callback marks the test complete. Schedule assertions with `run-with-timer` after async operations. **Keep delays short** (0.1-0.3s) to avoid timeout. The test runner waits for all `done` calls before exiting.

#### Property-based tests (propcheck)

Use `propcheck-deftest` to verify that functions behave correctly across random inputs:

```elisp
(propcheck-deftest benedict-prop-context-slice-size ()
  "Context slices should always have numeric size-bytes field."
  (let ((content (propcheck-generate-string "content"))
        (max-bytes (propcheck-generate-integer "max" :min 10 :max 10000)))
    (let ((slice (benedict-context-make-slice :content content :max-bytes max-bytes)))
      (propcheck-should (numberp (plist-get slice :size-bytes))))))
```

Propcheck generates 100 random test cases per deftest. Use:

- `propcheck-generate-string` – Random ASCII string.
- `propcheck-generate-integer` – Integer in a range. **IMPORTANT**: This function takes keyword arguments `:min` and `:max`, not positional arguments.
  - Correct: `(propcheck-generate-integer "foo" :min 1 :max 10)`
  - Incorrect: `(propcheck-generate-integer "foo" 1 10)` (causes counterexample errors)
- `propcheck-generate-proper-list` – List of generated values.
- `propcheck-should` – Assertion that must hold for all cases.

**Key benefit**: Property tests catch edge cases (extreme values, unusual combinations) that unit tests might miss. When a property test fails, propcheck shrinks the failing input to find the minimal case.

**Note on Error Reporting**: If your test code (including generator calls) raises an error, `propcheck` will catch it and report it as a "Found counterexample". If you see a counterexample that looks impossible (e.g., nil when you expected an integer), check if your test setup code is raising an error (like invalid-argument) that is being swallowed.

#### Test file structure

Each test file should follow this pattern:

```elisp
;;; test/my-feature-test.el --- Tests for my-feature  -*- lexical-binding: t; -*-

(require 'ert)
(require 'ert-async)  ;; if using async tests

;; Load the feature under test
(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'my-feature)

(ert-deftest my-feature-basic () ...)
(ert-deftest-async my-feature-async (done) ...)

(provide 'test/my-feature-test)
;;; my-feature-test.el ends here
```

**Do not use `require` to load test files** if they don't provide a feature; `test/run-tests.el` uses `load` with force=t instead.

### Byte-Compilation & Linting

- **Byte-compile clean** on Emacs 27.1 and 28.x; catch warnings early.
- Keep UI non-blocking; prefer `make-process` or `url-retrieve` for IO.
- Consider adding a `test/run-lint.el` for `checkdoc`, `package-lint`, and `bytecomp` in future phases (see the flywire project for a complete example).

### Mocking and Isolation

Use `cl-letf` to dynamically rebind functions and avoid side effects:

```elisp
(cl-letf (((symbol-function 'benedict-provider-send)
           (lambda (msg) '(:mock-response t))))
  (let ((result (benedict-chat-send-prompt "test")))
    (should (equal result '(:mock-response t)))))
```

This isolates tests, improves speed, and makes assertions deterministic. Functions are restored automatically after the `let` block exits.

## Effort Logs: How To Write `log.md`

The **Build agent** (and humans doing implementation work) are responsible for maintaining `efforts/<effort-slug>/log.md`. This file replaces ad-hoc `devlogs/Notes_*.org` entries for new work.

### Purpose

- Capture what actually happened while executing the plan: changes made, decisions taken, surprises, and verification steps.
- Provide enough context that a future contributor can reconstruct the story of the effort without digging through shell history.
- Stay tightly linked to `research.md` and `plan.md`:
  - Reference research findings when they influence decisions.
  - Reference specific plan phases/steps when you complete or adjust them.

### Structure of `log.md`

Use timestamped, append-only entries. A simple recommended pattern:

- `## [YYYY-MM-DD HH:MM] [Agent/Human]`
  - **Phase/Step**: Short reference to the plan phase or step.
  - **Event**: What you attempted or completed.
  - **Decision**: Any choice made (including alternatives considered briefly).
  - **Rationale**: Why this decision was reasonable, referencing `research.md` or `plan.md` when applicable.
  - **Impact**: What changed in the codebase or plan (include `path:line` refs when possible).
  - **Verification**: Commands run or checks performed (e.g., `nix run .#test`, specific ERT selectors).

Keep entries short and scan-friendly; prefer bullets and concise sentences over prose. Avoid inlining large diffs — instead point to files and describe the change.

### When to add a log entry

- After completing a meaningful plan step (e.g., implementing a function, adding a test, updating a keybinding).
- When you discover new information that was not captured in `research.md` and that materially affects the plan.
- When you deviate from the plan (and whether the plan or research docs should be updated later).
- When you run tests or lints that meaningfully increase confidence (or fail in surprising ways).

Older `devlogs/Notes_*.org` files remain as historical context but should not be extended for new work; prefer the Efforts-based `log.md` instead.

## Commit/PR Messaging

- Prefer messages that explain the "why" more than the "what".
- Group changes by phase/task; avoid mixing planning docs with code changes unless directly related.

## Example repos

If needed, there is a set of repos that are used by the current user in their Doom Emacs setup symlinked into `./example-emacs-repos` that you can use to look at the source code of well-written Emacs packages. Of special note is `org-mode` which has a lot of similar patterns to what we're doing here.
