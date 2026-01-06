---
date: 2025-12-31T20:33:05-05:00
researcher: Codex (research agent)
git_commit: b3a58d1e4f86692452cddd37e64128c8a652a8fe
branch: main
repository: benedict
topic: "HTTP response handling across providers"
tags: [research, codebase, http, providers]
status: draft
last_updated: 2025-12-31
---

# Research: HTTP response handling across providers

**Date**: 2025-12-31T20:33:05-05:00  
**Researcher**: Codex (research agent)  
**Git Commit**: b3a58d1e4f86692452cddd37e64128c8a652a8fe  
**Branch**: main

## Research Question
Take stock of every place we parse HTTP responses today so we can align JSON-to-plist/alist handling and streaming message parsing across providers. Document how each provider structures server responses and how our handlers currently consume them.

## Summary
- `benedict-http.el` owns the curl process lifecycle and SSE framing; it does not parse JSON, instead delivering the raw 200 body (non-stream) or `data:` payload strings (streaming) to provider callbacks (`benedict-http.el:43-195`).
- The Gemini provider parses every HTTP response (token and chat) directly into plists via `json-parse-string`, wraps Cloud Code payloads, and never enables streaming (`benedict-provider-gemini.el:361-742`).
- OpenRouter, Vercel, and Ollama share the same structure: streaming SSE chunks are parsed into plists and accumulated in a request-state table, while non-streaming HTTP responses are decoded into alists first and later turned into plist-based messages (`benedict-provider-openrouter.el:222-820`, `benedict-provider-vercel.el:242-852`, `benedict-provider-ollama.el:201-823`).
- The fake provider never performs HTTP; it fabricates plist-based messages/usage data and exercises the callback contract via timers, so it does not influence JSON parsing decisions (`benedict-provider-fake.el:194-330`).

## Detailed Findings

### Shared HTTP Layer (`benedict-http.el`)
- `benedict-http-request` stores request metadata (URL, headers, whether streaming) in a context plist and spawns `curl`; on success it simply invokes `on-success` with the buffered body, never attempting JSON decoding (`benedict-http.el:43-119`, `benedict-http.el:219-235`).
- When `:stream` is non-nil the filter accumulates text until it finds a blank-line delimiter, then emits the combined `data:` payload and optional `event:` name to the provider’s `on-delta`; each provider is responsible for JSON parsing and deciding whether `[DONE]` terminates the stream (`benedict-http.el:155-195`).
- curl exit code 22 (HTTP 4xx/5xx) flows through `on-error` with the raw body to let providers parse error JSON themselves; other curl failures surface as `:process` errors with captured stderr (`benedict-http.el:236-258`).

### Gemini Provider (`benedict-provider-gemini.el`)
- OAuth/Tokens: `benedict-provider-gemini--token-request` reads the entire response buffer from `url-retrieve-synchronously`, extracts the HTTP status manually, and returns a plist with `:status`, `:body`, and an optional debug buffer (`benedict-provider-gemini.el:361-388`). Every token/body string is decoded via `benedict-provider-gemini--parse-json`, which forces plist objects and plain lists for arrays (`benedict-provider-gemini.el:390-410`).
- Chat completions: `benedict-provider-gemini--handle-success` always parses the body into a plist, unwraps the `:response` field if Cloud Code wrapped it, reduces Gemini `parts` vectors down to a single `:content` string, and emits a plist result with `:message`, `:usage`, and the raw Gemini payload (`benedict-provider-gemini.el:605-645`). Error payloads are similarly decoded into plists for message/code extraction before invoking `on-error` (`benedict-provider-gemini.el:651-692`).
- Transport setup: `benedict-provider-gemini--send` logs the POST metadata and calls `benedict-http-request` with `:stream nil` so every reply travels through the non-streaming callback path; there is no SSE parser for Gemini today (`benedict-provider-gemini.el:694-744`).

### OpenRouter Provider (`benedict-provider-openrouter.el`)
- Request dispatch: `benedict-provider-openrouter--perform-request` resolves the Bearer token, assembles headers, and passes `:stream` through to `benedict-http-request` so SSE callbacks invoke `--handle-sse-payload` (`benedict-provider-openrouter.el:222-249`).
- Streaming path: `benedict-provider-openrouter--handle-sse-payload` first attempts line-by-line NDJSON parsing (plist objects/lists) and falls back to treating the entire payload as one JSON object; parsed objects flow to `--stream-handle-json`, which records state (model, remote id, usage) and emits `:content-delta`/` :thinking-delta` callbacks (`benedict-provider-openrouter.el:253-348`).
- Non-streaming path: `benedict-provider-openrouter--process-http-response` decodes the body into an alist to preserve original string keys for helper access (`benedict-provider-openrouter.el:749-758`). Success paths convert those alists into Benedict plists (`benedict-provider-openrouter--decode-message`) and emit a plist result with usage/model/latency, while failures inspect the alist’s `"error"` block before retrying or invoking `on-error` (`benedict-provider-openrouter.el:775-849`).

