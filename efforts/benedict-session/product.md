# benedict-session: Spec & Shaping

## Overview
Introduce `benedict-session` as a first-class, in-memory data structure that owns the state of a Benedict conversation *and* its runtime (streaming/pending questions/tool activity), decoupling that state from `benedict-chat` buffers. The existing chat buffer remains the primary UI, but becomes a *frontend* attached to a session rather than the session itself.

This effort intentionally focuses on **in-daemon correctness and session separation**. Persistence and “remote client” ergonomics (e.g., `emacsclient` workflows + notifications) are follow-up phases that become straightforward once `benedict-session` is real.

## Terminology: Chat vs Session vs Thread
This effort is primarily about separating “conversation state” from “UI state”. The naming can get confusing because “chat” is currently both.

Working definitions:
- **Chat**: the UI buffer (`benedict-chat-mode`) and its presentation concerns (rendering, markers, input UX).
- **Thread / conversation**: the durable *data* that defines “what the chat is about” (messages + metadata like title/tags/context).
- **Session**: the *runtime* around a thread (streaming in-flight state, pending questions, tool activity), plus a stable identity for attach/detach.

Pragmatically:
- If we only introduce one new abstraction, `benedict-session` will be that abstraction and it will contain both the thread data and runtime fields.
- The doc uses “thread” as a conceptual subset of a session to keep persistence discussions crisp: persistence mostly cares about the thread, not the transient runtime.

## Motivation & Use Cases
- **Daemon-first Benedict**: run Emacs as a daemon on a remote VM; detach/reattach clients without losing the agent’s state.
- **Multiple parallel sessions**: exploratory threads, refactors, and PR review sessions can coexist without worktree overhead.
- **Non-blocking “needs input” flow**: when the agent requires user input, it should transition to a “waiting” state that survives disconnects.
- **Future follow-ups enabled by design**:
  - Disk-backed session persistence and restoration.
  - Remote-friendly clients (`emacsclient --eval`, TUI clients, notifications/webhooks).

## Problem Statement
Today, Benedict’s session state is effectively *buffer-scoped and ephemeral*:
- The chat buffer is the de facto session identity.
- Runtime state (streaming, message accumulation, pending tool calls, etc.) tends to live in buffer-local variables and/or transient markers.
- If the buffer is killed (or if Emacs exits), the session is gone.

This blocks:
- A clean daemon workflow (detach/reattach without losing session state).
- A session registry and session discovery/switching UX.
- Persistence that is not “serialize a UI buffer”.

## Desired End State (This Effort)
### Conceptual model
- `benedict-session` is the source of truth.
- A chat buffer is a *view/controller* attached to a `benedict-session`.
- Sessions exist without any UI attached (headless operation is possible even if not yet exposed).

### Core properties
- Unlimited sessions in a running Emacs (daemon).
- Sessions have stable identities (IDs) independent of buffers.
- UI attach/detach is safe and does not corrupt session state.
- The session can enter a “waiting for input” state without forcing minibuffer interaction.

## Non-Goals (Explicitly Out of Scope)
To keep this effort tightly scoped, we are **not** doing the following here:
- **Disk persistence**: no serialization/restore on restart (covered as a follow-up phase).
- **Remote client UX**: no push notifications, webhooks, Termius/mosh niceties, or “answer from phone” commands (covered as a follow-up phase).
- **Agent orchestration**: no multi-agent dispatcher, worktree automation, or tmux window management.
- **Tool permission model redesign**: no new sandbox policy; no changes to how tools are approved beyond what’s required to support sessions.
- **Provider protocol redesign**: no breaking change to provider request/response contracts unless required to move state out of buffers.

## Glossary
- **Chat**: a UI buffer running `benedict-chat-mode`.
- **Thread**: the durable conversation data (messages + metadata) that a human thinks of as “the chat”.
- **Session**: a `benedict-session` instance, the runtime wrapper around a thread (including in-flight state).
- **Frontend**: an Emacs UI that renders a session and lets the user interact with it (initially `benedict-chat-mode`).
- **Registry**: an in-memory index of sessions (create/list/get/delete).
- **Waiting state**: the session has an unanswered question and cannot continue safely.

