---
date: 2026-01-06T16:30:00-06:00
researcher: Claude Opus 4.5
git_commit: bee557f7c94716d3c804754621bd358461fdc2b8
branch: initial-benedict-session
repository: benedict
topic: "Current Architecture Analysis for benedict-session"
tags: [research, codebase, benedict-session, architecture, refactoring]
status: complete
last_updated: 2026-01-06
---

# Research: Current Architecture Analysis for benedict-session

**Date**: 2026-01-06
**Researcher**: Claude Opus 4.5
**Git Commit**: bee557f7c94716d3c804754621bd358461fdc2b8
**Branch**: initial-benedict-session

> **Relationship to product.md**: This research document maps the current codebase architecture to inform implementation of `benedict-session` as specified in `product.md`. The product spec is the authoritative source for requirements, scope, and success criteria. This document provides:
> - Inventory of current state locations and data flows
> - Resolved implementation questions with rationale
> - Mapping of current buffer-local state to session vs. UI ownership

## Research Question

How is state currently managed in Benedict's chat system, and what needs to change to implement `benedict-session` as described in `product.md`?

## Summary

Benedict's current architecture tightly couples **conversation state**, **runtime state**, and **UI state** in buffer-local variables within `benedict-chat-mode` buffers. The product spec calls for extracting this into a first-class `benedict-session` data structure that:

1. Owns the conversation thread (messages)
2. Manages runtime state (streaming, pending questions, tool activity)
3. Has a stable identity independent of buffers
4. Supports attach/detach of UI frontends—**including headless operation where sessions continue running with no buffer attached**

This research documents the current state locations, data flows, and dependencies to inform the implementation strategy.

**Key Design Principle**: Sessions are the source of truth and run independently of buffers. Buffers are views that attach/detach without affecting session state. This enables the daemon-first workflow where an agent can stream responses, execute tools, and wait for input even when no UI is connected.

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

## Resolved Questions

All implementation questions have been resolved through discussion. Each resolution includes rationale and implementation guidance for the planner.

### ✅ Message ID stability

**Question**: Messages currently lack stable IDs for cross-session reference. Need to add `:id` field for persistence/sync.

**Answer**: Use session-scoped monotonic integers for message IDs.

**Implementation Details**:

1. **ID Format**: String `"msg-NNN"` where NNN is zero-padded to 3 digits (e.g., `"msg-001"`, `"msg-042"`)
   - String format allows future extension if needed
   - Zero-padding keeps messages sortable lexicographically

2. **Session Struct Addition**:
   ```elisp
   (cl-defstruct (benedict-session ...)
     ...
     (message-seq 0)  ; Monotonic counter for message IDs
     ...)
   ```

3. **ID Assignment**: IDs are assigned in `benedict-session-add-message`:
   ```elisp
   (defun benedict-session-add-message (session message)
     "Add MESSAGE to SESSION, assigning a stable ID."
     (let ((id (format "msg-%03d" (cl-incf (benedict-session-message-seq session)))))
       (setq message (plist-put message :id id))
       ;; ... add to session messages list
       message))
   ```

4. **Immutability**: Once assigned, `:id` is never changed. Updates to message content preserve the ID.

5. **Tool Call Correlation**: Tool result messages already have `:tool-call-id`. The parent assistant message's `:id` provides the other half of the linkage.

6. **Event References**: Session events (e.g., `message-updated`) will reference messages by `:id`:
   ```elisp
   (benedict-session--emit session 'message-updated :id "msg-007" :field :content)
   ```

7. **Lookup Helper**:
   ```elisp
   (defun benedict-session-get-message (session id)
     "Return message with ID from SESSION, or nil."
     (cl-find id (benedict-session-messages session)
              :key (lambda (m) (plist-get m :id))
              :test #'equal))
   ```

**Rationale**: Session-scoped integers are simple, compact, and sufficient for all identified use cases. If global uniqueness is ever needed (e.g., cross-device sync), the combination of `session-id + message-id` provides it.

