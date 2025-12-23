---
date: 2025-12-22T10:00:00-05:00
researcher: gpt-5.1
git_commit: 9adca12ce4e8350bde815feb1ef2395738c59ad7
branch: main
repository: benedict
topic: "Current state of credentials handling"
tags: [research, codebase, credentials, authentication, providers, oauth]
status: draft
last_updated: 2025-12-22
---

# Research: Current state of credentials handling

**Date**: 2025-12-22
**Researcher**: gpt-5.1
**Git Commit**: 683e44f3969737a4dec5aaffa6e02a72311bc9e8
**Branch**: main

## Research Question
Map the current implementation of credential resolution and storage in Benedict to inform the creation of a generic credentials store that supports filesystem-based configuration and OAuth flow integration.

## Summary
- Benedict currently uses a decentralized approach where each provider (`openrouter`, `vercel`, `gemini`) implements its own credential resolution logic.
- Most providers follow a pattern of checking `auth-source` first, then a provider-specific environment variable.
- `benedict-provider-gemini.el` implements a more complex OAuth flow with token refresh, persisting the refresh token back to `auth-source`.
- There is no shared "credentials store" component; logic is repeated across provider files.
- The system lacks a dedicated filesystem-based configuration file for credentials (e.g., `auth.json`), relying instead on standard Emacs `auth-source` mechanisms or environment variables.

## Detailed Findings

### Provider-Specific Credential Resolution
- **OpenRouter** (`benedict-provider-openrouter.el:1215`): Calls `--auth-source-credential` then `--env-credential`. Uses `OPENROUTER_API_KEY` env var.
- **Vercel** (`benedict-provider-vercel.el:1253`): Calls `--auth-source-credential` then `--env-credential`. Uses `AI_GATEWAY_API_KEY` env var.
- **Gemini** (`benedict-provider-gemini.el:185`): Uses `auth-source` to store and retrieve a refresh token. Implements a full OAuth flow and token refresh cycle. It caches access tokens in-memory (`benedict-provider-gemini--token-cache`).

### Shared Patterns
- Use of `auth-source-search` with provider-specific `:host` and `:user` values.
- Fallback to `getenv` for API keys.
- Redaction helpers for headers and secrets are implemented per-provider (`--redact-secret`, `--redact-headers`).

### OAuth Implementation (Gemini)
- `benedict-provider-gemini-login` (`benedict-provider-gemini.el:589`) drives an interactive OAuth flow using PKCE.
- Results are persisted to `auth-source` via `benedict-provider-gemini--persist-refresh-token` (`benedict-provider-gemini.el:714`). This does not work due to the lack of write features of `auth-source`.
- Token refresh happens automatically during `resolve-credential` if the cached access token is expired or missing.

## Code References
- `benedict-provider-openrouter.el:1215-1246` - OpenRouter credential resolution.
- `benedict-provider-vercel.el:1253-1284` - Vercel credential resolution.
- `benedict-provider-gemini.el:185-206` - Gemini credential resolution and refresh.
- `benedict-provider-gemini.el:589-619` - Gemini OAuth login flow.
- `benedict-provider-gemini.el:714-726` - Gemini refresh token persistence.

## Architecture Documentation
- Current providers are self-contained regarding authentication. They build their own headers and resolve their own keys.
- The HTTP layer (`benedict-http.el`) is agnostic of authentication, receiving already-formed headers from providers.

## Historical Context
- A previous research effort (`oauth-auth-provider-setup`) mapped how Opencode handles authentication via `auth.json` and centralized paths. Benedict currently lacks this centralized infrastructure.
