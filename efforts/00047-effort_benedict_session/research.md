---
date: 2026-01-06T16:30:00-06:00
researcher: Claude Opus 4.5
git_commit: bee557f7c94716d3c804754621bd358461fdc2b8
branch: initial-benedict-session
repository: benedict
topic: "Current Architecture Analysis for benedict-session"
tags: [research, codebase, benedict-session, architecture, refactoring]
status: draft
last_updated: 2026-01-06
---

# Research: Current Architecture Analysis for benedict-session

**Date**: 2026-01-06
**Researcher**: Claude Opus 4.5
**Git Commit**: bee557f7c94716d3c804754621bd358461fdc2b8
**Branch**: fix-chat-render-ordering

## Research Question

How is state currently managed in Benedict's chat system, and what needs to change to implement `benedict-session` as described in `product.md`?

## Summary

Benedict's current architecture tightly couples **conversation state**, **runtime state**, and **UI state** in buffer-local variables within `benedict-chat-mode` buffers. The product spec calls for extracting this into a first-class `benedict-session` data structure that:

1. Owns the conversation thread (messages)
2. Manages runtime state (streaming, pending questions, tool activity)
3. Has a stable identity independent of buffers
4. Supports attach/detach of UI frontends

This research documents the current state locations, data flows, and dependencies to inform the implementation strategy.

---

## Detailed Findings

### 1. Current File Architecture

The codebase is organized into these key modules:

| File | Purpose |
|------|---------|
| `benedict.el` | Package entry, customization groups, faces, minor mode |
| `benedict-chat.el` | Main chat buffer, mode, message handling, dispatch |
| `benedict-chat-render.el` | Buffer insertion, markers, text properties |
| `benedict-chat-stream.el` | Streaming state and delta buffering |
| `benedict-provider.el` | Provider registry and dispatch abstraction |
| `benedict-provider-*.el` | Concrete provider implementations |
| `benedict-tools.el` | Tool registry, schemas, invocation |
| `benedict-flywire.el` | Agent frame/session for tool execution |
| `benedict-context.el` | Context slice management |

### 2. Buffer-Local State Inventory

All session state currently lives in buffer-local variables in `benedict-chat.el`. The init function (`benedict-chat--init-buffer` at line 3705) initializes these:

#### Thread/Conversation State (Should Move to Session)

| Variable | Line | Description | Session Field |
|----------|------|-------------|---------------|
| `benedict-chat--messages` | 434 | List of message plists (newest first) | `messages` |
| `benedict-chat-profile` | 708 | Active profile symbol | `profile` |
| `benedict-chat--provider-override` | 695 | Buffer-local provider override | `provider` |
| `benedict-chat--compose-model-override` | 692 | Transient model override | `model` |

#### Runtime State (Should Move to Session)

| Variable | Line | Description | Session Field |
|----------|------|-------------|---------------|
| `benedict-chat--pending-request` | 441 | In-flight provider request handle | `inflight` |
| `benedict-chat--streaming-message` | 456 | Current streaming assistant message | `draft` |
| `benedict-chat--active-request-id` | 459 | Current request identifier | `inflight.request-id` |
| `benedict-chat--request-seq` | 462 | Monotonic request sequence | n/a (session-scoped) |
| `benedict-chat--last-dispatch` | 444 | Last request (for retry) | `last-request` |
| `benedict-chat--telemetry` | 680 | Status/timing/usage tracking | Derived or separate |
| `benedict-chat--loop-start-time` | 699 | Autonomous loop timing | `inflight.loop-state` |
| `benedict-chat--loop-turn-count` | 702 | Loop turn counter | `inflight.loop-state` |
| `benedict-chat--loop-canceled` | 705 | Loop cancellation flag | `inflight.canceled` |
| `benedict-chat--flywire-session` | 711 | Active flywire session | `flywire-session` |
| `benedict-chat--flywire-event-unsubscribe` | 714 | Event cleanup function | (internal) |
| `benedict-chat--thinking-items` | 453 | Hash table mapping IDs to thinking items | `thinking-items` |
| `benedict-chat--thinking-temp-counter` | 465 | Per-request thinking ID generator | (internal) |
| `benedict-chat--context-slices` | 686 | Pending context for next message | `pending-context` |

#### UI/Presentation State (Stays in Buffer)