---

### ✅ Thinking item tracking

**Question**: `benedict-chat--thinking-items` is a hash table keyed by ID. Should this move to session or be re-derived on attach?

**Answer**: Separate content (session) from lookup table (buffer). Re-derive the hash table on attach.

**Analysis**:

The hash table serves two distinct purposes:
1. **Content storage** - the actual thinking text → belongs in session
2. **Render item lookup** - mapping IDs to UI elements for streaming updates → belongs in buffer

Render items contain buffer markers (`start-marker`, `end-marker`) which are inherently buffer-local and cannot be shared across buffers.

**Implementation Details**:

1. **Session stores thinking content** in message data:
   - Option A: As `:thinking-blocks` property on assistant messages
   - Option B: As separate entries in `messages` list with `:kind thinking`
   - Each thinking block retains its `:thinking-id` from the provider

2. **Buffer rebuilds hash table on attach**:
   ```elisp
   (defun benedict-chat--attach-session (session)
     "Attach current buffer to SESSION."
     ;; Reset UI state
     (setq benedict-chat--thinking-items (make-hash-table :test 'equal))
     ;; Re-render all messages (this populates the hash table)
     (benedict-chat--render-session-messages session))
   ```

3. **Re-render registers thinking items**:
   ```elisp
   ;; In benedict-chat--render-thinking-block (called during re-render)
   (let ((item (benedict-chat--create-thinking-item ...)))
     (benedict-chat--register-thinking-item thinking-id item)
     item)
   ```

4. **Streaming continues to work**: After attach, the hash table is populated and streaming deltas can look up items normally via `benedict-chat--lookup-thinking-item`.

**Key Insight**: The hash table is an **optimization for streaming lookups**, not canonical storage. The canonical thinking content lives in session messages.

---

### ✅ Compose buffer association

**Question**: How should compose buffers relate to sessions? One compose per session, or shared?

**Answer**: Compose buffers remain 1:1 with chat buffers. They are purely UI state.

**Rationale**:

1. **Compose buffers are for text input** - inherently per-buffer, per-user-interface
2. **Multiple frontends** - if two buffers show the same session, each needs its own compose area
3. **Context slices are ephemeral** - they're an implementation detail for assembling the next message, not worth preserving across buffer kills

**Implementation Details**:

1. **No changes needed** to compose buffer architecture—it stays as-is:
   - `benedict-chat--compose-buffer` remains buffer-local in chat buffer
   - Compose buffer lifecycle tied to chat buffer lifecycle

2. **Context slices stay buffer-local**:
   - `benedict-chat--context-slices` remains in chat buffer, not session
   - Lost on buffer kill (acceptable—they just help assemble the message)
   - Not listed in session struct

3. **On attach**: Fresh compose state
   ```elisp
   ;; In benedict-chat--attach-session
   (setq benedict-chat--compose-buffer nil)  ; Will be created on demand
   (setq benedict-chat--context-slices nil)
   ```

**Summary**: Compose and context slices are UI concerns. Session owns conversation history; buffer owns input-in-progress.

---

### ✅ Error recovery (headless streaming)

**Question**: If a session was `streaming` when detached, what happens on reattach? Need to define recovery semantics.

**Answer**: Sessions continue running independently of buffers. Streaming continues "headless" when no buffer is attached. On reattach, render current state and resume live updates.

**Core Requirement**: Support Emacs daemon mode where:
1. Connect emacsclient, open chat, start a request
2. Close emacsclient (buffer killed)
3. Request continues in the background (session still streaming)
4. Later, reconnect and attach to session—see completed or still-streaming response

**Implementation Details**:

1. **Session owns the inflight request**, not the buffer:
   - `benedict-session-inflight` holds request metadata and accumulating draft
   - Provider callbacks update session state, then emit events
   - Buffers subscribe to session events for UI updates

