---
date: 2025-12-23T00:00:00Z
researcher: benedict-research-agent
git_commit: 33c0689a44919530816c67ad95b2630a5d021cee
branch: main
repository: benedict
topic: "Troubleshooting Benedict Google Gemini provider vs opencode-gemini-auth behavior"
tags: [research, codebase, gemini, provider, http]
status: draft
last_updated: 2025-12-23
---

# Research: Troubleshooting Benedict Google Gemini provider vs opencode-gemini-auth behavior

**Date**: 2025-12-23
**Researcher**: benedict-research-agent
**Git Commit**: 33c0689a44919530816c67ad95b2630a5d021cee
**Branch**: main

## Research Question

Why is the Benedict Google Gemini provider (`benedict-provider-gemini.el`) returning HTTP 500 errors from Google, and how does its request URL/body construction compare to the opencode-gemini-auth plugin’s Gemini request patterns?

## Summary

- Benedict’s Gemini provider currently sends requests to either the standard Generative Language API (`https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`) or to the Cloud Code Assist endpoint (`https://cloudcode-pa.googleapis.com/v1internal:generateContent`), depending on auth mode (`api-key` vs `oauth`).
- In OAuth mode, Benedict mirrors the opencode-gemini-auth plugin by wrapping requests into a Code Assist-specific envelope with `project`, `model`, and `request` keys, and by calling `v1internal:{generateContent|streamGenerateContent}` on `cloudcode-pa.googleapis.com` with specific IDE-style headers.
- The opencode-gemini-auth plugin does not construct the original Generative Language URLs itself; instead, it intercepts existing `generativelanguage.googleapis.com` calls, rewrites them into Code Assist form, and standardizes bodies and headers.
- The main structural parity points between Benedict and the plugin are: use of `cloudcode-pa.googleapis.com/v1internal:{action}`, Code Assist headers (`User-Agent`, `X-Goog-Api-Client`, `Client-Metadata`), and a wrapped body `{ project, model, request }` whose `request` field contains `contents`, optional `systemInstruction`, and `generationConfig` (including optional thinking config and cached content hints).
- Given this alignment, HTTP 500s from Google are more likely to stem from subtle body-shape or model/project configuration issues rather than a completely wrong base URL, but both URL and body formats are documented below for comparison.

## Detailed Findings

### Benedict Gemini provider: endpoints, headers, and body shape

- Base endpoint for standard Generative Language API calls is configured as `https://generativelanguage.googleapis.com/v1beta/models` in `benedict-provider-gemini-endpoint`.
  - `benedict-provider-gemini.el:44` – `defcustom benedict-provider-gemini-endpoint` holds the base URL; the provider appends `/:model:generateContent` or `/:model:streamGenerateContent` when building requests.
- The default model used when no `:model` is explicitly provided is `gemini-2.0-flash`.
  - `benedict-provider-gemini.el:52` – `defcustom benedict-provider-gemini-default-model` is set to `"gemini-2.0-flash"`.
- A separate Cloud Code Assist endpoint and header set are defined for IDE/Code Assist style calls:
  - `benedict-provider-gemini.el:126` – `defconst benedict-provider-gemini-cloud-code-endpoint` is `"https://cloudcode-pa.googleapis.com"`.
  - `benedict-provider-gemini.el:130` – `defconst benedict-provider-gemini-cloud-code-headers` supplies:
    - `User-Agent: google-api-nodejs-client/9.15.1`
    - `X-Goog-Api-Client: gl-node/22.17.0`
    - `Client-Metadata: ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI`
- Header construction logic depends on whether the request is wrapped for Code Assist:
  - `benedict-provider-gemini.el:510` – `benedict-provider-gemini--build-headers` builds headers from an access token:
    - Always includes `Content-Type: application/json` and `Authorization: Bearer {access-token}`.
    - In wrapped (Code Assist) mode, prepends the `benedict-provider-gemini-cloud-code-headers` values; the resulting header set closely matches opencode-gemini-auth’s `CODE_ASSIST_HEADERS`.
    - In non-wrapped mode, adds a Benedict-specific `User-Agent` string if configured (`benedict-provider-gemini-user-agent`).
