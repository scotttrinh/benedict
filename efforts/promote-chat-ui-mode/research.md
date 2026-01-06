# Research: promote-chat-ui-mode

## Goal
Document how `benedict-chat-ui-mode` functionality is currently layered on top of `benedict-chat.el`, what will need to be merged/renamed into `benedict-chat` (single mode), and which public tests rely on `benedict-chat-mode` or `benedict-chat-ui-mode` APIs.

## Files Reviewed
- `benedict-chat.el`
- `benedict-chat-ui.el`
- `benedict-chat-mode.el`
- `benedict-chat-render.el`
- `test/benedict-chat-mode-test.el`
- `test/benedict-chat-thinking-test.el`
- `test/benedict-chat-fold-test.el`
- `test/benedict-chat-fold-propcheck-test.el`
- `test/benedict-chat-integration-test.el`
- `test/benedict-chat-logic-test.el`
- `test/benedict-chat-stream-test.el`

## Current Mode Split Summary
- `benedict-chat-mode` (defined in `benedict-chat-mode.el`) is a `special-mode` derived mode with markdown font-lock configured for body regions. It has a mostly empty keymap waiting for bindings to be moved in. `benedict-chat-mode` is used in most tests as the classic chat buffer mode.
- `benedict-chat-ui-mode` (defined in `benedict-chat-ui.el`) is a `magit-section-mode` derived mode that wraps chat rendering inside magit sections and provides folding synchronization. It has its own keymap (section navigation + thinking/tool toggles) and a set of helper macros/functions to build the magit section tree.
- `benedict-chat.el` already calls into `benedict-chat-ui` helpers for sections and badges, but still treats UI mode as optional (checks `derived-mode-p 'benedict-chat-ui-mode` and `benedict-chat-render--ui-active-p` before using UI helpers).

## Replacement Map: Move `benedict-chat-ui.el` into `benedict-chat.el`

Each entry lists the current `benedict-chat-ui.el` definitions, line references, and known call sites that will need to be updated when merged and renamed under `benedict-chat`.

### UI configuration + state
- `benedict-chat-ui.el:22` `defgroup benedict-chat-ui` and `benedict-chat-ui.el:27` `defcustom benedict-chat-ui-fringe-bars-enabled`
  - UI-only customization; currently unused elsewhere. If UI becomes the only mode, decide whether to rename under `benedict-chat` (for public use) or remove.
- `benedict-chat-ui.el:33` `benedict-chat-ui--conversation-section`
- `benedict-chat-ui.el:39` `benedict-chat-ui--current-turn-section`
  - Buffer-local magit-section state. These are reset in `benedict-chat.el:3430` when `benedict-chat-ui-mode` is active. If UI is the only mode, these become core buffer locals and should be initialized unconditionally.

### Badge rendering
- `benedict-chat-ui.el:45` `benedict-chat-ui--svg-supported-p`
- `benedict-chat-ui.el:52` `benedict-chat-ui--badge-face`
- `benedict-chat-ui.el:63` `benedict-chat-ui--badge`
  - Used indirectly in `benedict-chat.el:1080` (`benedict-chat--header-badge` checks `fboundp`) and `benedict-chat-render.el:53` (`benedict-chat-render--badge` checks `fboundp`). When merged, replace the `fboundp` checks with a direct call to the renamed function (likely `benedict-chat--badge`).

### Magit section classes and registration
- `benedict-chat-ui.el:82` `benedict-chat-ui-section` + subclasses for conversation, turn, message/user, message/assistant, message/system, thinking, tool.
- `benedict-chat-ui.el:102` `benedict-chat-ui--section-classes`
- `benedict-chat-ui.el:113` registers section classes via `magit--section-type-alist`.
  - This registration needs to move into `benedict-chat.el` or be performed during mode definition.

### UI predicate + role normalization
- `benedict-chat-ui.el:116` `benedict-chat-ui-active-p`
  - Used by `benedict-chat-render.el:36` (`benedict-chat-render--ui-active-p`) and the `benedict-chat-ui--with-section` macros. When merged, either replace it with a `benedict-chat-mode` predicate or drop the check entirely if UI is always active.
- `benedict-chat-ui.el:120` `benedict-chat-ui--normalize-role`
  - Duplicates `benedict-chat.el:1032` (`benedict-chat--normalize-role`). Consolidate these to a single implementation.
- `benedict-chat-ui.el:128` `benedict-chat-ui--item-section-kind`
  - Used by the section insertion macros to determine section kind from item plists.

### Section helpers and folding sync
- `benedict-chat-ui.el:152` `benedict-chat-ui--section-p`
  - Used in `test/benedict-chat-thinking-test.el:61` and other UI tests. Needs a new name/location once merged.
- `benedict-chat-ui.el:160` `benedict-chat-ui--set-section-folded`
  - Used by `benedict-chat.el:1286` and `benedict-chat.el:1549` (thinking folding) and by `benedict-chat-render.el:547` (tool folding). Must be moved and renamed to the new `benedict-chat` namespace.
