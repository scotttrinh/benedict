# Generic Credentials Store Implementation Plan

## Overview
Implement a shared, filesystem-backed credentials store for Benedict that centralizes provider credential resolution, fixes the Gemini OAuth persistence bug (caused by `auth-source` being effectively read-only from Emacs), and aligns with Opencode’s XDG-based auth layout while remaining compatible with existing `auth-source` and environment-variable based configurations.

## Current State Analysis
- Providers are self-contained and resolve credentials independently:
  - OpenRouter: `benedict-provider-openrouter--resolve-credential` checks `auth-source` then `OPENROUTER_API_KEY` (`benedict-provider-openrouter.el:70-79,1215-1246`).
  - Vercel: `benedict-provider-vercel--resolve-credential` checks `auth-source` then `AI_GATEWAY_API_KEY` (`benedict-provider-vercel.el:85-94,1253-1284`).
  - Gemini: `benedict-provider-gemini.el` implements OAuth (PKCE) and attempts to persist refresh tokens via `auth-source` (`benedict-provider-gemini.el:185-206,589-619,714-726`), which is broken because `auth-source` does not provide a generic write API from Emacs Lisp.
- There is no centralized “credentials store” abstraction in Benedict:
  - Each provider repeats similar patterns for `auth-source` lookup, env var fallback, and token redaction (`benedict-provider-openrouter.el:905-933,1215-1246`; `benedict-provider-vercel.el:943-971,1253-1284`).
  - No shared on-disk config like `auth.json` exists (`efforts/generic-credentials-store/research.md:24-29`).
- Opencode provides a precedent for an XDG-aligned auth store:
  - `auth.json` under `Global.Path.data` (XDG) stores `Auth.Api`, `Auth.Oauth`, and `Auth.WellKnown` entries with `0o600` permissions (`opencode/packages/opencode/src/global/index.ts:6-31`; `opencode/packages/opencode/src/auth/index.ts:6-69`).
  - MCP uses a similar `mcp-auth.json` file for OAuth tokens and state (`opencode/packages/opencode/src/mcp/auth.ts:7-123`).
  - The `opencode-gemini-auth` plugin persists Gemini OAuth tokens and project context into `auth.json` via `client.auth.set` (`opencode-gemini-auth/src/plugin/types.ts:3-8`; `opencode-gemini-auth/src/plugin/token.ts:126-153`).
- Benedict’s documented security posture today emphasizes `auth-source` and environment variables and explicitly avoids writing secrets to disk (`README.org:185,225`), but this is already in tension with the need for OAuth refresh tokens for Gemini (`efforts/generic-credentials-store/research.md:42-45`).

## Desired End State
- A reusable credentials store module (e.g., `benedict-credentials.el`) that:
  - Resolves credentials using a consistent precedence: **environment variables → filesystem-backed store → `auth-source`** (a deliberate breaking change from the current auth-source-first behavior, to make env-based overrides the most immediate and explicit mechanism).
  - Provides read/write operations for provider-specific credentials, with writes going only to the filesystem store (not `auth-source` or env vars).
  - Uses an XDG-compliant, Benedict-specific path for the on-disk store (e.g., `xdg-config-home/benedict/auth.json`), with sane fallbacks.
  - Stores secrets as plaintext JSON with filesystem permissions restricted to the user (mode `600`), mirroring Opencode’s approach.
- Provider modules (OpenRouter, Vercel, Gemini, future providers) delegate credential resolution to this shared store instead of duplicating logic.
- Gemini’s OAuth flow persists and refreshes tokens via the new filesystem store, eliminating dependence on `auth-source` writes while retaining compatibility with existing `auth-source` and env-based setups for read access.
- The plan documents how future at-rest encryption support (GPG/sops) could be layered on top of the filesystem store without breaking compatibility.