- Endpoint URL selection mirrors the two modes (standard vs Code Assist):
  - `benedict-provider-gemini.el:522` – `benedict-provider-gemini--endpoint-for`:
    - When `wrap` is non-nil (OAuth/Code Assist mode), builds `cloudcode-pa` URLs: `"{cloudcode-pa}/v1internal:{streamGenerateContent|generateContent}"` (no `/models/{model}` component).
    - When `wrap` is nil (API key / direct Generative Language mode), builds standard URLs: `"{generativelanguage.googleapis.com}/v1beta/models/{model}:{streamGenerateContent|generateContent}"`.
- Request body construction follows Gemini’s `contents` and `systemInstruction` schema, with an optional outer Code Assist wrapper:
  - `benedict-provider-gemini.el:461` – `benedict-provider-gemini--build-body` takes a Benedict request plist and produces a JSON-ready alist:
    - Extracts `:messages`, enforces non-empty list, and splits out a first `system` message (if present) from the remainder via `benedict-provider-gemini--extract-system-prompt`.
    - Serializes non-system messages into `contents` entries, each with a `role` and `parts` field; `parts` is built as a vector of single `{ "text": <content> }` objects via `benedict-provider-gemini--parts-from-text` and `benedict-provider-gemini--serialize-message` (`benedict-provider-gemini.el:432–449`).
    - When a system message exists, adds `systemInstruction` with `role: "system"` and `parts` as above (`benedict-provider-gemini.el:479–484`).
    - Reads optional generation parameters from the request plist:
      - `:temperature` → `generationConfig.temperature`.
      - `:top-p` → `generationConfig.topP`.
      - `:max-tokens` → `generationConfig.maxOutputTokens`.
    - In non-wrapped mode, `model` is included as a top-level field in the body next to `contents` and `systemInstruction`.
    - In wrapped (Code Assist) mode, the function instead produces an outer object `{ project, model, request }`:
      - `project` is the resolved project ID (or empty string if missing).
      - `model` is the selected model.
      - `request` is the non-wrapped body (contents, systemInstruction, generationConfig), matching the shape expected by Cloud Code Assist management endpoints.
  - `benedict-provider-gemini.el:505` – `benedict-provider-gemini--encode-payload` encodes this body as UTF-8 JSON.
- The core send function selects between standard and Code Assist behavior based on auth method:
  - `benedict-provider-gemini.el:638` – `benedict-provider-gemini--send`:
    - Resolves credentials via `benedict-provider-gemini--resolve-credential`, which yields an `:access` token and, in OAuth mode, a `:project-id` if known (`benedict-provider-gemini.el:233–287`).
    - Determines `wrap` with `(eq benedict-provider-gemini-auth-method 'oauth)`. In API-key mode, `wrap` is `nil`, leading to direct Generative Language API calls.
    - Builds a payload with `benedict-provider-gemini--encode-payload`, passing the resolved `project-id` and `wrap` flag.
    - Builds the URL via `benedict-provider-gemini--endpoint-for model nil wrap` and headers via `benedict-provider-gemini--build-headers`.
    - Dispatches the request through `benedict-http-request`, capturing success and error callbacks.
- Successful responses are parsed with an awareness of both standard Generative Language and Code Assist-wrapped formats:
  - `benedict-provider-gemini.el:558` – `benedict-provider-gemini--handle-success`:
    - Parses the JSON body into a plist via `benedict-provider-gemini--parse-json`.
    - If the response is Code Assist-wrapped, expects an outer `response` key and uses its value as the effective payload; otherwise, uses the root object as-is.
    - Extracts the first candidate’s content (`candidates[0].content.parts`) and concatenates any `text` fields into a single string via `benedict-provider-gemini--parts->text` (`benedict-provider-gemini.el:533–541`).
    - Extracts token usage from `usageMetadata` into a normalized `:usage` plist via `benedict-provider-gemini--usage-from-metadata` (`benedict-provider-gemini.el:543–556`).

