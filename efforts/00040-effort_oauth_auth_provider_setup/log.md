# OAuth Auth Provider Setup — Log

## 2025-12-19 — Phase 2–4 implementation

- Added the full Gemini provider backend (`benedict-provider-gemini.el`):
  - Credential resolution via `auth-source`, access-token caching, refresh-token rotation, and redacted logging helpers.
  - PKCE/state helpers plus the interactive `M-x benedict-provider-gemini-login` command; login stores only the refresh token in `auth-source` and seeds the cache.
  - Request shaping (messages → `generateContent` payload), header construction, and final `--send` wiring through `benedict-http-request`.
- Expanded `README.org` with instructions covering the OAuth-only storage model, login flow, and customization knobs.
- Created `test/benedict-provider-gemini-test.el` with unit coverage for credential caching/refresh, error surfacing, payload structure, and header redaction. Full `nix run .#test` now passes.

## Manual testing checklist

1. **Configuration**
   - Ensure `benedict` is on your `load-path` and `auth-source` points at the file you want to store the refresh token in (defaults: host `gemini`, user `oauth`, port `443`).
   - Override `benedict-provider-gemini-*-id/secret/redirect-uri/scopes` only if you have custom credentials; defaults mirror `gemini-cli`.
   - (Optional) tweak endpoint, default model, or user-agent via Customize.
2. **OAuth login (`M-x benedict-provider-gemini-login`)**
   - Command copies the consent URL to the kill-ring and tries to open it; approve the scopes in your browser.
   - After Google redirects to your configured `redirect_uri`, copy the *full* callback URL and paste it into the minibuffer prompt.
   - The command validates PKCE state, exchanges the code at `https://oauth2.googleapis.com/token`, persists the refresh token via `auth-source`, and caches the returned access token. Look for the "Gemini refresh token stored for <host>/<user>" message.
3. **Chat verification**
   - Set `benedict-provider` to `'gemini` (Customize or `(setq benedict-provider 'gemini)`), then send a prompt via `M-x benedict-chat`.
   - Watch `*Messages*`/logs for `Gemini request` + `Gemini completion` entries. Responses should echo from the selected model (`gemini-2.0-flash` by default).
4. **Refresh rotation**
   - Restart Emacs or `(clrhash benedict-provider-gemini--token-cache)` to force a new refresh; send another chat. If Google rotates the refresh token, confirm the `auth-source` entry’s password updates.
5. **Failure modes**
   - Delete or corrupt the `auth-source` entry and try to chat: you should get the “Gemini refresh token missing… run M-x benedict-provider-gemini-login” error.
   - Revoke the credential in Google, then chat: the provider should raise an `invalid_grant` error instructing you to rerun the login flow.