2. **Headless streaming** (no buffer attached):
   ```elisp
   ;; Provider callback updates session regardless of attached buffers
   (defun benedict-session--handle-delta (session delta)
     ;; Update session draft
     (benedict-session--append-draft session delta)
     ;; Emit event (attached buffers will receive and render)
     (benedict-session--emit session 'draft-updated :delta delta))
   ```

3. **Attach to streaming session**:
   ```elisp
   (defun benedict-chat--attach-session (session)
     ;; Render message history
     (benedict-chat--render-session-messages session)
     ;; If streaming, render accumulated draft and show indicator
     (when (eq (benedict-session-state session) 'streaming)
       (benedict-chat--render-draft (benedict-session-draft session))
       (benedict-chat--show-streaming-indicator))
     ;; Subscribe to future events
     (benedict-session--add-frontend session (current-buffer)))
   ```

4. **State-specific attach behavior**:

   | Session State | On Attach Behavior |
   |---------------|-------------------|
   | `idle` | Render message history |
   | `streaming` | Render history + accumulated draft, show streaming indicator, receive live updates |
   | `error` | Render history + error message, enable retry command |
   | `cancelled` | Render history + partial response with cancelled marker |

5. **Detach does NOT cancel**:
   ```elisp
   (defun benedict-chat--detach-session ()
     "Detach current buffer from session without affecting session state."
     (when-let ((session benedict-chat--session))
       ;; Just unsubscribe from events - session continues running
       (benedict-session--remove-frontend session (current-buffer))
       (setq benedict-chat--session nil)))
   ```

6. **Explicit cancel is separate**: User can explicitly cancel via command (`benedict-session-cancel`), which sets state to `cancelled`. Buffer kill never cancels.

**Key Architectural Change**: Provider dispatch callbacks must be refactored to:
- Update session state (not buffer-local variables)
- Emit session events
- Attached buffers respond to events by updating UI

---

### ✅ Provider request handles

**Question**: `benedict-chat--pending-request` holds an opaque provider handle. Can sessions "own" network connections, or must they be buffer-scoped for cleanup?

**Answer**: Sessions own provider request handles. This follows directly from Question 4 (sessions continue independently of buffers).

**Implementation Details**:

1. **Session `inflight` field** holds all request state:
   ```elisp
   ;; Within benedict-session struct
   inflight  ; plist or nil when idle:
             ;   :request     - opaque provider handle (for cancellation)
             ;   :request-id  - identifier for correlating callbacks
             ;   :started-at  - timestamp for elapsed time display
             ;   :draft       - accumulating response content (text + tool calls)
             ;   :loop-state  - agent loop metadata (turn count, etc.)
   ```

2. **Provider dispatch changes**:
   ```elisp
   ;; Old: callbacks captured buffer
   (benedict-provider-dispatch request
     :on-delta (lambda (delta) (with-current-buffer buffer ...)))

   ;; New: callbacks capture session
   (benedict-provider-dispatch request
     :on-delta (lambda (delta) (benedict-session--handle-delta session delta)))
   ```

3. **Cancellation via session**:
   ```elisp
   (defun benedict-session-cancel (session)
     "Cancel any in-flight request for SESSION."
     (when-let ((inflight (benedict-session-inflight session)))
       (when-let ((handle (plist-get inflight :request)))
         (benedict-provider-cancel handle))
       (setf (benedict-session-state session) 'cancelled)
       (benedict-session--emit session 'state-changed :state 'cancelled)))
   ```

4. **Session destruction cleanup**: If a session is explicitly destroyed while streaming, cancel the request first.

**Key Change**: `benedict-chat--pending-request` buffer-local variable is removed. Request ownership moves entirely to session.

---

### ✅ Flywire session lifecycle

**Question**: Should `benedict-flywire-session` be session-owned or chat-buffer-owned? Current design ties it to chat buffer kill hooks.