## Scope: Data Model
### `benedict-session` fields (proposed)
This effort defines the shape; implementation can adjust fields as refactors reveal what’s truly needed.

Required:
- `id`: stable identifier (string; UUID-ish).
- `created-at`, `updated-at`: timestamps.
- `title`: string; can be user-set, provider-suggested, or derived from the first prompt.
- `messages`: normalized message list (see below). (Conceptually, this is the “thread”.)
- `state`: one of `idle`, `streaming`, `waiting`, `error`, `cancelled`.

Optional context:
- `root`: project root directory (or nil for exploratory sessions).
- `provider`, `model`, `profile`: provider configuration snapshot used for requests.
- `meta`: plist for tags, originating buffer/file, etc.

Runtime state (in-memory only):
- `pending-question`: nil or plist describing the outstanding question.
- `inflight`: request/stream metadata (provider request id, tool call accumulation, etc.).
- `draft`: nil or a “streaming draft” object used while receiving deltas; committed into `messages` on finalization.
- `last-error`: last error object/message, if any.
- `attached-frontends`: weak association to buffers (e.g., a list of live buffers).

### Normalized message shape (proposed)
Keep the schema close to what the providers already consume/produce, but normalize enough that multiple frontends can render it consistently.

Message minimum:
- `:role` (`system`/`user`/`assistant`/`tool`)
- `:content` (string, possibly empty if tool-only)
- `:id` and/or `:timestamp` (optional but helpful for stable rendering)

Tool call support (optional, provider-dependent):
- `:tool-calls` (list of normalized tool call objects)
- `:tool-results` (list of tool results/observations)

### Normalized tool call shape (proposed)
Frontends and persistence should not depend on provider-specific tool-call shapes. Normalize tool calls into a minimal internal schema and retain provider-specific payload in `:raw` for round-tripping and debugging.

Minimum tool call:
- `:id` (string; stable within the session)
- `:name` (string; tool/function name)
- `:arguments` (plist/alist; decoded from JSON when possible)
- `:arguments-text` (string; raw JSON string when decoding fails or for exact round-trip)
- `:state` (`proposed` / `approved` / `running` / `done` / `error`)
- `:result` (optional; tool output/metadata, if stored inline rather than as `tool` role messages)
- `:raw` (provider-specific payload needed to reconstruct provider requests)

Important: this effort should avoid a large “message schema rewrite”; the goal is to *move ownership* of the session, not perfect the shape.

## Scope: Session Registry
Introduce a registry (in-memory) responsible for:
- Creating sessions.
- Looking up sessions by id.
- Listing sessions (for later UI and for debugging).
- Deleting/archiving sessions (archiving can be a no-op placeholder in phase 1).

### API surface (proposed)
- `(benedict-session-create &rest init-plist) -> session`
- `(benedict-session-get id) -> session|nil`
- `(benedict-session-list &optional predicate) -> sessions`
- `(benedict-session-delete id) -> t|nil`
- `(benedict-session-touch session)` updates `updated-at`, indexes, etc.

## Scope: Frontend Integration (benedict-chat as a frontend)
### What changes in principle
- The chat buffer should store only a pointer (`session-id` or `session` reference) and presentation state.
- Actions like “send prompt” operate on the attached session (which owns history + runtime), not on buffer-local history.

### What must remain stable
- `M-x benedict-chat` still opens a familiar buffer experience.
- Existing provider behavior and tool flows should remain functionally equivalent from the user’s perspective.

### Session selection rules (initial proposal)
Prefer a single “router” command (`benedict-chat`) with prefix-arg behavior, in line with common Emacs conventions:
- `M-x benedict-chat` (no prefix):
  - If **no sessions exist**: create a new session and open its chat buffer.
  - If **exactly one session exists**: open that session’s chat buffer.
  - If **multiple sessions exist**: prompt with a session picker (e.g., `completing-read`) and open the selected session.
  - Implementation detail: the picker should make `waiting` sessions easy to spot/select (e.g., annotate candidates, or sort them first).
