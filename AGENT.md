# AGENT.md

Working notes for future agents contributing to Benedict. This doc explains our planning/devlogs flow, how we develop and test in Doom Emacs, and coding practices that keep the Elisp predictable in a live Emacs environment.

## Workflow: Plans vs Notes

- Plans live in `devlogs/` with filenames like `YYYYMMDDHHMM-Plan_Phase_N.org`.
  - Contents: tasks, decisions, acceptance criteria, tentative file layout.
- Notes (what actually happened) also live in `devlogs/` as `YYYYMMDDHHMM-Notes_*.org`.
  - Contents: what worked, what didn’t, concrete diffs/decisions, and follow‑ups.
- Keep planning docs forward‑looking; keep notes factual/retrospective. Don’t mix them.
- Reference: see `devlogs/20251116105736-Plan_Phase_0.org`, `devlogs/20251116105752-Plan_Phase_1.org`, and subsequent `Notes_*` entries.
- Timestamp accuracy
  - Create the file however you like (Org capture, `touch`, Emacs, etc.), then rename it based on the filesystem creation time so the prefix is always correct.
  - Command: `ts=$(stat -f '%SB' -t '%Y%m%d%H%M%S' devlogs/tmp.org) && mv devlogs/tmp.org "devlogs/${ts}-Plan_Phase_2.org"`.
  - This uses macOS `stat` to read the real creation time (`%SB`) and ensures distinct prefixes even when multiple files are created the same minute.

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

2) Symlink into straight’s repos (integrated with Doom builds)
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

- Byte-compile clean on Emacs 27.1 and 28.x (reduce warnings early).
- ERT tests: start small
  - Chat opens and can send a prompt (echo response).
  - Tools registry: register/list/call roundtrip.
- Keep UI non-blocking; prefer `make-process` or `url-retrieve` for IO in later phases.

## How To Manually Test Right Now

- Enable `benedict-mode` and run `C-c C-b c` to open chat (`M-x benedict-chat` also works).
- In the chat buffer, `C-c C-s` prompts for input and inserts an echo response.
- Tool demo (eval):
  ```elisp
  (require 'benedict-tools)
  (benedict-tool-call 'uppercase :text "foo")  ;; => "FOO"
  ```

## Devlogs: When To Write Notes

- After any discrete task lands (keybinding fix, autoload change, new file skeleton), add a `Notes_*.org` entry summarizing:
  - Problem, root cause, fix, verification steps, and any follow-ups.
- Keep entries short and scan-friendly; include commands or Emacs forms that helped verify.

## Commit/PR Messaging (Future)

- Prefer messages that explain the “why” more than the “what”.
- Group changes by phase/task; avoid mixing planning docs with code changes unless directly related.

## Common Pitfalls

- Autoload failures: ensure `benedict.el` autoloads interactive commands from other files.
- Reserved key sequences: don’t bind `C-c <letter>`.
- Load-path issues: confirm the working copy is in `load-path` during WIP.
- Over-eager `require`: avoid heavy `require` at top-level if it creates cycles; autoload where possible.
