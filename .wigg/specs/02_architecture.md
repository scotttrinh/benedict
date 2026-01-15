# Architecture Specification

This document details the architectural components of Benedict and their interactions.

## 1. Component Diagram (Conceptual)

```
[ User Input (Chat Buffer) ] <---> [ Chat UI Controller ] <---> [ Session Manager ]
                                          ^                            |
                                          | (Events)                   | (Dispatch)
                                          |                            v
                                     [ Renderer ]               [ Provider Adapter ]
                                                                       |
                                                                       v
                                                                 [ External LLM ]
                                                                       ^
                                                                       | (Tool Calls)
                                                                       v
[ Flywire Isolation ] <--- [ Tool Registry ] <--- [ Session Loop Logic ]
```

## 2. Core Components

### 2.1 Session Manager (`benedict-session.el`)
- **Role:** The central source of truth. It owns the conversation history and state machine.
- **State Machine:**
    - `idle`: Waiting for user input.
    - `running`: Active agent loop (dispatching requests, processing tools).
    - `streaming`: Receiving data from a provider.
    - `checkpoint`: Paused waiting for user confirmation (turn limits, etc.).
    - `error`: Stopped due to a failure.
    - `cancelled`: Stopped by user.
- **Data Structure:** `benedict-session` struct containing:
    - Messages (chronological list).
    - Draft (accumulator for streaming content).
    - Inflight request handle.
    - Loop configuration (limits).
    - Telemetry (token usage, timing).
- **Event System:** Emits signals (`message-added`, `draft-updated`, `tool-started`, etc.) that frontends (UI) subscribe to.

### 2.2 Chat UI (`benedict-chat.el`)
- **Role:** View-Controller for the Session.
- **Buffer Management:** Maintains the `*Benedict Chat*` buffer.
- **Event Handling:** Subscribes to Session events to trigger re-renders.
- **Commands:** Exposes interactive commands (`benedict-chat-send-prompt`, `benedict-chat-cancel`, etc.).
- **Context:** Manages buffer-local context (e.g., attached file slices) before they are committed to the Session.

### 2.3 Rendering Engine (`benedict-chat-render.el`)
- **Role:** Visual presentation.
- **Mechanism:** Uses markers ("Sentinel Pattern") to update regions of the buffer safely during streaming without disturbing user cursor or other content.
- **Features:**
    - Markdown-lite rendering (font-lock for code blocks, bold/italic).
    - SVG Badges for roles, status, and tools.
    - `magit-section` for foldable blocks (thinking, tool calls).

### 2.4 Provider Layer (`benedict-provider.el`)
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

### 2.5 Tooling (`benedict-tools.el`)
- **Role:** Functional capabilities exposed to the Agent.
- **Registry:** Maps tool IDs to:
    - Implementation function (Elisp).
    - JSON Schema (for LLM definition).
    - Approval Policy (`auto`, `confirm`, `always`).
- **Execution:**
    - Invoked by the Session when the LLM requests a tool call.
    - Results are fed back into the conversation history.

### 2.6 Isolation (`benedict-flywire.el`)
- **Role:** Safety sandbox.
- **Mechanism:** Creates a dedicated "Agent Frame" or uses a headless environment.
    - Executes tools in a controlled frame/environment.
    - Purpose: Prevents the agent from accidentally modifying the user's active buffers or window configuration during complex tasks. Tools operate within this isolated context.

### 2.7 Persistence Layer
- **Role:** Long-term memory and history.
- **Mechanism:**
    - Primary: File-backed storage (JSONL/Sexp) per project (`.benedict/` directory).
    - Secondary/Index: SQLite database (`sqlite.el`) for fast searching and history browsing across projects.
- **Data:**
    - Threads (Messages, Tool Calls, usage stats).
    - Session Metadata (Profiles used, outcomes).

### 2.8 Extensibility
- **Role:** Enabling user customization.
- **Public API:**
    - `benedict-register-tool`: Add custom user scripts as tools.
    - `benedict-register-provider`: Add custom backends.
    - `benedict-register-profile`: Define custom system prompts and constraints.
- **Hooks:**
    - Pre-dispatch and Post-dispatch hooks for transforming messages or handling results.
    - Middleware pattern for message interception.

## 3. Data Flow

1.  **User Turn:**
    - User types in Chat Buffer.
    - `C-c C-s` triggers `benedict-chat-send-prompt`.
    - Message added to Session.
    - Session transitions to `running`.
    - Session builds request payload (system prompt + history).
    - Session dispatches to Provider.

2.  **Streaming Response:**
    - Provider receives chunks (delta).
    - Provider callbacks trigger Session `on-delta`.
    - Session updates internal Draft.
    - Session emits `draft-updated`.
    - Chat UI receives event, updates buffer via Renderer (appending text).

3.  **Tool Execution:**
    - Provider finishes with a `tool_calls` payload.
    - Session parses call.
    - Session checks Approval Policy (may prompt user).
    - Session invokes Tool (via `benedict-tools`).
    - Tool runs (potentially in `flywire` context).
    - Tool returns result (text/json).
    - Session adds Tool Result to history.
    - Session Loop Logic decides to continue (recurse) or stop.

4.  **Completion:**
    - Provider finishes with content (no tools) or Loop decides to stop.
    - Session transitions to `idle`.
    - Final message committed to history.
