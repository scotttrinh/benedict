---
date: 2026-01-07T10:30:00-06:00
researcher: Claude Opus 4.5
git_commit: ee96b5e2e7f6e193c5d411417d6822f921477505
branch: main
repository: benedict
topic: "Complete Session-as-Source-of-Truth Refactoring"
tags: [research, codebase, benedict-session, architecture, refactoring, state-management]
status: complete
last_updated: 2026-01-07
---

# Research: Complete Session-as-Source-of-Truth Refactoring

**Date**: 2026-01-07
**Researcher**: Claude Opus 4.5
**Git Commit**: ee96b5e2e7f6e193c5d411417d6822f921477505
**Branch**: main

## Research Question

How do we complete the session-as-source-of-truth refactoring that was partially implemented in effort 00047, making the chat buffer a pure reactive view on session state?

## Summary

Effort 00047 (`benedict-session`) implemented the core session infrastructure but stopped short of fully transitioning the chat buffer to be a pure view layer. The critical deferral was the event subscription pattern (line 877 of the plan: "Add `benedict-chat--handle-session-event` for UI updates driven by session events (deferred - direct calls work for now)").

**Current State**: The buffer maintains parallel state with the session, with both "headless" handlers (updating session) and "buffer" handlers (updating buffer-local state) running on provider callbacks.

**Target State**: Session owns all non-ephemeral state. Buffer subscribes to session events and purely renders what the session tells it.

---

## Detailed Findings

### 1. Buffer-Local State Audit

The file `benedict-chat.el` contains **31 custom buffer-local variables** (plus standard Emacs settings). Here is a classification by ownership:

#### State That DUPLICATES Session (Must Be Eliminated)

| Variable | Line | Current Purpose | Session Equivalent |
|----------|------|-----------------|-------------------|
| `benedict-chat--messages` | 465 | Message history (newest first) | `(benedict-session-messages session)` |
| `benedict-chat--streaming-message` | 487 | In-progress streaming plist | `(benedict-session-draft session)` |
| `benedict-chat--telemetry` | 711 | Provider/model/usage/phase tracking | **Missing from session** |
| `benedict-chat--pending-request` | 472 | Provider request handle | `(plist-get (benedict-session-inflight session) :request)` |
| `benedict-chat--active-request-id` | 490 | Current request identifier | `(plist-get (benedict-session-inflight session) :request-id)` |
| `benedict-chat-profile` | 739 | Active profile symbol | `(benedict-session-profile session)` |
| `benedict-chat--provider-override` | 726 | Provider override | `(benedict-session-provider session)` |
| `benedict-chat--loop-turn-count` | 733 | Autonomous loop turn counter | `(plist-get (benedict-session-inflight session) :loop-state)` |
| `benedict-chat--loop-start-time` | 730 | Loop start timestamp | `(plist-get (benedict-session-inflight session) :loop-state)` |

#### State That Is Pure UI (Can Stay in Buffer)

| Variable | Line | Purpose | Notes |
|----------|------|---------|-------|
| `benedict-chat--items` | 478 | Rendered chat items with markers | UI rendering state |
| `benedict-chat--thinking-items` | 484 | Hash table for thinking block lookup | Rebuilt on attach |
| `benedict-chat--conversation-section` | 136 | Root magit-section | UI structure |
| `benedict-chat--current-turn-section` | 142 | Current turn section | UI structure |
| `benedict-chat--item-counter` | 481 | Item ID generator | UI-only counter |
| `benedict-chat--has-rendered-block` | 1602 | Gap insertion flag | UI rendering |
| `benedict-chat--status-timer` | 714 | Spinner/elapsed timer | UI animation |
| `benedict-chat--compose-buffer` | 720 | Associated compose buffer | Per-buffer UI |
| `benedict-chat--context-slices` | 717 | Staged context for next message | Ephemeral composition |

#### State That Needs Analysis

| Variable | Line | Current Purpose | Recommendation |
|----------|------|-----------------|----------------|
| `benedict-chat--last-dispatch` | 475 | Last request for retry | Move to `session.last-request` |
| `benedict-chat--request-seq` | 493 | Request sequence counter | Session-scoped |
| `benedict-chat--thinking-temp-counter` | 496 | Per-request thinking ID gen | Request-scoped |
| `benedict-chat--loop-canceled` | 736 | Loop cancellation flag | Handled via session state |
| `benedict-chat--flywire-session` | 742 | Flywire session reference | Already in session struct |

---

### 2. Session Struct Analysis

The `benedict-session` struct (defined at `benedict-session.el:13-19`) has 18 fields:

