# Chat Modularization Implementation Plan

## Overview

Refactor `benedict-chat.el` (~3950 lines) into focused, cohesive modules following the "changes together, stays together" principle. The chat buffer should become a **pure reactive view** over the session, with only UI and compose-buffer state tracked locally.

## Current State Analysis

### File Sizes
| File | Lines | Purpose |
|------|-------|---------|
| `benedict-chat.el` | 3946 | Monolithic chat buffer + UI + compose + context + navigation |
| `benedict-chat-render.el` | 554 | Message/tool/thinking item rendering |
| `benedict-chat-stream.el` | 33 | Stub for streaming (mostly empty) |
| `benedict-session.el` | 743 | Session state, dispatch, tool execution |

### Identified Functional Clusters in benedict-chat.el

| Cluster | Lines | Functions | Cohesion |
|---------|-------|-----------|----------|
| Section Infrastructure | 100-420 | ~15 | High - magit-section plumbing |
| Profile/Config Resolution | 783-940 | ~18 | High - configuration lookups |
| Status Line UI | 1057-1252 | ~17 | High - status presentation |
| Tool Block UI | 1558-1970 | ~26 | High - tool rendering/state |
| Thinking Block UI | 1970-2210 | ~19 | High - thinking domain |
| Streaming Handlers | 2213-2525 | ~14 | Medium - **NON-REACTIVE** |
| Compose Buffer Flow | 2675-2980 | ~23 | High - compose workflow |
| Context Capture Commands | 2985-3147 | ~12 | High - context capture |
| Navigation & Items | 3159-3433 | ~24 | High - navigation |

### Architectural Issues

1. **Non-Reactive Streaming** (`benedict-chat.el:2486-2560`)
   - `benedict-chat--handle-provider-delta` updates buffer directly
   - `benedict-chat--handle-provider-error` bypasses session events
   - Should flow through session observers instead

2. **Vestigial State Tracking** (`benedict-chat.el:448-449`)
   - `benedict-chat--last-dispatch` duplicates `(benedict-session-inflight session)`
   - `benedict-chat--message-history` is a trivial wrapper

3. **Duplicate Item Tracking**
   - `benedict-chat--items` (UI items) vs `benedict-session-messages` (source of truth)
   - These should stay synced via observers only

4. **No Shared Abstraction for Collapsible Blocks**
   - Tool blocks and thinking blocks have identical patterns:
     - Collapsible header with ▶/▼ indicator
     - Status badge
     - Content body region
     - Fold state tracking

## Desired End State

### New Module Structure

```
benedict-chat.el           (~400 lines) - Core mode, observers, entry point
benedict-chat-sections.el  (~350 lines) - Magit-section infrastructure
benedict-chat-profiles.el  (~200 lines) - Profile/provider/tool resolution
benedict-chat-status.el    (~250 lines) - Status line UI
benedict-chat-blocks.el    (~300 lines) - Shared collapsible block abstraction
benedict-chat-tool-ui.el   (~400 lines) - Tool block specifics
benedict-chat-thinking.el  (~300 lines) - Thinking block specifics
benedict-chat-stream.el    (~200 lines) - Streaming state (expanded)
benedict-chat-compose.el   (~350 lines) - Compose mode and workflow
benedict-chat-context.el   (~200 lines) - Context capture commands
benedict-chat-nav.el       (~300 lines) - Navigation commands
benedict-chat-render.el    (~600 lines) - Rendering (existing, minimal changes)
```

### Dependency Graph

```
benedict-chat.el (core)
    ├── requires: benedict-session
    ├── requires: benedict-chat-sections
    ├── requires: benedict-chat-profiles
    ├── requires: benedict-chat-status
    ├── requires: benedict-chat-stream
    ├── requires: benedict-chat-nav
    └── requires: benedict-chat-compose
            └── requires: benedict-chat-context

benedict-chat-render.el
    └── requires: benedict-chat-sections

benedict-chat-tool-ui.el
    ├── requires: benedict-chat-blocks
    └── requires: benedict-chat-render

benedict-chat-thinking.el
    ├── requires: benedict-chat-blocks
    └── requires: benedict-chat-render
```

### Post-Refactor benedict-chat.el Contents