### opencode-gemini-auth: how URLs and bodies are transformed

- The plugin introduces constants for Code Assist base URL and headers that mirror Benedict’s:
  - `/opencode-gemini-auth/src/constants.ts:28` – `GEMINI_CODE_ASSIST_ENDPOINT` is `"https://cloudcode-pa.googleapis.com"`.
  - `/opencode-gemini-auth/src/constants.ts:30` – `CODE_ASSIST_HEADERS` is a map of Code Assist-required headers including `User-Agent`, `X-Goog-Api-Client`, and `Client-Metadata`, used for all Code Assist management and generateContent calls.
- OAuth token acquisition uses the same Google endpoints and a PKCE-based auth flow similar to Benedict:
  - `/opencode-gemini-auth/src/gemini/oauth.ts:80` – `authorizeGemini` constructs an OAuth URL to `https://accounts.google.com/o/oauth2/v2/auth` with `client_id`, `redirect_uri`, `scope` (from `GEMINI_SCOPES`), `code_challenge`, `code_challenge_method`, `state`, `access_type=offline`, and `prompt=consent`.
  - `/opencode-gemini-auth/src/gemini/oauth.ts:103` – `exchangeGemini` exchanges the code against `https://oauth2.googleapis.com/token` with `Content-Type: application/x-www-form-urlencoded` body containing `client_id`, `client_secret`, `code`, `grant_type=authorization_code`, `redirect_uri`, and `code_verifier`, then optionally fetches user info from `https://www.googleapis.com/oauth2/v1/userinfo?alt=json`.
- A local HTTP server is used to capture the OAuth redirect at the configured redirect URI:
  - `/opencode-gemini-auth/src/plugin/server.ts:23` – `redirectUri` parses `GEMINI_REDIRECT_URI` to derive `callbackPath` and port.
  - `/opencode-gemini-auth/src/plugin/server.ts:30` – `startOAuthListener` starts `node:http` server listening on the redirect port, responds to callbacks on `callbackPath` with a success HTML page, and resolves a promise with the full callback URL.
- Standard Generative Language API calls are identified and then rewritten into Code Assist format:
  - `/opencode-gemini-auth/src/plugin/request.ts:22` – `isGenerativeLanguageRequest` returns true when the request URL string contains `generativelanguage.googleapis.com`.
  - `/opencode-gemini-auth/src/plugin/request.ts:55` – `prepareGeminiRequest` performs the main transformation:
    - If `input` is not a `generativelanguage.googleapis.com` string, returns it unchanged.
    - Otherwise, converts headers:
      - Sets `Authorization: Bearer {accessToken}`.
      - Removes any `x-api-key` header.
    - Extracts model and action from the URL using `/\/models\/([^:]+):(\w+)/`:
      - `rawModel` is the pre-transform model name; `rawAction` is typically `generateContent` or `streamGenerateContent`.
      - `MODEL_FALLBACKS` currently maps `gemini-2.5-flash-image` → `gemini-2.5-flash` (`/opencode-gemini-auth/src/plugin/request.ts:14–16`).
      - `streaming` is true when `rawAction === "streamGenerateContent"`.
    - Builds the transformed Code Assist URL:
      - `transformedUrl = "{GEMINI_CODE_ASSIST_ENDPOINT}/v1internal:" + rawAction + (streaming ? "?alt=sse" : "")` (`/opencode-gemini-auth/src/plugin/request.ts:88–90`).
    - Rewrites the JSON body:
      - If the incoming body is already a wrapped object with `project` (string) and `request` keys, it simply overrides the `model` field with the normalized model and re-serializes.
      - Otherwise, constructs `requestPayload` from the parsed JSON body and normalizes it:
        - Thinking config: normalizes `generationConfig.thinkingConfig` using `normalizeThinkingConfig`, accepting `thinkingBudget` / `thinking_budget`, `thinkingLevel` / `thinking_level`, and `includeThoughts` / `include_thoughts` (`/opencode-gemini-auth/src/plugin/request-helpers.ts:40–73`).
        - System instruction: if `system_instruction` exists on the original payload, moves it to `systemInstruction` and deletes `system_instruction` (`/opencode-gemini-auth/src/plugin/request.ts:119–123`).
        - Cached content: coalesces `cached_content`, `cachedContent`, and any `extra_body.cached_content` / `extra_body.cachedContent` into a single `cachedContent` field on `requestPayload`, then removes the legacy fields and prunes `extra_body` if it becomes empty (`/opencode-gemini-auth/src/plugin/request.ts:125–146`).
        - Removes any top-level `model` field from `requestPayload` (`/opencode-gemini-auth/src/plugin/request.ts:148–150`).
      - Wraps the normalized payload in a Code Assist envelope:
        - `wrappedBody = { project: projectId, model: effectiveModel, request: requestPayload }` (`/opencode-gemini-auth/src/plugin/request.ts:152–156`).
    - For streaming requests, sets `Accept: text/event-stream` (`/opencode-gemini-auth/src/plugin/request.ts:164–167`).
    - Ensures Code Assist headers are present:
      - `User-Agent`, `X-Goog-Api-Client`, and `Client-Metadata` are set from `CODE_ASSIST_HEADERS` (`/opencode-gemini-auth/src/plugin/request.ts:169–171`).
    - Returns the transformed URL, init options (with modified headers and body), a `streaming` flag, and the `requestedModel`.
