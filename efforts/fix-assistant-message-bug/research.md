## Research: Provider → Chat → Tool Call Message Flow

This research captures the end-to-end data flow for assistant messages,
including streaming deltas, final messages, tool calls, and history updates.
It highlights where data shape transitions occur and where issues commonly
surface due to type/shape mismatches or mixed streaming/non-streaming paths.

### 1) Request Assembly and Tool Spec Hydration

- Chat requests are built in `benedict-chat.el:2323` (`benedict-chat--build-request`).
  - The request includes `:provider`, `:model`, `:profile`, `:tools`,
    and `:messages` (system + history).
  - Tool specs are hydrated from the registry in `benedict-chat.el:602`
    (`benedict-chat--resolve-tools`) and attached to the request.
- Tool specs originate in `benedict-tools.el:370` (`benedict-tools-register`).
  - Tool JSON schema conversion is centralized in
    `benedict-tools.el:115` (`benedict-tool-schema->json-parameters`).

Potential issues:
- Provider payload builders must accept a list of tool spec plists and
  serialize them to provider JSON. Any mismatch in schema shape or keys
  will propagate to provider payload encoding.

### 2) Provider Dispatch and HTTP Streaming Plumbing

- Dispatch entrypoint: `benedict-provider.el:58` (`benedict-provider-dispatch`).
- Each provider implements its own `--send` and determines streaming:
  - Vercel: `benedict-provider-vercel.el:191` (`benedict-provider-vercel--send`).
  - OpenRouter: `benedict-provider-openrouter.el:172`.
  - Ollama: `benedict-provider-ollama.el:150`.
- HTTP transport: `benedict-http.el:43` (`benedict-http-request`).
  - SSE framing: `benedict-http.el:187` and `benedict-http.el:193` emit
    `(on-delta event-type payload)`; `payload` is raw `data:` text.

Potential issues:
- Streaming mode depends on `:on-delta` being provided and/or request flags.
  If streaming is enabled but provider code assumes non-streaming results,
  control flow may bypass finalization paths.
- Any provider `:on-delta` adapter must accept the `(event-type payload)`
  signature from `benedict-http` and convert it to the chat-layer contract.

### 3) Provider Streaming: Parsing and Delta Normalization

#### Vercel
- SSE parsing (NDJSON or single JSON):
  `benedict-provider-vercel.el:279` (`benedict-provider-vercel--handle-sse-payload`).
- Streaming event handling:
  `benedict-provider-vercel.el:340` (`benedict-provider-vercel--stream-handle-json`).
  - Emits deltas by calling `on-delta` with keyword args:
    `:message-id`, `:kind`, `:text`.
  - `content-delta` and `thinking-delta` are derived from normalized choices.
- Delta normalization (including tool-call accumulation):
  `benedict-provider-vercel.el:410` (`benedict-provider-vercel--normalize-delta-choice`)
  calls `benedict-provider-vercel--accumulate-tool-calls-from-delta` at
  `benedict-provider-vercel.el:564`.

#### OpenRouter
- SSE parsing: `benedict-provider-openrouter.el:253`.
- Delta normalization and `on-delta` calls:
  `benedict-provider-openrouter.el:303` and `benedict-provider-openrouter.el:323`.
- Tool-call accumulation:
  `benedict-provider-openrouter.el:535`.

#### Ollama
- SSE parsing: `benedict-provider-ollama.el:228`.
- Delta normalization and `on-delta` calls:
  `benedict-provider-ollama.el:278` and `benedict-provider-ollama.el:298`.
- Tool-call accumulation:
  `benedict-provider-ollama.el:510`.

Potential issues:
- Provider streaming handlers generate keyword-argument calls to `on-delta`
  (not a single plist). Any chat handler must correctly unwrap or normalize.
- Tool-call chunks are accumulated across multiple deltas; if `:index`,
  `:id`, or `:function.arguments` are missing or partial in a different
  shape, accumulation can stall or create empty tool-call data.

### 4) Provider Finalization: Message + Tool Calls

#### Vercel
- Finalization constructs the final result at
  `benedict-provider-vercel.el:635` (`benedict-provider-vercel--finalize-stream`).
  - `tool-calls` are finalized from partials at
    `benedict-provider-vercel.el:593`.
  - `:message` contains `:role`, `:content`, and `:tool-calls`.

#### OpenRouter
- Finalization at `benedict-provider-openrouter.el:642`.
  - `tool-calls` finalized at `benedict-provider-openrouter.el:559`.

#### Ollama
- Finalization at `benedict-provider-ollama.el:617`.
  - `tool-calls` finalized at `benedict-provider-ollama.el:534`.

Potential issues:
- Final message assembly merges streamed content (`message-chunks`) and
  `final-message-text`. If both are empty but tool calls exist, the chat
  layer must still render tool blocks reliably.
- Tool-call argument decoding uses `json-parse-string`. If arguments are
  not valid JSON, tool-calls are dropped or become nil, which changes
  downstream UI expectations.

### 5) Chat Layer: Streaming Deltas

- `:on-delta` wrapper in chat dispatch:
  `benedict-chat.el:2556`.
  - Accepts `&rest payload`, unwraps if payload is list-wrapped, then
    calls `benedict-chat--handle-provider-delta`.
- Delta handler: `benedict-chat.el:2382`.
  - Updates streaming metadata and inserts:
    - `content-delta` via `benedict-chat--stream-insert-delta`
      after ensuring a streaming message exists.
    - `thinking-delta` via `benedict-chat--display-thinking-detail`.