| Variable | Line | Description | Notes |
|----------|------|-------------|-------|
| `benedict-chat--buffer` | 438 | Self-reference to buffer | Stays (or becomes session pointer) |
| `benedict-chat--items` | 447 | Rendered chat items list | UI-only, re-render on attach |
| `benedict-chat--item-counter` | 450 | Monotonic item ID generator | UI-only |
| `benedict-chat--conversation-section` | 135 | Root magit-section | UI-only |
| `benedict-chat--current-turn-section` | 141 | Current turn section | UI-only |
| `benedict-chat--has-rendered-block` | 1563 | Gap insertion flag | UI-only |
| `benedict-chat--status-timer` | 683 | Spinner/elapsed timer | UI-only |
| `benedict-chat--compose-buffer` | 689 | Associated compose buffer | UI-only |

### 3. Data Flow Analysis

#### 3.1 Message Send Flow

```
User Input (compose buffer)
    │
    ▼
benedict-chat--send-text (line ~2898)
    │
    ├─► benedict-chat--record-message (line 1629)
    │       └─► Stores in benedict-chat--messages
    │       └─► Renders via benedict-chat--render-message
    │
    ▼
benedict-chat--build-request (line 2635)
    │ Reads from:
    │   - benedict-chat--messages
    │   - benedict-chat-profile
    │   - benedict-chat--provider-override
    │   - benedict-chat--compose-model-override
    │
    ▼
benedict-chat--start-dispatch (line 2848)
    │ Sets:
    │   - benedict-chat--request-seq
    │   - benedict-chat--active-request-id
    │   - benedict-chat--pending-request
    │   - benedict-chat--last-dispatch
    │
    ▼
benedict-provider-dispatch (benedict-provider.el:58)
    │ Callbacks registered:
    │   :on-success → benedict-chat--handle-provider-success
    │   :on-error → benedict-chat--handle-provider-error
    │   :on-delta → benedict-chat--handle-provider-delta
```

#### 3.2 Streaming Response Flow

```
Provider SSE event
    │
    ▼
:on-delta callback
    │
    ▼
benedict-chat--handle-provider-delta
    │
    ├─► benedict-chat--streaming-ensure-message (line 2429)
    │       Creates placeholder assistant message if needed
    │       Sets benedict-chat--streaming-message
    │
    ├─► benedict-chat--streaming-append-text (line 2449)
    │       Appends delta to streaming content
    │       Updates buffer via benedict-chat--replace-message-content
    │
    └─► Thinking/reasoning handling
            benedict-chat--display-thinking-detail (line 2320)
```

#### 3.3 Tool Call Flow

```
Provider response with tool_calls
    │
    ▼
benedict-chat--process-tool-calls (line 2144)
    │
    ├─► benedict-chat--record-tool-block (line 1984)
    │       Creates tool UI item
    │       Renders in buffer
    │
    └─► benedict-chat--invoke-tool-call (line 2094)
            │
            ├─► benedict-tool-invoke (benedict-tools.el:403)
            │       Applies approval policy
            │       Executes tool function
            │
            └─► benedict-chat--update-tool-block (line 2015)
                    Updates UI with result
                    Stores in history
```

#### 3.4 Agent Loop Flow

```
Tool call response triggers continuation
    │
    ▼
benedict-chat--loop-step (line 790)
    │
    ├─► benedict-chat--check-repetition-guard
    │       Compares with previous tool calls
    │
    ├─► benedict-chat--check-loop-constraints (line 737)
    │       Checks: turn count, time limit, token limit
    │       May prompt user for continuation
    │
    └─► benedict-chat--start-dispatch
            Continues the loop
```

### 4. Message Schema Analysis

Current message plist structure (from `benedict-chat--messages`):

```elisp
(:role user|assistant|system|tool
 :content "text content"
 :time (timestamp)
 :metadata (:provider "..." :model "..." :usage (...) :error t/nil ...)
 :kind message|thinking|tool
 :item <render-item-plist>       ; UI reference
 :tool-calls [...]               ; For assistant messages
 :tool-call-id "..."             ; For tool role messages
 :name "tool-name"               ; For tool role messages
 :raw <provider-payload>         ; For debugging/round-trip
 :display-content "..."          ; When different from content
)
```

Tool call structure (embedded in assistant messages):

```elisp
(:id "call_id"
 :name tool-name-symbol
 :arguments (:key val ...)
 :arguments-text "{json}"        ; Raw JSON for round-trip
 :raw <provider-payload>)
```

### 5. Key Dependencies and Coupling Points

#### 5.1 Provider Dispatch

