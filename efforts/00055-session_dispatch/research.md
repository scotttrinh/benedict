---
date: 2026-01-08T15:30:00-06:00
researcher: claude-opus-4-5
git_commit: ee96b5e2e7f6e193c5d411417d6822f921477505
branch: 00054-session_source_of_truth
repository: benedict
topic: "Extract dispatch logic from benedict-chat.el into benedict-session.el"
tags: [research, codebase, session, dispatch, refactoring, architecture]
status: complete
last_updated: 2026-01-08
implementation_plan: efforts/00055-session_dispatch/plan.md
---

# Research: Session Dispatch Extraction

**Date**: 2026-01-08
**Researcher**: claude-opus-4-5
**Git Commit**: ee96b5e2e7f6e193c5d411417d6822f921477505
**Branch**: 00054-session_source_of_truth

## Research Question

How should dispatch logic be extracted from `benedict-chat.el` into `benedict-session.el` to make the chat buffer a pure reactive view? The chat buffer currently acts as a middle-man: it calls `provider-dispatch` directly, defines headless callbacks, and builds requests.

## Summary

The session module (`benedict-session.el`) is **complete as a state container** but **incomplete as an agent dispatcher**. Effort 00054 successfully moved message storage, telemetry accumulation, and event subscription to the session. However, the actual request dispatch still lives in `benedict-chat.el`, creating an awkward architecture where:

1. The chat buffer calls `benedict-provider-dispatch` directly
2. Callbacks are defined in the chat module (even the "headless" ones)
3. Request building happens in the chat module
4. The session is updated as a side effect, not as the owner

This research documents the current architecture and what needs to change to complete the transition.

## Detailed Findings

### Current Architecture: Chat Buffer as Middle-Man

```
┌─────────────────────────────────────────────────────────────────────┐
│                        benedict-chat.el                             │
│                                                                     │
│  compose-send ─→ send-text ─→ record-message ─→ start-dispatch     │
│                                    │                   │            │
│                                    ▼                   ▼            │
│                            add-message         provider-dispatch    │
│                            (to session)        (DIRECT CALL)        │
│                                                     │               │
│                           ┌─────────────────────────┴───────┐       │
│                           │ Inline callbacks defined:       │       │
│                           │  • handle-provider-*-headless   │       │
│                           │  • handle-provider-* (buffer)   │       │
│                           └─────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       benedict-session.el                           │
│                                                                     │
│  Session is PASSIVE - just holds state                              │
│  Updated by callbacks defined in chat.el                            │
│  NO dispatch capability                                             │
└─────────────────────────────────────────────────────────────────────┘
```

### Dispatch Flow in benedict-chat.el

**Entry Point: `benedict-chat--send-text`** (Lines 3000-3018)
- Validates chat buffer and prompt
- Initializes loop state variables
- Records user message to session via `benedict-chat--record-message`
- Calls `benedict-chat--start-dispatch`

**Orchestrator: `benedict-chat--start-dispatch`** (Lines 2926-2993)

This function is the heart of the problem. It:

1. **Manages buffer-local state** (lines 2934-2941):
   - Increments `benedict-chat--request-seq`
   - Resets thinking counter, streaming state, status UI
   - Stores dispatch record for retry capability

2. **Updates session metadata** (lines 2944-2948):
   - Sets provider, model, profile on session
   - But does NOT delegate dispatch to session

3. **Calls provider directly** (lines 2953-2978):
   ```elisp
   (benedict-provider-dispatch
    request
    :on-success (lambda (result)
                  (benedict-chat--handle-provider-success-headless session result)
                  (when (buffer-live-p buffer)
                    (benedict-chat--handle-provider-success buffer result)))
    :on-error (lambda (payload) ...)
    :on-delta (lambda (&rest payload) ...))
   ```

4. **Tracks request in session after dispatch** (lines 2980-2987):
   ```elisp
   (benedict-session-start-request session handle)
   (benedict-session-start-draft session)
   ```

### The "Headless" Handlers Live in Chat Module

Despite their name suggesting session-level operation, these functions are defined in `benedict-chat.el`:

