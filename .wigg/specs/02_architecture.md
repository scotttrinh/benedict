# Architecture Specification

This document details the architectural components of Benedict and their interactions.

## 1. Component Diagram (Conceptual)

```
[ User Input / Commands ]
            |
            v
[ Chat UI / VUI Frontend ] <----> [ Session Store / Branching / Compaction ]
            ^                                 ^
            | (Stable events)                | (Loads/saves transcript)
            |                                 |
            +------------ [ Agent Core ] -----+
                              |      ^
                              |      |
                       (Dispatch)    | (Tool results / lifecycle)
                              v      |
                      [ Provider Adapter ]
                              |
                              v
                        [ External LLM ]
                              ^
                              | (Tool calls)
                              v
                     [ Tool Runtime / Harness ]
                              ^
                              |
                     [ Extension Runtime ]
                              |
                              v
                     [ Flywire / Emacs APIs ]
```

## 2. Core Components

### 2.1 Agent Core (`benedict-session.el`, target shape)
- **Role:** The smallest headless runtime.
- **Responsibilities:**
    - Own the loop state machine.
    - Dispatch provider requests.
    - Execute tools through the harness/tool runtime.
    - Emit stable lifecycle events.
- **Non-Responsibilities:**
    - Rendering.
    - Buffer management.
    - Session file layout.
    - Extension discovery.
- **State Machine:**
    - `idle`: Waiting for user input.
    - `running`: Active agent loop (dispatching requests, processing tools).
    - `streaming`: Receiving data from a provider.
    - `checkpoint`: Paused waiting for user confirmation (turn limits, etc.).
    - `error`: Stopped due to a failure.
    - `cancelled`: Stopped by user.
- **Data Structure:** runtime state containing:
    - canonical typed messages
    - draft/stream accumulator
    - inflight request handle
    - loop configuration and budgets
    - telemetry and last-result metadata
- **Event System:** Emits stable events (`message-start`, `message-update`, `message-end`, `tool-started`, `tool-completed`, `checkpoint-requested`, etc.) that frontends and extensions subscribe to.

### 2.2 Session Store / Persistence
- **Role:** Durable transcript management.
- **Responsibilities:**
    - Save/load sessions using a provider-agnostic transcript format.
    - Support branching from arbitrary history points.
    - Support summaries/compaction metadata without destroying raw history.
    - Preserve extension-specific metadata without polluting the core message model.
    - Record model/provider changes as session events rather than rewriting history.
- **Design Notes:**
    - This should be a first-class layer, not a later add-on.
    - JSONL or s-expression transcripts are preferred over early SQLite lock-in.
    - SQLite may exist as an index/search accelerator, not the only source of truth.
    - Raw provider request/response payloads must not be the canonical persisted format.

#### Persistence Contract

The persisted session should be built from canonical internal entries, for example:
- message entries
- model/provider change entries
- thinking-level or verbosity changes
- branch summary / compaction entries
- extension-owned custom entries
- audit/provenance entries when needed

This is the key enabler for:
- switching models mid-session
- replaying the same chat through different providers
- compacting or branching without provider lock-in
- preserving extension and UI metadata without leaking it into provider payloads

#### Replay / Reconstruction

When a session is reloaded:
- the session store reconstructs canonical internal messages from the entry stream/tree
- the current model/provider is derived from the latest explicit model/provider change entry or message metadata
- only at request time are canonical messages transformed into provider-ready messages

This implies a two-step normalization pipeline:

1. **Session entries -> canonical internal messages**
2. **Canonical internal messages -> provider-ready request messages**

Provider-specific cleanup belongs in step 2, not in the persisted transcript.

### 2.3 Chat UI (`benedict-chat.el`)
- **Role:** View-Controller for the Session.
- **Buffer Management:** Maintains the `*Benedict Chat*` buffer.
- **Event Handling:** Subscribes to core/runtime events to trigger re-renders.
- **Commands:** Exposes interactive commands (`benedict-chat-send-prompt`, `benedict-chat-cancel`, message queueing, retry, branch/resume).
- **Context:** Manages buffer-local context (e.g., attached file slices) before they are committed to the Session.

### 2.4 Rendering Engine
- **Role:** Visual presentation.
- **Mechanism:** VUI component tree plus stable keys/identifiers for typed blocks.
- **Features:**
    - Markdown/code rendering for typed assistant text blocks.
    - Distinct renderers for thinking, tool calls, tool results, checkpoints, queued messages, and subagent blocks.
    - Action-bearing tool result UIs (open file, jump to hunk, apply patch, visit Org node, rerun command).