Only these responsibilities remain in the core module:
- Mode definition (`benedict-chat-mode`)
- Buffer initialization (`benedict-chat--init-buffer`)
- Session event subscription and observers
- Entry point (`benedict-chat`)
- Keymap definition
- Buffer-local UI state (not conversation state)

### Verification Criteria

1. All existing tests pass: `nix run .#test`
2. No direct buffer manipulation outside of observers
3. All persistent state flows through session
4. Clear module boundaries with explicit `require` declarations
5. No circular dependencies

## What We're NOT Doing

- **Not changing session.el** - It's already well-factored
- **Not changing the provider interface** - Out of scope
- **Not adding new features** - Pure refactoring
- **Not changing test file organization** - Tests can span modules
- **Not changing public API** - All interactive commands remain available

## Implementation Approach

### Strategy: Bottom-Up Extraction

Extract modules from least-dependent to most-dependent:
1. First extract modules with no internal dependencies (sections, profiles, status)
2. Then extract modules with single dependencies (blocks abstraction)
3. Then extract modules that depend on the abstraction (tool-ui, thinking)
4. Finally extract higher-level modules (compose, context, nav)
5. Clean up core chat.el and remove vestigial code

### Risk Mitigation

- Each phase has its own test verification step
- Phases are small enough to revert if issues arise
- Existing tests provide regression safety net

### Elisp Naming Conventions

**IMPORTANT:** When moving functions to a new module, they must be renamed to match the module name. This is standard Elisp convention.

**Pattern:** `benedict-chat--<name>` → `benedict-<module>--<name>`

**Examples for each module:**

| Original Name | New Module | New Name |
|---------------|------------|----------|
| `benedict-chat--section-p` | `benedict-chat-sections.el` | `benedict-chat-sections--section-p` |
| `benedict-chat--set-section-folded` | `benedict-chat-sections.el` | `benedict-chat-sections--set-folded` |
| `benedict-chat--resolve-provider` | `benedict-chat-profiles.el` | `benedict-chat-profiles--resolve-provider` |
| `benedict-chat--status-phase` | `benedict-chat-status.el` | `benedict-chat-status--phase` |
| `benedict-chat--tool-name-string` | `benedict-chat-tool-ui.el` | `benedict-chat-tool-ui--name-string` |
| `benedict-chat--thinking-item-p` | `benedict-chat-thinking.el` | `benedict-chat-thinking--item-p` |
| `benedict-chat--streaming-reset` | `benedict-chat-stream.el` | `benedict-chat-stream--reset` |
| `benedict-chat-compose-send` | `benedict-chat-compose.el` | `benedict-chat-compose-send` (public, no change) |
| `benedict-chat--slice-from-region` | `benedict-chat-context-capture.el` | `benedict-chat-context-capture--slice-from-region` |
| `benedict-chat-next-tool` | `benedict-chat-nav.el` | `benedict-chat-nav-next-tool` (public, adjust prefix) |

**Rules:**
1. **Private functions** (`--` prefix): Rename to `benedict-<module>--<rest>`
2. **Public/interactive functions**: Rename to `benedict-<module>-<rest>` (single dash)
3. **Update all call sites** in both the new module and any modules that depend on it
4. **Constants and defcustoms** follow the same pattern: `benedict-chat-profiles-default-profile`
5. **Buffer-local variables** that stay in `benedict-chat.el` keep their original names

**Implementation Note:** When extracting a module, use search-and-replace across the codebase:
```bash
# Find all call sites for a function being moved
grep -rn "benedict-chat--section-p" *.el test/*.el
```

Then update each call site to use the new name after the function is moved.

---

## Phase 1: Extract Section Infrastructure

### Overview
Move magit-section EIEIO classes and manipulation functions to a dedicated module. This has no internal dependencies and is used by rendering code.

### Changes Required

#### Create: `benedict-chat-sections.el`

Extract from `benedict-chat.el` lines 100-420:

```elisp
;;; benedict-chat-sections.el --- Magit-section infrastructure for Benedict chat -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'magit-section)
(require 'eieio)

;;; Section Classes

(defclass benedict-chat-section (magit-section)
  ((item :initarg :item :initform nil :accessor benedict-chat-section-item)
   (kind :initarg :kind :initform nil :accessor benedict-chat-section-kind))
  :documentation "Base section for Benedict chat UI.")

(defclass benedict-chat-conversation-section (benedict-chat-section) ()
  :documentation "Top-level conversation container.")
(defclass benedict-chat-turn-section (benedict-chat-section) ()
  :documentation "Turn section grouping user/assistant blocks.")
(defclass benedict-chat-message-user-section (benedict-chat-section) ()
  :documentation "User message section.")
(defclass benedict-chat-message-assistant-section (benedict-chat-section) ()
  :documentation "Assistant message section.")
(defclass benedict-chat-message-system-section (benedict-chat-section) ()
  :documentation "System message section.")
(defclass benedict-chat-thinking-section (benedict-chat-section) ()
  :documentation "Thinking/analysis section.")
(defclass benedict-chat-tool-section (benedict-chat-section) ()
  :documentation "Tool call section.")

(defconst benedict-chat-sections--classes
  '((conversation . benedict-chat-conversation-section)
    (turn . benedict-chat-turn-section)
    (message/user . benedict-chat-message-user-section)
    (message/assistant . benedict-chat-message-assistant-section)
    (message/system . benedict-chat-message-system-section)
    (thinking . benedict-chat-thinking-section)
    (tool . benedict-chat-tool-section))
  "Canonical mapping from chat block kinds to magit-section classes.")

;; ... rest of section functions
```

**Functions to move:**
- `benedict-chat--section-p`
- `benedict-chat--set-section-folded`
- `benedict-chat--section-end-position`
- `benedict-chat--insert-anchor`
- `benedict-chat--ensure-conversation-root`
- `benedict-chat--current-turn`
- `benedict-chat--begin-turn`
- `benedict-chat--sync-fold-state`
- `benedict-chat--sync-fold-state-after-visibility`
- `benedict-chat--register-section`
- `benedict-chat--insert-section` (macro)
- `benedict-chat--with-section` (macro)
- `benedict-chat--with-parent-section` (macro)

**Variables to move:**
- `benedict-chat--section-classes` → rename to `benedict-chat-sections--classes`

#### Update: `benedict-chat.el`

```elisp
;; Add at top
(require 'benedict-chat-sections)

;; Remove lines 100-420
;; Keep buffer-local variables:
;;   benedict-chat--conversation-section
;;   benedict-chat--current-turn-section
```

#### Update: `benedict-chat-render.el`

```elisp
;; Add at top
(require 'benedict-chat-sections)
```

### Success Criteria

#### Automated Verification
- [x] `nix run .#test` passes all tests
- [ ] `emacs --batch -l benedict-chat-sections.el` loads without error
- [ ] `emacs --batch -l benedict-chat.el` loads without error

#### Manual Verification
- [ ] Open chat buffer, verify section folding works
- [ ] Tool blocks collapse/expand correctly
- [ ] Thinking blocks collapse/expand correctly

---

## Phase 2: Extract Profile Resolution

### Overview
Move profile, provider, model, and tool resolution to a dedicated module. These are pure lookup functions with no side effects.

### Changes Required

#### Create: `benedict-chat-profiles.el`

Extract from `benedict-chat.el` lines 783-940:

```elisp
;;; benedict-chat-profiles.el --- Profile and configuration resolution -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'benedict)
(require 'benedict-tools)

;; Defcustoms to move:
;; - benedict-chat-profiles
;; - benedict-chat-default-profile
;; - benedict-chat-project-default-profiles
;; - benedict-chat-base-system-prompt
;; - benedict-chat-capability-tool-map

;; Functions to move:
;; - benedict-chat--project-root
;; - benedict-chat--profile-entry
;; - benedict-chat--profile-label
;; - benedict-chat--profile-provider
;; - benedict-chat--profile-model
;; - benedict-chat--profile-preamble
;; - benedict-chat--profile-tool-allowlist
;; - benedict-chat--profile-tool-denylist
;; - benedict-chat--profile-capabilities
;; - benedict-chat--profile-autonomy
;; - benedict-chat--effective-limit
;; - benedict-chat--profile-verbosity
;; - benedict-chat--default-profile
;; - benedict-chat--effective-profile
;; - benedict-chat--provider-default-model
;; - benedict-chat--resolve-provider
;; - benedict-chat--resolve-model
;; - benedict-chat--system-content
;; - benedict-chat--system-messages
;; - benedict-chat--registered-tool-ids
;; - benedict-chat--normalize-capabilities
;; - benedict-chat--tools-for-capabilities
;; - benedict-chat--effective-tool-ids
;; - benedict-chat--resolve-tools

(provide 'benedict-chat-profiles)
```