- Responses are normalized back to standard-looking Gemini responses:
  - `/opencode-gemini-auth/src/plugin/request.ts:189` – `transformGeminiResponse`:
    - Reads the full response body as text and inspects `content-type` for JSON vs SSE (`text/event-stream`).
    - For error responses, attempts to parse an `error.details` array and extracts any `RetryInfo` detail into `Retry-After` and `retry-after-ms` headers (`/opencode-gemini-auth/src/plugin/request.ts:206–233`).
    - Parses the JSON body using `parseGeminiApiBody`, which handles array-wrapped responses (`/opencode-gemini-auth/src/plugin/request-helpers.ts:78–96`).
    - Applies `rewriteGeminiPreviewAccessError` to Gemini 3 404 errors, adding a `Request preview access` hint (`/opencode-gemini-auth/src/plugin/request-helpers.ts:154–177`).
    - Extracts usage metadata via `extractUsageMetadata` / `extractUsageFromSsePayload` and exposes it as `x-gemini-*` headers (`/opencode-gemini-auth/src/plugin/request.ts:245–257`).
    - For streaming responses that are OK and SSE, rewrites the stream so that each `data:` line contains only the inner `response` object (`transformStreamingPayload` at `/opencode-gemini-auth/src/plugin/request.ts:27–48`).
    - For non-streaming responses, returns either the JSON stringified `effectiveBody.response`, the patched body, or the original text, depending on which structure is available.

### opencode-gemini-auth: provider loader and when Code Assist applies

- The plugin is wired as an OAuth-backed provider that only rewrites requests when auth type is `oauth`:
  - `/opencode-gemini-auth/src/plugin/auth.ts:5` – `isOAuthAuth` returns `auth.type === "oauth"`.
  - `/opencode-gemini-auth/src/plugin.ts:29` – `GeminiCLIOAuthPlugin` registers the Gemini provider:
    - In its loader, calls `getAuth()` and immediately returns `null` unless `isOAuthAuth(auth)` is true.
    - Resolves provider options including optional `configuredProjectId`.
    - For OAuth auth, constructs a loader result with `apiKey: ""` and a custom `fetch` implementation.
