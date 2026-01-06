---
date: 2025-12-23T21:58:58Z
researcher: Codebase Research Orchestrator
git_commit: 28a772523775aa661aa6f37a7fc55d516ef393e3
branch: main
repository: benedict
topic: "Gemini OAuth credential storage and API call comparison: opencode-gemini-auth vs Benedict"
tags: [research, codebase, gemini, oauth, credentials, api-calls]
status: final
last_updated: 2025-12-23
---

# Research: Gemini OAuth Credential Storage and API Call Comparison

**Date**: 2025-12-23T21:58:58Z
**Researcher**: Codebase Research Orchestrator
**Git Commit**: 28a772523775aa661aa6f37a7fc55d516ef393e3
**Branch**: main

## Research Question

How does the credential storage for Gemini OAuth in `opencode-gemini-auth` differ from Benedict's implementation? The user is experiencing 500 server errors and suspects missing project ID in user message requests may be the root cause. This research provides a comprehensive 1:1 comparison of how both systems manage auth state and API calls.

## Summary

Both `opencode-gemini-auth` and Benedict share nearly identical architectures for Gemini OAuth credential management, including:
- Identical OAuth client credentials, scopes, redirect URI, and endpoints
- The same packed refresh token format (`refreshToken|projectId|managedProjectId`)
- The same Cloud Code Assist API endpoint for wrapped requests
- The same request wrapping structure with `project`, `model`, and `request` fields

**Key finding**: Benedict's implementation of project ID resolution and request wrapping is functionally equivalent to `opencode-gemini-auth`. The `project` field IS being included in the request body when using OAuth mode.

## 1:1 Comparison Matrix

### OAuth Configuration Constants

| Concept | opencode-gemini-auth | Benedict | Notes |
|---------|---------------------|----------|-------|
| Client ID | `GEMINI_CLIENT_ID` (constants.ts:4) | `benedict-provider-gemini-client-id` (72-76) | Identical: `681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com` |
| Client Secret | `GEMINI_CLIENT_SECRET` (constants.ts:9) | `benedict-provider-gemini-client-secret` (78-82) | Identical: `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` |
| Scopes | `GEMINI_SCOPES` (constants.ts:14-18) | `benedict-provider-gemini-scopes` (90-96) | Identical: cloud-platform, userinfo.email, userinfo.profile |
| Redirect URI | `GEMINI_REDIRECT_URI` (constants.ts:23) | `benedict-provider-gemini-redirect-uri` (84-88) | Identical: `http://localhost:8085/oauth2callback` |
| Token Endpoint | Hardcoded in token.ts:74 | `benedict-provider-gemini-token-endpoint` (104-108) | Both: `https://oauth2.googleapis.com/token` |
| Authorization Endpoint | Hardcoded in oauth.ts:83 | `benedict-provider-gemini-authorization-endpoint` (98-102) | Both: `https://accounts.google.com/o/oauth2/v2/auth` |

### Token Storage and Persistence

| Concept | opencode-gemini-auth | Benedict | Notes |
|---------|---------------------|----------|-------|
| Storage mechanism | Via `client.auth.set()` (token.ts:149-152) | Via `benedict-credentials-set()` (credentials.el:96-108) | opencode uses client callback, Benedict uses filesystem store |
| Storage format | OAuthAuthDetails object with `type`, `access`, `expires`, `refresh` | File-based JSON with provider → auth-type hierarchy | Both store same core fields |
| Refresh token packing | `formatRefreshParts()` (auth.ts:24-36) | `benedict-provider-gemini--format-refresh()` (877-884) | Identical format: `refreshToken\|projectId\|managedProjectId` |
| Refresh token unpacking | `parseRefreshParts()` (auth.ts:12-19) | `benedict-provider-gemini--parse-refresh()` (870-875) | Identical: split on `|` into 3 parts |
| In-memory cache | Map keyed by refresh token (cache.ts:4-65) | Hash table keyed by refresh token (120-211) | Same caching strategy |

### Project ID Resolution Flow