Potential issues:
- The chat on-delta wrapper expects a plist (or wrapped plist). Provider
  callbacks pass keyword arguments. Unwrapping logic must convert
  `(&rest payload)` keyword/value pairs into a plist; if it treats the
  `&rest` list as a list of values, downstream code sees an unexpected
  shape.
- `benedict-chat--telemetry-streaming` uses payload metadata. If the payload
  is malformed, status/telemetry can fail or become inconsistent.

### 6) Chat Layer: Success Handling and Tool Calls

- Success handler: `benedict-chat.el:2420` (`benedict-chat--handle-provider-success`).
  - Extracts `result :message` and `message :tool-calls`.
  - Uses streaming or non-streaming path:
    - Streaming: updates existing streaming record and header.
    - Non-streaming: inserts a new assistant record.
  - Renders final thinking payloads before tools.
  - Executes tool calls via `benedict-chat--process-tool-calls`.
- Tool call processing: `benedict-chat.el:1831`.
  - Renders tool block: `benedict-chat.el:1673`.
  - Invokes tool: `benedict-chat.el:1768`.
  - Stores tool result in history: `benedict-chat.el:1771`.

Potential issues:
- Tool-call handling assumes `:tool-calls` is a list of plists with
  `:id`, `:name`, and `:arguments`. If providers emit missing keys
  or names that do not match registry IDs, tool execution fails or
  renders fallback UI.
- The streaming path updates an existing record; if the streaming record
  is missing or corrupted, tool blocks can end up detached from the
  assistant message section.

### 7) Tool Call Encoding for Provider Requests

- Provider serialization of tool specs:
  - Vercel: `benedict-provider-vercel.el:1010`.
  - OpenRouter: `benedict-provider-openrouter.el:1011`.
  - Ollama: `benedict-provider-ollama.el:967`.
- Provider serialization of tool call results:
  - Vercel: `benedict-provider-vercel.el:1075`.
  - OpenRouter: `benedict-provider-openrouter.el:1030`.
  - Ollama: `benedict-provider-ollama.el:1017`.

Potential issues:
- Tool call results are re-serialized for subsequent requests. If tool
  outputs store non-JSON-friendly values or nested data structures,
  request encoding can fail or silently omit fields.

### 8) Cross-Cutting Data Shape Assumptions

Data shapes that must remain consistent across layers:
- Streaming delta: keyword plist with `:kind`, `:text`, `:message-id`.
- Final result: plist with `:message` (containing `:content` and optional
  `:tool-calls`), plus `:provider`, `:model`, and optional `:usage`.
- Tool call: plist with `:id`, `:type`, `:name`, `:arguments` (plist).

Common mismatch points:
- Provider emits keyword arguments to `on-delta`, but chat expects a plist
  (or list-wrapped plist).
- Tool-call argument decoding returns nil on parse errors, producing tool
  calls with missing arguments and unexpected empty bodies.
- In streaming mode, partial tool call data accumulates across deltas;
  missing indices or partial function fields can lead to empty or
  malformed final tool-call structures.

## Investigation Notes (Session End)

Symptoms observed:
- Chat buffer shows: `ASSISTANT ERROR Vercel Wrong type argument: json-value-p, #[(&rest payload) ...]`
  which points at the `:on-delta` lambda in `benedict-chat--start-dispatch`
  (`benedict-chat.el:2556`), specifically the payload handling around
  `benedict-chat--handle-provider-delta`.

Paths checked (not fruitful or not directly causal yet):
- Provider request building in `benedict-chat--build-request`
  (`benedict-chat.el:2323`) only uses strings/lists, not seeing any obvious
  `json-value-p` traps.
- Vercel request serialization (`benedict-provider-vercel--encode-payload`,
  `benedict-provider-vercel--build-body`, `benedict-provider-vercel--serialize-message`)
  uses `json-encode`, not `json-serialize`. No direct `json-value-p` usage
  found in codebase (rg search); only referenced in older dev logs.
- Tool registry/spec building (`benedict-tools.el`) appears JSON-safe
  (alists/plists only); no non-JSON values in default tool schemas.
- `benedict-http` streaming parser emits `(on-delta event-type payload)`;
  Vercel/OpenRouter/Ollama adapters parse JSON and then call their
  `on-delta` with keyword args. This matches the expected calling convention,
  but the chat wrapper still treats the `&rest` list as a plist without
  converting it, which can cause type/shape mismatches.

Likely culprit(s) to revisit:
- `benedict-chat--start-dispatch` `:on-delta` wrapper currently:
  - Unwraps only when payload is list-wrapped (list of list), but does not
    convert keyword/value pairs from `&rest` into a proper plist if needed.
  - This can cause `benedict-chat--handle-provider-delta` to receive a list
    that is not a plist (or has unexpected elements), leading to errors when
    downstream code expects JSON-safe values or plists.
  - Consider normalizing `payload` into a plist (e.g., when `&rest payload`
    is a flat keyword/value list) before calling the handler.

Other observations:
- The error message references `json-value-p`; this is a `json-serialize`
  type validator. There is no direct `json-serialize` call in the codebase,
  so the error may be thrown indirectly by logging or UI render paths when
  handling malformed payloads (possibly via `lgr` or UI JSON encode usage).
- No buffer-specific argument passing issues were found yet; no explicit
  `:buffer` argument exists in provider dispatch or HTTP callbacks.
  The suspected "missing buffer arg" might actually be about the on-delta
  payload shape instead.

Recommended next steps for future session:
- Add a small normalization helper in `benedict-chat--start-dispatch` to
  coerce `&rest payload` into a plist (when the provider calls `funcall` with
  keyword args), and re-run to see if the error disappears.
- If the error persists, capture a backtrace from the chat buffer (or via
  `toggle-debug-on-error`) to see which function calls `json-serialize`.