### 2.5 Provider Layer (`benedict-provider.el`)
- **Role:** Abstraction over LLM APIs.
- **Interface:**
    - `dispatch(request)`: Asynchronous send.
    - `abort(handle)`: Cancel active request.
    - `capabilities`: Feature flags (streaming, json-mode, etc.).
- **Implementations:**
    - `openrouter`: HTTP/SSE streaming via `curl` or `url-retrieve`.
    - `gemini`: OAuth2 + REST API (non-streaming currently).
    - `ollama`: Local API.
    - `fake`: For testing/dev.

### 2.6 Tooling (`benedict-tools.el`)
- **Role:** Functional capabilities exposed to the Agent.
- **Registry:** Maps tool IDs to:
    - Implementation function (Elisp).
    - JSON Schema (for LLM definition).
    - Effect and scope metadata.
    - Approval metadata (legacy `auto`/`confirm`/`always`) plus optional permission predicate evaluation.
- **Execution:**
    - Invoked by the agent core when the LLM requests a tool call.
    - Results are normalized into a typed tool result structure before being fed back into history.

### 2.7 Harness / Tool Runtime
- **Role:** Safety and enforcement boundary.
- **Responsibilities:**
    - Apply scope/budget policy before tool execution.
    - Record auditable events for tool calls and side effects.
    - Normalize permission denials and scope denials into structured results the model can recover from.
    - Distinguish routine allowed work from privileged scope expansion.

### 2.8 Isolation (`benedict-flywire.el`)
- **Role:** UI and execution isolation.
- **Mechanism:** Creates a dedicated "Agent Frame" or uses a headless environment.
    - Executes potentially disruptive operations (buffer switching, file opens) in a controlled frame/environment.
    - Purpose: Prevent the agent from hijacking the user's window layout or active buffers.

### 2.9 Extensibility
- **Role:** Enabling user customization.
- **Public API:**
    - register tools, providers, profiles, context providers, renderers, prompts, and lifecycle hooks
    - allow dynamic tool registration at runtime
    - allow extension-owned session metadata and UI state
- **Hooks:**
    - Pre-dispatch, context transform, pre-tool, post-tool, persistence, and UI hooks
    - Middleware pattern for message/event interception

### 2.10 Message / Event Protocol
- **Role:** The central compatibility layer between runtime, UI, persistence, and extensions.
- **Requirements:**
    - Typed message blocks instead of loosely-shaped plists.
    - Stable event names and payloads.
    - Provider-specific payloads translated only at the provider boundary.
    - Extension-specific messages/entries supported without leaking into provider payloads unless explicitly transformed.
    - Assistant messages may retain provider/model metadata for provenance, but their content model must remain provider-agnostic enough to survive replay through another backend.

### 2.11 Sub-Agents & Delegation
- **Role:** Keep the main conversation context clean by delegating bounded sub-tasks to subagents.
- **Mechanism:** The main session can spawn ephemeral sub-sessions with:
    - reduced context window (task-local messages only)
    - stricter budgets and narrower tool access
    - a well-defined output contract (summary + artifacts)
    - explicit visibility in transcript and UI as subagent activity, not anonymous noise

### 2.12 Agent Programs (Programmable Loop)
- **Role:** Allow users (and the project) to "program" the loop itself (Ralph Wiggum Loop style).
- **Mechanism:** A loop program is data that configures:
    - step types (observe/plan/act/verify/capture)
    - when to spawn subagents
    - what tool categories are permitted at each step
    - stop/continue conditions and checkpoint policy

## 3. Data Flow

1.  **User Turn:**
    - User types in Chat Buffer.
    - `C-c C-s` triggers `benedict-chat-send-prompt`.
    - Typed user message is added to the session store/runtime.
    - Agent core transitions to `running`.
    - Agent core builds request payload from provider-agnostic messages via provider adapter.
    - Agent core dispatches to Provider.

2.  **Streaming Response:**
    - Provider receives chunks (delta).
    - Provider callbacks trigger agent core streaming handlers.
    - Agent core updates internal Draft/partial assistant message.
    - Agent core emits message update events.
    - Chat UI receives events, updates buffer via typed block renderers.

3.  **Tool Execution:**
    - Provider finishes with a `tool_calls` payload.
    - Agent core parses call.
    - Harness checks scope/budgets/effects policy (may require scope expansion).
    - Tool runtime invokes Tool (via `benedict-tools` or extension-registered tools).
    - Tool runs (potentially in `flywire` context).
    - Tool returns normalized result (text/json/actions/metadata/effects summary).
    - Agent core adds Tool Result to history.
    - Session store persists the new branch head.
    - Loop Logic decides to continue or stop.

4.  **Completion:**
    - Provider finishes with content (no tools) or Loop decides to stop.
    - Agent core transitions to `idle`.
    - Final message committed to history.
    - Session store persists completion metadata.