## What We’re NOT Doing
- Implementing full at-rest encryption for the credentials store in this effort (no GPG/sops integration yet).
- Changing the external HTTP transport layer (`benedict-http.el`) or provider-neutral chat APIs; all changes remain within provider and credentials layers.
- Migrating Opencode to read Benedict’s credentials, or vice versa; we only take architectural cues from Opencode’s `auth.json` and XDG pathing.
- Introducing a provider-auth UI/CLI inside Benedict comparable to Opencode’s `opencode auth` commands; interactions remain Emacs-driven for now.

## Implementation Approach
- Introduce a dedicated `benedict-credentials` module that encapsulates:
  - XDG-based config path resolution using the `xdg` library to locate a Benedict-specific credentials file.
  - A minimal JSON schema for credentials (per-provider records) that can represent both simple API keys and OAuth-style blobs, using nested auth-type keys (e.g., `api`, `oauth`) under each provider rather than a flat `:type` discriminant.
  - Read/write helpers that enforce `600` permissions on the credentials file and validate the in-memory representation.
- Refactor provider modules to call into `benedict-credentials` for resolving tokens while preserving their existing error messages and logging behavior as much as possible.
- For Gemini, rewire OAuth login and refresh flows so that refresh tokens and related metadata are written to and read from the filesystem store, with `auth-source` and env-var reads as fallback only.
- Incrementally add tests that cover:
  - Path resolution and file permission behavior.
  - Credential precedence and backward compatibility with existing `auth-source` and env-var setups.
  - Gemini OAuth flows using a temporary credentials file in a test-specific XDG directory.

## Phase 1: Define Credentials Store Module and Paths

### Overview
Create a new `benedict-credentials` module that defines the on-disk auth file location, in-memory schema, and basic read/write operations with secure permissions.

### Changes Required
- **File**: `benedict-credentials.el` (new)
  - **Changes**:
    - Define a new customization group and core settings:
      - `defgroup benedict-credentials` for store-related options.
      - `defcustom benedict-credentials-file-name "auth.json"` (string) – filename under the config directory.
      - `defcustom benedict-credentials-config-app-name "benedict"` (string) – app name passed to XDG helpers; allows future reuse if needed.
    - Implement XDG-based config directory and file resolution using the `xdg` package:
      - `(require 'xdg)` at top-level.
      - A private helper like:
        ```elisp
        (defun benedict-credentials--config-dir ()
          "Return the directory for Benedict credentials."
          (let* ((base (xdg-config-home))
                 (dir (expand-file-name benedict-credentials-config-app-name base)))
            (unless (file-directory-p dir)
              (make-directory dir t))
            dir))
        
        (defun benedict-credentials--file ()
          (expand-file-name benedict-credentials-file-name
                            (benedict-credentials--config-dir)))
        ```
    - Define an internal JSON shape and parsing helpers:
      - Use an alist keyed by provider id symbols (e.g., `openrouter`, `vercel`, `gemini`). Each provider entry is itself an alist keyed by auth-type symbols (e.g., `api`, `oauth`, `wellknown`) whose values are plists describing that auth method.
      - For this effort, support two basic auth-type entries for all providers (with Gemini using both):
        - API key (`api` key under the provider): plist like `(:token "..." :meta <optional-plist>)`.
        - OAuth (`oauth` key under the provider): plist like `(:refresh "..." :access "..." :expires <number-or-nil> :meta <optional-plist>)`.
      - This nested structure keeps the “auth type” as a key, not a flat `:type` field, and allows a provider (like Gemini) to hold both `api` and `oauth` entries simultaneously if needed.
      - Implement:
        ```elisp
        (defun benedict-credentials--read-all ()
          "Return the full credentials map as an alist."
          (let ((file (benedict-credentials--file)))
            (if (file-exists-p file)
                (with-temp-buffer
                  (insert-file-contents file)
                  (let ((json-object-type 'alist)
                        (json-key-type 'symbol)
                        (json-array-type 'list))
                    (json-read)))
              nil)))
        
        (defun benedict-credentials--write-all (data)
          "Write DATA (an alist) to the credentials file with 600 perms."
          (let* ((file (benedict-credentials--file))
                 (json-encoding-pretty-print t))
            (with-temp-file file
              (insert (json-encode data)))
            (set-file-modes file #o600)))
        ```
      - Keep the representation simple and flexible; the plan is for the General Agent to align with existing Emacs JSON usage in the repo.
    - Expose public helpers for provider-level access:
      - `benedict-credentials-get (provider-id auth-type)` – read the entry for a provider and specific auth-type (e.g., `'openrouter` + `'api`, `'gemini` + `'oauth`), returning the underlying plist for that auth-type.
      - `benedict-credentials-set (provider-id auth-type entry)` – set or update the given auth-type entry for the provider (merging with existing provider data if appropriate) and persist via `--write-all`.
      - `benedict-credentials-remove (provider-id &optional auth-type)` – delete a specific auth-type entry for the provider, or the entire provider entry if `auth-type` is nil, and persist.
    - Enforce permissions:
      - After writing, call `set-file-modes` with `#o600`.
      - Optionally, when reading, warn (via `message` or `benedict-logging`) if existing permissions are more permissive than `600`, but do not hard-fail to avoid breaking users.