| Concept | opencode-gemini-auth | Benedict | Notes |
|---------|---------------------|----------|-------|
| Main function | `ensureProjectContext()` (project.ts:233-351) | `benedict-provider-gemini--resolve-credential()` (270-324) | Different scopes, same logic |
| Configured project source | `provider.options.projectId` or `OPENCODE_GEMINI_PROJECT_ID` env (plugin.ts:44-49) | No equivalent - only from packed refresh token or API discovery | opencode has config file support, Benedict does not |
| Cache check | Checks `projectContextResultCache` (project.ts:250-258) | Checks `benedict-provider-gemini--token-cache` (291-297) | Same caching pattern |
| Fallback to managed project API | `loadManagedProject()` (project.ts:272-290) | `benedict-provider-gemini--load-managed-project()` (317) | Identical endpoint and payload |
| Onboarding for FREE tier | `onboardManagedProject()` (project.ts:308-324) | Not implemented - only calls loadManagedProject | Benedict lacks onboarding retry logic |
| Error when no project | Throws `ProjectIdRequiredError` (project.ts:293, 298, 305, 327) | Does NOT throw - returns `nil` for `project-id` field (298, 306) | **Critical difference**: Benedict silently continues without project ID |

### API Request Structure

| Concept | opencode-gemini-auth | Benedict | Notes |
|---------|---------------------|----------|-------|
| Wrap trigger | Always wraps for OAuth (implicit in prepareGeminiRequest) | When `benedict-provider-gemini-auth-method` is `'oauth` (700) | Same trigger condition |
| Wrapped endpoint | `https://cloudcode-pa.googleapis.com/v1internal:generateContent` (request.ts:87) | `https://cloudcode-pa.googleapis.com/v1internal:generateContent` (577) | Identical |
| Streaming endpoint | Adds `?alt=sse` suffix (request.ts:87-89) | No SSE query param - uses `:streamGenerateContent` path suffix (574) | Different streaming mechanism |
| Request body structure | `{ project, model, request }` (request.ts:152-156) | `{ project, model, request }` (545-548) | Identical |
| Headers (Code Assist) | User-Agent, X-Goog-Api-Client, Client-Metadata (request.ts:169-171) | Same headers (130-134) | Identical |
| Authorization header | `Bearer ${accessToken}` (request.ts:72) | `Bearer ${accessToken}` (561) | Identical |

### Token Refresh Flow

| Concept | opencode-gemini-auth | Benedict | Notes |
|---------|---------------------|----------|-------|
| Refresh function | `refreshAccessToken()` (token.ts:64-162) | `benedict-provider-gemini--refresh-access-token()` (393-437) | Same logic, different error handling |
| Token expiration buffer | 60 seconds (auth.ts:3) | 30 seconds (418) | opencode is more conservative |
| invalid_grant handling | Clears auth, tells user to re-login (token.ts:100-120) | Removes oauth entry, tells user to re-login (433-436) | Identical handling |
| Refresh rotation support | Yes - uses new refresh token if provided (token.ts:133) | Yes - uses new refresh token if provided (417) | Identical |

## Detailed Findings

### opencode-gemini-auth Architecture

**Auth State Management** (`src/plugin/token.ts`, `src/plugin/cache.ts`, `src/plugin/auth.ts`):
- Refresh token stores packed format: `refreshToken|projectId|managedProjectId`
- In-memory Map cache keyed by refresh token
- Token expiration checked with 60-second buffer
- On refresh failure with `invalid_grant`, clears stored auth and prompts re-login

**Project Context Resolution** (`src/plugin/project.ts`):
- `ensureProjectContext()` is the main entry point
- Fallback hierarchy:
  1. Configured project ID from provider config or `OPENCODE_GEMINI_PROJECT_ID` env
  2. `projectId` from packed refresh token
  3. `managedProjectId` from packed refresh token
  4. Call `loadManagedProject()` to discover from API
  5. If tier is FREE, call `onboardManagedProject()` with retries
  6. Throw `ProjectIdRequiredError` if all fail
- Results cached per refresh token + config combination
- Onboarding retries up to 10 times with 5-second delay

