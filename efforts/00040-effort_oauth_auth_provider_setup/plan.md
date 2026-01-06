---
date: 2025-12-19T00:00:00-05:00
planner: gpt-5.1
git_commit: 683e44f3969737a4dec5aaffa6e02a72311bc9e8
branch: main
repository: benedict
topic: "Plan: Gemini OAuth provider using gemini-cli credentials"
status: draft
last_updated: 2025-12-19
---

# Plan: Gemini OAuth provider using gemini-cli credentials

## Goal

Add a `gemini` Benedict provider that:

- Uses OAuth 2.0 with PKCE to authenticate to Google Gemini.
- Works with OAuth-style tokens (refresh + access + expiry) stored in `auth-source` as the single on-disk credential store.
- Provides an Emacs-driven OAuth login flow that only writes a refresh token to `auth-source`.
- Supports text-only chat models, wired into the existing provider, chat, and HTTP layers.

## Non-Goals (Phase 1)

- Image / multimodal Gemini features.
- Full reproduction of Opencode Code Assist request/response transforms (we start with a direct Gemini chat API).
- Automatic Google Cloud project provisioning or troubleshooting; we assume a working project with Gemini enabled.

## Assumptions and Known Facts

1. [Design] The provider will use Google OAuth 2.0 with PKCE and a manual callback URL paste flow (no local HTTP listener in Emacs).
2. [Design] `auth-source` is the only on-disk credential store Benedict uses for Gemini; refresh tokens are persisted there, while access tokens remain in memory.
3. [Design] Users normally obtain credentials via the Emacs login flow; advanced users may configure `auth-source` entries manually, but Benedict does not integrate directly with any external tools' credential files.
4. [Design] The Benedict provider id will be `'gemini`.
5. [Design] Text-only Gemini chat is sufficient for the initial integration phase.


## Requirements

### Functional requirements

1. **New provider module `benedict-provider-gemini.el`**
   - Register a provider with `:id 'gemini`, `:name "Google Gemini"`, and a `:send` function that consumes Benedict's neutral request plist.
   - Optionally supply `:cancel` if we decide to support streaming cancellation in Phase 1; otherwise plan streaming for a later phase.