- The custom `fetch` is where `prepareGeminiRequest` and `transformGeminiResponse` are applied:
  - `/opencode-gemini-auth/src/plugin.ts:101` (approximate) – Loader’s `fetch`:
    - Refreshes access tokens as needed via `refreshAccessToken` (`/opencode-gemini-auth/src/plugin/token.ts:64`).
    - Resolves an effective project context via `ensureProjectContext`, which calls `loadManagedProject` and `onboardManagedProject` as necessary (`/opencode-gemini-auth/src/plugin/project.ts:132–182`).
    - Calls `prepareGeminiRequest(input, init, accessToken, effectiveProjectId)` to rewrite URLs and bodies for Generative Language API requests.
    - Issues the transformed fetch and then wraps the response via `transformGeminiResponse`.
  - For API-key-based auth (`type: "api"`), this loader is not used; the plugin’s README and code imply that such requests use the core OpenAI-style provider path, which sends `x-api-key` headers directly to `generativelanguage.googleapis.com` without Code Assist wrapping.

## Hypotheses & Potential Causes

These are hypotheses about why Benedict’s Gemini provider may receive HTTP 500 responses, based on the code as written and the opencode-gemini-auth behavior. Each is grounded in code references and includes a confidence level.

1. **Mismatch between model and endpoint flavor in Code Assist mode** (Medium confidence)
   - Benedict’s default model is `gemini-2.0-flash` and its standard endpoint base is `v1beta/models` (`benedict-provider-gemini.el:44–52`).
   - In Code Assist (OAuth) mode, Benedict sends requests to `cloudcode-pa.googleapis.com/v1internal:{generateContent|streamGenerateContent}` with `{ project, model, request }` bodies (`benedict-provider-gemini.el:461–502, 522–531, 638–654`), mirroring the plugin’s behavior.
   - If the model name used in Benedict (e.g., `gemini-2.0-flash` or a user-specified value) is not recognized or supported in the Code Assist context for the given project (or requires a different naming convention), the backend could respond with internal errors rather than clear 4xx errors.
   - The opencode plugin contains a `MODEL_FALLBACKS` map to smooth over at least one such discrepancy (`gemini-2.5-flash-image` → `gemini-2.5-flash` at `/opencode-gemini-auth/src/plugin/request.ts:14–16`). Benedict currently has no such internal fallback for models.

2. **Project ID missing or inconsistent in OAuth mode** (Medium confidence)
   - Benedict’s OAuth credential resolution attempts to derive a project ID from the packed refresh token and, if missing, to load a managed project via `benedict-provider-gemini--load-managed-project` (`benedict-provider-gemini.el:233–287, 197–221`).
   - `benedict-provider-gemini--load-managed-project` calls `POST {cloudcode-pa}/v1internal:loadCodeAssist` with a `metadata` object similar to the opencode plugin’s `loadManagedProject` (`benedict-provider-gemini.el:197–221`; cf. `/opencode-gemini-auth/src/plugin/project.ts:132–182`). It expects a `cloudaicompanionProject` field in the response.
   - If this project discovery fails (e.g., due to permissions or region configuration) or returns unexpected data, Benedict may persist an empty or invalid `project-id` (`benedict-provider-gemini.el:280–287`), which is then used in subsequent Code Assist wrapped calls (`benedict-provider-gemini.el:461–502`).
   - The plugin’s `ensureProjectContext` performs similar logic but adds onboarding (`onboardUser`) and more explicit management of `cloudaicompanionProject` vs `effectiveProjectId` (`/opencode-gemini-auth/src/plugin/project.ts:172–182, 233–243`). Differences here might cause Benedict’s project context to be less robust, potentially leading to backend errors.

3. **Body shape differences for system instructions and thinking config** (Low–Medium confidence)
   - Benedict constructs `systemInstruction` as a top-level field in non-wrapped bodies and as part of the inner `request` in wrapped bodies, using a specific `contents/parts` representation (`benedict-provider-gemini.el:461–484`). It does not support alternative field names like `system_instruction`.
   - The opencode plugin’s `prepareGeminiRequest` specifically normalizes `system_instruction` to `systemInstruction` and carefully handles `generationConfig.thinkingConfig` using `normalizeThinkingConfig`, including multiple naming conventions and types (`/opencode-gemini-auth/src/plugin/request.ts:119–123; /opencode-gemini-auth/src/plugin/request-helpers.ts:40–73`).
   - If Benedict callers are passing request plists that differ from the expected shape (e.g., using field names that map poorly to Gemini’s API or mixing in unhandled fields), the resulting JSON might be considered malformed by the backend, potentially leading to 5xx errors.