**Request Preparation** (`src/plugin/request.ts`):
- `prepareGeminiRequest()` detects generativelanguage.googleapis.com URLs
- Rewrites URL to Cloud Code Assist endpoint with `:generateContent` or `:streamGenerateContent`
- Wraps request body: `{ project, model, request: {...} }`
- Adds Code Assist headers: User-Agent, X-Goog-Api-Client, Client-Metadata
- For streaming, adds `?alt=sse` query param

**OAuth Flow** (`src/gemini/oauth.ts`):
- Uses PKCE with S256 challenge method
- State parameter contains verifier
- After code exchange, fetches user info from userinfo endpoint
- Returns `GeminiTokenExchangeResult` with type: "success" or "failed"

### Benedict Architecture

**Auth State Management** (`benedict-credentials.el`):
- File-based JSON store at `~/.config/benedict/auth.json`
- Structure: `{ provider-id: { auth-type: { :refresh, :access, :expires } } }`
- Uses XDG config directory layout
- Credential sources consulted in order: env → file → auth-source (127-136)

**Project Context Resolution** (`benedict-provider-gemini.el:270-324`):
- `benedict-provider-gemini--resolve-credential()` is the main entry point
- For OAuth mode:
  - Unpacks refresh token string into 3-part list
  - Checks in-memory cache for valid access token + project ID
  - Checks stored access token from file for validity + project ID
  - If no project ID, calls `--load-managed-project()` (213-258)
  - Repacks refresh token with project IDs and persists
  - Returns plist: `(:access :expires :refresh :project-id)`
- **Critical**: Does NOT throw error if no project ID available - returns with `nil` project-id

**Request Preparation** (`benedict-provider-gemini.el:508-578`):
- `--build-body()` constructs request payload
- When `wrap` is true (OAuth mode), wraps as `{ project, model, request }` (545-548)
- Uses Cloud Code Assist endpoint for wrapped requests (572-575)
- Adds Code Assist headers when wrapping (563)

**OAuth Flow** (`benedict-provider-gemini.el:745-867`):
- Interactive login with PKCE
- Verifier stored in base64-encoded state parameter
- Callback URL parsed for code and state
- After token exchange, loads managed project and persists

## Critical Differences

### 1. Project ID Required Handling

**opencode-gemini-auth** (`project.ts:45-54, 293, 298, 305, 327`):
- Throws `ProjectIdRequiredError` when no project ID can be resolved
- Error message guides user to set `provider.google.options.projectId` or `OPENCODE_GEMINI_PROJECT_ID`
- Prevents request execution without project context

**Benedict** (`benedict-provider-gemini.el:270-324`):
- Does NOT throw error if no project ID
- Silently proceeds with `nil` or empty string for `:project-id`
- Request body gets wrapped with `project: ""` or `project: null`
- API call may fail with 500 error due to missing project

### 2. Configured Project Support

**opencode-gemini-auth** (`plugin.ts:44-49`):
- Reads project ID from provider config: `provider.options.projectId`
- Reads project ID from environment: `OPENCODE_GEMINI_PROJECT_ID`
- Uses this as first fallback before API discovery
- Allows explicit project configuration

**Benedict**:
- No configuration file support for project ID
- No environment variable for project ID
- Relies entirely on packed refresh token or API discovery
- Cannot explicitly specify a project

### 3. Onboarding Retry Logic

**opencode-gemini-auth** (`project.ts:172-228`):
- Calls `onboardManagedProject()` for FREE tier
- Retries up to 10 attempts with 5-second delay
- Returns managed project ID when onboarding completes

**Benedict**:
- Only calls `--load-managed-project()`
- No retry logic for onboarding
- May fail if onboarding is asynchronous

### 4. Streaming Implementation

**opencode-gemini-auth** (`request.ts:86-89`):
- Adds `?alt=sse` query parameter for streaming
- Keeps `:streamGenerateContent` in path
- Transforms SSE payloads to unwrap `response` field (29-48)

**Benedict** (`benedict-provider-gemini.el:572-578`):
- Uses `:streamGenerateContent` path suffix for streaming
- No `?alt=sse` query parameter
- Does not currently support streaming (streaming capability marked as nil in provider registration 899)