### Vercel Provider (`benedict-provider-vercel.el`)
- Request dispatch mirrors OpenRouter: `benedict-provider-vercel--perform-request` wraps `benedict-http-request` and wires `--handle-sse-payload` for streaming deliveries (`benedict-provider-vercel.el:242-272`).
- Streaming path: `benedict-provider-vercel--handle-sse-payload` uses the same NDJSON-first strategy and produces plist events that are accumulated into reasoning/tool-call state before `on-delta` callbacks fire (`benedict-provider-vercel.el:279-377`).
- Non-streaming path: `benedict-provider-vercel--process-http-response` decodes HTTP bodies into alists, inspecting an `"error"` entry before dispatching to success/error helpers; decoded completions are transformed into plists via `--decode-message` so the rest of Benedict receives the same structure as the streaming path (`benedict-provider-vercel.el:741-852`).

### Ollama Provider (`benedict-provider-ollama.el`)
- Request dispatch uses the same scaffolding despite targeting a local endpoint; `benedict-provider-ollama--perform-request` builds JSON, chooses whether to stream, and delegates to `benedict-http-request` (`benedict-provider-ollama.el:201-225`).
- Streaming path: SSE payloads are parsed into plists with NDJSON fallback identical to OpenRouter/Vercel, and the normalized deltas feed the shared `on-delta` contract (`benedict-provider-ollama.el:228-347`).
- Non-streaming path: `benedict-provider-ollama--process-http-response` decodes JSON bodies into alists, checks for an `"error"` entry, and on success produces plist messages/results while updating usage/latency; errors respect the same retry/backoff helpers as the hosted providers (`benedict-provider-ollama.el:724-823`).

### Fake/Test Provider (`benedict-provider-fake.el`)
- `benedict-provider-fake--send` never touches `benedict-http`; it selects a scripted entry, schedules delta/thinking chunks via timers, and fabricates plist payloads for both completion and error cases, exercising the provider callback contract without exercising JSON parsing (`benedict-provider-fake.el:194-330`).

## Code References
- `benedict-http.el:43-258` — Shared HTTP wrapper (curl invocation, SSE framing, success/error callback plumbing).
- `benedict-provider-gemini.el:361-744` — Token fetch logic, plist JSON parser, completion success/error handling, and synchronous-only dispatch path.
- `benedict-provider-openrouter.el:222-849` — Request execution, SSE parsing, alist-oriented HTTP response decoding, and success/error emitters.
- `benedict-provider-vercel.el:242-852` — Identical streaming strategy plus alist-to-plist conversion for non-stream responses.
- `benedict-provider-ollama.el:201-823` — Local endpoint handling with the same NDJSON streaming parser and alist/non-stream conversions.
- `benedict-provider-fake.el:194-330` — Timer-driven fake responses (no HTTP parsing but validates callback semantics).

## Architecture Documentation
- Provider dispatch flow: `benedict-provider-dispatch` (via each provider’s `--send`) constructs request payloads, then calls `benedict-http-request`. curl’s exit path determines whether we see a non-streaming `on-success` (always treated as HTTP 200) or an `on-error` carrying the HTTP status/body via exit code 22 (`benedict-http.el:43-258`).
- Streaming contract: The shared HTTP layer only splits SSE frames and forwards raw strings; every provider that supports streaming must parse JSON and decide when `[DONE]` ends a session, so OpenRouter/Vercel/Ollama each implement their own NDJSON-parsing loop (`benedict-provider-openrouter.el:253-284`, `benedict-provider-vercel.el:279-313`, `benedict-provider-ollama.el:228-260`).
- Data structures: Gemini keeps everything as plists from the moment JSON is parsed, while the other HTTP providers mix alists (for string-key access via helper functions) with plists for the final Benedict-facing message results. Streaming deltas are already plists to simplify merging into state tables (`benedict-provider-openrouter.el:749-820`, `benedict-provider-vercel.el:741-852`, `benedict-provider-ollama.el:724-823`).

## Historical Context (from previous efforts)
No prior documentation exists for `http-response-handling-refactor`; this is the initial research baseline.

## Open Questions
- Is the alist-versus-plist split on non-streaming responses intentional (e.g., to keep helper `--aget` semantics), or could providers safely standardize on plists without breaking downstream consumers? Confirming this requires auditing every `--aget` usage in the provider modules.
- Gemini currently runs only non-streaming completions. If streaming support is added later, should it reuse the NDJSON/SSE accumulation helpers already built for the other providers or introduce a new parsing path?