```elisp
(cl-defstruct (benedict-session (:constructor benedict-session--create))
  id created-at updated-at title
  messages (message-seq 0)
  (state 'idle) draft pending-question inflight last-error last-request
  root provider model profile meta
  flywire-session attached-frontends)
```

#### What the Session Has

- **Identity**: `id`, `created-at`, `updated-at`, `title`
- **Conversation**: `messages`, `message-seq`
- **Runtime**: `state`, `draft`, `pending-question`, `inflight`, `last-error`, `last-request`
- **Configuration**: `root`, `provider`, `model`, `profile`, `meta`
- **Resources**: `flywire-session`, `attached-frontends`

#### What the Session is MISSING (Currently in Buffer Telemetry)

| Missing Field | Purpose | Current Location |
|---------------|---------|------------------|
| `request-started-at` | Timestamp when current request began | `(plist-get telemetry :started-at)` |
| `request-metadata` | Provider/model/usage for current request | `(plist-get telemetry :usage)` |
| `accumulated-usage` | Token counts across all requests | `(plist-get telemetry :session-usage)` |
| `accumulated-seconds` | Total elapsed time across requests | `(plist-get telemetry :session-seconds)` |

These should either be added to the session struct or stored in `inflight` and accumulated on finalization.

---

### 3. Handler Architecture Analysis

The codebase has a **dual handler architecture**:

#### Headless Handlers (Update Session Only) - Lines 2927-2976

```elisp
(defun benedict-chat--handle-provider-delta-headless (session data)
  ;; Appends to session draft, never touches buffer
  (benedict-session-append-draft session text))

(defun benedict-chat--handle-provider-success-headless (session result)
  ;; Clears request, finalizes draft, updates session state
  (benedict-session-clear-request session)
  (benedict-session-finalize-draft session metadata))

(defun benedict-chat--handle-provider-error-headless (session payload)
  ;; Sets session error state
  (benedict-session-set-state session 'error))
```

#### Buffer Handlers (Update Buffer-Local State) - Lines 2762-2921

```elisp
(defun benedict-chat--handle-provider-delta (buffer payload)
  ;; Updates benedict-chat--streaming-message
  ;; Updates benedict-stream-state
  ;; Comment says: "Session state is updated by headless handler, not here")

(defun benedict-chat--handle-provider-success (buffer result)
  ;; Clears benedict-chat--pending-request
  ;; Updates streaming message record
  ;; Handles tool calls and loop continuation)

(defun benedict-chat--handle-provider-error (buffer payload)
  ;; Clears benedict-chat--pending-request
  ;; Records error message in buffer)
```

#### Callback Wiring (Lines 2978-3038)

In `benedict-chat--start-dispatch`, both handlers are called:

```elisp
:on-delta (lambda (&rest payload)
            ;; Update session state even if buffer is dead
            (benedict-chat--handle-provider-delta-headless session data)
            ;; Update buffer UI only if alive
            (when (buffer-live-p buffer)
              (benedict-chat--handle-provider-delta buffer data)))
```

**The Problem**: Buffer handlers directly mutate buffer-local state (`benedict-chat--streaming-message`, `benedict-chat--telemetry`, etc.) instead of reacting to session events.

---

### 4. The Deferred Event Subscription

The original plan (effort 00047, line 877) explicitly deferred this work:

> "Add `benedict-chat--handle-session-event` for UI updates driven by session events (deferred - direct calls work for now)"

#### What Was Supposed to Be Implemented

```elisp
(defun benedict-chat--handle-session-event (buffer event-type payload)
  "Dispatch session EVENT-TYPE to appropriate buffer updater."
  (with-current-buffer buffer
    (pcase event-type
      ('message-added (benedict-chat--render-new-message ...))
      ('draft-updated (benedict-chat--refresh-streaming-content ...))
      ('draft-finalized (benedict-chat--finalize-streaming-ui ...))
      ('state-changed (benedict-chat--refresh-status ...))
      ('telemetry-updated (benedict-chat--refresh-header ...)))))
```

#### Current Event System (Session Side)

The session already emits events via `benedict-session--emit` (line 97-102):

| Event Type | Emitted When | Payload |
|------------|--------------|---------|
| `state-changed` | State transition | `:old`, `:new` |
| `message-added` | New message | `:message` |
| `message-updated` | Message modified | `:id`, `:updates` |
| `draft-started` | Streaming begins | (none) |
| `draft-updated` | Delta received | `:delta` or `:tool-call` |
| `draft-finalized` | Streaming complete | (none) or `:discarded t` |
| `destroyed` | Session destroyed | (none) |

**The Gap**: No code subscribes to these events. The buffer handlers bypass the event system entirely.

