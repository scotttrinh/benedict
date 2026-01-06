# Troubleshoot Gemini Provider via HTTP Observability

## Overview
Add targeted tests and logging around the Gemini provider’s HTTP flows so we can reliably capture and compare request/response behavior (especially in OAuth/Code Assist mode) against the known-good `opencode-gemini-auth` implementation. The initial focus is on (a) hardening header redaction to safely log authorization metadata, and (b) emitting high-signal, low-risk HTTP diagnostics when opted-in.

## Current State Analysis
- Gemini provider core:
  - `benedict-provider-gemini.el:140–169` implements logging helpers for secrets and headers:
    - `benedict-provider-gemini--redact-secret` masks arbitrary strings for logs.
    - `benedict-provider-gemini--redact-authorization-value` attempts to preserve the `Bearer` prefix while redacting the token.
    - `benedict-provider-gemini--redact-headers` walks a header alist and redacts values whose header name matches `authorization` (case-insensitively).
  - `benedict-provider-gemini--build-headers` constructs request headers including `Authorization: Bearer <access-token>` and Code Assist headers when `wrap` is non-nil (`benedict-provider-gemini.el:510–520`).
  - `benedict-provider-gemini--endpoint-for` chooses between Generative Language and Code Assist endpoints (`benedict-provider-gemini.el:522–531`).
  - `benedict-provider-gemini--send` is the main dispatch function; it resolves credentials, builds payload, URL, and headers, logs a minimal debug line (`"Gemini request"` with request id and model), then calls `benedict-http-request` (`benedict-provider-gemini.el:638–675`).
  - `benedict-provider-gemini--handle-success` and `benedict-provider-gemini--handle-error` log high-level success/error events, but they do not currently log the HTTP status, URL, or headers; errors log the raw body without constraint (`benedict-provider-gemini.el:558–636`).
- HTTP client layer:
  - `benedict-http-request` wraps `curl`, constructs a process with a structured context (including URL, method, headers, body, stream flag, request-id, provider) and logs `"HTTP start"` and `"HTTP exit"` events via the `benedict.http` logger (`benedict-http.el:43–83, 97–103, 197–217`).
  - Non-streaming responses are buffered in `:partial`; on success, `on-success` is called with a hard-coded status `200` and no header metadata (`benedict-http.el:219–234`).
  - Errors where curl exits with code 22 (HTTP 4xx/5xx) are reported as `:type 'http` with `:code 22` and the raw body; the true HTTP status is not surfaced, so provider code must infer status from the JSON body if needed (`benedict-http.el:236–259`).
- Existing Gemini tests:
  - `test/benedict-provider-gemini-test.el` already covers PKCE helpers, state encoding/decoding, credential resolution paths, payload shape (wrapped and unwrapped), endpoint construction, and one basic header redaction test that asserts redacted Authorization headers differ from originals while preserving the `Bearer` prefix (`benedict-provider-gemini-test.el:17–81, 134–181`).
  - `test/benedict-provider-gemini-http-test.el` validates `benedict-provider-gemini--token-request` correctly parses HTTP status and body from a mock `url-retrieve-synchronously` response (`test/benedict-provider-gemini-http-test.el:11–29`).
- External reference: `opencode-gemini-auth` debug logging
  - `opencode-gemini-auth/src/plugin/debug.ts:36–61` implements `startGeminiDebugRequest`, which logs request id, resolved URL, original URL, project id, streaming flag, masked headers, and a truncated body preview when `OPENCODE_GEMINI_DEBUG=1`.
  - `debug.ts:66–98` provides `logGeminiDebugResponse`, logging response status, headers, optional note/error, and a truncated body preview, tied to the same request context id.
  - `debug.ts:100–118` uses `maskHeaders` to redact Authorization headers while logging other headers verbatim; body previews are truncated to 2000 characters (`debug.ts:120–155`).

## Desired End State
- We have comprehensive, deterministic unit tests around the Gemini header redaction helpers that:
  - Cover normal Bearer tokens, malformed Authorization values, non-string values, and case-insensitive header names.
  - Guarantee no test can observe a full access token or raw secret in any redacted output.
- The Gemini provider can emit detailed HTTP diagnostics (at `debug` level) that are:
  - Correlated via a request id shared between provider-level logs and HTTP client logs.
  - Structured enough to compare one-for-one with `opencode-gemini-auth` debug output: URL, project id, model, streaming flag, masked headers, and truncated JSON payloads.
  - Safe by default: never log full Authorization headers or raw API keys; truncate bodies to a bounded size; avoid logging raw user prompts when not necessary.
