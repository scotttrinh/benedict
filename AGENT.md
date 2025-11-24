# AGENT.md

Working notes for future agents contributing to Benedict. This doc explains our planning/devlogs flow, how we develop and test in Doom Emacs, and coding practices that keep the Elisp predictable in a live Emacs environment.

## Workflow: Plans vs Notes

- Plans live in `devlogs/` with filenames like `YYYYMMDDHHMM-Plan_Phase_N.org`.
  - Contents: tasks, decisions, acceptance criteria, tentative file layout.
- Notes (what actually happened) also live in `devlogs/` as `YYYYMMDDHHMM-Notes_*.org`.
  - Contents: what worked, what didn't, concrete diffs/decisions, and follow-ups.
- Keep planning docs forward-looking; keep notes factual/retrospective. Don't mix them.
- Reference: see `devlogs/20251116105736-Plan_Phase_0.org`, `devlogs/20251116105752-Plan_Phase_1.org`, and subsequent `Notes_*` entries.
- Timestamp accuracy
  - Create the file however you like (Org capture, `touch`, Emacs, etc.), then rename it based on the filesystem creation time so the prefix is always correct.
  - Command: `ts=$(stat -f '%SB' -t '%Y%m%d%H%M%S' devlogs/tmp.org) && mv devlogs/tmp.org "devlogs/${ts}-Plan_Phase_2.org"`.
  - This uses macOS `stat` to read the real creation time (`%SB`) and ensures distinct prefixes even when multiple files are created the same minute.
- If you find yourself stuck with syntax issues, primarily issues with balancing parentheses, please summarize what you're trying to do, stop the agentic loop, and ask for help from the user.

## Local Dev Environment (Doom Emacs)

Choose one of these setups. Option 1 is fastest for iteration.

1) Add repo to load-path (recommended during WIP)
- In `~/.config/doom/config.el`:
  ```elisp
  (add-to-list 'load-path "/Users/scotttrinh/github.com/scotttrinh/benedict")
  (use-package! benedict
    :commands (benedict-chat benedict-mode))
  ```
- Reload Doom: `M-x doom/reload` (or restart Emacs).

2) Symlink into straight's repos (integrated with Doom builds)
- Shell:
  ```sh
  ln -s ~/github.com/scotttrinh/benedict \
        ~/.config/emacs/.local/straight/repos/benedict
  ```
- In `~/.config/doom/packages.el`:
  ```elisp
  (package! benedict :recipe (:local-repo "benedict"))
  ```
- In `~/.config/doom/config.el`:
  ```elisp
  (use-package! benedict
    :commands (benedict-chat benedict-mode))
  ```
- Run `doom sync`, then restart Emacs (or `M-x doom/reload`).

Tips
- For fast iteration, Option 1 avoids native-comp latency.
- When using `:commands`, ensure interactive entry points are autoloaded (see below).

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

## Provider & Tools (Early Phases)

- Provider interface (Phase 0/1 sketch)
  - Struct or plist carrying `:id`, `:name`, `:send`, `:capabilities`, `:cancel`.
  - Phase 1 uses an echo provider (local, no network) to keep iteration fast.
- Tool registry (Phase 1 skeleton)
  - Minimal register/list/call with simple schema and approval placeholders.
  - Approval policy values: `auto`, `confirm`, `always` (no-op or stub UI in Phase 1).
- Security posture (carry through phases)
  - Keys via `auth-source` first, env var fallback. Never write secrets to disk. Redact in logs.

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

- **Without Nix** (manual in a dev shell):
  ```sh
  nix develop
  emacs -Q --batch -l test/run-tests.el
  ```

- **Interactive debugging** (in Emacs):
  ```sh
  emacs -Q
  M-x load-file test/my-test.el
  M-x ert RET my-test-name RET
  ```

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

### Markers, overlays, and folding (read this before editing chat UI)

- Whenever you insert complex UI like folded "Thinking" blocks, store `:content-start` and `:content-end` as markers that use **correct stickiness**. For example, thinking content should use a front-non-sticky marker at the start and a rear-sticky marker for the end so streaming append operations do not invert the region.
- Capture `:content-end` immediately after inserting the block's payload, then keep that marker front-sticky while you append closing dividers/newlines. Once the scaffolding is in place, flip it back to rear-sticky so later updates extend the overlay without swallowing the next message.
- If a block installs an overlay, **always** update it whenever you mutate the block's text. Forgetting to move the overlay leads to `args-out-of-range` errors once Emacs tries to adjust it during timers.
- When regenerating content (e.g., final reasoning replaces streamed chunks), delete text between the stored markers rather than rewriting the entire block; this keeps downstream markers (buttons, block dividers) valid.
- New streaming UI must survive timers firing after the buffer is killed. Audit every `run-at-time` callback to guard with `(buffer-live-p buffer)` before touching markers.

## How To Manually Test Right Now

- Enable `benedict-mode` and run `C-c C-b c` to open chat (`M-x benedict-chat` also works).
- In the chat buffer, `C-c C-s` prompts for input and inserts an echo response.
- Tool demo (eval):
  ```elisp
  (require 'benedict-tools)
  (benedict-tool-invoke 'uppercase '(:text "foo"))  ;; => "FOO"
  ```

## Devlogs: When To Write Notes

- After any discrete task lands (keybinding fix, autoload change, new file skeleton), add a `Notes_*.org` entry summarizing:
  - Problem, root cause, fix, verification steps, and any follow-ups.
- Keep entries short and scan-friendly; include commands or Emacs forms that helped verify.

## Commit/PR Messaging (Future)

- Prefer messages that explain the "why" more than the "what".
- Group changes by phase/task; avoid mixing planning docs with code changes unless directly related.

## Common Pitfalls

- Autoload failures: ensure `benedict.el` autoloads interactive commands from other files.
- Reserved key sequences: don't bind `C-c <letter>`.
- Load-path issues: confirm the working copy is in `load-path` during WIP.
- Over-eager `require`: avoid heavy `require` at top-level if it creates cycles; autoload where possible.