### Success Criteria
#### Automated Verification
- [x] New unit tests (e.g., `test/benedict-credentials-test.el`) validate:
  - XDG path resolution uses `xdg-config-home` and app name `benedict` and creates the directory as needed.
  - `--write-all` writes valid JSON and enforces `#o600` on new files.
  - `benedict-credentials-get`, `set`, and `remove` behave as expected for simple API-key and OAuth-shaped entries.
  - Tests use a temporary directory by rebinding XDG-related behavior (e.g., via `cl-letf` around `xdg-config-home`) to avoid touching real user state.

#### Manual Verification
- [x] Evaluate `(benedict-credentials--file)` in Emacs and confirm it points under `~/.config/benedict/auth.json` (or the platform-appropriate XDG config dir).
- [x] Manually create a small JSON file with a test provider entry and verify `benedict-credentials-get` returns the expected structure.
- [x] Confirm the file mode on the created `auth.json` is `-rw-------` (600) via shell (`ls -l`) or Emacs `file-modes` inspection.

## Phase 2: Credential Resolution Abstraction and Precedence

### Overview
Introduce higher-level helpers that combine environment variables, the filesystem store, and existing `auth-source` resolution, defining a consistent precedence (env → file → auth-source) and preparing for provider integration.

### Changes Required
- **File**: `benedict-credentials.el`
  - **Changes**:
    - Add a defcustom to configure the precedence of sources while defaulting to “environment variables first” to support easy temporary overrides:
      ```elisp
      (defcustom benedict-credentials-sources '(env file auth-source)
        "Ordered list of credential sources to consult.

By default this is a breaking change from the previous auth-source-first behavior: environment variables now take precedence over filesystem and auth-source entries, so setting an env var like OPENROUTER_API_KEY temporarily overrides other stored credentials."
        :type '(repeat (choice (const env) (const file) (const auth-source)))
        :group 'benedict-credentials)
      ```
    - Implement composite resolution helpers:
      - `benedict-credentials-resolve-api-key (provider-id &key env-var auth-source-params)`:
        - For each source in `benedict-credentials-sources` (default: env → file → auth-source):
          - `env`: read `getenv env-var` and normalize to `(:token TOKEN :source 'env)`.
          - `file`: call `benedict-credentials-get provider-id 'api`, and if a plist with `:token` is present, return a credential plist `(:token TOKEN :source 'file)`, including any `:meta` if useful.
          - `auth-source`: reuse provider-specific `auth-source-search` calls (passed via `auth-source-params`) and normalize to `(:token TOKEN :source 'auth-source ...)`.
        - Return the first non-empty credential; otherwise signal an error with a provider-specific message.
      - `benedict-credentials-resolve-oauth (provider-id &key env-var auth-source-params)` for providers that support OAuth (primarily Gemini):
      - Document in docstrings that **writes only go to the filesystem store**; `auth-source` and env are read-only sources.