- `benedict-chat-ui.el:171` `benedict-chat-ui--section-end-position`
- `benedict-chat-ui.el:179` `benedict-chat-ui--insert-anchor`
  - Used by section tree builders. These remain core helpers after merge.
- `benedict-chat-ui.el:189` `benedict-chat-ui--ensure-conversation-root`
  - Called in `benedict-chat.el:3448` during init when UI mode is active. With a single mode, should be called unconditionally.
- `benedict-chat-ui.el:209` `benedict-chat-ui--begin-turn`
  - Called in `benedict-chat.el:1214` when rendering user messages to start a new turn section.
- `benedict-chat-ui.el:230` `benedict-chat-ui--sync-fold-state`
- `benedict-chat-ui.el:246` advice wiring for `magit-section-show` / `magit-section-hide`
  - Keeps item metadata in sync with magit section visibility; depends on `benedict-chat--update-tool-header` and `benedict-chat--update-thinking-header`.

### Section insertion macros
- `benedict-chat-ui.el:253` `benedict-chat-ui--insert-section`
- `benedict-chat-ui.el:278` `benedict-chat-ui--register-section`
- `benedict-chat-ui.el:288` `benedict-chat-ui--with-section`
- `benedict-chat-ui.el:306` `benedict-chat-ui--with-parent-section`
  - These are used directly by chat rendering in `benedict-chat.el`:
    - `benedict-chat.el:1204` (assistant message item rendering)
    - `benedict-chat.el:1215` (user/system message insertion)
    - `benedict-chat.el:1278` and `benedict-chat.el:1282` (thinking blocks)
    - `benedict-chat.el:1693` and `benedict-chat.el:1697` (tool blocks)
  - These should be moved into `benedict-chat.el` and renamed to `benedict-chat--...` equivalents (or kept with the same names if backward compat is needed).

### UI-specific insertion helpers (currently unused)
- `benedict-chat-ui.el:325` `benedict-chat-ui--propertize-region`
- `benedict-chat-ui.el:329` `benedict-chat-ui--insert-header-line`
- `benedict-chat-ui.el:339` `benedict-chat-ui--insert-body`
  - Not referenced outside `benedict-chat-ui.el` (no `rg` hits). Decide whether to carry over or drop.

### UI mode definition + keymap
- `benedict-chat-ui.el:348` `benedict-chat-ui-mode-map`
  - Parent is `magit-section-mode-map` and includes navigation bindings for tools/thinking. `benedict-chat.el:3363` currently defines a separate `benedict-chat-mode-map`. These should be reconciled when `benedict-chat-mode` becomes the sole mode.
- `benedict-chat-ui.el:367` `benedict-chat-ui-mode` (derived from `magit-section-mode`)
  - This replaces the existing `benedict-chat-mode` definition in `benedict-chat-mode.el:86` when consolidating modes.

## `benedict-chat.el` UI Call Sites
These are the touchpoints already relying on UI mode helpers and will need renaming when merged.

- `benedict-chat.el:23` `(require 'benedict-chat-ui)`
  - Should be removed after merge.
- `benedict-chat.el:61` `benedict-chat-major-mode` defcustom lists `benedict-chat-ui-mode` as an option.
  - With one mode, this can be simplified or removed.
- `benedict-chat.el:1080` `benedict-chat--header-badge` calls `benedict-chat-ui--badge` if available.
  - Replace with direct call to merged badge helper.
- `benedict-chat.el:1204` `benedict-chat--render-message` wraps assistant messages with `benedict-chat-ui--with-section`.
- `benedict-chat.el:1214` calls `benedict-chat-ui--begin-turn` for user messages.
- `benedict-chat.el:1215` wraps user/system messages with `benedict-chat-ui--with-section`.
- `benedict-chat.el:1278` and `benedict-chat.el:1282` wrap thinking blocks with `benedict-chat-ui--with-parent-section` and `benedict-chat-ui--with-section`.
- `benedict-chat.el:1286` and `benedict-chat.el:1549` call `benedict-chat-ui--set-section-folded` for thinking fold sync.
- `benedict-chat.el:1693` and `benedict-chat.el:1697` wrap tool blocks with `benedict-chat-ui--with-parent-section` and `benedict-chat-ui--with-section`.
- `benedict-chat.el:3110` checks `derived-mode-p 'benedict-chat-mode 'benedict-chat-ui-mode` in `benedict-chat--ensure-chat-buffer`.
  - Simplify to `benedict-chat-mode` only.
- `benedict-chat.el:3430` resets `benedict-chat-ui--conversation-section` / `benedict-chat-ui--current-turn-section` when UI mode is active.
- `benedict-chat.el:3447` calls `benedict-chat-ui--ensure-conversation-root` when UI mode is active.
- `benedict-chat.el:3457` checks both modes before initializing.