`benedict-chat--start-dispatch` (line 2848) is the critical coupling point:
- Takes `buffer` as first argument
- All callbacks reference `buffer` via closure
- Must remain buffer-aware for now (UI updates), but can delegate to session

#### 5.2 Streaming State

`benedict-chat--streaming-message` couples streaming to buffer:
- Used by `benedict-chat--streaming-ensure-message`
- Updated by `benedict-chat--streaming-append-text`
- Cleared by `benedict-chat--streaming-reset`

This maps directly to the proposed session `draft` field.

#### 5.3 Tool Execution

Tools are executed via `benedict-tool-invoke` which is stateless, but:
- Results are stored via `benedict-chat--history-store`
- UI updates via `benedict-chat--update-tool-block`
- Both currently assume buffer context

#### 5.4 Flywire Session

`benedict-chat--flywire-session` and `benedict-chat--flywire-event-unsubscribe` manage tool execution isolation. This is already somewhat decoupled and could be associated with a session instead.

### 6. State Machine Analysis

Current implicit states (should become explicit session `state` field):

| State | Indicators | Description |
|-------|------------|-------------|
| `idle` | `pending-request` is nil | No active request |
| `streaming` | `pending-request` non-nil, `streaming-message` active | Receiving response |
| `waiting` | (Not implemented) | Needs user input |
| `error` | Metadata `:error` flag | Last request failed |
| `cancelled` | (Implicit via callback) | Request aborted |

The product spec calls for explicit `state` field: `idle`, `streaming`, `waiting`, `error`, `cancelled`.

### 7. Entry Point Analysis

#### 7.1 benedict-chat Command (line 3757)

```elisp
(defun benedict-chat ()
  "Open or switch to the Benedict chat buffer."
  (interactive)
  (let ((buf (get-buffer-create benedict-chat-buffer-name)))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (unless (derived-mode-p 'benedict-chat-mode)
        (let ((mode (or benedict-chat-major-mode #'benedict-chat-mode)))
          (unless (fboundp mode)
            (setq mode #'benedict-chat-mode))
          (funcall mode)
          (benedict-chat--init-buffer)))))
  (message "Type C-c C-s to send a prompt; g r retries; w copies last response."))
```

This is the simplest entry point. The product spec proposes:
- No prefix: reattach to existing session(s) or create new
- `C-u` prefix: always create new session

#### 7.2 Buffer Initialization

`benedict-chat--init-buffer` (line 3705) initializes all state. With sessions:
- Create or attach to session
- Store session reference in buffer-local
- Initialize UI-only state
- Subscribe to session events for rendering

### 8. Event System Gaps

The product spec proposes:
- `benedict-session-event-hook` with event types: `message-added`, `message-updated`, `state-changed`, `draft-started`, `draft-updated`, `draft-finalized`, `question-raised`, `question-answered`, `error`

Currently:
- No event system exists for session state changes
- UI updates are direct buffer mutations
- Hook points would need to be added at each state transition

---

## Architecture Documentation

### Current Architecture (Buffer-Centric)

```
┌─────────────────────────────────────────────────────────────────┐
│                      benedict-chat buffer                        │
├─────────────────────────────────────────────────────────────────┤
│  Buffer-Local Variables:                                         │
│  ┌─────────────────────┬──────────────────────────────────────┐ │
│  │ Thread State        │ Runtime State                        │ │
│  │ - messages          │ - pending-request                    │ │
│  │ - profile           │ - streaming-message                  │ │
│  │ - provider-override │ - active-request-id                  │ │
│  │ - model-override    │ - loop-state                         │ │
│  └─────────────────────┴──────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ UI State                                                    │ │
│  │ - items, sections, markers, timers                          │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────┐     ┌───────────────────────┐
│   benedict-provider   │────▶│   Provider (HTTP)     │
└───────────────────────┘     └───────────────────────┘
        │
        ▼
┌───────────────────────┐
│   benedict-tools      │
└───────────────────────┘
```

### Target Architecture (Session-Centric)

```
┌──────────────────────────────────────────────────────────────────┐
│                        Session Registry                           │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ session-1: { id, state, messages, draft, inflight, ... }   │  │
│  │ session-2: { id, state, messages, draft, inflight, ... }   │  │
│  │ ...                                                         │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                │                              │
    (attach)    ▼                              ▼    (attach)
┌───────────────────────────┐    ┌───────────────────────────┐
│  Chat Buffer (Frontend 1) │    │  Future Frontend          │
│  - session-id (pointer)   │    │  (emacsclient, TUI, ...)  │
│  - UI-only state          │    │                           │
└───────────────────────────┘    └───────────────────────────┘
```