**Answer**: Flywire sessions are session-owned, not buffer-owned.

**Rationale**: Tool execution is part of the agent loop, which is session-scoped. If a buffer is killed mid-tool-execution, the tool must continue. Multiple attached buffers share the same execution context.

**Implementation Details**:

1. **Add to session struct**:
   ```elisp
   (cl-defstruct (benedict-session ...)
     ...
     flywire-session)  ; flywire session for tool execution, or nil
   ```

2. **Lazy creation** on first tool invocation via `benedict-session-ensure-flywire`.

3. **Cleanup on session destruction**:
   ```elisp
   (defun benedict-session-destroy (session)
     (when-let ((fw (benedict-session-flywire-session session)))
       (benedict-flywire-session-teardown fw))
     ...)
   ```

4. **Event forwarding**: Flywire events route through session events to attached buffers.

---

### ✅ Event granularity

**Question**: Should events be fine-grained (every delta) or batched (message-level)? Performance vs. flexibility trade-off.

**Answer**: Support both granularities via distinct event types, as specified in product.md.

**Event Types** (from product spec):

| Event | Granularity | Purpose |
|-------|-------------|---------|
| `message-added` | Message-level | New message committed to history |
| `message-updated` | Message-level | Existing message modified (e.g., tool result added) |
| `state-changed` | Session-level | State transitions (idle→streaming, etc.) |
| `draft-started` | Stream-level | Streaming response begins |
| `draft-updated` | Delta-level | Streaming delta received |
| `draft-finalized` | Stream-level | Streaming complete, draft committed |
| `question-raised` | Session-level | Agent needs user input |
| `question-answered` | Session-level | User answered pending question |
| `error` | Session-level | Error occurred |

**Implementation Details**:

1. **Single hook** dispatches all events:
   ```elisp
   (defvar benedict-session-event-hook nil
     "Hook called with (session event-type &rest payload).")
   ```

2. **Convenience hook** for question flow:
   ```elisp
   (defvar benedict-session-ask-user-hook nil
     "Hook called when session raises a question.")
   ```

3. **Buffers subscribe** during attach and filter events they care about:
   ```elisp
   (defun benedict-chat--handle-session-event (session event-type &rest payload)
     (pcase event-type
       ('draft-updated (benedict-chat--append-streaming-delta payload))
       ('message-added (benedict-chat--render-message payload))
       ('state-changed (benedict-chat--update-status-line))
       ...))
   ```

4. **Performance**: `draft-updated` events may fire rapidly during streaming. Buffer handlers should be efficient (append-only, minimal redisplay).

---

## Recommendations for Implementation

> **Note**: The authoritative product requirements are in `product.md`. This section synthesizes implementation guidance from the research findings. The planner should reference `product.md` for scope and success criteria.

### Session Struct (from product.md + resolved questions)

Create `benedict-session.el` with `cl-defstruct`:

```elisp
(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state and runtime."
  ;; Identity & metadata
  id                    ; stable string identifier (UUID-ish)
  created-at            ; timestamp
  updated-at            ; timestamp
  title                 ; string; user-set or derived from first prompt

  ;; Thread/conversation state
  messages              ; list of normalized messages (with :id field)
  (message-seq 0)       ; monotonic counter for message IDs (resolved Q1)

  ;; Runtime state
  state                 ; idle | streaming | waiting | error | cancelled
  draft                 ; streaming accumulator (text + tool calls)
  pending-question      ; nil or plist describing outstanding question
  inflight              ; plist: :request :request-id :started-at :loop-state
  last-error            ; last error object/message

  ;; Configuration snapshot
  root                  ; project root directory or nil
  provider              ; provider symbol
  model                 ; model string
  profile               ; profile symbol
  meta                  ; plist for tags, originating context, etc.

  ;; Resources
  flywire-session       ; flywire session for tool execution (resolved Q6)
  attached-frontends)   ; list of attached buffer references
```