4. **Cached content / extra body handling absent in Benedict** (Low confidence)
   - The opencode plugin includes detailed logic for merging `cached_content`, `cachedContent`, and `extra_body.cached_content`/`cachedContent` into a single canonical `cachedContent` field (`/opencode-gemini-auth/src/plugin/request.ts:125–146`). This helps ensure that cache-related hints are always in the shape Code Assist expects.
   - Benedict’s provider does not currently have explicit support for `cachedContent` or `extra_body`-style fields in its request building (`benedict-provider-gemini.el:461–502`); if callers pass such fields directly, their serialization may differ from what the backend expects.
   - While misaligned cache hints are more likely to cause 4xx errors, certain backend configurations might respond with 5xx when unexpected fields are present.

5. **Differences in error handling and retry semantics** (Low confidence)
   - The opencode plugin’s `transformGeminiResponse` inspects error payloads for `RetryInfo` and exposes retry delays via headers (`/opencode-gemini-auth/src/plugin/request.ts:206–233`), as well as enhancing 404 errors for Gemini 3 models (`/opencode-gemini-auth/src/plugin/request-helpers.ts:154–177`).
   - Benedict’s error handler focuses on extracting `error.message`, `error.code`, and potential `error_description` from response bodies (`benedict-provider-gemini.el:598–606`), but does not inspect `error.details` for structured retry info. While this does not directly cause 500s, it may obscure underlying causes and could make transient backend issues look like persistent 500 errors.

## Code References

- `benedict-provider-gemini.el:44` – `benedict-provider-gemini-endpoint` base URL for standard Generative Language API.
- `benedict-provider-gemini.el:52` – `benedict-provider-gemini-default-model` default Gemini model.
- `benedict-provider-gemini.el:126–134` – `benedict-provider-gemini-cloud-code-endpoint` and `benedict-provider-gemini-cloud-code-headers` for Code Assist.
- `benedict-provider-gemini.el:461–502` – `benedict-provider-gemini--build-body` building `contents`, `systemInstruction`, `generationConfig`, and optional `{ project, model, request }` wrapper.
- `benedict-provider-gemini.el:505–520` – `benedict-provider-gemini--encode-payload` and `benedict-provider-gemini--build-headers` encoding JSON and composing headers for Gemini/Code Assist.
- `benedict-provider-gemini.el:522–531` – `benedict-provider-gemini--endpoint-for` choosing between `generativelanguage.googleapis.com/v1beta/models/{model}:{action}` and `cloudcode-pa.googleapis.com/v1internal:{action}`.
- `benedict-provider-gemini.el:558–575` – `benedict-provider-gemini--handle-success` parsing responses and extracting `candidates`, `usageMetadata`, and text.
- `benedict-provider-gemini.el:598–636` – `benedict-provider-gemini--extract-error-message` and `benedict-provider-gemini--handle-error` decoding error payloads.
- `/opencode-gemini-auth/src/constants.ts:28–33` – `GEMINI_CODE_ASSIST_ENDPOINT` and `CODE_ASSIST_HEADERS`.
- `/opencode-gemini-auth/src/gemini/oauth.ts:80–98` – `authorizeGemini` building the OAuth authorization URL.
- `/opencode-gemini-auth/src/gemini/oauth.ts:103–163` – `exchangeGemini` exchanging code for tokens and fetching user info.
- `/opencode-gemini-auth/src/plugin/server.ts:23–46` – `startOAuthListener` HTTP server for OAuth callbacks.
- `/opencode-gemini-auth/src/plugin/request.ts:22–24` – `isGenerativeLanguageRequest` detection of Generative Language URLs.
- `/opencode-gemini-auth/src/plugin/request.ts:55–83` – Beginning of `prepareGeminiRequest` (header changes, URL parsing).
- `/opencode-gemini-auth/src/plugin/request.ts:88–107` – Building `cloudcode-pa` `v1internal:{action}` URLs and handling already-wrapped bodies.
- `/opencode-gemini-auth/src/plugin/request.ts:113–159` – Normalizing `generationConfig.thinkingConfig`, `system_instruction` → `systemInstruction`, and cache-related fields, then wrapping into `{ project, model, request }`.
- `/opencode-gemini-auth/src/plugin/request.ts:164–171` – Setting streaming-specific headers and Code Assist headers.
- `/opencode-gemini-auth/src/plugin/request.ts:189–283` – `transformGeminiResponse` normalizing responses and extracting usage/preview errors.
- `/opencode-gemini-auth/src/plugin/request-helpers.ts:40–73` – `normalizeThinkingConfig` handling thinking config naming variants.
- `/opencode-gemini-auth/src/plugin/request-helpers.ts:78–96` – `parseGeminiApiBody` handling array-wrapped responses.
- `/opencode-gemini-auth/src/plugin/request-helpers.ts:102–149` – `extractUsageMetadata` and `extractUsageFromSsePayload`.
- `/opencode-gemini-auth/src/plugin/request-helpers.ts:154–177` – `rewriteGeminiPreviewAccessError` for Gemini 3 preview errors.
- `/opencode-gemini-auth/src/plugin/project.ts:132–182` – `loadManagedProject` and `onboardManagedProject` for Code Assist project context.
- `/opencode-gemini-auth/src/plugin/project.ts:233–243` – `ensureProjectContext` computing effective project ID.
- `/opencode-gemini-auth/src/plugin.ts:29–120` (approximate) – `GeminiCLIOAuthPlugin` loader wiring `prepareGeminiRequest` and `transformGeminiResponse` into the provider’s fetch.