- `C-u M-x benedict-chat`: always create a new session and open its chat buffer (never reattach).

This keeps “open chat” fast and predictable while still supporting async/detached workflows via a low-friction session picker.

## Scope: Eventing & “Needs Input”
To support multiple frontends and eventual notifications, define session events:
- `message-added`, `message-updated` (stream deltas), `state-changed`
- `draft-started`, `draft-updated`, `draft-finalized` (optional; can also be represented as message-updated/message-added)
- `question-raised`, `question-answered`
- `error`

Proposed hooks:
- `benedict-session-event-hook` receives an event plist including `:session-id`, `:type`, and relevant payload.
- `benedict-session-ask-user-hook` is a convenience hook specifically for “question raised” events (future webhook integration point).

This effort does not implement push notifications, but it should ensure there is a reliable hook point.

## Success Criteria (This Effort)
Functional:
- Chat buffers can be killed and reopened while the underlying session remains valid (as long as Emacs is alive).
- Multiple sessions can exist concurrently and be discoverable via a basic listing command (even if not yet a full UI).
- Session state transitions (`idle` ↔ `streaming` ↔ `waiting`) are driven by session state, not buffer heuristics.

Quality:
- Byte-compiles cleanly on Emacs 27.1+.
- Tests cover creation/lookup and a minimal “append message triggers event” path.

## Follow-up Phases (Not Implemented Here)
### Phase 2: Persistence
Goal: optional on-disk persistence so sessions survive daemon restarts *without losing “where we were”*.

Likely shape:
- Persist two related things:
  - **Thread log**: the durable conversation data (messages + metadata).
  - **Runtime snapshot**: enough session runtime state to restore a meaningful state machine (e.g., “waiting for input”).
- Serialize into an Emacs-readable form (sexp or JSON).
- Store under an XDG-ish path with a user-configurable directory.
- Support “archive” vs “active” sessions and retention policies.

What should be persisted (runtime snapshot examples):
- `state` (at least `idle`/`waiting`/`error`/`cancelled`)
- `pending-question` (question text, choices, correlation ids, when asked)
- minimal “resume context” (e.g., which message the question relates to)
- last-selected provider/model/profile (references, not secrets)

What should *not* be persisted (or should be treated as non-resumable):
- active network processes, timers, and streaming connections
- provider request handles / raw SSE buffers
- partially executed tool side effects (unless tools become resumable/idempotent by design)

Restore semantics (important to define early):
- If a session was `waiting`, it should restore as `waiting` with the same `pending-question`.
- If a session was `streaming` when persisted, restore should *not* attempt to “reconnect” mid-stream; instead transition to a safe recoverable state (e.g., `idle` with a warning event, or `error` with “retry last request” affordance).
- If there were queued tool calls awaiting approval/execution, restore should keep them queued but require explicit user confirmation to re-run.
- If there was a streaming `draft`, restore may either discard it or keep it as an explicitly-marked partial assistant message (decision deferred; default to discarding unless we have a strong UX reason to keep partial output).

Non-goals for persistence follow-up:
- Do not store secrets (provider keys) in persisted data; sessions should reference profiles, not embed credentials.

### Phase 3: Remote Client Frontends
Goal: allow interacting with sessions without opening the full chat UI.

Examples:
- `emacsclient --eval` commands to list sessions, show status, answer pending questions.
- Notification integration via `benedict-session-ask-user-hook` (Poke/ntfy/Slack).
- Minimal terminal UI that can render “needs input” and accept an answer.

## Open Questions (To Resolve During Research/Implementation)
- [Answered] `benedict-session` should be a `cl-defstruct` (fast, explicit schema; avoids `eieio`/plist complexity).
- [Answered] Streaming deltas should accumulate into a `draft` object, then be committed to `messages` on finalization (avoid mutating committed history during streaming).
- [Answered] Tool calls should be normalized into a minimal internal schema and must retain provider payload in `:raw` for round-tripping.
- [Answered] `benedict-chat` should route based on active session count, and `C-u` should force creating a new session.