---

### 5. Telemetry System Analysis

The buffer-local `benedict-chat--telemetry` plist contains:

```elisp
(:phase 'idle|'sending|'streaming    ; Current request phase
 :provider "label"                    ; Provider display name
 :model "model-id"                    ; Model identifier
 :started-at float                    ; Request start timestamp
 :last-phase 'complete|'error|...    ; Terminal phase of last request
 :last-usage plist                    ; Token counts from last request
 :last-elapsed float                  ; Elapsed seconds for last request
 :session-usage plist                 ; Accumulated token counts
 :session-seconds float               ; Total elapsed across session
 :spinner-index int                   ; Current spinner frame
 :usage plist)                        ; In-flight usage data
```

#### Telemetry Functions (All Buffer-Local)

| Function | Line | Purpose |
|----------|------|---------|
| `benedict-chat--telemetry-reset` | 1161 | Initialize on buffer creation |
| `benedict-chat--telemetry-update` | 1178 | Generic plist merge |
| `benedict-chat--telemetry-apply-metadata` | 1186 | Extract provider/model/usage |
| `benedict-chat--telemetry-begin` | 1238 | Mark request as sending |
| `benedict-chat--telemetry-streaming` | 1253 | Mark as streaming |
| `benedict-chat--telemetry-finish` | 1260 | Mark as idle, accumulate usage |
| `benedict-chat--telemetry-accumulate-session` | 1231 | Merge usage into session totals |

**The Problem**: All telemetry lives in the buffer. If the buffer dies, telemetry is lost. Session usage accumulation should survive buffer kill.

---

### 6. Impact Analysis: Functions to Change

#### Category 1: Functions to DELETE (Replace with Event Subscriptions)

| Function | Line | Reason |
|----------|------|--------|
| `benedict-chat--telemetry-reset` | 1161 | Session should own telemetry |
| `benedict-chat--telemetry-update` | 1178 | Session should own telemetry |
| `benedict-chat--telemetry-begin` | 1238 | React to session state-changed |
| `benedict-chat--telemetry-streaming` | 1253 | React to session state-changed |
| `benedict-chat--telemetry-finish` | 1260 | React to session state-changed |
| `benedict-chat--ensure-streaming-message` | 2735 | React to draft-started event |
| `benedict-chat--streaming-reset` | 2464 | React to draft-finalized event |
| `benedict-chat--history-store` | 1667 | Session owns messages |

#### Category 2: Functions to MODIFY (Read from Session)

| Function | Line | Change Needed |
|----------|------|---------------|
| `benedict-chat--build-request` | 2699 | Already reads from session (verify) |
| `benedict-chat--record-message` | 1673 | Write to session only, not buffer |
| `benedict-chat--message-history` | 1749 | Read from session |
| `benedict-chat--handle-provider-success` | 2803 | UI-only, no state mutation |
| `benedict-chat--handle-provider-error` | 2900 | UI-only, no state mutation |
| `benedict-chat--check-repetition-guard` | 815 | Read session messages |
| `benedict-chat--loop-step` | 825 | Read session messages |
| `benedict-chat--invoke-tool-call` | 2153 | Verify session usage |
| `benedict-chat--find-last-assistant` | 3557 | Read session messages |
| `benedict-chat-retry-last` | 3830 | Use session.last-request |
| `benedict-chat--send-text` | 3045 | Order: session first, then render |

#### Category 3: Functions to CREATE (Event Observers)

| Function | Purpose |
|----------|---------|
| `benedict-chat--subscribe-to-session` | Register event handlers on attach |
| `benedict-chat--unsubscribe-from-session` | Unregister on detach |
| `benedict-chat--handle-session-event` | Main event dispatcher |
| `benedict-chat--observe-state-changed` | Update status/telemetry display |
| `benedict-chat--observe-message-added` | Render new message |
| `benedict-chat--observe-draft-started` | Initialize streaming UI |
| `benedict-chat--observe-draft-updated` | Append streaming content |
| `benedict-chat--observe-draft-finalized` | Finalize streaming message |
| `benedict-chat--observe-error` | Display error state |
| `benedict-chat--sync-buffer-from-session` | Full re-render on attach |

#### Category 4: Functions That Are PURE UI (No Changes)

There are approximately **116 functions** that are pure rendering/navigation and need no changes. Examples:
- Badge rendering (`benedict-chat--badge`, `benedict-chat--badge-face`)
- Section management (`benedict-chat--insert-section`, `benedict-chat--register-section`)
- Navigation (`benedict-chat-jump-to-*`, `benedict-chat-next-*`, `benedict-chat-previous-*`)
- Tool UI (`benedict-chat--tool-*-string`, `benedict-chat--refresh-tool-block`)
- Status display (`benedict-chat--status-string`, `benedict-chat--status-indicator`)