---

## Code References

### Core State Management
- `benedict-chat--init-buffer`: `benedict-chat.el:3705` - Buffer initialization
- `benedict-chat--messages` definition: `benedict-chat.el:434`
- `benedict-chat--streaming-message` definition: `benedict-chat.el:456`
- `benedict-chat--pending-request` definition: `benedict-chat.el:441`

### Message Flow
- `benedict-chat--build-request`: `benedict-chat.el:2635` - Request construction
- `benedict-chat--start-dispatch`: `benedict-chat.el:2848` - Provider dispatch
- `benedict-chat--record-message`: `benedict-chat.el:1629` - Message persistence
- `benedict-chat--streaming-ensure-message`: `benedict-chat.el:2429` - Streaming init

### Tool Handling
- `benedict-chat--process-tool-calls`: `benedict-chat.el:2144` - Tool call processing
- `benedict-chat--invoke-tool-call`: `benedict-chat.el:2094` - Tool execution
- `benedict-tool-invoke`: `benedict-tools.el:403` - Tool dispatch with approval

### UI Rendering
- `benedict-chat--render-message`: `benedict-chat.el:1585` - Message rendering
- `benedict-chat--render-tool-item`: `benedict-chat-render.el:457` - Tool rendering
- `benedict-chat--update-tool-header`: `benedict-chat-render.el:509` - Header updates

---

## Open Questions

1. **Message ID stability**: Messages currently lack stable IDs for cross-session reference. Need to add `:id` field for persistence/sync.

2. **Thinking item tracking**: `benedict-chat--thinking-items` is a hash table keyed by ID. Should this move to session or be re-derived on attach?

3. **Compose buffer association**: How should compose buffers relate to sessions? One compose per session, or shared?

4. **Error recovery**: If a session was `streaming` when detached, what happens on reattach? Need to define recovery semantics.

5. **Provider request handles**: `benedict-chat--pending-request` holds an opaque provider handle. Can sessions "own" network connections, or must they be buffer-scoped for cleanup?

6. **Flywire session lifecycle**: Should `benedict-flywire-session` be session-owned or chat-buffer-owned? Current design ties it to chat buffer kill hooks.

7. **Event granularity**: Should events be fine-grained (every delta) or batched (message-level)? Performance vs. flexibility trade-off.

---

## Recommendations for Implementation

### Phase 1: Define `benedict-session` struct

Create `benedict-session.el` with `cl-defstruct`:

```elisp
(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state."
  id
  created-at
  updated-at
  title
  state           ; idle, streaming, waiting, error, cancelled
  messages        ; list of normalized messages
  draft           ; streaming accumulator
  pending-question
  inflight        ; request metadata
  root            ; project root
  provider
  model
  profile
  meta
  last-error
  attached-frontends)
```

### Phase 2: Create session registry

```elisp
(defvar benedict-session--registry (make-hash-table :test 'equal))

(defun benedict-session-create (&rest init-plist) ...)
(defun benedict-session-get (id) ...)
(defun benedict-session-list (&optional predicate) ...)
(defun benedict-session-delete (id) ...)
```

### Phase 3: Refactor chat buffer

1. Add `benedict-chat--session` buffer-local variable (session struct or ID)
2. Modify `benedict-chat--init-buffer` to create/attach session
3. Modify `benedict-chat--build-request` to read from session
4. Modify `benedict-chat--record-message` to update session
5. Modify streaming handlers to update session `draft`
6. Add session event emission at state transitions

### Phase 4: Implement re-render on attach

When attaching a buffer to an existing session:
1. Clear buffer content
2. Re-render all session messages
3. Restore streaming state if active
4. Subscribe to session events

---

## Historical Context

This effort builds on the existing architecture established in:
- `00003-phase_1_skeleton`: Basic chat structure
- `00005-phase_3_streaming`: Streaming support
- `00009-phase_4_context_compose`: Context/compose model
- `00011-phase_5_tools`: Tool system
- `00013-phase_6_agent_loop`: Autonomous agent loops

The `benedict-flywire.el` module (from `flywire` package) already demonstrates a session-like pattern with `flywire-session-create`, `flywire-session-teardown`, and event subscriptions. This can serve as a reference for the `benedict-session` implementation.