### Success Criteria
#### Automated Verification
- [x] Unit tests cover the resolution precedence for synthetic provider ids (env → file → auth-source by default):
  - When an env var is set, it wins over both file and `auth-source` (explicit temporary override behavior).
  - When relevant env vars are unset but the file store has a token, the file wins over `auth-source`.
  - When both env and file are empty, but `auth-source` is mocked to return a secret, that secret is used.
- [x] Tests verify that resolution helpers never attempt to write back to `auth-source` or env vars.

#### Manual Verification
- [x] In an Emacs session, simulate each scenario by temporarily binding `benedict-credentials-sources` and stubbing `auth-source-search` and `getenv` via `cl-letf`, and verify the returned credentials.
- [x] Confirm error messages for missing credentials still guide users to configure `auth-source` or env vars, while also mentioning the new filesystem store as the preferred mechanism.

## Phase 3: Integrate Store with OpenRouter and Vercel Providers

### Overview
Refactor OpenRouter and Vercel providers to use `benedict-credentials-resolve-api-key` while preserving behavior for existing users of `auth-source` and env vars.

### Changes Required
- **File**: `benedict-provider-openrouter.el`
  - **Changes**:
    - Require the new module near the top: `(require 'benedict-credentials)`.
    - Replace the body of `benedict-provider-openrouter--resolve-credential` to:
      - Call a new shared helper:
        ```elisp
        (defun benedict-provider-openrouter--resolve-credential ()
          (or (benedict-credentials-resolve-api-key
               'openrouter
               :env-var benedict-provider-openrouter-env-var
               :auth-source-params (list :host (benedict-provider-openrouter--host)
                                         :user benedict-provider-openrouter-auth-source-user))
              (error "...")))
        ```
      - Ensure the error message still references `auth-source` entries, the env var, and now the filesystem store path (e.g., `~/.config/benedict/auth.json`), so users know all options.
    - Keep `--auth-source-credential` and `--env-credential` as thin wrappers used by `benedict-credentials-resolve-api-key` when invoked with `auth-source-params` and `env-var` (or inline them if that’s simpler, but preserve tests and docstrings).

- **File**: `benedict-provider-vercel.el`
  - **Changes**:
    - Require `benedict-credentials`.
    - Update `benedict-provider-vercel--resolve-credential` in the same pattern:
      - Use `benedict-credentials-resolve-api-key` with provider id `'vercel`, env-var `benedict-provider-vercel-env-var`, and `auth-source-params` built from `benedict-provider-vercel--host` and `benedict-provider-vercel-auth-source-user`.
    - Keep redaction helpers and header building logic unchanged.

- **File**: `README.org`
  - **Changes**:
    - Update provider credential configuration sections to mention the new filesystem-backed store as the **preferred** method, e.g.:
      - Document `~/.config/benedict/auth.json` (or platform equivalent) as the place where `openrouter` and `vercel` tokens may be stored.
      - Provide a minimal JSON example:
        ```json
        {
          "openrouter": { "api": { "token": "sk-or-..." } },
          "vercel": { "api": { "token": "vcl-..." } },
        }
        ```

### Success Criteria
#### Automated Verification
- [x] Update or add tests for OpenRouter and Vercel credential resolution (new or existing tests in `test/benedict-provider-openrouter-test.el`, `test/benedict-provider-vercel-test.el`):
  - Ensure they exercise the file store path by temporarily binding a fake credentials file and verifying that provider header construction uses the token from the file when present.
  - Confirm that when the file is empty, auth-source mocks are used, and when those are empty, env mocks are used.
- [x] Existing HTTP tests (`test/benedict-http-test.el`) continue to pass, confirming headers are built correctly with the resolved token.

#### Manual Verification
- [x] Configure a test `auth.json` with API keys for OpenRouter and Vercel and confirm Benedict can send chat requests without `auth-source` or env vars set.
- [x] Remove the file and confirm that `auth-source`-only and env-only configurations still function as before.
- [x] Verify log output still redacts secrets and that error messages mention all supported credential sources.

## Phase 4: Fix Gemini OAuth Persistence via Filesystem Store