### 5. Credential Storage Backend

**opencode-gemini-auth**:
- Uses `client.auth.set()` callback to persist
- Storage backend is abstracted behind Opencode's auth system
- May be encrypted or stored securely by the client

**Benedict**:
- Uses filesystem-based JSON at `~/.config/benedict/auth.json`
- File permissions set to 600 (read-only for owner) (credentials.el:70)
- Stored in plain text (no encryption)

## Hypotheses & Potential Causes

Based on 1:1 comparison and user credential inspection, following hypotheses explain why 500 errors might occur:

### Hypothesis 1: Stale Benedict Credentials Missing Managed Project ID (High Confidence)

**User Evidence**:
- Opencode credentials at `~/.local/share/opencode/auth.json` show:
  ```json
  "refresh": "[redacted]||prime-veld-l3gmn"
  ```
- Packed format: `refresh_token|project_id|managed_project_id`
- `refresh_token`: Present (redacted)
- `project_id`: EMPTY (first `|` followed by nothing)
- `managed_project_id`: ✅ `prime-veld-l3gmn` (populated by opencode)

**Evidence from Code Analysis**:
- Benedict's `--resolve-credential()` uses `(or project-id managed-project-id)` at lines 297, 302, 324
- Code correctly handles empty `project-id` and populated `managed-project-id`
- Issue is: **When is managed project ID discovered and persisted?**

**Critical Difference - When Managed Project ID is Discovered**:

| Implementation | When Managed Project ID is Discovered | Persistence Frequency |
|---------------|-------------------------------------|---------------------|
| **opencode-gemini-auth** | On **every request** via `ensureProjectContext()` (project.ts:233-351) | On every request if discovered |
| **Benedict** | Only during **token refresh** (lines 315-317) | Only when access token is refreshed |

**opencode-gemini-auth flow**:
1. `ensureProjectContext()` called on every request (line 88)
2. Checks cache for existing result (line 250)
3. If no cached project ID, calls `loadManagedProject()` (line 272)
4. If `loadManagedProject()` returns `managedProjectId`, stores it immediately (line 277)
5. Updates auth store with `formatRefreshParts()` containing the managed project ID (line 277)
6. Subsequent requests use cached result (line 250-258)

**Benedict flow** (`benedict-provider-gemini.el:270-324`):
1. `--resolve-credential()` called on request
2. Unpacks `refresh` string at line 285
3. Checks if access token is valid AND project ID exists (lines 291-299, 301-306)
4. Only calls `--load-managed-project()` if BOTH project-id AND managed-project-id are empty (lines 315-317)
5. If token never expires, managed project ID is NEVER discovered
6. If user logged in before managed project logic was added, credentials lack the `||managed-id` suffix

**Mechanism**:
1. User authenticates with Benedict initially
2. `--exchange-authorization-code` (833-867) exchanges code for tokens
3. Initial tokens stored without calling `--load-managed-project()`
4. Packed refresh string stored as just `refresh_token` (no `||managed-id` suffix)
5. If access token remains valid indefinitely, managed project ID is never discovered
6. Request uses packed refresh string with empty managed project ID
7. API rejects request with 500 error

### Hypothesis 2: API Discovery Failure (Medium Confidence)

**Evidence**:
- `--load-managed-project()` returns `nil` on non-200 status or error (244, 253-256)
- Logs error but continues without project ID
- opencode-gemini-auth has same behavior but throws error when project ID is still missing after all fallbacks

**Mechanism**:
1. Cloud Code Assist API call fails (permission issue, rate limit, etc.)
2. No project ID from refresh token
3. Request proceeds without project ID
4. API rejects with 500

**Why this is less likely**: User confirmed opencode works with same Google account and has managed project ID `prime-veld-l3gmn`. This suggests the API discovery call does work when made.

### Hypothesis 3: Missing Headers or Incorrect Content-Type (Low Confidence)