## Architecture Documentation

- Benedict’s Gemini provider is structured as a single Emacs Lisp backend that supports two auth modes:
  - `api-key`: uses `benedict-provider-gemini-endpoint` and model-specific paths to talk to the standard Generative Language API with API key credentials.
  - `oauth`: uses `cloudcode-pa.googleapis.com/v1internal:{action}` endpoints with OAuth Bearer tokens and a project-scoped `request` envelope, mirroring the Code Assist pattern used by opencode-gemini-auth.
- Request bodies in Benedict are built directly from Benedict’s own `:messages` and generation settings, rather than rewriting an upstream OpenAI-compatible payload. In contrast, opencode-gemini-auth sits as a transformer between an existing OpenAI-style client and Gemini/Code Assist, rewriting URLs and bodies but not originating them.
- Both systems use similar token acquisition flows (PKCE-based OAuth, refresh tokens against `oauth2.googleapis.com/token`), and both manage a project context via Cloud Code Assist management endpoints, albeit with different degrees of onboarding logic and project metadata handling.
- Error handling is more elaborate in opencode-gemini-auth (e.g., RetryInfo extraction, Gemini 3 preview hints) than in Benedict, which focuses on extracting message strings and status codes for logging and user-facing errors.

## Historical Context (from previous efforts)

- The existing effort `fix-gemini-pkce-multibyte-error` indicates prior work around Gemini OAuth flows, specifically PKCE verifier encoding. That effort focused on auth robustness rather than request URL/body shape for generateContent, but it provides context that Gemini integration has already undergone at least one iteration of bug fixing.

## Open Questions

- What exact HTTP 500 response bodies are returned by Google in the scenarios where Benedict’s provider fails? Capturing and examining these bodies in the Benedict logs (and/or a temporary debug buffer) would help disambiguate between model, project, or body-shape issues.
- Are Benedict users invoking the provider with any advanced configuration (e.g., thinking config, cached content, or custom `generationConfig`) that may produce request bodies differing from the minimal shapes described here?
- Is the same refresh token and project context that works in the opencode-gemini-auth CLI being used by Benedict, and if so, does the managed project ID match across both systems?
- Does the error occur in both `api-key` and `oauth` modes, or only in OAuth/Code Assist mode? This distinction would narrow the investigation to either standard Generative Language endpoints or Code Assist-specific flows.