### Session Registry API (from product.md)

```elisp
(defvar benedict-session--registry (make-hash-table :test 'equal))

(defun benedict-session-create (&rest init-plist) -> session)
(defun benedict-session-get (id) -> session|nil)
(defun benedict-session-list (&optional predicate) -> sessions)
(defun benedict-session-delete (id) -> t|nil)
(defun benedict-session-touch (session))  ; updates updated-at
(defun benedict-session-destroy (session)) ; cleanup + delete
```

### Event System (from product.md + resolved Q7)

```elisp
(defvar benedict-session-event-hook nil
  "Hook called with (session event-type &rest payload).")

(defvar benedict-session-ask-user-hook nil
  "Convenience hook for question-raised events.")

;; Event types: message-added, message-updated, state-changed,
;; draft-started, draft-updated, draft-finalized,
;; question-raised, question-answered, error
```

### Chat Buffer Refactoring

**State that moves to session** (all buffer-local variables listed in research):
- `benedict-chat--messages` → `(benedict-session-messages session)`
- `benedict-chat--pending-request` → `(plist-get (benedict-session-inflight session) :request)`
- `benedict-chat--streaming-message` → `(benedict-session-draft session)`
- `benedict-chat--flywire-session` → `(benedict-session-flywire-session session)`
- `benedict-chat--loop-*` variables → `(plist-get (benedict-session-inflight session) :loop-state)`
- Provider/model overrides → session fields

**State that stays in buffer** (UI-only):
- `benedict-chat--items` (render items with markers)
- `benedict-chat--thinking-items` (rebuilt on attach, resolved Q2)
- `benedict-chat--compose-buffer` (1:1 with buffer, resolved Q3)
- `benedict-chat--context-slices` (ephemeral, resolved Q3)
- Sections, markers, timers, counters

### Session Routing (from product.md)

`M-x benedict-chat` behavior:
- **No sessions exist**: create new session, open chat buffer
- **One session exists**: open that session's chat buffer
- **Multiple sessions**: prompt with session picker, open selected
- **C-u prefix**: always create new session (never reattach)

### Attach/Detach Semantics (from resolved Q4)

**Attach** (`benedict-chat--attach-session`):
1. Store session reference in buffer-local `benedict-chat--session`
2. Clear and re-render buffer from session messages
3. If `state` is `streaming`: render accumulated draft, show indicator
4. If `state` is `error`: show error, enable retry
5. Rebuild `thinking-items` hash table during render
6. Subscribe to session events via `benedict-session--add-frontend`

**Detach** (`benedict-chat--detach-session`):
1. Unsubscribe from session events
2. Clear buffer-local session reference
3. **Do NOT cancel inflight requests** - session continues headless

### Provider Callback Refactoring (from resolved Q4/Q5)

Provider callbacks must be changed to update session, not buffer:

```elisp
;; Old pattern (buffer-centric)
(benedict-provider-dispatch request
  :on-delta (lambda (d) (with-current-buffer buffer ...)))

;; New pattern (session-centric)
(benedict-provider-dispatch request
  :on-delta (lambda (d) (benedict-session--handle-delta session d))
  :on-success (lambda (r) (benedict-session--handle-success session r))
  :on-error (lambda (e) (benedict-session--handle-error session e)))
```

Session handlers update state and emit events; attached buffers respond to events.

---

## Historical Context

This effort builds on the existing architecture established in:
- `00003-phase_1_skeleton`: Basic chat structure
- `00005-phase_3_streaming`: Streaming support
- `00009-phase_4_context_compose`: Context/compose model
- `00011-phase_5_tools`: Tool system
- `00013-phase_6_agent_loop`: Autonomous agent loops

The `benedict-flywire.el` module (from `flywire` package) already demonstrates a session-like pattern with `flywire-session-create`, `flywire-session-teardown`, and event subscriptions. This can serve as a reference for the `benedict-session` implementation.