---

### 7. Test Coverage Assessment

#### Existing Test Safety Net

| Test File | Tests | Coverage Area |
|-----------|-------|---------------|
| `benedict-session-test.el` | 33 | Session CRUD, messages, draft, events |
| `benedict-chat-session-test.el` | 16 | Buffer-session binding, streaming, headless |
| `benedict-chat-integration-test.el` | 12 | End-to-end flows, marker stability |
| `benedict-chat-logic-test.el` | 12 | Telemetry, provider resolution |
| `benedict-chat-render-test.el` | 8 | Marker management, tool rendering |
| `benedict-chat-thinking-test.el` | 8 | Thinking blocks, folding |
| `benedict-agent-loop-test.el` | 11 | Loop safeguards, autonomy |
| `benedict-chat-stream-test.el` | 2 | Stream insertion |

**Total: ~100 tests** provide strong safety net for refactoring.

#### Key Tests to Verify After Refactoring

1. **Headless streaming**: `benedict-chat-session-test-headless-streaming` - Session continues when buffer killed
2. **Reattach mid-stream**: `benedict-chat-session-test-reattach-midstream` - Content visible on reattach
3. **Tool completion headless**: `benedict-chat-session-test-headless-tool-completion` - Tools execute without buffer
4. **Session routing**: `benedict-chat-session-test-routing-*` - Session selection logic

#### Coverage Gaps to Address

1. **Multi-buffer attachment**: Multiple buffers viewing same session
2. **Telemetry persistence**: Session usage survives buffer kill
3. **Event ordering**: Events delivered in correct order
4. **State synchronization**: Buffer accurately reflects session state on attach

---

### 8. Risk Analysis

#### High Risk Areas

1. **Streaming Flow**
   - Risk: Breaking streaming display during refactor
   - Mitigation: Existing integration tests cover marker stability
   - Test: `benedict-chat-integration-streaming-preserves-body-across-header-refresh`

2. **Tool Execution**
   - Risk: Tool calls failing when buffer killed
   - Mitigation: Headless handlers already update session
   - Test: `benedict-chat-session-test-headless-tool-completion`

3. **Message History**
   - Risk: Messages lost or duplicated
   - Mitigation: Session already owns messages (dual-write exists)
   - Action: Remove buffer-local `benedict-chat--messages` after verifying session is authoritative

#### Medium Risk Areas

1. **Telemetry Accuracy**
   - Risk: Token counts/timing inaccurate
   - Action: Add session fields for accumulated usage before removing buffer telemetry

2. **Event Performance**
   - Risk: High-frequency `draft-updated` events causing lag
   - Mitigation: Buffer handlers should be efficient (append-only)

3. **State Machine Consistency**
   - Risk: Buffer and session state out of sync
   - Action: Buffer always reads from session, never caches

#### Low Risk Areas

1. **Navigation commands** - Pure UI, read from `benedict-chat--items`
2. **Rendering functions** - Pure UI, no state dependencies
3. **Profile/provider selection** - Already works via session

---

## Architectural Recommendations

### Target Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                     Session Registry                            │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ benedict-session                                          │  │
│  │  - messages (authoritative)                               │  │
│  │  - draft (streaming accumulator)                          │  │
│  │  - state (idle|streaming|error|cancelled)                 │  │
│  │  - inflight (request + timing + loop state)               │  │
│  │  - telemetry (usage, elapsed) ← NEW                       │  │
│  │  - attached-frontends                                     │  │
│  └──────────────────────────────────────────────────────────┘  │
│                          │                                      │
│                          │ emits events                         │
│                          ▼                                      │
│            benedict-session-event-hook                          │
└────────────────────────────────────────────────────────────────┘
                           │
          ┌────────────────┴────────────────┐
          │ subscribes                      │ subscribes
          ▼                                 ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│   Chat Buffer 1         │     │   Chat Buffer 2         │
│   (View Layer)          │     │   (Same Session)        │
│                         │     │                         │
│   - items (UI state)    │     │   - items (UI state)    │
│   - sections (magit)    │     │   - sections (magit)    │
│   - markers             │     │   - markers             │
│   - spinner-index       │     │   - spinner-index       │
│                         │     │                         │
│   NO: messages          │     │   NO: messages          │
│   NO: streaming-message │     │   NO: streaming-message │
│   NO: telemetry         │     │   NO: telemetry         │
└─────────────────────────┘     └─────────────────────────┘
```

### Event Flow

```
Provider Callback
       │
       ▼