- For Gemini OAuth failures returning HTTP 500s, Benedict logs provide enough context to distinguish between project-id issues, model mismatches, and body shape problems without re-running Emacs under a debugger (assuming debug logging is enabled in the logger configuration).

## What We're NOT Doing
- Not changing the core OAuth flow, token endpoints, or PKCE implementation (beyond adding observability around them as needed).
- Not altering the request URL or body shape semantics for Gemini (standard vs Code Assist) in this effort.
- Not introducing cross-provider HTTP logging changes in `benedict-http.el` beyond what Gemini specifically needs.
- Not adding new UI commands or user-facing customization.

## Implementation Approach
- Start with safety: expand and harden unit tests around the redaction helpers, then adjust implementations to handle edge cases (e.g., malformed Authorization headers) without ever leaking secrets or throwing errors in the logger.
- Activate richer HTTP logging at the provider layer using `lgr-debug`, modeled on `opencode-gemini-auth`’s `debug.ts` module.
- Build small, focused helpers to:
  - Redact and normalize headers for logs (`benedict-provider-gemini--redact-headers`, potentially extended).
  - Produce truncated body previews suitable for logs.
  - Emit structured provider-level logs for request/response that include URL, model, project-id, streaming flag, and request-id.
- Keep HTTP client behavior stable; use the existing `request-id` and `provider` fields in the `benedict-http` context to correlate logs without changing curl invocation semantics.

## Phase 1: Harden Header Redaction & Tests

### Overview
Extend and tighten test coverage for Gemini header redaction helpers, then adjust implementations to handle malformed or unexpected Authorization header values robustly while ensuring no secret leakage.

### Changes Required
- **File**: `test/benedict-provider-gemini-test.el`
  - **Changes**:
    - Add multiple new `ert-deftest` cases around:
      - `benedict-provider-gemini--redact-secret` behavior for short strings, empty strings, and non-string values.
      - `benedict-provider-gemini--redact-authorization-value` for:
        - Well-formed `"Bearer token"` values.
        - Bare `"Bearer"` or `"Bearer   "` values (no token or whitespace-only token).
        - Mixed-case prefixes (e.g., `"bearer token"`, `"BEARER token"`).
        - Non-string values (symbols, numbers) coerced via `benedict-provider-gemini--stringify`.
      - `benedict-provider-gemini--redact-headers` for:
        - Different header name spellings/cases (`"authorization"`, `"Authorization"`, symbols).
        - Presence of other headers that must remain unchanged.
    - Use assertions that:
      - No redacted output equals the original secret/token string for realistic samples.
      - `benedict-provider-gemini--redact-authorization-value` never signals an error given arbitrary `Authorization` strings.
    - Example test pattern:
      ```elisp
      (ert-deftest benedict-provider-gemini-redact-authorization-missing-token ()
        (let ((value "Bearer"))
          (should-not (string-match-p "Bearer$"
                                      (benedict-provider-gemini--redact-authorization-value value)))))
      ```
