# Promote Chat UI Mode Implementation Plan

## Overview
Replace the classic `benedict-chat-mode` implementation with the magit-section based UI currently in `benedict-chat-ui-mode`, making `benedict-chat-mode` the sole chat UI. This consolidates UI helpers and state into `benedict-chat` while removing classic overlay folding and any compatibility layer.

## Current State Analysis
- `benedict-chat-mode` is defined in `benedict-chat-mode.el` as a `special-mode` derivative with markdown font-lock setup; tests rely on its initialization behavior. (`benedict-chat-mode.el:86`, `test/benedict-chat-mode-test.el:6`)
- `benedict-chat-ui-mode` is defined in `benedict-chat-ui.el` as a `magit-section-mode` derivative, with its own keymap, section helpers, and folding sync. (`benedict-chat-ui.el:367`)
- `benedict-chat.el` conditionally integrates UI helpers and checks `benedict-chat-ui-mode` or a `benedict-chat-render--ui-active-p` predicate before using magit-section logic. (`benedict-chat.el:1204`, `benedict-chat.el:1286`, `benedict-chat-render.el:36`)
- Classic overlay folding and toggle logic lives in `benedict-chat.el` and is used when UI mode is inactive. (`benedict-chat.el:1552` through `benedict-chat.el:1640`)
- Tests target both modes; UI tests explicitly reference `benedict-chat-ui-mode` helpers while fold tests target classic overlay behavior. (`test/benedict-chat-thinking-test.el:55`, `test/benedict-chat-fold-test.el:1`)

## Desired End State
- `benedict-chat-mode` becomes the magit-section based mode (current `benedict-chat-ui-mode` behavior) and is the only chat mode.
- All `benedict-chat-ui--*` helpers move into `benedict-chat` as `benedict-chat--*` with no compatibility shims.
- Classic overlay folding logic and tests are removed; folding is exclusively magit-section based.
- Tests reference `benedict-chat-mode` and updated helper names; no tests refer to `benedict-chat-ui-mode`.

## What We're NOT Doing
- No backwards compatibility for `benedict-chat-ui-mode` or `benedict-chat-ui--*` symbols.
- No support for classic overlay folding or any runtime toggle between behaviors.
- No new UI features beyond parity with the existing `benedict-chat-ui-mode`.

## Implementation Approach
- Merge the mode and all UI helpers into `benedict-chat.el`, renaming to the `benedict-chat` namespace.
- Delete `benedict-chat-mode.el` and `benedict-chat-ui.el` content (or leave minimal stubs only if required by load order), ensuring `benedict-chat-mode` is defined once as magit-section based.
- Remove classic folding paths and update call sites to unconditionally use magit-section helpers.
- Update tests to reflect the single mode and renamed helpers; remove classic folding tests.

## Phase 1: Consolidate Mode Definition
### Overview
Define `benedict-chat-mode` as the magit-section derived mode in `benedict-chat.el` and remove the old definition file(s).
### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: Move `benedict-chat-ui-mode` definition, keymap, defcustom, and section-class registration here; rename to `benedict-chat-mode` and `benedict-chat-mode-map`. Ensure it derives from `magit-section-mode` and preserves existing keybindings and setup.
  - ```elisp
    (defcustom benedict-chat-fringe-bars-enabled ...)
    (defvar benedict-chat-mode-map ...)
    (define-derived-mode benedict-chat-mode magit-section-mode "Benedict-Chat" ...)
    ```
- **File**: `benedict-chat-mode.el`
  - **Changes**: Remove the classic mode definition and any related setup now owned by `benedict-chat.el`.
- **File**: `benedict-chat-ui.el`
  - **Changes**: Remove the UI mode definition and associated helpers after they are moved to `benedict-chat.el`.
### Success Criteria
#### Automated Verification
- [ ] `nix run .#lint`
#### Manual Verification
- [ ] Opening a chat buffer uses `benedict-chat-mode` with magit-section navigation keys available.

## Phase 2: Merge UI Helpers + State
### Overview
Move `benedict-chat-ui--*` helpers into `benedict-chat.el`, rename to `benedict-chat--*`, and update all call sites.
### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: Add the renamed helpers for badges, section classes, section insertion, folding sync, and UI state; initialize conversation/turn section locals unconditionally.
  - ```elisp
    (defvar-local benedict-chat--conversation-section nil)
    (defvar-local benedict-chat--current-turn-section nil)
    (defun benedict-chat--badge ...) ; replaces benedict-chat-ui--badge
    ```
- **File**: `benedict-chat-render.el`
  - **Changes**: Replace `benedict-chat-render--ui-active-p` checks and `benedict-chat-ui--*` calls with direct `benedict-chat--*` equivalents.
- **File**: `benedict-chat.el`
  - **Changes**: Remove any `benedict-chat-ui-mode` checks; use `benedict-chat-mode` only.
### Success Criteria
#### Automated Verification
- [ ] `nix run .#test -- test/benedict-chat-thinking-test.el`
#### Manual Verification
- [ ] Thinking/tool sections fold and unfold via magit-section and keep headers in sync.

## Phase 3: Remove Classic Folding + Update Tests
### Overview
Eliminate overlay-based folding logic and classic-mode tests; update test suite to use the new single-mode helpers.
### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: Remove classic folding functions (`benedict-chat--prepare-thinking-block`, `benedict-chat--apply-thinking-fold`, etc.) and any branching that depended on classic mode.
- **File**: `test/benedict-chat-fold-test.el`
  - **Changes**: Remove tests that target overlay folding; replace with magit-section equivalents if coverage is still needed.
- **File**: `test/benedict-chat-fold-propcheck-test.el`
  - **Changes**: Remove propcheck tests for classic folding or rewrite to assert magit-section folding invariants.
- **File**: `test/benedict-chat-thinking-test.el`
  - **Changes**: Update to use `benedict-chat-mode` and renamed helpers (`benedict-chat--register-section`, `benedict-chat--section-p`, `benedict-chat--sync-fold-state`).
- **File**: `test/benedict-chat-mode-test.el`
  - **Changes**: Update expectations to align with magit-section mode and new mode definition location; ensure markdown font-lock setup is retained if still required.
### Success Criteria
#### Automated Verification
- [ ] `nix run .#test`
#### Manual Verification
- [ ] No references to `benedict-chat-ui-mode` or `benedict-chat-ui--*` remain in the codebase.

## Testing Strategy
- Use `nix run .#test` after each phase to catch regressions in chat rendering and folding behavior.
- Run `nix run .#lint` once the mode definition is consolidated to catch package/lint issues.
- Manual verification: open a chat buffer, render assistant/user messages, and verify folding and navigation are magit-section driven.

## References
- `efforts/00049-effort_promote_chat_ui_mode/research.md`