| Function | Lines | Updates Session State |
|----------|-------|----------------------|
| `benedict-chat--handle-provider-delta-headless` | 2853-2863 | Appends to draft |
| `benedict-chat--handle-provider-success-headless` | 2865-2907 | Finalizes draft, accumulates telemetry |
| `benedict-chat--handle-provider-error-headless` | 2909-2924 | Sets error state, discards draft |

This is backwards: session state updates should be owned by the session module, not delegated to it from the chat module.

### Request Building in benedict-chat.el

**`benedict-chat--build-request`** (Lines 2633-2652)

Assembles the provider request plist:
- Resolves provider, model, profile from buffer/profile settings
- Gets tools from profile configuration
- **Reads messages from session** (correct - session is source of truth)
- Returns plist with `:provider`, `:model`, `:profile`, `:tools`, `:messages`

This function has some session awareness but lives in the wrong module.

### Session Module Capabilities

From `benedict-session.el` (330 lines total):

**What Session CAN Do:**
- Create/delete/list sessions (registry management)
- Store and retrieve messages
- Manage draft state (start, append, finalize, discard)
- Track inflight requests (start, clear, cancel)
- Accumulate telemetry (usage, elapsed time)
- Emit events (state-changed, message-added, draft-*, destroyed)
- Manage frontend buffer attachments

**What Session CANNOT Do (Missing):**
- Call `benedict-provider-dispatch`
- Build request plists
- Own callback implementations
- Process tool calls
- Drive the agent loop

### Event System Status

The event system works correctly:
- `benedict-session-event-hook` receives events
- Chat buffer subscribes via `benedict-chat--subscribe-to-session`
- Events emitted: `state-changed`, `message-added`, `draft-started`, `draft-updated`, `draft-finalized`, `destroyed`

But the events are emitted as a **side effect** of callbacks defined in `benedict-chat.el`, not as the primary flow.

### Provider Interface Contract

From `benedict-provider.el:58-74`:

```elisp
(cl-defun benedict-provider-dispatch
    (request &key on-success on-error on-delta on-complete)
  "Send REQUEST to the active provider.")
```

**Callback Contracts:**

| Callback | Payload | Purpose |
|----------|---------|---------|
| `:on-success` | `(:message M :model S :provider S :usage P :latency F)` | Final response |
| `:on-error` | `(:type S :message S :status N :retryable B)` | Error handling |
| `:on-delta` | `(:kind K :text S :message-id S)` | Streaming chunks |
| `:on-complete` | Same as success | Streaming completion |

The session module can use this same interface.

## Target Architecture: Session as Dispatcher

```
┌─────────────────────────────────────────────────────────────────────┐
│                        benedict-chat.el                             │
│                                                                     │
│  compose-send ─→ send-text ─→ session-dispatch(request)             │
│                                                                     │
│  OBSERVES session events:                                           │
│   • draft-started → create streaming UI                             │
│   • draft-updated → append text to UI                               │
│   • message-added → render message                                  │
│   • state-changed → update status line                              │
│   • tool-call-requested → show tool block                           │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (calls)
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       benedict-session.el                           │
│                                                                     │
│  benedict-session-dispatch(session request):                        │
│   → validate session state (not busy)                               │
│   → call benedict-provider-dispatch                                 │
│   → own callbacks that update session state                         │
│   → emit events as state changes                                    │
│                                                                     │
│  Session is ACTIVE - owns request lifecycle                         │
└─────────────────────────────────────────────────────────────────────┘
```

## What Needs to Move

### From benedict-chat.el to benedict-session.el

| Function/Logic | Current Location | Notes |
|----------------|------------------|-------|
| `benedict-chat--start-dispatch` core | chat.el:2926-2993 | Becomes `benedict-session-dispatch` |
| `benedict-chat--handle-provider-delta-headless` | chat.el:2853-2863 | Becomes internal session callback |
| `benedict-chat--handle-provider-success-headless` | chat.el:2865-2907 | Becomes internal session callback |
| `benedict-chat--handle-provider-error-headless` | chat.el:2909-2924 | Becomes internal session callback |
| Request validation | chat.el:3011 | `ensure-not-busy` → session guards |