### Overview
Re-target Gemini’s OAuth login and token refresh flows to use the filesystem store, and introduce an explicit auth-method switch between `'oauth` (default) and `'api-key`. In `'oauth` mode we **only** consult the filesystem-backed `oauth` entry; in `'api-key` mode we resolve a token using env → file → auth-source and the nested `api` entry for Gemini.

### Changes Required
- **File**: `benedict-provider-gemini.el`
  - **Changes**:
    - Require `benedict-credentials`.
    - Define a clear on-disk representation for Gemini credentials in `auth.json` using nested auth-type keys, e.g.:
      ```json
      {
        "gemini": {
          "oauth": {
            "refresh": "<refresh-token>|<project-id>|<managed-project-id>",
            "access": "ya29...",
            "expires": 1734556800
          },
          "api": {
            "token": "AIza..."
          }
        }
      }
      ```
      - This mirrors the packed `refresh` string and fields used in `opencode-gemini-auth` (`opencode-gemini-auth/src/plugin/types.ts:3-8,67-71`), while also leaving room for a separate `api` entry when Gemini is configured for API-key auth.
    - Introduce a defcustom to select the Gemini auth method:
      - `defcustom benedict-provider-gemini-auth-method 'oauth` with allowed values `'oauth` and `'api-key` (and a docstring that clearly describes behavior and non-fallback semantics).
    - Update Gemini’s credential resolution logic:
      - For `'oauth` mode (default):
        - Use a helper like `benedict-provider-gemini--load-oauth-from-file` that calls `benedict-credentials-get 'gemini 'oauth` and maps the result into the provider’s internal auth representation.
        - **Do not** fall back to env vars or `auth-source` in this mode; if the `oauth` entry is missing or invalid, signal a clear error instructing the user to run the Gemini OAuth login command.
      - For `'api-key` mode:
        - Reuse `benedict-credentials-resolve-api-key` with provider-id `'gemini`, env-var (e.g., `benedict-provider-gemini-env-var` / `GEMINI_API_KEY`), and Gemini-specific `auth-source` params (host/user) to resolve an API token using env → file (`'api` entry) → auth-source.
        - This gives Gemini the same override behavior as OpenRouter/Vercel for API-key style auth.
    - Replace the broken `benedict-provider-gemini--persist-refresh-token` implementation:
      - Remove any direct `auth-source` writes.
      - Implement it in terms of `benedict-credentials-set 'gemini 'oauth` to write/update the OAuth entry:
        ```elisp
        (defun benedict-provider-gemini--persist-refresh-token (refresh access expires &optional project-id managed-project-id)
          (let* ((entry (list :refresh (benedict-provider-gemini--format-refresh refresh project-id managed-project-id)
                              :access access
                              :expires expires)))
            (benedict-credentials-set 'gemini 'oauth entry)))
        ```
      - Ensure any in-memory token caches (`benedict-provider-gemini--token-cache`) are kept in sync or invalidated appropriately after writes.
    - Update token refresh logic:
      - After successfully refreshing in `'oauth` mode, write back the updated auth snapshot (refresh/access/expires/project context) via `benedict-credentials-set 'gemini 'oauth`.
      - On errors like `invalid_grant` (revoked refresh token), clear or downgrade the stored `oauth` entry via `benedict-credentials-remove` (or set it to a degraded state) instead of attempting to write to `auth-source`.
    - Keep behavior around PKCE, redirect handling, and HTTP endpoints unchanged; only the persistence mechanism, resolution sources, and auth-method selection change.

### Success Criteria
#### Automated Verification
- [x] Extend existing Gemini tests (`test/benedict-provider-gemini-test.el`, `test/benedict-provider-gemini-http-test.el`) to cover:
  - Successful OAuth login in `'oauth` mode writing a new `oauth` entry for `'gemini` into a temporary credentials file (using a test XDG directory override).
  - Subsequent Emacs sessions reading the same `oauth` entry and using the stored refresh/access tokens without re-running login.
  - Token refresh updating the stored `oauth` entry and rotating refresh tokens when required.
  - Handling of revoked tokens (e.g., simulated `invalid_grant` response) clears or downgrades the stored `oauth` entry and surfaces a user-visible error.
  - `'api-key` mode resolving credentials using env → file (`api` entry) → auth-source, without ever reading the `oauth` entry.
