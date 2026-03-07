# Providers Specification

This document defines the Provider Abstraction Layer, enabling Benedict to support multiple LLM backends.

## 1. Provider Interface (`benedict-provider.el`)

A Provider is a struct implementing the following contract:

- **`id`** (symbol): Unique identifier (e.g., `'openrouter`).
- **`name`** (string): Display name.
- **`capabilities`** (plist): Feature flags.
    - `:streaming` (bool)
    - `:tools` (bool) - Does it support native function calling?
    - `:json-mode` (bool)
    - `:transcript-format` (symbol/string, optional) - Provider-native transcript schema, if any.
- **`send`** (function): Dispatches a request.
- **`cancel`** (function): Aborts an inflight request.

## 2. Request/Response Protocol

### 2.1 Request Payload
Standardized plist passed to `send`:
- `:messages` (list): Chronological provider-ready message history derived from Benedict's internal message model.
- `:model` (string): Model identifier (e.g., "anthropic/claude-3-opus").
- `:tools` (list): List of tool definitions (JSON Schema).
- `:stream` (bool): Whether to request streaming.

### 2.2 Response Callback (`on-success`)
Called with a result plist:
- `:message` (plist): The final message object.
    - `:role` ('assistant)
    - `:content` (string or typed content blocks before normalization)
    - `:tool-calls` (list, optional)
- `:usage` (plist): Token usage stats.
- `:model` (string): The actual model used.

### 2.3 Streaming Callback (`on-delta`)
Called repeatedly with chunks:
- `:content` (string): Text delta.
- `:tool-calls` (list): Partial tool call structures (if supported).

### 2.4 Transcript Serialization (Important, Not a v0.1 Blocker)

Persistence should be able to reuse existing, widely-used transcript formats where possible.

Requirements:
- Benedict maintains a provider-agnostic internal message model.
- Provider adapters are responsible for translating between internal messages and provider payloads.
- Benedict must not persist raw provider request/response bodies as the canonical chat history.
- Provider/model switches in a conversation should be represented as explicit session metadata/events, not by mutating older messages into the new provider's shape.
- Benedict can export/import transcripts via adapters to external schemas, such as:
  - OpenAI-style message arrays (role/content/tool messages)
  - Vercel AI SDK compatible transcript/message representations
  - Opencode-compatible transcript serialization (if available)
- The persistence layer can choose one canonical on-disk format, but adapters must exist so users can interop with other tooling.

### 2.5 Cross-Provider Replay and Model Switching

To support switching models/providers in the same chat, Benedict should use a layered approach:

1. Persist canonical internal messages and session events.
2. Reconstruct canonical history from persistence on resume/branch/replay.
3. Convert canonical history into LLM-compatible messages.
4. Apply provider-specific normalization only for the target model/provider.

Examples of provider-specific normalization that belong at replay/send time:
- dropping or degrading reasoning/thinking blocks that only the original model can replay safely
- normalizing tool-call IDs when one provider emits IDs another provider rejects
- synthesizing missing tool results or other repair messages when a target API requires stricter turn structure
- stripping provider-specific signatures or encrypted reasoning payloads that are meaningless cross-model

The provider layer should therefore support both:
- **forward translation**: internal messages -> provider request payload
- **cross-provider replay normalization**: canonical history -> provider-safe history

## 3. Supported Providers

### 3.1 OpenRouter
- **Transport:** HTTP/SSE.
- **Method:** `curl` (subprocess) preferred for robust streaming, or `url-retrieve` (native) fallback.
- **Auth:** Bearer token via `auth-source` or Env Var (`OPENROUTER_API_KEY`).
- **Features:** High model variety, standardized OpenAI-compatible API.

### 3.2 Vercel AI SDK
- **Transport:** HTTP/SSE.
- **Auth:** Bearer token via `auth-source` or Env Var.
- **Features:** Access to specific Vercel-hosted models.

### 3.3 Gemini
- **Transport:** REST API.
- **Capabilities:**
    - Streaming (via SSE/HTTP chunking) is the target implementation.
    - Native Function Calling.
- **Auth:** OAuth2 flow (via `google-oauth` or similar mechanism).
    - Requires Refresh Token management in `auth-source`.
    - Supports re-authentication flow inside Emacs.

### 3.4 Ollama
- **Transport:** Local HTTP (default `localhost:11434`).
- **Auth:** usually none.
- **Features:** Local, privacy-first models.

### 3.5 Fake
- **Purpose:** Testing and Development.
- **Behavior:** Echos input, simulates latency, simulates tool calls deterministically based on prompts.

## 4. Credential Management

Benedict adheres to strict security practices:
1.  **Never hardcode secrets.**
2.  **`auth-source` Priority:** Look in `~/.authinfo.gpg` first.
3.  **Env Var Fallback:** Look for specific env vars (e.g., `OPENROUTER_API_KEY`) second.
4.  **Filesystem Store:** Optional JSON store `~/.config/benedict/auth.json` (user preferred).

Secrets are loaded into memory only when needed and redacted from logs.