### Stays in benedict-chat.el

| Function/Logic | Reason |
|----------------|--------|
| `benedict-chat--build-request` | Needs profile/tool resolution from buffer context |
| `benedict-chat--handle-provider-delta` | Buffer UI updates |
| `benedict-chat--handle-provider-success` | Buffer UI updates |
| `benedict-chat--handle-provider-error` | Buffer UI updates |
| Loop management | UI-driven checkpoints |
| Status display | Buffer-local UI state |

### New Session Functions Needed

```elisp
;; Core dispatch
(defun benedict-session-dispatch (session request)
  "Send REQUEST through the provider for SESSION.
Updates session state and emits events. Returns request-id.")

;; Internal callbacks (not exported)
(defun benedict-session--on-delta (session data) ...)
(defun benedict-session--on-success (session result) ...)
(defun benedict-session--on-error (session payload) ...)

;; Query helpers
(defun benedict-session-busy-p (session)
  "Return non-nil if SESSION has an active request.")
```

### New Events Needed

| Event | Payload | When |
|-------|---------|------|
| `request-started` | `(:request-id N)` | After dispatch begins |
| `request-completed` | `(:request-id N :success B)` | After success/error |
| `thinking-updated` | `(:id S :text S)` | During reasoning streaming |
| `tool-call-requested` | `(:tool-call P)` | When tool call detected |

## Migration Path

The detailed migration path has been extracted into a separate implementation plan.

**See**: `efforts/00055-session_dispatch/plan.md`

### Summary of Phases

1. **Phase 1: Core Dispatch in Session** - Session can dispatch requests and update its own state
2. **Phase 2: Tool Execution in Session** - Session executes tools without buffer involvement
3. **Phase 3: Agent Loop in Session** - Session drives full autonomous loop
4. **Phase 4: Request Building in Session** - Session accepts configuration, builds requests internally
5. **Phase 5: Chat Buffer as Pure View** - Chat buffer only handles UI, delegates everything else

The implementation plan covers Phase 1 in detail with step-by-step instructions.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking existing tests | Phased migration, keep dual paths initially |
| Buffer-specific context needed | Pass context in request plist, not via buffer-local vars |
| Provider module dependency | Session already requires benedict core |
| Tool call processing | Keep in chat initially, migrate later |

## Code References

### Current Dispatch (to be moved)
- `benedict-chat.el:2926-2993` - `benedict-chat--start-dispatch`
- `benedict-chat.el:2853-2863` - `handle-provider-delta-headless`
- `benedict-chat.el:2865-2907` - `handle-provider-success-headless`
- `benedict-chat.el:2909-2924` - `handle-provider-error-headless`
- `benedict-chat.el:2633-2652` - `build-request`
- `benedict-chat.el:3000-3018` - `send-text`

### Session Module (to be extended)
- `benedict-session.el:196-228` - Inflight request tracking
- `benedict-session.el:149-192` - Draft mechanism
- `benedict-session.el:103-115` - Event emission
- `benedict-session.el:260-287` - Telemetry accumulation

### Provider Interface (to be called by session)
- `benedict-provider.el:58-74` - `benedict-provider-dispatch`
- `benedict-provider.el:76-80` - `benedict-provider-abort`

## Historical Context

- **Effort 00047**: Introduced session struct and basic state management
- **Effort 00054**: Completed session-as-source-of-truth for state storage:
  - Phase 1: Added telemetry fields to session
  - Phase 2: Implemented event subscription infrastructure
  - Phase 3: Converted buffer handlers to event observers
  - Phase 4: Eliminated duplicate buffer-local variables
  - Phase 5: Fixed attach flow to render from session

This effort (00055) is the logical next step: session owns not just state, but the request lifecycle.

## Architectural Decision: Session as Headless Agent Engine

**Key insight**: The session should be a fully autonomous agent engine that can be driven by **any** frontend, not just the chat buffer. Possible frontends include:

- **Chat buffer** (current) - Emacs UI for interactive use
- **CLI** - Command-line interface for scripting/automation
- **Daemon process** - Background agent responding to external triggers
- **Email integration** - Processing incoming emails as prompts
- **API server** - HTTP endpoints for remote agent access
- **Test harness** - Programmatic driving for testing