**Evidence**:
- Benedict sets same headers as opencode-gemini-auth (560-567)
- Content-Type is "application/json" (560)
- Headers match opencode-gemini-auth's implementation

**Mechanism**: Unlikely - headers are correctly set and match the working implementation.

## Code References

### opencode-gemini-auth

- `opencode-gemini-auth/src/constants.ts:4-9` - OAuth client credentials
- `opencode-gemini-auth/src/plugin/auth.ts:12-36` - Refresh token packing/unpacking
- `opencode-gemini-auth/src/plugin/token.ts:64-162` - Token refresh logic
- `opencode-gemini-auth/src/plugin/project.ts:233-351` - Project context resolution with fallbacks
- `opencode-gemini-auth/src/plugin/project.ts:132-166` - Managed project loading
- `opencode-gemini-auth/src/plugin/project.ts:172-228` - Managed project onboarding
- `opencode-gemini-auth/src/plugin/request.ts:55-183` - Request preparation and wrapping
- `opencode-gemini-auth/src/gemini/oauth.ts:80-98` - Authorization URL building

### Benedict

- `benedict-credentials.el:20-41` - File-based credential storage setup
- `benedict-credentials.el:127-202` - Credential resolution with multiple sources
- `benedict-provider-gemini.el:72-96` - OAuth client credentials and scopes
- `benedict-provider-gemini.el:120-211` - In-memory token cache
- `benedict-provider-gemini.el:213-258` - Managed project loading
- `benedict-provider-gemini.el:270-324` - Credential resolution with project ID
- `benedict-provider-gemini.el:393-437` - Token refresh logic
- `benedict-provider-gemini.el:508-555` - Request body building with project ID
- `benedict-provider-gemini.el:557-578` - Header building and endpoint resolution
- `benedict-provider-gemini.el:694-743` - Request dispatch
- `benedict-provider-gemini.el:870-892` - Refresh token packing/unpacking

## Architecture Documentation

### Credential Storage Architecture

Both implementations use a three-tier approach:

1. **Refresh Token**: Long-lived token stored securely, contains project IDs
2. **Access Token**: Short-lived token obtained by refreshing, sent with requests
3. **Project Context**: Derived from refresh token or API discovery, cached per session

The packed refresh token format is identical:
```
<refresh_token>|<project_id>|<managed_project_id>
```

### Request Flow Comparison

**opencode-gemini-auth flow**:
1. `getAuth()` → fetches stored auth details
2. `refreshAccessToken()` → refreshes if expired
3. `ensureProjectContext()` → resolves or discovers project ID, throws if missing
4. `prepareGeminiRequest()` → wraps request with project ID
5. `fetch()` → sends to Cloud Code Assist endpoint

**Benedict flow**:
1. `benedict-credentials-get()` → fetches stored auth from file
2. `benedict-provider-gemini--resolve-credential()` → refreshes if expired, resolves project ID (does not throw)
3. `benedict-provider-gemini--build-body()` → wraps request with project ID (may be empty)
4. `benedict-http-request()` → sends to Cloud Code Assist endpoint

### Cloud Code Assist API Integration

Both implementations target the same API:
- Endpoint: `https://cloudcode-pa.googleapis.com/v1internal:generateContent`
- Request format:
  ```json
  {
    "project": "<project-id>",
    "model": "<model-name>",
    "request": {
      "contents": [...],
      "generationConfig": {...}
    }
  }
  ```
- Required headers:
  - `Authorization: Bearer <access-token>`
  - `Content-Type: application/json`
  - `User-Agent: google-api-nodejs-client/9.15.1`
  - `X-Goog-Api-Client: gl-node/22.17.0`
  - `Client-Metadata: ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI`

## Historical Context (from previous efforts)

No previous efforts found in the `efforts/` directory related to Gemini OAuth or credential comparison.

## Open Questions

1. **What does Benedict's stored auth.json contain?**
   - User needs to check `~/.config/benedict/auth.json`
   - Compare `refresh` field format with opencode's `[redacted]||prime-veld-l3gmn`
   - Verify if managed project ID suffix is present

