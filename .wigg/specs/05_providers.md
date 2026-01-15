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
- **`send`** (function): Dispatches a request.
- **`cancel`** (function): Aborts an inflight request.

## 2. Request/Response Protocol

### 2.1 Request Payload
Standardized plist passed to `send`:
- `:messages` (list): Chronological message history.
- `:model` (string): Model identifier (e.g., "anthropic/claude-3-opus").
- `:tools` (list): List of tool definitions (JSON Schema).
- `:stream` (bool): Whether to request streaming.

### 2.2 Response Callback (`on-success`)
Called with a result plist:
- `:message` (plist): The final message object.
    - `:role` ('assistant)
    - `:content` (string)
    - `:tool-calls` (list, optional)
- `:usage` (plist): Token usage stats.
- `:model` (string): The actual model used.

### 2.3 Streaming Callback (`on-delta`)
Called repeatedly with chunks:
- `:content` (string): Text delta.
- `:tool-calls` (list): Partial tool call structures (if supported).

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