This means:

1. **Session owns the full agent loop** - including tool execution, continuation decisions, and checkpoints
2. **Session is completely headless-capable** - no buffer required for full operation
3. **Request building moves to session** - profile/tool config passed in, not read from buffer
4. **Tool execution happens in session** - results flow back via events
5. **Loop constraints are session-level** - max turns, timeouts, token limits

### Implications for Design

| Concern | Old Location | New Location |
|---------|--------------|--------------|
| Provider dispatch | Chat buffer | Session |
| Tool execution | Chat buffer | Session |
| Agent loop | Chat buffer | Session |
| Loop constraints | Chat buffer | Session |
| Request building | Chat buffer | Session (config passed in) |
| Checkpoint prompts | Chat buffer (y-or-n-p) | Session event + frontend handler |

### Frontend Responsibilities (Chat Buffer)

After this refactoring, the chat buffer becomes a pure UI layer:

- **Rendering** - Display messages, tool blocks, thinking
- **Input** - Compose prompts, capture context
- **Observation** - Subscribe to session events, update display
- **User interaction** - Handle checkpoint prompts, cancellation
- **Status display** - Show spinner, elapsed time, token counts

### Session Events for Frontend Coordination

New events needed for headless operation with frontend coordination:

| Event | Payload | Frontend Response |
|-------|---------|-------------------|
| `checkpoint-requested` | `(:reason :turn-limit :turn-count N)` | Prompt user, call `session-continue` or `session-stop` |
| `tool-started` | `(:tool-call P)` | Show tool block in UI |
| `tool-completed` | `(:tool-call P :result R :error E)` | Update tool block |
| `user-input-requested` | `(:prompt S :type :confirmation)` | Show prompt, return response |

## Open Questions (Resolved)

~~1. **Request building location**: Should `build-request` move to session?~~
**Answer**: Yes. Profile/tool config should be passed into `session-dispatch` or stored in session metadata, not read from buffer-local variables.

~~2. **Tool call processing**: Should session drive tool execution?~~
**Answer**: Yes. Session executes tools headlessly, emits events for UI updates.

~~3. **Loop management**: Should session own the agent loop?~~
**Answer**: Yes. Session drives the full loop, emits `checkpoint-requested` when user confirmation needed.

~~4. **Cancel semantics**: Should dispatch track handle for abort?~~
**Answer**: Yes. `benedict-session-cancel` should abort the provider request via the stored handle.

## Remaining Questions

1. **Checkpoint UX**: How should headless frontends (CLI, daemon) handle checkpoint prompts? Auto-continue with limits? Queue for later?

2. **Tool isolation**: Should session use flywire for all tool execution, or only when explicitly requested?

3. **Configuration source**: Should session store profile/model/tools at creation time, or accept them per-dispatch?

4. **Multi-frontend sync**: If two frontends are attached, how do checkpoint prompts work? First responder wins?

## Appendix: Callback Data Structures

### on-success Result Plist
```elisp
(:message (:role 'assistant
           :content "response text"
           :tool-calls [(:id "call-1" :name "tool" :arguments {...})])
 :model "claude-3-sonnet"
 :provider 'openrouter
 :usage (:prompt_tokens 100 :completion_tokens 50 :total_tokens 150)
 :thinking [(:type "reasoning.text" :text "...")]
 :latency 1.234
 :empty-response nil)
```

### on-error Payload Plist
```elisp
(:type 'api           ; 'network | 'http | 'api | 'decode | 'dispatch
 :message "Error description"
 :status 400          ; HTTP status if applicable
 :code "invalid_request"
 :retryable t
 :provider 'openrouter)
```

### on-delta Payload Plist
```elisp
;; Content delta
(:kind 'content-delta
 :text "chunk of text"
 :message-id "req-123"
 :provider 'openrouter
 :model "claude-3-sonnet")

;; Thinking delta
(:kind 'thinking-delta
 :text "reasoning chunk"
 :id "thinking-1"
 :type "reasoning.text")
```