#### Update: `benedict-chat.el`

```elisp
(require 'benedict-chat-profiles)
;; Remove lines 783-940
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] Profile resolution tests pass: `benedict-chat-resolves-provider-and-model`

#### Manual Verification
- [ ] `M-x benedict-chat-choose-profile` works
- [ ] `M-x benedict-chat-choose-model` works
- [ ] `M-x benedict-chat-choose-provider` works

---

## Phase 3: Extract Status Line UI

### Overview
Move status line rendering, timer management, and usage formatting to a dedicated module.

### Changes Required

#### Create: `benedict-chat-status.el`

Extract from `benedict-chat.el` lines 1057-1252:

```elisp
;;; benedict-chat-status.el --- Status line UI for Benedict chat -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'benedict-session)

;; Defcustoms to move:
;; - benedict-chat-token-display

;; Constants to move:
;; - benedict-chat--spinner-frames

;; Buffer-local variables stay in chat.el:
;; - benedict-chat--status-spinner-index
;; - benedict-chat--status-timer

;; Functions to move:
;; - benedict-chat--status-reset
;; - benedict-chat--status-phase
;; - benedict-chat--status-request-started-at
;; - benedict-chat--status-request-started-at-float
;; - benedict-chat--status-elapsed
;; - benedict-chat--status-active-p
;; - benedict-chat--status-stop-timer
;; - benedict-chat--status-refresh
;; - benedict-chat--status-tick
;; - benedict-chat--status-start-timer
;; - benedict-chat--status-usage-string
;; - benedict-chat--status-indicator
;; - benedict-chat--status-phase-label
;; - benedict-chat--status-provider-label
;; - benedict-chat--status-agent-indicator
;; - benedict-chat--status-string
;; - benedict-chat--mode-line-status
;; - benedict-chat--header-line-status