- [x] Ensure tests do not depend on real Google endpoints; use mocks of HTTP requests and predictable token payloads.

#### Manual Verification
- [ ] Run the Gemini OAuth login flow in an Emacs session and confirm that `~/.config/benedict/auth.json` gains a `gemini` entry with expected fields.
- [ ] Restart Emacs and confirm Gemini requests succeed without re-running login.
- [ ] Manually corrupt or delete the `gemini` entry and confirm Benedict surfaces a clear error and offers guidance on re-running login.

## Phase 5: Documentation, Security Posture, and Future Encryption Hooks

### Overview
Align documentation with the new credentials store, clarify security posture (plaintext JSON with `600` permissions), and sketch hooks for future at-rest encryption without implementing it yet.

### Changes Required
- **File**: `README.org`
  - **Changes**:
    - Update the “Security & Privacy” section to reflect that:
      - Benedict now uses a filesystem-backed credentials store in addition to `auth-source` and env vars.
      - Credentials in `auth.json` are stored as plaintext but restricted by filesystem permissions to the current user (mode `600`).
      - `auth-source` remains fully supported as a read-only source and may still be preferred for users who want GPG-encrypted `.authinfo.gpg`.
    - Document the Gemini OAuth entry format and mention that project context may be encoded into the `refresh` string as in Opencode.

- **File**: `benedict-credentials.el`
  - **Changes**:
    - Add docstrings and comments clearly marking where future encryption support could be plugged in, e.g.:
      - A hook variable like `benedict-credentials-encode-function` / `benedict-credentials-decode-function` that defaults to identity but could later call out to sops/GPG.
      - Comments noting that any such integration must maintain the same in-memory schema and provider-facing API.

### Success Criteria
#### Automated Verification
- [ ] `nix run .#lint` passes, including checkdoc and byte-compilation for the new module and updated providers.

#### Manual Verification
- [ ] README changes accurately describe the behavior of the credentials store, the new precedence of sources (env → file → auth-source), and call out the breaking-change nature of env vars now overriding other credentials by default.
- [ ] Confirm there is a clear note that at-rest encryption is **not** yet implemented but is planned via pluggable encode/decode hooks.

## Testing Strategy
- **Unit Tests**:
  - New tests in `test/benedict-credentials-test.el` for path resolution, file permissions, and basic get/set/remove behavior.
  - Provider-specific tests for OpenRouter, Vercel, and Gemini credential resolution and header construction, exercising all precedence paths.
- **Integration Tests**:
  - End-to-end chat tests that simulate a configured `auth.json` for OpenRouter/Vercel/Gemini and ensure messages flow without touching real `auth-source` or env vars.
  - Gemini-specific integration tests that cover login, token refresh, and error handling using mocked HTTP responses.
- **Manual Tests**:
  - Local Emacs sessions verifying `auth.json` creation, updates, and correct fallback to legacy sources.
  - Manual inspection of file permissions and minimal editing/repair of `auth.json` to confirm resilience to minor corruption.

## References
- `efforts/generic-credentials-store/research.md` – Current state of credentials handling in Benedict.
- `efforts/oauth-auth-provider-setup/research.md` – Detailed mapping of Opencode auth storage, `auth.json`, and Gemini plugin behavior.
- `benedict-provider-openrouter.el`, `benedict-provider-vercel.el`, `benedict-provider-gemini.el` – Provider-specific auth logic to be refactored.
- `opencode/packages/opencode/src/auth/index.ts`, `opencode/packages/opencode/src/global/index.ts` – Reference implementation for XDG-based auth stores and `0o600` permissions.
- `opencode-gemini-auth/src/*` – Reference for Gemini OAuth token and project context representation.