- **File**: `benedict-provider-gemini.el`
  - **Changes**:
    - Update `benedict-provider-gemini--redact-authorization-value` to be defensive when handling short or malformed strings:
      - Avoid `(substring string 7)` when `string` is shorter than `"Bearer "`.
      - Treat values that begin with `"Bearer"` but have no non-whitespace token as a generic secret (e.g., `"Bearer"` → a fixed masked placeholder) without throwing.
      - Normalize prefixes case-insensitively when deciding whether to preserve `Bearer` in the output.
    - Optionally, introduce a small helper to safely extract the token portion:
      ```elisp
      (defun benedict-provider-gemini--authorization-token-part (string)
        (let ((rest (substring string 6))) ; after "Bearer"
          (string-trim-left rest)))
      ```
      and use it inside `benedict-provider-gemini--redact-authorization-value` to reduce indexing errors.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-provider-gemini-test.el` passes with the new redaction tests.
- [x] New tests cover at least: well-formed Bearer headers, malformed/missing-token headers, non-string header values, and case-insensitive header names.

#### Manual Verification
- [ ] Inspect the new tests to confirm that no test fixture includes a literal access token or highly realistic secret (keep samples obviously synthetic).
- [ ] Review `benedict-provider-gemini--redact-authorization-value` behavior in `*scratch*` with a few sample values to confirm it never errors and always masks the token portion.

## Phase 2: Gemini HTTP Request/Response Observability

### Overview
Add Gemini-specific debug logging at the provider layer to capture sanitized HTTP request and response metadata, modeled after `opencode-gemini-auth`’s `debug.ts`.

### Changes Required
- **File**: `benedict-provider-gemini.el`
  - **Changes**:
    - Add a helper to build a truncated body preview for logs:
      ```elisp
      (defun benedict-provider-gemini--body-preview (body &optional limit)
        "Return a truncated preview string for BODY."
        (let* ((text (benedict-provider-gemini--stringify body))
               (max (or limit 2000)))
          (if (> (length text) max)
              (format "%s… (truncated %d chars)"
                      (substring text 0 max)
                      (- (length text) max))
            text)))
      ```
    - Extend `benedict-provider-gemini--send` to emit a richer debug log:
      - After computing `url`, `headers`, and `payload`, and before calling `benedict-http-request`, log via `lgr-debug`:
        - Request-id, model, auth method (`oauth` vs `api-key`), `wrap` flag, project-id.
        - URL and whether it is a Code Assist endpoint.
        - Sanitized headers via `benedict-provider-gemini--redact-headers`.
        - A truncated body preview via `benedict-provider-gemini--body-preview`.
      - Example pattern:
        ```elisp
        (let ((lgr (benedict-provider-gemini--logger)))
          (lgr-debug lgr "Gemini HTTP request"
                     :request-id request-id
                     :url url
                     :model model
                     :auth-method benedict-provider-gemini-auth-method
                     :wrap wrap
                     :project-id project-id
                     :headers (benedict-provider-gemini--redact-headers headers)
                     :body-preview (benedict-provider-gemini--body-preview payload)))
        ```
    - Extend `benedict-provider-gemini--handle-success` to log a response summary:
      - Include request-id, latency, model, whether `text` was empty, and a truncated preview of the raw response JSON via `lgr-debug`.
      - Use `benedict-provider-gemini--body-preview` on the original `body` string.
    - Extend `benedict-provider-gemini--handle-error` logging:
      - Preserve existing error payload behavior, but also log a truncated body preview via `lgr-debug` (if not already sufficiently captured).
      - Ensure logs include `:request-id`, `:type`, and the parsed `:status` to make HTTP 500 vs other errors visible.
- **File**: `test/benedict-provider-gemini-test.el`
  - **Changes**:
    - Add unit tests for `benedict-provider-gemini--body-preview`:
      - Short bodies are returned unchanged.
      - Long bodies are truncated with the expected suffix text.
    - Add a focused test that exercises the new logging path without depending on `lgr` internals:
      - Use `cl-letf` to temporarily override `benedict-provider-gemini--logger` with a fake logger that records the last debug call.
      - Invoke a minimal `benedict-provider-gemini--send` flow with `benedict-http-request` mocked out to avoid real network I/O.
      - Assert that the logged payload includes a redacted Authorization header and a non-empty body preview string.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-provider-gemini-test.el` passes with the new logging-related tests.
- [x] `nix run .#test -- test/benedict-provider-gemini-http-test.el` continues to pass.

#### Manual Verification
- [ ] Run a simple Gemini request and inspect the `benedict.gemini` logs (ensure debug level is enabled) to confirm:
  - Request logs show URL, model, auth method, project-id, redacted Authorization header, and a truncated body preview.
  - Response logs show status (derived from the body), latency, and a truncated body preview.
- [ ] Compare a captured Benedict debug log for an OAuth Code Assist request with a corresponding `opencode-gemini-auth` debug log to verify that the endpoints, headers (after masking), and body shapes match expectations.

## Testing Strategy
- **Unit tests**:
  - Extend `test/benedict-provider-gemini-test.el` to cover:
    - Redaction helper edge cases and invariants (no secret leakage, no errors on malformed input).
    - Body preview/truncation behavior.
    - Logging-path behavior via mocked logger and HTTP request functions.
  - Keep tests hermetic by avoiding real network calls; rely on `cl-letf` to stub `benedict-http-request`, `benedict-provider-gemini--resolve-credential`, and logger functions.
- **Integration-style manual tests**:
  - With valid Gemini OAuth credentials configured (reusing the same refresh token/project context as `opencode-gemini-auth`), run interactive Benedict sessions in both:
    - `api-key` mode (no wrapping, standard Generative Language endpoint).
    - `oauth` mode (wrapped Code Assist endpoint).
  - Compare (after enabling debug logging in the `lgr` configuration):
    - Constructed URLs.
    - Presence of Code Assist headers.
    - Shape of the wrapped body (`{ project, model, request }`) against the CLI plugin’s logs.

## References
- Research doc: `efforts/troubleshoot-gemini-provider/research.md`.
- Gemini provider implementation: `benedict-provider-gemini.el`.
- HTTP client wrapper: `benedict-http.el`.
- Existing Gemini tests: `test/benedict-provider-gemini-test.el`, `test/benedict-provider-gemini-http-test.el`.
- opencode Gemini debug logging: `opencode-gemini-auth/src/plugin/debug.ts`.