2. **Configuration and auth-source wiring**
   - Define a `defgroup benedict-provider-gemini`.
   - Add defcustoms:
     - `benedict-provider-gemini-auth-source-host` (default like `"gemini"` or `"google-gemini"`).
     - `benedict-provider-gemini-auth-source-user` (default user label, e.g. `"oauth"`).
     - `benedict-provider-gemini-endpoint` (base URL for the chosen Gemini chat API).
     - `benedict-provider-gemini-client-id`, `-client-secret`, `-redirect-uri`, `-scopes` (defaults matching `opencode-gemini-auth`'s `GEMINI_CLIENT_ID`, `GEMINI_CLIENT_SECRET`, `GEMINI_REDIRECT_URI`, `GEMINI_SCOPES`).
   - Ensure `benedict.el` requires `benedict-provider-gemini` so the provider registers on load.

3. **Credential resolution from auth-source**
   - Implement `benedict-provider-gemini--resolve-credential` that returns a plist like `(:access ACCESS :expires EXPIRES :refresh REFRESH)` or signals a user-facing error.
   - Resolution priority:
     1. Use `auth-source-search` with `benedict-provider-gemini-auth-source-host` and `benedict-provider-gemini-auth-source-user` (and any other required fields) to obtain a refresh token and any associated metadata.
     2. Optionally, support a provider-specific env var for the refresh token as a last-resort fallback, if we decide that is useful; otherwise, treat `auth-source` as the sole credential store.
      3. If no usable credentials are found, signal a clear error instructing the user to either run `M-x benedict-provider-gemini-login` or configure `auth-source` manually using the documented entry format.

   - If a refresh token exists but access is missing or expired, call the refresh helper (see below), update in-memory state, and update the stored refresh token in `auth-source` when rotation occurs.

4. **Token refresh helper**
   - Implement `benedict-provider-gemini--refresh-access-token` that:
     - POSTs to `https://oauth2.googleapis.com/token` with `grant_type=refresh_token`, `refresh_token`, `client_id`, `client_secret`.
     - On success, returns new `access`, `expires`, and a possibly updated `refresh` token.
      - On `invalid_grant` (or equivalent), clears or invalidates the corresponding `auth-source` entry and instructs the user to re-authenticate (normally via `M-x benedict-provider-gemini-login`, or by manually updating `auth-source` if they prefer).

     - On other errors, produces a detailed error (status + short reason) but does not log raw tokens.
   - Maintain a simple in-memory cache keyed by refresh token or provider id so we don't refresh on every request.

5. **Emacs OAuth login command (fallback path)**
   - Add `M-x benedict-provider-gemini-login`:
     - Generates a PKCE verifier/challenge (Elisp helper mirroring `generatePKCE`).
     - Constructs the authorization URL using `benedict-provider-gemini-client-id`, `-redirect-uri`, and `-scopes`, encoding state that includes the PKCE verifier.
     - Displays the URL and instructions, asking the user to open it in a browser and then paste the final redirect URL back into Emacs.
     - Parses the pasted callback URL, extracts `code` and `state`, decodes the verifier, and exchanges the code for tokens at `https://oauth2.googleapis.com/token`.
     - On success, writes only the refresh token into `auth-source` (with host/user from the defcustoms), seeds the in-memory cache, and confirms success to the user.
     - On failure, surfaces a clear error message.

6. **Request building and HTTP dispatch**
   - Implement `benedict-provider-gemini--send` (the provider `:send` function):
     - Resolves credentials via `--resolve-credential`.
     - For Phase 1, target a non-streaming text chat endpoint; optionally add streaming if the chosen API makes it simple.
     - Map Benedict's neutral messages (system, user, assistant) to the Gemini chat request schema defined by the selected endpoint.
     - Build headers: at minimum `Content-Type: application/json` and `Authorization: Bearer ACCESS_TOKEN`, plus optional `User-Agent` or telemetry headers.
     - Encode the payload as JSON and invoke `benedict-http-request` with `:url`, `:method "POST"`, `:headers`, `:body`, and `:stream` if streaming is enabled.
     - Parse responses, map Gemini output back into chat text, and call `:on-delta`, `:on-success`, `:on-error`, and `:on-complete` per Benedict's provider contract.

7. **Redaction and logging**
   - Implement `benedict-provider-gemini--redact-secret` and `benedict-provider-gemini--redact-headers` to mask `Authorization` and `Proxy-Authorization` header values before logging.
   - Ensure any lgr logging in this provider uses the redaction helpers, aligning with existing OpenRouter/Vercel logging behavior.

8. **Tests**
   - Add `test/benedict-provider-gemini-test.el` with ERT tests that:
     - Verify `--refresh-access-token` handles success and `invalid_grant`-style errors correctly (using mocks for HTTP).
     - Verify `--resolve-credential` correctly interprets `auth-source` entries into `(:access :expires :refresh)` plists and signals a clear error when no credentials are configured.
     - Verify headers passed into `benedict-http-request` include `Authorization: Bearer` and that redaction removes secrets from logs.
     - Validate that a simple neutral request produces a payload with the expected top-level Gemini fields (without chasing every corner of the schema).

9. **Documentation**
   - Update `README.org` to:
     - Introduce the `gemini` provider alongside OpenRouter, Vercel, Ollama, and Fake.
     - Document the Emacs-only login flow (`M-x benedict-provider-gemini-login`) and the expected `auth-source` entry format for Gemini credentials.
     - Note security guarantees: refresh token only in `auth-source`, access token in memory, secrets redacted from logs.

### Non-functional requirements

- **Security**
  - Never log full access or refresh tokens; use redaction consistently.
  - Only write refresh tokens to disk via `auth-source`; access tokens remain in memory.
  - Use HTTPS for all OAuth and Gemini API calls.

- **Performance**
  - Cache access tokens within an Emacs session to limit token refresh calls.
  - Keep request shaping and JSON encoding comparable in cost to existing providers.

- **Reliability**
  - The provider functions purely with `auth-source`-backed OAuth credentials; it does not depend on any external tools' credential files at runtime.
  - Authentication failures produce actionable, human-readable messages.

## Phases & Work Breakdown

### Phase 0: Confirm API targets & auth model

**Goal**: Eliminate key unknowns before coding provider internals.

Tasks:

1. **Summarize auth-source entry model**
    - Use `efforts/oauth-auth-provider-setup/research.md` and Google OAuth documentation to define the minimal set of fields Benedict needs to store in `auth-source` for Gemini (at least a refresh token, and optionally encoded project ids).
    - Capture this entry shape in this plan and in docstrings so that both the provider and the login flow share a single, clear contract.


2. **Select Gemini text chat endpoint and schema**
   - Consult current Gemini API documentation to choose the appropriate endpoint for text chat (e.g., `generateContent` or equivalent).
   - Capture request/response shapes needed for:
     - Messages / content.
     - Model name.
     - Streaming vs non-streaming behavior.
   - Add a short “API contract” subsection to this plan.

3. **PKCE implementation sketch**
   - Translate the `generatePKCE` + `encodeState` logic from TypeScript into an Elisp design:
     - Random verifier generation.
     - SHA256 + base64url encoding.
     - State encoding/decoding of the verifier.
   - Document any Emacs-version constraints or library requirements.

Exit criteria:

- We have a concise description of the expected `auth-source` entry format for Gemini credentials, suitable for README and implementation.
- We have a chosen Gemini chat endpoint and its minimal request/response shapes documented.
- We know how we'll implement PKCE in Elisp (or have a documented fallback if PKCE cannot be used for some reason).
 
 ### Phase 0 Findings (2025-12-19)
 
 #### Auth-source entry format
 
 - Host defaults to the customizable `benedict-provider-gemini-auth-source-host` (initially `"gemini"`), and user defaults to `benedict-provider-gemini-auth-source-user` (initially `"oauth"`).
 - Each auth entry stores **only** the refresh token as its `password`/`:secret`. Access tokens and expiry timestamps live exclusively in memory so we never write them to disk.
 - A minimal `~/.authinfo.gpg` stanza therefore looks like:
 
   #+begin_example
   machine gemini
   login oauth
   password 1//0gr3fr3sh-TOKEN-from-google
   port 443
   #+end_example
 
 - Advanced users can override any of the host/user/port fields via the defcustoms if they prefer to separate environments (e.g., `machine gemini-work`).
 - When Google rotates refresh tokens during the refresh exchange, we overwrite the stored `password` with the new refresh token using `auth-source-update`. The `:port` field remains available for future metadata (e.g., project ids) but is unused in Phase 1.
 - Credentials are resolved with `auth-source-search` restricted to these host/user values; if no entry exists we instruct the user to run `M-x benedict-provider-gemini-login`.
 
 #### Gemini text chat endpoint (non-streaming baseline)
 
 - **HTTP method + URL**: `POST https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`. We'll default to `gemini-2.0-flash` (text-only capable) but keep the model customizable via the standard `benedict-provider-model` or provider-level defaults.
 - **Headers**: `Content-Type: application/json` and `Authorization: Bearer <access token>` (from the OAuth exchange); optional `User-Agent` will identify Benedict.
 - **Request body**: JSON payload containing
   - `contents`: ordered list of chat turns, each `{:role "user"|"model"|"system", :parts [ {:text "..."} ... ]}` built directly from Benedict messages.
   - `systemInstruction` (optional) when Benedict has a system prompt.
   - `generationConfig` for temperature, top-p, max-output-tokens, which we wire to the existing provider-neutral request knobs later.
   - `safetySettings` (optional) to match defaults; we can omit initially and rely on Google defaults.
 - **Response body**: Gemini returns `candidates`, each containing `content.parts[].text`, `finishReason`, and `safetyRatings`. We treat the first candidate's text as the assistant reply and propagate `usageMetadata` for token accounting once we integrate streaming.
 - **Streaming**: When we enable streaming we switch to `:streamGenerateContent` (same base path) which yields incremental SSE-delimited JSON objects with partial `candidates`. Phase 1+2 work against the simpler non-streaming endpoint.
 
 #### PKCE and OAuth state plan
 
 - **Verifier generation**: Use `secure-hash` on random bytes for entropy, but keep the literal verifier as a base64url string per [RFC 7636]. Emacs provides `random`/`cl-loop` for bytes plus `url-base64-encode`. Implementation sketch:
   1. Generate 32 random bytes via `cl-loop repeat 32 collect (random 256)`; convert to string with `apply #'string`.
   2. Feed into `url-base64-encode` with `no-line-break` and `url-unreserved-chars` replacements to obtain a base64url string; strip padding `=` and replace `+`/`/` with `-`/`_`.
 - **Challenge derivation**: `secure-hash` with `'sha256` on the verifier (encoded as UTF-8), decode hex to bytes via `string-to-unibyte`, then base64url encode as above.
 - **State encoding**: Mirror `opencode-gemini-auth` by serializing `{ :verifier VERIFIER }` into JSON (using `json-encode`), then base64url encode the UTF-8 bytes. We'll add helpers `benedict-provider-gemini--encode-state`/`--decode-state` that perform this reversible transformation and signal errors when the state payload is invalid or mismatched.
 - **Storage**: During login, stash the verifier in a lexical binding while waiting for the callback URL; no disk writes. When exchanging the code, re-use the same verifier and compare with the decoded state to prevent CSRF/paste mistakes.
 - **Dependencies**: Only relies on built-in Emacs libs (`cl-lib`, `json`, `url-parse`, `url-util`). No external modules or subprocesses are required, so it works in the default Benedict environment.
 
 ### Phase 1: Provider skeleton and configuration


**Goal**: Introduce a compile-clean `benedict-provider-gemini.el` that registers the provider and exposes configuration variables, but does not yet send real requests.

Tasks:

1. Create `benedict-provider-gemini.el` with:
   - `defgroup` and basic defcustoms (endpoint, auth-source host/user, OAuth client settings).
   - A placeholder `--send` that signals a clear "not implemented" error.
   - Provider registration using `benedict-provider-register` with `:id 'gemini`.

2. Wire into core:
   - Ensure `benedict.el` requires `benedict-provider-gemini` so it self-registers when Benedict loads.
   - Add a minimal note in `README.org` that `gemini` is experimental / under development.

3. Verify basic wiring:
   - Run tests or a small manual experiment to confirm that setting `benedict-provider` to `'gemini` causes the new provider to be selected and its placeholder `--send` to be called.

Exit criteria:

- Emacs loads cleanly with the new provider.
- `benedict-provider-current` can resolve `'gemini` and `--send` is reachable.

### Phase 2: Credential resolution & token refresh

**Goal**: Implement the credential resolution and refresh logic based on OAuth-style tokens stored in `auth-source`, without yet wiring full request shaping.

Tasks:

1. Implement `benedict-provider-gemini--resolve-credential`:
   - Resolve credentials from `auth-source` into a plist `(:access ACCESS :expires EXPIRES :refresh REFRESH)` using the configured host/user conventions.
   - If no suitable `auth-source` entry is found, signal a clear error instructing the user to either run `M-x benedict-provider-gemini-login` or configure `auth-source` manually using the documented entry format.
   - Add in-memory caching of access tokens keyed by refresh token.

2. Implement `benedict-provider-gemini--refresh-access-token`:
   - Call Google token endpoint with refresh tokens.
   - Handle success, `invalid_grant`, and generic errors.
   - Update cache and, if appropriate, `auth-source` when refresh tokens rotate.

3. Add tests for these functions:
   - Use mocks for file IO and HTTP to cover success and failure paths.

Exit criteria:

- Credential resolution works in isolation and passes tests.
- Clear error messages exist for missing credentials and revocation.

### Phase 3: Emacs OAuth login command

**Goal**: Provide an Emacs-only way to obtain and store a refresh token compatible with the provider.

Tasks:

1. Implement PKCE + state helpers in Elisp.
2. Implement `benedict-provider-gemini-login`:
   - Build authorization URL.
   - Show URL + instructions.
   - Read callback URL from user and extract `code` + `state`.
   - Exchange code for tokens at the Google token endpoint.
   - Store refresh token into `auth-source` and update in-memory cache.

3. Manual test:
   - Run the login command, complete OAuth, and verify an auth-source entry is created.
   - Confirm that subsequent calls to `--resolve-credential` pick up the stored refresh token.

4. Deferred automation:
   - Add an async ERT integration test that `cl-letf`s `browse-url`, `read-string`, `auth-source` writes, and `benedict-provider-gemini--token-request` so `benedict-provider-gemini-login` can run in batch and assert the refresh token lands in the fake auth-source entry.
   - The test should simulate a full PKCE roundtrip: capture the generated verifier/state, feed back a synthetic redirect URL, and ensure the cached credentials/access token cache are seeded as expected.

Exit criteria:

- `benedict-provider-gemini-login` reliably creates valid credentials for the provider.


### Phase 4: Request shaping, HTTP integration, and basic chat

**Goal**: Wire `benedict-provider-gemini--send` into the HTTP layer and achieve a working text chat flow.

Tasks:

1. Implement request mapping from Benedict messages to Gemini chat request JSON using the Phase 0 API contract.
2. Implement `benedict-provider-gemini--build-headers` producing the necessary `Authorization` and `Content-Type` headers (and optional telemetry headers).
3. Implement full `--send`:
   - Call `--resolve-credential`.
   - Build payload and headers.
   - Call `benedict-http-request` with appropriate `:stream` setting.
   - Parse response and feed chat callbacks.

4. Add tests that:
   - Mock `benedict-http-request` and assert correct URL, headers, and payload for a simple conversation.
   - Validate that responses are turned into assistant text as expected.

5. Manual tests:
   - With OAuth-style credentials configured directly in `auth-source` (without using the Emacs login flow), send a chat from Benedict and confirm Gemini responses.
   - With only Emacs-based login, repeat the same test.

Exit criteria:

- Sending a text chat message via `gemini` works end-to-end for both credential sources (Opencode reuse and Emacs login).

### Phase 5: Redaction, polish, and documentation

**Goal**: Align security/observability with other providers and document how to use Gemini.

Tasks:

1. Implement redaction helpers and apply them to any logging in `benedict-provider-gemini.el`.
2. Expand `README.org`:
   - Describe the `gemini` provider, its configuration options, and how it uses OAuth-style tokens stored in `auth-source`.
   - Explain how to use `benedict-provider-gemini-login` to obtain credentials, and briefly document how an advanced user could configure `auth-source` directly using the same entry format.
   - Highlight security posture.
3. Run full test and lint suite (e.g., `nix run .#test`, `nix run .#lint`) and fix any provider-specific issues.

Exit criteria:

- Provider code matches Benedict's logging and security expectations.
- Documentation is sufficient for a user to configure and use the Gemini provider without referring to the effort docs.

## Risks and Mitigations

- **Risk**: Gemini API surface changes (endpoints or request schema).
  - *Mitigation*: Keep the request mapping code localized in a few helpers, documented against the current API version, and add tests that serve as living examples.

- **Risk**: PKCE/state implementation errors cause confusing auth failures.
  - *Mitigation*: Keep the Elisp implementation small and well-tested, and surface detailed error messages when Google rejects the code exchange.

- **Risk**: Misconfigured credentials leak tokens in logs.
  - *Mitigation*: Centralize header redaction and ensure all logging of headers goes through it; add tests for redaction behavior.

## Acceptance Criteria

1. With `benedict-provider` set to `'gemini` and valid OAuth-style Gemini credentials stored in `auth-source`, sending a text chat yields a successful response.
2. On a fresh machine with no credentials, running `M-x benedict-provider-gemini-login` succeeds in creating an `auth-source` entry, after which Gemini chat works normally.
3. No tests in `test/` fail due to the new provider, and new provider-specific tests pass.
4. `README.org` contains a clear "Gemini provider" section documenting configuration options, the Emacs login flow, and the expected `auth-source` entry format.
5. Logging never prints full access or refresh tokens, as verified by tests and spot inspection of logs.