(provide 'benedict-chat-status)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] `benedict-chat-session-accumulates-seconds` test passes

#### Manual Verification
- [ ] Status line shows spinner during streaming
- [ ] Token usage displays correctly
- [ ] Elapsed time updates during requests

---

## Phase 4: Create Shared Collapsible Block Abstraction

### Overview
Create a new module with shared rendering infrastructure for collapsible blocks (used by both tool and thinking blocks).

### Changes Required

#### Create: `benedict-chat-blocks.el`

```elisp
;;; benedict-chat-blocks.el --- Collapsible block abstraction -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'benedict-chat-sections)
(require 'benedict-chat-render)

;;; Block Structure
;;
;; A collapsible block has:
;; - Header line with fold indicator (▶/▼), status badge, and label
;; - Content body region (hidden when folded)
;; - Markers: :header-start, :header-end, :content-start, :content-end
;; - State: :folded boolean

(defun benedict-chat-blocks--fold-indicator (folded)
  "Return fold indicator arrow for FOLDED state."
  (if folded "▶" "▼"))

(defun benedict-chat-blocks--render-header (item badge-text badge-face &optional actions)
  "Render collapsible header for ITEM with BADGE-TEXT, BADGE-FACE, and optional ACTIONS."
  ;; Common header rendering logic extracted from tool and thinking
  ...)

(defun benedict-chat-blocks--update-header (item header-fn)
  "Update ITEM header using HEADER-FN to generate new text."
  ;; Common header update logic
  ...)

(defun benedict-chat-blocks--set-folded (item folded)
  "Set ITEM fold state to FOLDED and update visibility."
  ;; Common fold state logic
  ...)

(defun benedict-chat-blocks--toggle (item)
  "Toggle ITEM fold state."
  (benedict-chat-blocks--set-folded item (not (plist-get item :folded))))

(provide 'benedict-chat-blocks)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] New module loads without error

#### Manual Verification
- [ ] (Deferred to Phase 5/6 when tool-ui and thinking use this)

---

## Phase 5: Extract Tool Block UI

### Overview
Move tool block rendering, error formatting, and state management to a dedicated module that uses the shared block abstraction.

### Changes Required

#### Create: `benedict-chat-tool-ui.el`

Extract from `benedict-chat.el` lines 1558-1970:

```elisp
;;; benedict-chat-tool-ui.el --- Tool block UI for Benedict chat -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'benedict-chat-blocks)
(require 'benedict-chat-render)

;; Functions to move:
;; - benedict-chat--tool-name-string
;; - benedict-chat--tool-value-string
;; - benedict-chat--tool-arguments-string
;; - benedict-chat--truncate-string
;; - benedict-chat--tool-error-stringify
;; - benedict-chat--tool-error-backtrace
;; - benedict-chat--tool-error-details
;; - benedict-chat--tool-error-json
;; - benedict-chat--tool-error-summary
;; - benedict-chat--tool-error-ui-body
;; - benedict-chat--tool-status-label
;; - benedict-chat--tool-default-header
;; - benedict-chat--normalize-tool-state
;; - benedict-chat--tool-ui--stringify-body
;; - benedict-chat--validate-action
;; - benedict-chat--normalize-actions
;; - benedict-chat--normalize-tool-ui
;; - benedict-chat--tool-ui-body-string
;; - benedict-chat--refresh-tool-block
;; - benedict-chat--tool-call-content
;; - benedict-chat--tool-result-content
;; - benedict-chat--record-tool-block
;; - benedict-chat--update-tool-block
;; - benedict-chat--normalize-tool-id
;; - benedict-chat--tool-call-metadata
;; - benedict-chat--normalize-tool-output
;; - benedict-chat--tool-result-history-entry
;; - benedict-chat--find-tool-item

;; Refactor to use benedict-chat-blocks for common fold/visibility

(provide 'benedict-chat-tool-ui)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] Tool-related tests pass

#### Manual Verification
- [ ] Tool blocks render correctly
- [ ] Tool blocks fold/unfold
- [ ] Tool error states display correctly
- [ ] Tool action buttons work

---

## Phase 6: Extract Thinking Block UI

### Overview
Move thinking block rendering and delta handling to a dedicated module that uses the shared block abstraction.

### Changes Required

#### Create: `benedict-chat-thinking.el`

Extract from `benedict-chat.el` lines 1970-2210:

```elisp
;;; benedict-chat-thinking.el --- Thinking block UI for Benedict chat -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'benedict-chat-blocks)
(require 'benedict-chat-render)

;; Functions to move:
;; - benedict-chat--normalize-seq
;; - benedict-chat--alist-to-plist
;; - benedict-chat--current-request-id
;; - benedict-chat--next-thinking-temp-id
;; - benedict-chat--thinking-stream-id
;; - benedict-chat--register-thinking-item
;; - benedict-chat--lookup-thinking-item
;; - benedict-chat--thinking-label-from-type
;; - benedict-chat--thinking-detail-text
;; - benedict-chat--normalize-thinking-entry
;; - benedict-chat--normalize-thinking-payload
;; - benedict-chat--ensure-thinking-item
;; - benedict-chat--write-thinking-content
;; - benedict-chat--append-thinking-content
;; - benedict-chat--replace-thinking-content
;; - benedict-chat--display-thinking-detail
;; - benedict-chat--collect-delta-reasoning-details
;; - benedict-chat--delta-choice-text
;; - benedict-chat--delta-text-from-delta
;; - benedict-chat--delta-content-entry-text
;; - benedict-chat--collect-delta-message-content

;; Buffer-local variable stays in chat.el:
;; - benedict-chat--thinking-items
;; - benedict-chat--thinking-temp-counter

;; Refactor to use benedict-chat-blocks for common fold/visibility

(provide 'benedict-chat-thinking)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] `benedict-chat-thinking-test.el` tests pass

#### Manual Verification
- [ ] Thinking blocks render during streaming
- [ ] Thinking blocks fold/unfold
- [ ] Thinking labels display correctly

---

## Phase 7: Expand Streaming Module

### Overview
Expand `benedict-chat-stream.el` (currently 33 lines) with streaming state management. **Remove non-reactive direct buffer manipulation** - all updates should flow through session observers.

### Changes Required

#### Update: `benedict-chat-stream.el`

Extract from `benedict-chat.el` lines 2213-2370:

```elisp
;;; benedict-chat-stream.el --- Streaming support for Benedict chat -*- lexical-binding: t; -*-

(require 'benedict-chat-render)
(require 'benedict-chat-thinking)

;; Existing content plus:

;; Functions to move:
;; - benedict-chat--streaming-reset
;; - benedict-chat--streaming-merge-metadata
;; - benedict-chat--streaming-apply-metadata
;; - benedict-chat--streaming-ensure-message
;; - benedict-chat--streaming-append-text
;; - benedict-chat--complete-streaming-message
;; - benedict-chat--fail-streaming-message
;; - benedict-chat--format-metadata-line
;; - benedict-chat--clear-block-buttons
;; - benedict-chat--insert-action-button
;; - benedict-chat--block-target-string
;; - benedict-chat-copy-block
;; - benedict-chat-apply-block

;; Buffer-local variable stays in chat.el:
;; - benedict-chat--streaming-message

(provide 'benedict-chat-stream)
```

#### Remove from `benedict-chat.el`:
- `benedict-chat--handle-provider-delta` - Replace with pure observer
- `benedict-chat--handle-provider-error` - Replace with pure observer

#### Update Observers to be Purely Reactive

The `benedict-chat--observe-draft-updated` should call into streaming module functions rather than the removed direct handlers.

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] `benedict-chat-stream-test.el` tests pass

#### Manual Verification
- [ ] Streaming responses render incrementally
- [ ] Errors display correctly
- [ ] Code block copy/apply buttons work

---

## Phase 8: Extract Compose Buffer Flow

### Overview
Move compose mode, handle management, and send/cancel workflow to a dedicated module.

### Changes Required

#### Create: `benedict-chat-compose.el`

Extract from `benedict-chat.el` lines 2675-2980:

```elisp
;;; benedict-chat-compose.el --- Compose buffer for Benedict chat -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'benedict-context)

;; Defcustoms to move:
;; - benedict-chat-compose-buffer-name-format
;; - benedict-chat-context-retain-after-send

;; Constants to move:
;; - benedict-chat--compose-separator
;; - benedict-chat--handle-regexp
;; - benedict-chat--anchor-guidance

;; Keymap to move:
;; - benedict-chat-compose-mode-map

;; Mode to move:
;; - benedict-chat-compose-mode

;; Functions to move:
;; - benedict-chat--compose-buffer-name
;; - benedict-chat--compose-header-text
;; - benedict-chat--sanitize-handle
;; - benedict-chat--valid-handle-p
;; - benedict-chat--preferred-handle
;; - benedict-chat--context-handles
;; - benedict-chat--prepare-context-slice
;; - benedict-chat--upsert-context-slice
;; - benedict-chat--insert-handle-link
;; - benedict-chat--extract-handle-links
;; - benedict-chat--warn-unknown-handles
;; - benedict-chat-compose--render-header
;; - benedict-chat--refresh-compose-header
;; - benedict-chat--ensure-compose-buffer
;; - benedict-chat-compose-open
;; - benedict-chat-compose--body-text
;; - benedict-chat--assemble-message-text
;; - benedict-chat--clear-compose-state
;; - benedict-chat-compose-send
;; - benedict-chat-compose-cancel
;; - benedict-chat--deliver-context-slices

;; Buffer-local variables stay in chat.el:
;; - benedict-chat--context-slices
;; - benedict-chat--compose-buffer
;; - benedict-chat--compose-model-override

(provide 'benedict-chat-compose)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] `benedict-chat-compose-sends-context` test passes

#### Manual Verification
- [ ] `M-x benedict-chat-compose-open` works
- [ ] Context slices appear in compose header
- [ ] Send from compose works
- [ ] Cancel discards context

---

## Phase 9: Extract Context Capture Commands

### Overview
Move context capture interactive commands to a dedicated module.

### Changes Required

#### Create: `benedict-chat-context-capture.el`

Extract from `benedict-chat.el` lines 2985-3147:

```elisp
;;; benedict-chat-context-capture.el --- Context capture commands -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'benedict-context)

;; Functions to move:
;; - benedict-chat--slice-with-handle-default
;; - benedict-chat--buffer-label
;; - benedict-chat--slice-from-region
;; - benedict-chat--current-defun-name
;; - benedict-chat--slice-from-defun
;; - benedict-chat--slice-from-buffer
;; - benedict-chat--slice-from-project
;; - benedict-chat--git-run
;; - benedict-chat--slice-from-git

;; Interactive commands to move:
;; - benedict-chat-ask-region
;; - benedict-chat-ask-defun
;; - benedict-chat-ask-buffer
;; - benedict-chat-ask-project
;; - benedict-chat-ask-git-context

(provide 'benedict-chat-context-capture)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests

#### Manual Verification
- [ ] `M-x benedict-chat-ask-region` works
- [ ] `M-x benedict-chat-ask-defun` works
- [ ] `M-x benedict-chat-ask-buffer` works
- [ ] `M-x benedict-chat-ask-git-context` works

---

## Phase 10: Extract Navigation Commands

### Overview
Move navigation commands and item predicates to a dedicated module.

### Changes Required

#### Create: `benedict-chat-nav.el`

Extract from `benedict-chat.el` lines 3159-3433:

```elisp
;;; benedict-chat-nav.el --- Navigation commands for Benedict chat -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'magit-section)

;; Functions to move:
;; - benedict-chat--ensure-chat-buffer (shared, may stay in chat.el)
;; - benedict-chat--item-at-point
;; - benedict-chat--item-index
;; - benedict-chat--seek-item
;; - benedict-chat--goto-item
;; - benedict-chat--navigate

;; Predicates to move:
;; - benedict-chat--tool-item-p
;; - benedict-chat--thinking-item-p
;; - benedict-chat--assistant-message-item-p
;; - benedict-chat--last-assistant-item
;; - benedict-chat--current-assistant-section
;; - benedict-chat--assistant-item-for-tool
;; - benedict-chat--last-assistant-with-tools-item
;; - benedict-chat--tool-failure-item-p
;; - benedict-chat--error-item-p
;; - benedict-chat--find-last-assistant

;; Navigation commands to move:
;; - benedict-chat-jump-to-latest
;; - benedict-chat-jump-to-last-assistant
;; - benedict-chat-jump-to-last-assistant-with-tools
;; - benedict-chat-next-tool
;; - benedict-chat-previous-tool
;; - benedict-chat-next-tool-failure
;; - benedict-chat-previous-tool-failure
;; - benedict-chat-next-error
;; - benedict-chat-previous-error
;; - benedict-chat-next-thinking
;; - benedict-chat-previous-thinking
;; - benedict-chat-toggle-thinking
;; - benedict-chat-copy-last-response
;; - benedict-chat-retry-last

(provide 'benedict-chat-nav)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests

#### Manual Verification
- [ ] `] t` / `[ t` navigate to tool blocks
- [ ] `] e` / `[ e` navigate to errors
- [ ] `g l` jumps to latest
- [ ] `w` copies last response

---

## Phase 11: Clean Up Core & Remove Vestigial Code

### Overview
Final cleanup of `benedict-chat.el`: remove vestigial code, ensure pure reactive architecture.

### Changes Required

#### Remove Vestigial Code from `benedict-chat.el`:

1. **Remove `benedict-chat--last-dispatch`** (line 448)
   - Replace usages with `(benedict-session-inflight session)`
   - Affects: `benedict-chat-retry-last`, observers

2. **Remove `benedict-chat--message-history`** (line 1551)
   - Direct calls to `(benedict-session-messages-chronological session)` instead

3. **Remove duplicate state in observers**
   - `benedict-chat--request-seq` if duplicating session's request tracking

4. **Audit remaining functions**
   - Ensure all remaining code is:
     - Mode definition
     - Buffer initialization
     - Session observer dispatching
     - Entry point

#### Expected Final `benedict-chat.el` Structure:

```elisp
;;; benedict-chat.el --- Chat buffers and commands -*- lexical-binding: t; -*-

(require 'benedict-chat-sections)
(require 'benedict-chat-profiles)
(require 'benedict-chat-status)
(require 'benedict-chat-stream)
(require 'benedict-chat-tool-ui)
(require 'benedict-chat-thinking)
(require 'benedict-chat-compose)
(require 'benedict-chat-context-capture)
(require 'benedict-chat-nav)
(require 'benedict-session)

;;; Mode Definition

(define-derived-mode benedict-chat-mode magit-section-mode "Benedict-Chat"
  ...)

;;; Keymap

(defvar benedict-chat-mode-map ...)

;;; Buffer-Local State (UI only)

(defvar-local benedict-chat--buffer nil)
(defvar-local benedict-chat--items nil)
(defvar-local benedict-chat--item-counter 0)
(defvar-local benedict-chat--session nil)
(defvar-local benedict-chat--session-subscription nil)
;; ... other UI state

;;; Session Event Subscription

(defun benedict-chat--subscribe-to-session (session) ...)
(defun benedict-chat--unsubscribe-from-session () ...)
(defun benedict-chat--handle-session-event (event-type payload) ...)

;;; Observers (Pure Reactive)

(defun benedict-chat--observe-state-changed (old new) ...)
(defun benedict-chat--observe-message-added (message) ...)
(defun benedict-chat--observe-draft-started () ...)
(defun benedict-chat--observe-draft-updated (payload) ...)
(defun benedict-chat--observe-draft-finalized (payload) ...)
(defun benedict-chat--observe-request-completed (payload) ...)
(defun benedict-chat--observe-tool-started (payload) ...)
(defun benedict-chat--observe-tool-completed (payload) ...)
(defun benedict-chat--observe-session-destroyed () ...)

;;; Buffer Initialization

(defun benedict-chat--init-buffer () ...)
(defun benedict-chat--detach-session () ...)

;;; Entry Point

;;;###autoload
(defun benedict-chat (&optional prefix) ...)

(provide 'benedict-chat)
```

### Success Criteria

#### Automated Verification
- [ ] `nix run .#test` passes all tests
- [ ] `wc -l benedict-chat.el` shows ~400 lines (down from 3946)
- [ ] No direct buffer manipulation outside observers
- [ ] No references to removed variables

#### Manual Verification
- [ ] Full end-to-end chat workflow works
- [ ] All keybindings functional
- [ ] Profile/model selection works
- [ ] Compose flow works
- [ ] Tool execution displays correctly
- [ ] Thinking blocks work
- [ ] Navigation works

---

## Testing Strategy

### Unit Tests (Per Phase)
Each new module should maintain test coverage. Existing tests in:
- `test/benedict-chat-logic-test.el` (345 lines)
- `test/benedict-chat-render-test.el` (170 lines)
- `test/benedict-chat-thinking-test.el` (167 lines)
- `test/benedict-chat-stream-test.el` (48 lines)
- `test/benedict-chat-session-test.el` (415 lines)
- `test/benedict-chat-integration-test.el` (454 lines)

### Integration Tests
The existing integration tests exercise cross-module workflows and will catch regressions during refactoring.

### Regression Command
After each phase:
```bash
nix run .#test
```

### Manual Smoke Test Checklist
After complete refactor:
1. [ ] `M-x benedict-chat` opens chat buffer
2. [ ] `C-c C-s` prompts and sends message
3. [ ] Response streams incrementally
4. [ ] Tool calls display and fold
5. [ ] Thinking blocks display and fold
6. [ ] `M-x benedict-chat-ask-region` captures region
7. [ ] Compose buffer works end-to-end
8. [ ] `C-c C-k` cancels request
9. [ ] `g r` retries last request
10. [ ] `w` copies last response
11. [ ] Navigation keybindings work

---

## References

- Source analysis performed on `benedict-chat.el` (3946 lines)
- Related modules: `benedict-chat-render.el`, `benedict-chat-stream.el`, `benedict-session.el`
- Test files: `test/benedict-chat-*-test.el` (1638 lines total)
- Session module documentation: `benedict-session.el:1-30`