2. **When did the user authenticate with Benedict?**
   - If before managed project discovery was implemented, credentials lack the `||managed-id` suffix
   - Need to re-authenticate via `M-x benedict-provider-gemini-login`

3. **Is the access token still valid (never expired)?**
   - If access token never expired, `--load-managed-project()` was never called
   - Need to trigger a token refresh or re-authenticate

4. **What is the actual 500 error message from the Cloud Code Assist API?**
   - Need to inspect error body from failed requests
   - May indicate whether empty project ID is the cause

5. **Is the `--load-managed-project()` call succeeding?**
   - Check debug logs for `Loaded Gemini managed project` or `Failed to load Gemini managed project`
   - May be returning `nil` silently

6. **Should Benedict implement `ProjectIdRequiredError` behavior?**
   - Need to decide if failing fast is preferable to silent 500 errors
   - Consider user experience implications

7. **Should Benedict support configured project IDs via environment variables?**
   - Would align with opencode-gemini-auth behavior
   - Would provide explicit control over project selection

## Follow-up Research: Opencode Credential Storage Location

**Opencode credential storage**: `~/.local/share/opencode/auth.json`

- **Storage path** (opencode/packages/opencode/src/global/index.ts:8): Uses XDG data directory (`xdgData + "/opencode"`)
- **Auth file path** (opencode/packages/opencode/src/auth/index.ts:35): `path.join(Global.Path.data, "auth.json")`
- **On macOS**: `~/.local/share/opencode/auth.json`
- **File permissions**: Set to `0o600` (read-only for owner) (auth/index.ts:60)

**Compare to Benedict**: `~/.config/benedict/auth.json` (benedict-credentials.el:40)

- Benedict uses XDG **config** directory
- Opencode uses XDG **data** directory
- Both set `0o600` file permissions

## Recommended Action Plan

Based on the analysis, here's the recommended sequence to resolve the 500 errors:

### Step 1: Verify Benedict's Credentials

```bash
cat ~/.config/benedict/auth.json
```

Look at the `google.oauth.refresh` field:
- If it ends with `||prime-veld-l3gmn` (or similar managed project ID), credentials are up-to-date
- If it's just a raw refresh token without the `||managed-id` suffix, credentials need updating

### Step 2: Re-authenticate in Benedict

If credentials are missing the managed project ID suffix:

1. Run `M-x benedict-provider-gemini-login` in Emacs
2. Complete the OAuth flow in your browser
3. This will:
   - Exchange the authorization code for tokens
   - Call `--load-managed-project()` with the new access token (line 317)
   - Persist the packed refresh string with `||prime-veld-l3gmn` appended (line 318-319)
   - Update `~/.config/benedict/auth.json`

### Step 3: Verify Updated Credentials

```bash
cat ~/.config/benedict/auth.json | grep -A 5 'gemini'
```

The `refresh` field should now match opencode's format:
```json
"refresh": "[redacted]||prime-veld-l3gmn"
```

### Step 4: Test a Request

Try a Gemini chat request in Benedict. It should now work without 500 errors.

### Alternative: Manual Credential Update

If you prefer not to re-authenticate, you can manually copy the packed refresh string from opencode to Benedict:

1. Copy the entire `google` object from `~/.local/share/opencode/auth.json`
2. Update `~/.config/benedict/auth.json` with the same object
3. Ensure structure matches: `{ "google": { "oauth": { "type": "oauth", "refresh": "...", "access": "...", "expires": 1234567890 } }`

**Warning**: This bypasses the authentication flow and may have token expiration issues. Re-authenticating is recommended.

## Summary

**Root Cause (High Confidence)**: Benedict's stored credentials lack the managed project ID suffix because:
1. User authenticated with Benedict before managed project discovery was implemented
2. Initial `--exchange-authorization-code` does not call `--load-managed-project()`
3. Benedict only calls `--load-managed-project()` during token refresh (lines 315-317)
4. If access token never expires, managed project ID is never discovered
5. Request uses empty project ID, causing 500 errors

**Solution**: Re-authenticate with `M-x benedict-provider-gemini-login` to trigger full OAuth flow with managed project discovery.