Headless Handler
       │
       ├─► Update session.draft
       ├─► Update session.state
       ├─► Update session.inflight.usage
       │
       ▼
Session emits event
       │
       ├─► 'draft-updated with :delta
       ├─► 'state-changed with :old :new
       │
       ▼
Buffer event handler (if attached)
       │
       ├─► Append text to stream display
       ├─► Update status line
       ├─► Refresh message header
       │
       ▼
UI updated
```

### Session Struct Additions

```elisp
;; Add to inflight plist structure:
inflight
  :request        ; provider handle
  :request-id     ; correlation ID
  :started-at     ; timestamp
  :loop-state     ; turn count, etc.
  :usage          ; current request usage (in-flight) ← NEW

;; Add to session struct:
(cl-defstruct (benedict-session ...)
  ...
  accumulated-usage    ; plist: :prompt :completion :total :cost ← NEW
  accumulated-seconds  ; float: total elapsed time ← NEW
  ...)
```

---

## Historical Context

### Effort 00047 Accomplishments

1. Created `benedict-session.el` with full struct and registry
2. Added event emission infrastructure (`benedict-session--emit`)
3. Implemented headless handlers for session state updates
4. Established dual-write pattern (buffer + session)
5. Added session routing for buffer creation
6. Implemented attach/detach semantics

### Effort 00047 Deferrals

1. **Event subscription** - "deferred - direct calls work for now"
2. **Telemetry migration** - Still buffer-local
3. **Buffer state elimination** - Duplicate state remains
4. **Multi-buffer testing** - Single buffer per session assumed

### Why This Matters

The current architecture:
- Loses telemetry when buffer dies
- Requires maintaining parallel state in sync
- Cannot support multiple views of same session
- Has complex dual-handler wiring

The target architecture:
- Preserves all state across buffer lifecycle
- Single source of truth (session)
- Natural multi-frontend support
- Simpler event-driven updates

---

## Open Questions

1. **Spinner state**: Should `spinner-index` be session-scoped (all buffers show same frame) or buffer-scoped (each buffer animates independently)?
   - Recommendation: Buffer-scoped (it's purely cosmetic UI)

2. **Telemetry display**: When session has no attached buffer, should telemetry still accumulate?
   - Recommendation: Yes, session owns telemetry regardless of frontends

3. **Error recovery**: If session is in error state, how does buffer display retry option?
   - Recommendation: Check `session.state` and `session.last-error` on attach/event

4. **Draft rendering on attach**: If attaching to streaming session, render accumulated draft as single block or replay deltas?
   - Recommendation: Single block (replay is complex and unnecessary)

---

## Code References

### Core State Management
- `benedict-chat--init-buffer`: `benedict-chat.el:3705` - Buffer initialization
- `benedict-chat--messages` definition: `benedict-chat.el:465`
- `benedict-chat--streaming-message` definition: `benedict-chat.el:487`
- `benedict-chat--telemetry` definition: `benedict-chat.el:711`

### Handler Architecture
- `benedict-chat--handle-provider-delta`: `benedict-chat.el:2762`
- `benedict-chat--handle-provider-success`: `benedict-chat.el:2803`
- `benedict-chat--handle-provider-error`: `benedict-chat.el:2900`
- `benedict-chat--handle-provider-delta-headless`: `benedict-chat.el:2927`
- `benedict-chat--handle-provider-success-headless`: `benedict-chat.el:2939`
- `benedict-chat--handle-provider-error-headless`: `benedict-chat.el:2969`
- `benedict-chat--start-dispatch`: `benedict-chat.el:2978`

### Session Module
- `benedict-session` struct: `benedict-session.el:13-19`
- `benedict-session--emit`: `benedict-session.el:97-102`
- `benedict-session-event-hook`: `benedict-session.el:89`

### Telemetry Functions
- `benedict-chat--telemetry-reset`: `benedict-chat.el:1161`
- `benedict-chat--telemetry-begin`: `benedict-chat.el:1238`
- `benedict-chat--telemetry-streaming`: `benedict-chat.el:1253`
- `benedict-chat--telemetry-finish`: `benedict-chat.el:1260`

---

## References

- **Previous Effort Plan**: `efforts/00047-effort_benedict_session/plan.md`
- **Previous Effort Research**: `efforts/00047-effort_benedict_session/research.md`
- **Session Module**: `benedict-session.el` (260 lines)
- **Chat Module**: `benedict-chat.el` (4053 lines)
- **Session Tests**: `test/benedict-session-test.el`, `test/benedict-chat-session-test.el`