## Classic-mode-only logic likely to be removed
If the UI mode becomes the only mode, the classic overlay folding path in `benedict-chat.el` becomes dead code.

- `benedict-chat.el:1552` `benedict-chat--prepare-thinking-block`
- `benedict-chat.el:1561` `benedict-chat--apply-thinking-fold`
- `benedict-chat.el:1573` `benedict-chat--insert-thinking-toggle`
- `benedict-chat.el:1595` `benedict-chat--ensure-thinking-toggle`
- `benedict-chat.el:1612` `benedict-chat--refresh-thinking-toggle`
- `benedict-chat.el:1640` `benedict-chat--update-thinking-overlay`

These all assume classic overlay-based folding (`benedict-chat-fold`) and are skipped when the section-based UI is active.

## `benedict-chat-render.el` UI coupling
- `benedict-chat-render.el:18` declares `benedict-chat-ui-active-p` and uses it in `benedict-chat-render--ui-active-p` (`benedict-chat-render.el:36`).
  - When UI becomes the only mode, this predicate should be updated or removed.
- `benedict-chat-render.el:53` `benedict-chat-render--badge` calls `benedict-chat-ui--badge` if available.
- `benedict-chat-render.el:547` uses `benedict-chat-ui--set-section-folded` for tool folding when UI is active.

## Tests that target public `benedict-chat-mode` APIs

### `test/benedict-chat-mode-test.el`
- `test/benedict-chat-mode-test.el:6` `benedict-chat-mode-initialization`
  - Asserts `benedict-chat-mode` derives from `special-mode`, sets `buffer-read-only`, configures `benedict-region-kind` property, and enables markdown font-lock for code blocks.
  - If `benedict-chat-mode` becomes `magit-section-mode` derived, it still inherits from `special-mode`, but the test may need to `require 'benedict-chat` instead of `benedict-chat-mode` if the mode definition moves into `benedict-chat.el`.
- `test/benedict-chat-mode-test.el:17` `benedict-reproduce-jit-lock-error`
  - Initializes `benedict-chat-mode`, then exercises streaming insertions and forces font-lock. This depends on the markdown fontification setup from `benedict-chat-mode.el`.

### `test/benedict-chat-thinking-test.el`
- `test/benedict-chat-thinking-test.el:55` `benedict-chat-thinking-magit-section-syncs-fold-state`
  - Uses `benedict-chat-ui-mode`, `benedict-chat-ui--register-section`, `benedict-chat-ui--section-p`, `benedict-chat-ui--sync-fold-state`. These will need renaming + a shift to `benedict-chat-mode` once UI is the only mode.
- `test/benedict-chat-thinking-test.el:76` `benedict-chat-thinking-ui-nests-under-latest-assistant`
  - Uses `benedict-chat-ui-mode` to validate that thinking/tool sections nest under the latest assistant section.
- `test/benedict-chat-thinking-test.el:98` `benedict-chat-thinking-ui-sync-refreshes-header-arrow`
  - Uses `benedict-chat-ui-mode` and `benedict-chat-ui--sync-fold-state` to ensure header arrows update when section visibility changes.
- `test/benedict-chat-thinking-test.el:162` `benedict-chat-thinking-toggle-under-assistant-ui`
  - Verifies `benedict-chat-toggle-thinking` toggles nested thinking blocks when point is on an assistant section in UI mode.

### `test/benedict-chat-fold-test.el` and `test/benedict-chat-fold-propcheck-test.el`
- Both suites construct `benedict-chat-mode` buffers and exercise overlay-based folding (`benedict-chat-fold-*`) and tool toggles.
- If UI mode is the only mode and classic folding is removed, these tests either need to be deleted or rewritten to target magit-section folding behavior.

### Other tests that instantiate `benedict-chat-mode`
- `test/benedict-chat-integration-test.el` uses `benedict-chat-mode` in multiple cases; these are integration-level tests of streaming, status refresh, and request lifecycle. If mode definition moves, tests can still call `benedict-chat-mode` but should adapt to UI-only semantics if any behavior changes.
- `test/benedict-chat-logic-test.el` uses `benedict-chat-mode` for compose and provider selection flows. These should be unaffected unless mode init changes expected buffer properties.
- `test/benedict-chat-stream-test.el` does not directly use `benedict-chat-mode`, but depends on render/stream helpers.

## Open Questions / Decisions to Clarify
- Should `benedict-chat-ui-fringe-bars-enabled` remain as a defcustom, and under which namespace (`benedict-chat` vs `benedict-chat-ui`)? It is currently unused outside `benedict-chat-ui.el`.
- Should the UI insertion helpers `benedict-chat-ui--propertize-region`, `benedict-chat-ui--insert-header-line`, `benedict-chat-ui--insert-body` be retained or dropped when merging?
- What to do with classic overlay folding: remove all `benedict-chat-fold` tests and code paths, or keep a compatibility layer even if UI is always active?
