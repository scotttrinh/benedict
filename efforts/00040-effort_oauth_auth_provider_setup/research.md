---
date: 2025-12-19T07:07:32-05:00
researcher: gpt-5.1
git_commit: 683e44f3969737a4dec5aaffa6e02a72311bc9e8
branch: main
repository: benedict
topic: "Authentication in request building and provider setup"
tags: [research, codebase, providers, authentication, http, opencode, gemini]
status: complete
last_updated: 2025-12-19
---

# Research: Authentication in request building and provider setup

**Date**: 2025-12-19T07:07:32-05:00
**Researcher**: gpt-5.1
**Git Commit**: 683e44f3969737a4dec5aaffa6e02a72311bc9e8
**Branch**: main

## Research Question

Map how authentication is handled today in Benedict's provider and HTTP layers: how providers are configured and selected, how credentials are resolved, and where auth headers are attached to requests, to inform a future effort to add OAuth-based authentication. Extend this with documentation of how the Opencode project stores auth data and how the `opencode-gemini-auth` plugin participates in that flow, now that both repos are available locally.

## Summary

- Providers are modeled via a `benedict-provider` struct and registry (`benedict-provider.el`), with a single dynamic variable `benedict-provider` selecting the active backend (`benedict.el`, `benedict-chat.el:2150`).
- Chat entrypoints build a provider-neutral request plist (provider, model, tools, messages, autonomy) and call `benedict-provider-dispatch`, which delegates to provider-specific `send` functions and shared HTTP wrapper `benedict-http-request`.
- Authentication is entirely provider-specific: OpenRouter and Vercel providers each resolve a Bearer token via `auth-source` first and environment variable second, then build an `Authorization: Bearer TOKEN` header plus optional Referer/App headers before calling `benedict-http-request`.
- The HTTP layer (`benedict-http.el`) is transport-only: it accepts a header alist from providers, converts it to curl `-H` flags, adds streaming-specific `Accept: text/event-stream`, and does not know about auth or credentials.
- Ollama and Fake providers do not use authentication: Ollama talks to a local HTTP endpoint with only `Content-Type: application/json`, and Fake is in-process with no HTTP at all.
- Documentation and roadmap files confirm the intended security posture: keys come from `auth-source` or env vars, are not written to disk, and should be redacted in logs; provider modules implement masking helpers for Authorization headers.
- Opencode maintains its own auth stores (`auth.json`, `mcp-auth.json`, console auth tables, and browser sessions) and merges these with env-based credentials and config to decide how to authenticate AI providers, MCP servers, and console users.
- The `opencode-gemini-auth` plugin integrates into Opencode's provider auth system as a plugin-provided auth handler for the `"google"` provider id, using Opencode's auth store (via `client.auth.get/set`) to persist Gemini OAuth refresh/access tokens and project context, and wrapping fetch requests to inject `Authorization` headers and Code Assist-specific URL/body shapes.

## Detailed Findings

### Benedict: provider abstraction and selection

- `benedict-provider.el:19-24` — Defines `cl-defstruct benedict-provider` with fields `id`, `name`, `send`, `capabilities`, `cancel`, and a private registry `benedict-provider--registry` (hash-table) holding all providers.
- `benedict-provider.el:27-40` — `benedict-provider-register`, `benedict-provider-lookup`, and `benedict-provider-list-ids` manage provider registration and lookup by ID symbol.
- `benedict-provider.el:50-56` — `benedict-provider-current` resolves the active provider struct using the dynamic/global `benedict-provider` variable; errors if the id is unknown.
- `benedict-provider.el:58-74` — `benedict-provider-dispatch` fetches the current provider and calls its `send` function with the request plist and callbacks `:on-success`, `:on-error`, `:on-delta`, and `:on-complete`; this is the main entrypoint from chat into providers.
- `benedict-provider.el:76-82` — `benedict-provider-abort` looks up the current provider and calls its `cancel` function with a provider-specific handle.
- `benedict.el:28-31` — `defcustom benedict-provider 'openrouter` defines the default provider id for chat interactions.
- `benedict.el:85-88` — Requires `benedict-provider-openrouter`, `benedict-provider-vercel`, `benedict-provider-fake`, and `benedict-provider-ollama`, ensuring each built-in provider self-registers when the core package is loaded.

### Benedict: chat request-building pipeline (provider-neutral)

- `benedict-chat.el:2050` — User-facing chat send path (`benedict-chat-send-prompt` / `benedict-chat--send-text`) records a `:role 'user` message, then calls `benedict-chat--start-dispatch (benedict-chat--build-request)`.
- `benedict-chat.el:22821` — Compose-buffer send path (`benedict-chat-compose-send`) assembles staged context and compose body into text, records a `:role 'user` message, then uses the same `benedict-chat--send-text` path.
- `benedict-chat.el:384` — Autonomous loop (`benedict-chat--loop-step`) reuses `benedict-chat--start-dispatch (benedict-chat--build-request)` to send follow-up turns.
- `benedict-chat.el:2297-2313` — `benedict-chat--build-request` constructs a provider-neutral request plist with keys `:provider`, `:model`, `:profile`, `:tools`, `:autonomy`, `:verbosity`, and `:messages`. Messages are built from system messages and buffer history via `benedict-chat--message->provider`; no auth-related fields are present.
- `benedict-chat.el:2280` — `benedict-chat--message->provider` normalizes internal message plists into provider-ready shapes (`:role`, `:content`, optional `:tool-calls`, `:name`, `:tool-call-id`). This is the message representation that providers receive in `request[:messages]`.
- `benedict-chat.el:2505-2523` — `benedict-chat--start-dispatch` resolves a provider id from `:provider` in the request or falls back to `benedict-provider`. It `let`-binds `benedict-provider` to that id and calls `benedict-provider-dispatch` with the request and callbacks, storing the result handle in `benedict-chat--pending-request`.
- `benedict-tools.el:70` and surrounding — Tool registry; registered tools are returned as plists (`:id`, `:fn`, `:schema`, `:approval`, `:doc`) that become `request[:tools]`. Shared helpers like `benedict-tool-schema->json-parameters` are used by providers to encode tool schemas into JSON.
- `benedict-context.el:44` and `benedict-chat.el:2799` — Context slices are textual; `benedict-context-format-for-send` and `benedict-chat--assemble-message-text` embed them into the user message content. Providers see this only as part of `:content` in `request[:messages]`.

### Benedict: HTTP transport layer

- `benedict-http.el:23-33` — Defines `defgroup benedict-http`, `benedict-http-curl-program`, and `benedict-http-proxy-args` (curl path and extra args such as proxies) used for all HTTP calls.
- `benedict-http.el:43-76` — `benedict-http-request` is the shared HTTP wrapper. It accepts `:url`, `:method`, `:headers` (alist), `:body` (string), and `:stream` flag, constructs a curl command, and handles process lifecycle and callbacks. It does not inspect or construct auth headers; it passes through the header alist supplied by providers.
- `benedict-http.el:113-131` — `benedict-http--make-command` builds the actual curl command list. It adds fixed flags (e.g., `--no-buffer`, `--fail-with-body`), handles `:stream` by adding `Accept: text/event-stream`, and transforms each `(NAME . VALUE)` in the header alist into a `-H "NAME: VALUE"` argument.
- `benedict-http.el:219-235` — `benedict-http--finish-success` calls the success callback for non-streaming requests with a status (fixed `200`), `nil` headers, and the buffered body.
- `benedict-http.el:237-259` — `benedict-http--finish-error` interprets curl exit code `22` as an HTTP error, passing `:type 'http`, `:code 22`, and the body/stderr to `on-error`. Other non-zero codes are reported as process-level errors.
- `test/benedict-http-test.el:10-29` — `benedict-http-command-generation` test asserts that a header alist including `("Content-Type" . "application/json")` and `("Authorization" . "Bearer token")` is converted into the appropriate `-H` flags in the curl command, confirming the path from provider header alist to outbound HTTP headers.

### Benedict: OpenRouter provider — credentials and auth headers

- `benedict-provider-openrouter.el:20-23` — `defgroup benedict-provider-openrouter` groups OpenRouter-specific settings.
- `benedict-provider-openrouter.el:25-31` — `benedict-provider-openrouter-endpoint` holds the OpenRouter chat completions URL; `benedict-provider-openrouter--host` later derives the hostname for auth-source.
- `benedict-provider-openrouter.el:31-38` — `benedict-provider-openrouter-default-model` defines a default model when none is provided in the request.
- `benedict-provider-openrouter.el:36-52` — Additional defcustoms configure OpenRouter-specific request parameters (temperature, reasoning, usage reporting).
- `benedict-provider-openrouter.el:70-73` — `defcustom benedict-provider-openrouter-env-var "OPENROUTER_API_KEY"` specifies the environment variable name used when resolving credentials from the environment.
- `benedict-provider-openrouter.el:75-79` — `benedict-provider-openrouter-auth-source-user` gives the default `:user` field for `auth-source-search`.
- `benedict-provider-openrouter.el:81-89` — `benedict-provider-openrouter-referer` and `benedict-provider-openrouter-app-name` hold values sent in `HTTP-Referer` and `X-Title` headers, respectively.
- `benedict-provider-openrouter.el:170` — `benedict-provider-openrouter--send` is the provider-specific entrypoint for OpenRouter. It resolves a credential via `benedict-provider-openrouter--resolve-credential`, decides on streaming, builds the JSON payload, and calls `benedict-provider-openrouter--perform-request`.
- `benedict-provider-openrouter.el:221-247` — `benedict-provider-openrouter--perform-request` extracts the token from the credential plist, builds headers by calling `benedict-provider-openrouter--build-headers`, and calls `benedict-http-request` with `:url benedict-provider-openrouter-endpoint`, `:method "POST"`, `:headers headers`, `:body payload`, and `:stream` flag. This is where auth headers are attached to the outgoing request.
- `benedict-provider-openrouter.el:905-915` — `benedict-provider-openrouter--build-headers` returns a header alist containing:
  - `("Content-Type" . "application/json")`
  - `("Authorization" . (format "Bearer %s" token))`
  - Optional `("HTTP-Referer" . benedict-provider-openrouter-referer)` and `("X-Title" . benedict-provider-openrouter-app-name)` when non-nil.
- `benedict-provider-openrouter.el:917-933` — `benedict-provider-openrouter--redact-secret` and `benedict-provider-openrouter--redact-headers` provide helpers to mask `Authorization` and `Proxy-Authorization` header values (e.g., for logging).
- `benedict-provider-openrouter.el:1242-1246` — `benedict-provider-openrouter--env-credential` looks up `getenv benedict-provider-openrouter-env-var` and, when non-empty, wraps it as `(:token TOKEN :source 'env)`.
- `benedict-provider-openrouter.el:1224-1240` — `benedict-provider-openrouter--auth-source-credential` uses `auth-source-search` with `:host (benedict-provider-openrouter--host)` and optional `:user benedict-provider-openrouter-auth-source-user`, reading `:secret` (which may be a function) and producing `(:token TOKEN :source 'auth-source :entry ENTRY)`.
- `benedict-provider-openrouter.el:1215-1222` — `benedict-provider-openrouter--resolve-credential` first calls `--auth-source-credential`, then `--env-credential`, and signals a descriptive error if no non-empty token is found, guiding the user to configure auth-source or the environment variable.
- `benedict-provider-openrouter.el:1253-1259` — Registers the OpenRouter provider via `benedict-provider-register` with `:id 'openrouter` and capabilities including streaming and tools.

### Benedict: Vercel provider — credentials and auth headers

- `benedict-provider-vercel.el:35-38` — `defgroup benedict-provider-vercel` groups Vercel-specific settings.
- `benedict-provider-vercel.el:40-44` — `benedict-provider-vercel-endpoint` holds the Vercel AI Gateway chat completions URL.
- `benedict-provider-vercel.el:46-52` — `benedict-provider-vercel-default-model` and related defcustoms configure defaults for model and temperature.
- `benedict-provider-vercel.el:75-83` — `benedict-provider-vercel-max-retries` and `benedict-provider-vercel-retry-backoff-seconds` configure retry behavior.
- `benedict-provider-vercel.el:85-88` — `benedict-provider-vercel-env-var` (default `"AI_GATEWAY_API_KEY"`) names the env var consulted for credentials.
- `benedict-provider-vercel.el:90-94` — `benedict-provider-vercel-auth-source-user` supplies the default `:user` for auth-source lookups.
- `benedict-provider-vercel.el:96-104` — `benedict-provider-vercel-referer` and `benedict-provider-vercel-app-name` configure `HTTP-Referer` and `X-Title` headers.
- `benedict-provider-vercel.el:190` and `:241-271` — `benedict-provider-vercel--send` and `benedict-provider-vercel--perform-request` mirror OpenRouter's pattern: resolve credential (`benedict-provider-vercel--resolve-credential`), encode payload, build headers via `benedict-provider-vercel--build-headers`, and call `benedict-http-request` with those headers.
- `benedict-provider-vercel.el:943-953` — `benedict-provider-vercel--build-headers` constructs headers:
  - `("Content-Type" . "application/json")`
  - `("Authorization" . (format "Bearer %s" token))`
  - Optional `("HTTP-Referer" . benedict-provider-vercel-referer)` and `("X-Title" . benedict-provider-vercel-app-name)` when non-nil.
- `benedict-provider-vercel.el:955-971` — `benedict-provider-vercel--redact-secret` and `--redact-headers` mask `Authorization`/`Proxy-Authorization` header values.
- `benedict-provider-vercel.el:1280-1284` — `benedict-provider-vercel--env-credential` reads `getenv benedict-provider-vercel-env-var` and returns `(:token TOKEN :source 'env)` when present.
- `benedict-provider-vercel.el:1262-1278` — `benedict-provider-vercel--auth-source-credential` uses `auth-source-search` with host from `benedict-provider-vercel--host` and optional `benedict-provider-vercel-auth-source-user`, pulling `:secret` into a token.
- `benedict-provider-vercel.el:1253-1260` — `benedict-provider-vercel--resolve-credential` tries auth-source then env var, signaling a descriptive error if both fail.
- `benedict-provider-vercel.el:1291-1297` — Registers the Vercel provider as `:id 'vercel` with streaming and tools capabilities.

### Benedict: Ollama provider — local, no auth

- `benedict-provider-ollama.el:20-23` — `defgroup benedict-provider-ollama` groups Ollama settings.
- `benedict-provider-ollama.el:25-29` — `benedict-provider-ollama-endpoint` defaults to a local HTTP endpoint (e.g., `http://localhost:11434/v1/chat/completions`).
- `benedict-provider-ollama.el:31-38` — `benedict-provider-ollama-default-model` and `benedict-provider-ollama-default-temperature` configure local model behavior.
- `benedict-provider-ollama.el:60-68` — Retry-related defcustoms configure retries for local HTTP calls.
- `benedict-provider-ollama.el:149-196` — `benedict-provider-ollama--send` / `--perform-request` construct the request payload and call `benedict-http-request` with `benedict-provider-ollama-endpoint` and headers from `benedict-provider-ollama--build-headers`; there is no credential resolution.
- `benedict-provider-ollama.el:881-883` — `benedict-provider-ollama--build-headers` returns only `("Content-Type" . "application/json")`; there are no auth headers.
- `benedict-provider-ollama.el:1187-1193` — Registers the Ollama provider under `:id 'ollama` with streaming and tools capabilities.

### Benedict: Fake provider — no network, no auth

- `benedict-provider-fake.el:15-23` — `defgroup benedict-provider-fake` groups fake provider settings.
- `benedict-provider-fake.el:20-33` — Defcustoms like `benedict-provider-fake-default-model`, `benedict-provider-fake-latency-seconds`, and `benedict-provider-fake-streaming-chunk-delay` configure simulation behavior.
- `benedict-provider-fake.el:227-331` — `benedict-provider-fake--send` simulates streaming responses via timers and callback invocations without calling `benedict-http-request` or touching credentials.
- `benedict-provider-fake.el:333-338` — `benedict-provider-fake--cancel` cancels timers associated with in-flight fake requests.
- `benedict-provider-fake.el:340-346` — Registers the fake provider with `:id 'fake` and streaming/tools capabilities.

### Benedict: documentation and roadmap — auth configuration and expectations

- `README.org:22` — Quick Start shows `benedict-provider` as the main variable for selecting `'openrouter`, `'ollama`, `'vercel`, or `'fake` as the provider, aligning with the provider registry.
- `README.org:80-89` — OpenRouter credentials section documents `auth-source` configuration (e.g., `machine openrouter.ai login openrouter password sk-or-...` in `~/.authinfo.gpg`) and the `OPENROUTER_API_KEY` env var fallback. It also mentions `benedict-provider-openrouter-env-var` for overriding the env var name.
- `README.org:241-281` — OpenRouter provider options document `benedict-provider-openrouter-endpoint`, `...-env-var`, `...-auth-source-user`, `...-referer`, and `...-app-name`, plus streaming parameters, matching the defcustoms used in the provider code.
- `README.org:282-321` — Vercel provider options document `benedict-provider-vercel-endpoint`, `...-env-var` (default `AI_GATEWAY_API_KEY`), `...-auth-source-user`, `...-referer`, and `...-app-name`, plus streaming and retry settings.
- `README.org:322-337` — Ollama provider options describe `benedict-provider-ollama-endpoint`, `...-default-model`, `...-default-temperature`, and streaming enablement; no auth fields are present.
- `README.org:338-353` — Fake provider options describe latency and chunk delay; there is no authentication.
- `README.org:185` and `:225` — Security & Privacy and provider logging sections emphasize that keys come via auth-source or env vars, are never written to disk, and should be masked in logs. They also document provider-level logging configuration.
- `ROADMAP.org:28-44` — Early roadmap phases describe "Security posture: key management via auth-source; redaction helpers; logging policy" and "Auth integration: auth-source search; env var fallback; redact in messages" as explicit implementation goals, matching the provider code.

### Opencode: global paths and core auth stores

- `opencode/packages/opencode/src/global/index.ts:6-31` — `Global.Path` defines XDG-based paths for `data`, `config`, `cache`, `state`, and `bin` under the `opencode` app name and ensures corresponding directories exist. These paths are the base for on-disk auth/config files such as `auth.json` and `mcp-auth.json`.
- `opencode/packages/opencode/src/auth/index.ts:6-33` — `Auth.Oauth`, `Auth.Api`, `Auth.WellKnown`, and `Auth.Info` describe the stored credential shapes: OAuth tokens (access, refresh, expiry, optional enterprise URL), simple API keys, and "well-known" entries (token + env var name) that let Opencode populate environment variables for external tools.
- `opencode/packages/opencode/src/auth/index.ts:35-54` — `Auth.get` and `Auth.all` read `auth.json` from `Global.Path.data`, parse it with Zod validation, and return a map of provider IDs to `Auth.Info` entries. This file holds per-user provider credentials for Opencode.
- `opencode/packages/opencode/src/auth/index.ts:56-69` — `Auth.set` and `Auth.remove` update `auth.json` by merging/removing entries and set its permissions to `0o600`, so credentials are stored as plaintext JSON but restricted to the current user at the filesystem level.
- `opencode/packages/opencode/src/mcp/auth.ts:7-83` — `McpAuth` defines the on-disk MCP auth structure (`mcp-auth.json` under `Global.Path.data`), storing access/refresh tokens, OAuth client info, PKCE code verifier, OAuth state, and server URL for each MCP server name, with helpers to read/write entries and enforce `0o600` permissions.
- `opencode/packages/opencode/src/mcp/auth.ts:92-123` — Additional helpers maintain PKCE code verifier and OAuth `state` values (per MCP server) in `mcp-auth.json`. These values are used to correlate OAuth redirects and to detect CSRF but are not exposed outside MCP auth flows.

### Opencode: env wrapper, flags, and configuration

- `opencode/packages/opencode/src/env/index.ts:3-25` — `Env` wraps `process.env` into an `Instance`-scoped helper, providing `get`, `all`, `set`, and `remove` so auth and provider code can read/write env-based credentials consistently during an Opencode run.
- `opencode/packages/opencode/src/flag/flag.ts:2-30` — `Flag.OPENCODE_CONFIG`, `OPENCODE_CONFIG_CONTENT`, and related flags read env vars that override config file locations or inject inline config JSON; these flags can carry provider `options` including API keys, but they are not themselves a credential store.
- `opencode/packages/opencode/src/config/config.ts:37-63` — `Config.state` initializes configuration by combining `Auth` entries, global config, and per-project config files (`opencode.jsonc`/`opencode.json` discovered via search paths). It also processes `wellknown` auth entries by setting env vars and merging remote config from `/.well-known/opencode` endpoints.
- `opencode/packages/opencode/src/config/config.ts:70-105` — Config search paths include the global config dir, `.opencode` directories up the project tree, a home-level `.opencode` directory, and any directory specified by `OPENCODE_CONFIG_DIR`. Each such directory may contain `opencode.jsonc`/`opencode.json` and plugin/command definitions that influence how providers and auth behave for that project.
- `opencode/packages/opencode/src/config/config.ts:590-624,698-703` — `Config.Provider` describes provider-specific config fields including `options.apiKey`, `baseURL`, and `enterpriseUrl`. These options are merged with credentials from `Auth` and env vars and later used when building provider SDKs and HTTP requests.

### Opencode: provider auth aggregation and usage

- `opencode/packages/opencode/src/provider/auth.ts:10-40` — `ProviderAuth.state` and `ProviderAuth.Method` compute the available auth methods for each provider by scanning loaded plugins (`Plugin.list`) for entries with `auth.provider`. Methods are described by a type (`"oauth"` or `"api"`) and label, forming the basis for UI/CLI prompts.
- `opencode/packages/opencode/src/provider/auth.ts:43-52` — `ProviderAuth.Authorization` describes responses from provider auth methods (e.g., an OAuth authorization URL, method `"auto"` vs `"code"`, and instructions), which are surfaced by the server to clients.
- `opencode/packages/opencode/src/provider/auth.ts:54-72` — `ProviderAuth.authorize` receives a provider ID and method index, looks up the appropriate plugin auth method, calls its `.authorize()` hook, stores the result in `state().pending`, and returns the authorization URL and metadata. Pending entries are keyed by provider and method index.
- `opencode/packages/opencode/src/provider/auth.ts:74-113` — `ProviderAuth.callback` completes the OAuth flow. It retrieves the pending auth entry, invokes the plugin's callback (passing an OAuth `code` when required), and, on success, writes either API-key (`type: "api"`) or OAuth (`type: "oauth"`, with tokens) entries into `auth.json` using `Auth.set`. Token refresh and project context for Gemini are later handled by the plugin.
- `opencode/packages/opencode/src/provider/auth.ts:116-127` — `ProviderAuth.api` covers non-OAuth flows where the user provides an API key directly; it writes `Auth.Api` entries to `auth.json` for the provider ID.
- `opencode/packages/opencode/src/provider/provider.ts:615-625` — Env-based provider credentials: for each provider, if any environment variables listed in the provider's `env` configuration are set, the provider is marked as having `source: "env"` and a `key` derived from that env var.
- `opencode/packages/opencode/src/provider/provider.ts:628-636` — File-based provider credentials: `Auth.all()` is scanned for `type: "api"` entries; each such entry is added to the provider map with `source: "api"` and `key: auth.key`, letting `auth.json` drive API key discovery.
- `opencode/packages/opencode/src/provider/provider.ts:638-682` — Plugin-based provider options: for each plugin that declares `auth.provider`, if `Auth.get(providerId)` (and, for GitHub Copilot, a related enterprise entry) returns credentials, the plugin's `auth.loader` function is called. The loader returns provider-specific `options` (e.g., a wrapped `fetch`, apiKey overrides, or base URLs) that are merged into the provider's configuration.
- `opencode/packages/opencode/src/provider/provider.ts:705-734` — Provider filtering uses `Config.provider` to apply whitelists/blacklists and hides "alpha" models unless experimental flags are enabled. This determines which authenticated providers/models are exposed.
- `opencode/packages/opencode/src/provider/provider.ts:756-803` — `getSDK` builds an AI SDK client for the provider/model. It sets `options.baseURL` from provider config, uses `provider.key` as `options.apiKey` when `options.apiKey` is not specified, and delegates actual header/token handling to the underlying SDK (e.g., `@ai-sdk/openai`).

### Opencode: CLI and server endpoints for provider auth

- `opencode/packages/opencode/src/cli/cmd/auth.ts:21-61` — `handlePluginAuth` is the CLI helper driving plugin-defined auth flows. It calls provider auth endpoints to get available methods, then uses plugin callbacks (via `ProviderAuth`) to complete OAuth or API-key flows, ultimately writing results into `auth.json` via `Auth.set`.
- `opencode/packages/opencode/src/cli/cmd/auth.ts:170-215` — `AuthListCommand` reads `auth.json` with `Auth.all()` and prints each provider's auth type. It also inspects env vars defined in the provider database to report env-based credentials alongside file-backed ones.
- `opencode/packages/opencode/src/cli/cmd/auth.ts:217-265` — `AuthLoginCommand` (well-known URL flow) accepts a URL, fetches its `/.well-known/opencode` document, runs the recommended auth command, captures stdout as a token, and stores a `WellKnown` entry (`{ type: "wellknown", key: <env-name>, token }`) in `auth.json`. This allows subsequent runs to expose the token via an env var.
- `opencode/packages/opencode/src/cli/cmd/auth.ts:254-304` — `AuthLoginCommand` (standard providers) interacts with the provider database to choose a provider and either delegates to plugin-based auth (when `auth.provider` is defined) or asks for manual API-key entry. Delegated flows use plugin-provided methods (including Gemini plugin flows).
- `opencode/packages/opencode/src/cli/cmd/auth.ts:315-363` — Manual API-key flow prompts for a key and writes an `Auth.Api` entry into `auth.json` for the chosen provider.
- `opencode/packages/opencode/src/cli/cmd/auth.ts:368-390` — `AuthLogoutCommand` reads all entries with `Auth.all()`, lets the user select one, and removes it from `auth.json` via `Auth.remove`, clearing stored credentials for that provider.
- `opencode/packages/opencode/src/server/server.ts:1537-1555` — `/provider/auth` HTTP endpoint exposes available `ProviderAuth.Method` entries per provider, allowing clients (including the CLI and web UI) to discover supported login methods.
- `opencode/packages/opencode/src/server/server.ts:1557-1636` — `/provider/:providerID/oauth/authorize` and `/provider/:providerID/oauth/callback` endpoints delegate to `ProviderAuth.authorize` and `ProviderAuth.callback`. Plugin-provided auth methods (such as those from `opencode-gemini-auth`) are invoked through these endpoints, and successful completions result in updates to `auth.json`.

### Opencode: MCP auth flows

- `opencode/packages/opencode/src/mcp/index.ts:80-103` — `MCP.state` maintains a map of MCP client connections and per-server status (`connected`, `needs_auth`, `needs_client_registration`, etc.) based on configuration and stored tokens.
- `opencode/packages/opencode/src/mcp/index.ts:151-187` — Remote MCP connection uses an optional `McpOAuthProvider`. Unauthenticated errors are translated into statuses indicating that auth or client registration is required, and transports are stored in `pendingOAuthTransports` for later completion.
- `opencode/packages/opencode/src/mcp/index.ts:416-485` — `MCP.startAuth` initiates MCP OAuth for a named server by starting a local callback server, generating and storing an OAuth `state` value in `McpAuth`, constructing a `McpOAuthProvider`, and performing an initial connect to provoke a redirect; the captured redirect URL is returned as the authorization URL.
- `opencode/packages/opencode/src/mcp/index.ts:492-525` — `MCP.authenticate` calls `startAuth`, opens the browser to the authorization URL, waits for the callback server to receive a request, validates the returned state against `McpAuth`, clears state, and then calls `finishAuth`.
- `opencode/packages/opencode/src/mcp/index.ts:531-559` — `MCP.finishAuth` retrieves the stored transport, calls `finishAuth(code)` to exchange the OAuth code for tokens, clears the code verifier in `McpAuth`, and reconnects so the new tokens take effect. Updated tokens are persisted in `mcp-auth.json`.
- `opencode/packages/opencode/src/mcp/index.ts:571-95` — `removeAuth`, `supportsOAuth`, and `hasStoredTokens` provide helpers for clearing MCP auth entries, checking if OAuth is supported for a given server, and detecting whether tokens exist.
- `opencode/packages/opencode/src/server/server.ts:1946-2058` — `/mcp/:name/auth*` endpoints export `MCP.startAuth`, `MCP.finishAuth`/`authenticate`, and `MCP.removeAuth` over HTTP so external clients can drive MCP OAuth flows backed by `mcp-auth.json`.

### Opencode: console auth (OpenAuth, DB tables, and sessions)

- `opencode/packages/console/function/src/auth.ts:21-35` — `subjects` declares OpenAuth subjects for `account` and `user`, representing account-level and workspace-level identities used by console services.
- `opencode/packages/console/function/src/auth.ts:41-55,99-103` — `issuer({ providers, storage, subjects })` configures an OpenAuth issuer for GitHub and Google providers using Cloudflare KV-based storage. OpenAuth is responsible for token/session storage; this code supplies providers and storage.
- `opencode/packages/console/function/src/auth.ts:105-139` — `success` handlers call provider APIs (GitHub, Google) with `Authorization: Bearer <access-token>` to retrieve email/subject, ensuring that tokens map to identity fields used in the console.
- `opencode/packages/console/function/src/auth.ts:141-215` — Account and workspace provisioning logic uses Drizzle ORM to maintain `Account` rows and entries in `AuthTable` that map `(provider, subject)` pairs to `accountID`. This persists external identities and ties them to console accounts.
- `opencode/packages/console/core/src/schema/auth.sql.ts:4-20` — `AuthTable` defines the `auth` relational table storing `(provider, subject, accountID)` and a unique index over `(provider, subject)`. This table is the durable mapping between external auth identities and internal accounts.
- `opencode/packages/console/core/src/schema/user.sql.ts:5-29` — `UserTable` stores workspace-level users, linked to `Account` via `accountID`. Auth flows attach users to accounts based on email or provider-subject matching.
- `opencode/packages/console/core/src/user.ts:21-55` — `User.list` and `getAuthEmail` join `UserTable` and `AuthTable` (for provider `"email"`) to surface a user's primary auth email.
- `opencode/packages/console/core/src/user.ts:57-104` — `User.invite` looks up `AuthTable` entries for invited emails and, when present, attaches new users to existing accounts and provisions API keys.
- `opencode/packages/console/app/src/context/auth.session.ts:14-23` — `useAuthSession` configures a cookie-based `AuthSession` named `"auth"` holding a map of accounts (id + email) and the current account id. This session persists identities in the browser between requests.
- `opencode/packages/console/app/src/context/auth.ts:10-52` — `AuthClient` and `getActor` (without workspace) instantiate an OpenAuth client for the console and compute the current `Actor.Info` from `AuthSession`. When no accounts exist, `getActor` returns a `"public"` actor.
- `opencode/packages/console/app/src/context/auth.ts:53-89` — `getActor` (with workspace) joins the session accounts to workspace users via `UserTable` and, if none match, redirects to `/auth/authorize`. This enforces both authentication and workspace membership.
- `opencode/packages/console/app/src/context/auth.withActor.ts:1-7` — `withActor` wraps request handlers in an `Actor` context derived from `getActor`, propagating authenticated identity through console-core logic.
- `opencode/packages/console/app/src/routes/auth/authorize.ts:4-7` — `/auth/authorize` initiates the OpenAuth flow by redirecting the browser to the OpenAuth issuer's authorize endpoint.
- `opencode/packages/console/app/src/routes/auth/callback.ts:6-31` — `/auth/callback` exchanges an auth code using `AuthClient.exchange`, decodes the account subject, and updates `AuthSession.account` with the account id and email.
- `opencode/packages/console/app/src/routes/auth/index.ts:5-11` — `/auth` redirects authenticated users to a workspace and unauthenticated users to `/auth/authorize`.
- `opencode/packages/console/app/src/routes/auth/status.ts:4-7` — `/auth/status` returns the current `AuthSession` JSON, exposing accounts and selection to the frontend.
- `opencode/packages/console/app/src/routes/auth/logout.ts:5-16` — `/auth/logout` removes the current account from `AuthSession`, updates the currently selected account if others remain, and redirects to `/zen`.

### Opencode: other external auth interactions

- `opencode/packages/opencode/src/share/share.ts:68-80` — `Share.URL` and `Share.create` choose a share backend (`https://api.dev.opencode.ai` vs `https://api.opencode.ai`) and make unauthenticated POSTs to share endpoints. Access control is mediated via per-session share secrets rather than user auth.
- `opencode/packages/function/src/api.ts:205-302` — `/exchange_github_app_token` and `/exchange_github_app_token_with_pat` endpoints accept GitHub OIDC tokens or personal access tokens via `Authorization: Bearer <token>`, verify scopes/permissions, and return GitHub App installation tokens. These flows involve Opencode-hosted API endpoints but are separate from provider auth.
- `opencode/github/index.ts:371-386` — `getAccessToken` uses the `exchange_github_app_token(_with_pat)` endpoints to obtain installation access tokens from `https://api.opencode.ai`, then uses those tokens to call GitHub APIs with `Authorization: Bearer <token>`.

### opencode-gemini-auth: auth data structures and storage

- `opencode-gemini-auth/src/constants.ts:36-40` — `GEMINI_PROVIDER_ID` is set to `"google"`. This is the provider ID used throughout the plugin when reading/writing auth entries through Opencode's `client.auth` API.
- `opencode-gemini-auth/src/plugin/types.ts:3-8` — `OAuthAuthDetails` defines the stored auth record as `{ type: "oauth"; refresh: string; access?: string; expires?: number }`. This shape matches the payloads the plugin reads and writes via `client.auth.get/set` and corresponds to entries in Opencode's `auth.json` keyed by `"google"`.
- `opencode-gemini-auth/src/plugin/types.ts:67-71` — `RefreshParts` interprets the `refresh` string as `refreshToken`, `projectId`, and `managedProjectId`, allowing the plugin to encode project context alongside the refresh token in a single string.
- `opencode-gemini-auth/src/plugin/auth.ts:12-18` — `parseRefreshParts` splits the stored `refresh` string on `"|"` into the `RefreshParts` fields, treating missing segments as `undefined`. This function decodes the persisted Gemini auth state.
- `opencode-gemini-auth/src/plugin/auth.ts:24-36` — `formatRefreshParts` reverses the process, serializing `RefreshParts` back into the `refresh` string (`token`, `token|projectId`, or `token|projectId|managedProjectId`). Opencode persists this string as part of `OAuthAuthDetails`.
- `opencode-gemini-auth/src/plugin/auth.ts:5-7` — `isOAuthAuth` narrows generic `AuthDetails` to `OAuthAuthDetails` by checking `auth.type === "oauth"`. This is used in multiple places to guard OAuth-only logic.
- `opencode-gemini-auth/src/plugin/cache.ts:4-64` — `authCache`, `resolveCachedAuth`, `storeCachedAuth`, and `clearCachedAuth` maintain an in-memory `Map<string, OAuthAuthDetails>` keyed by trimmed `refresh` strings. This cache avoids redundant refreshes within a process but does not affect on-disk storage.

### opencode-gemini-auth: OAuth flow and token exchange

- `opencode-gemini-auth/src/gemini/oauth.ts:56-75` — `encodeState` and `decodeState` serialize a `GeminiAuthState` (currently just `{ verifier: string }`) into/from a base64url JSON string used as the OAuth `state` parameter. This embeds the PKCE code verifier into the redirect without server-side storage.
- `opencode-gemini-auth/src/gemini/oauth.ts:77-98` — `authorizeGemini` generates PKCE values, constructs a Google OAuth URL with Gemini scopes, PKCE challenge, and encoded state, and returns `{ url, verifier }` to the caller.
- `opencode-gemini-auth/src/gemini/oauth.ts:100-123` — `exchangeGemini` posts to `https://oauth2.googleapis.com/token` with code, client id/secret, redirect URI, and verifier. Non-OK responses are returned as `{ type: "failed", error }` without persisting anything.
- `opencode-gemini-auth/src/gemini/oauth.ts:131-156` — On success, `exchangeGemini` parses the token response, fetches user info for email, ensures a `refresh_token` is present, and returns `{ type: "success", refresh, access, expires, email }`. The plugin does not write to disk directly; Opencode consumes this result via `ProviderAuth.callback` and `client.auth.set`.

### opencode-gemini-auth: token refresh and persistence via Opencode

- `opencode-gemini-auth/src/plugin/token.ts:64-72` — `refreshAccessToken` reads the `refreshToken` from `auth.refresh` via `parseRefreshParts`. If none is present, it returns `undefined`, indicating there is no refresh path.
- `opencode-gemini-auth/src/plugin/token.ts:73-85` — When a refresh token exists, `refreshAccessToken` posts to Google's token endpoint with `grant_type=refresh_token`, the refresh token, and client id/secret, and parses a flexible OAuth error/response payload.
- `opencode-gemini-auth/src/plugin/token.ts:86-101` — On non-OK responses, OAuth errors are logged and, for `invalid_grant`, the plugin logs that Google has revoked the refresh token, clears related project context caches via `invalidateProjectContextCache`, and calls `client.auth.set` with an `OAuthAuthDetails` whose `refresh` string is updated to omit the refresh token while preserving project ids.
- `opencode-gemini-auth/src/plugin/token.ts:126-143` — On success, `refreshAccessToken` constructs new `RefreshParts` where the refresh token is the rotated token (if provided) or the existing token, with `projectId`/`managedProjectId` preserved. It then builds an `updatedAuth` with new `access`, `expires`, and `refresh` (formatted via `formatRefreshParts`).
- `opencode-gemini-auth/src/plugin/token.ts:145-153` — The updated auth snapshot is stored in the in-memory cache (`storeCachedAuth`) and persisted via `client.auth.set({ path: { id: GEMINI_PROVIDER_ID }, body: updatedAuth })`. `invalidateProjectContextCache` is also called for the old `refresh` string. This is the primary path where refreshed Gemini tokens and project ids are written back into Opencode's auth store.

### opencode-gemini-auth: project context and its relationship to stored auth

- `opencode-gemini-auth/src/plugin/project.ts:13-15` — `projectContextResults` and `projectContextPending` `Map`s cache `ProjectContextResult` and in-flight promises keyed by a derived key (based on `auth.refresh` and optional configured project id).
- `opencode-gemini-auth/src/plugin/project.ts:98-101` — `getCacheKey` derives the base cache key from the trimmed `refresh` string, so the packed `refresh` serves as an identifier for both credentials and project context.
- `opencode-gemini-auth/src/plugin/project.ts:106-127` — `invalidateProjectContextCache` clears cached project context entries globally or for a specific refresh string, including keys with `"|cfg:"` suffixes (which incorporate configured project ids).
- `opencode-gemini-auth/src/plugin/project.ts:260-270` — `ensureProjectContext` first attempts to parse `auth.refresh` into `RefreshParts` and, when `projectId` or `managedProjectId` is present, returns them immediately as `effectiveProjectId` without remote network calls. This means project ids are effectively stored inside the persisted `refresh` string.
- `opencode-gemini-auth/src/plugin/project.ts:272-290` — If no project id is stored but `loadManagedProject` returns a `cloudaicompanionProject` id, `ensureProjectContext` constructs an `updatedAuth` whose `refresh` includes `managedProjectId`, persists it via `client.auth.set({ path: { id: GEMINI_PROVIDER_ID }, body: updatedAuth })`, and returns the updated auth.
- `opencode-gemini-auth/src/plugin/project.ts:308-325` — For free-tier use, `ensureProjectContext` can call `onboardManagedProject`, which creates a managed project on the Code Assist backend; on success, it again updates `auth.refresh` with `managedProjectId` and persists via `client.auth.set`. For non-free tiers without project id, it throws `ProjectIdRequiredError`.

### opencode-gemini-auth: plugin entrypoint and integration with Opencode

- `opencode-gemini-auth/src/plugin.ts:29-37` — `GeminiCLIOAuthPlugin` is the plugin entrypoint Opencode loads. It returns a `PluginResult` with an `auth` block describing the `"google"` provider, an `auth.loader` function, and a list of auth methods.
- `opencode-gemini-auth/src/plugin.ts:32-37` — `auth.loader` receives `getAuth` and `provider`. It reads the current `AuthDetails` (via `getAuth`), and if the auth is not of type `"oauth"` it returns `undefined` so Opencode can fall back to other mechanisms. For OAuth entries, it constructs a loader result with `apiKey: ""` and a wrapped `fetch` that handles token refresh and project context.
- `opencode-gemini-auth/src/plugin.ts:59-78` — The wrapped `fetch` re-resolves auth via `getAuth`, checks `accessTokenExpired`, calls `refreshAccessToken` if needed, and always uses a current access token before proceeding with the request.
- `opencode-gemini-auth/src/plugin.ts:85-111` — Before issuing the HTTP request, the plugin uses `ensureProjectContext` to obtain an `effectiveProjectId` based on current auth and config (including `provider.options.projectId` and `OPENCODE_GEMINI_PROJECT_ID`), then calls `prepareGeminiRequest` to rewrite URL/headers/body for Gemini Code Assist.
- `opencode-gemini-auth/src/plugin.ts:130-199` — The primary OAuth auth method ("OAuth with Google (Gemini CLI)") defines the interactive flow. It may start a local HTTP listener (via `startOAuthListener`) or run in manual mode, calls `authorizeGemini` to get the auth URL, and returns a callback that eventually calls `exchangeGemini` to produce a `GeminiTokenExchangeResult` consumed by Opencode's `ProviderAuth.callback`.
- `opencode-gemini-auth/src/plugin.ts:201-227` — In environments where running a local listener is not possible, the plugin uses a `method: "code"` mode where the user manually pastes the callback URL. The callback extracts `code` and `state` and calls `exchangeGemini` just as in the automatic flow.
- `opencode-gemini-auth/src/plugin.ts:231-235` — A secondary auth method (`type: "api"`) offers "Manually enter API Key" for the same `"google"` provider. The plugin itself does not define the structure of API-key auth entries; Opencode treats them as `Auth.Api` entries in `auth.json`.
- `opencode-gemini-auth/src/plugin.ts:239` — `GoogleOAuthPlugin` re-exports `GeminiCLIOAuthPlugin` under an alternative name, allowing Opencode to refer to it as either when registering the plugin.
- `opencode-gemini-auth/src/plugin.ts:48-50` — The plugin reads `provider.options.projectId` and `process.env.OPENCODE_GEMINI_PROJECT_ID` to compute a `configuredProjectId` passed into `ensureProjectContext`, tying configuration and environment into project selection.

### opencode-gemini-auth: request rewriting, debug logging, and headers

- `opencode-gemini-auth/src/plugin/request.ts:22-24` — `isGenerativeLanguageRequest` classifies requests to `generativelanguage.googleapis.com` as Gemini requests; only these requests are rewritten.
- `opencode-gemini-auth/src/plugin/request.ts:55-83` — `prepareGeminiRequest` clones incoming headers, injects `Authorization: Bearer <accessToken>`, strips any `x-api-key` header, parses the `/models/<model>:<action>` pattern from the original URL, and rebuilds the URL against `GEMINI_CODE_ASSIST_ENDPOINT` with an internal `v1internal:<action>` path. It returns the rewritten `RequestInit` and a `streaming` flag.
- `opencode-gemini-auth/src/plugin/request.ts:92-159` — For JSON bodies, `prepareGeminiRequest` wraps the request into a Code Assist-compatible payload, ensuring that the configured `projectId` or `managedProjectId` is included under a `project` field and that the `model` and `request` fields are adjusted to match Gemini's expectations.
- `opencode-gemini-auth/src/plugin/request.ts:185-192` — `transformGeminiResponse` normalizes responses based on whether the request is streaming and the requested model. It can adjust error messages, add retry hints, and capture usage metadata while leaving auth storage unchanged.
- `opencode-gemini-auth/src/plugin/debug.ts:5-10` — Debugging is controlled via the `OPENCODE_GEMINI_DEBUG` env var. When enabled, the plugin writes detailed request/response logs (with masked `Authorization` headers) to a local file `gemini-debug-<timestamp>.log` in the current working directory.
- `opencode-gemini-auth/src/plugin/debug.ts:39-61` — `startGeminiDebugRequest` logs method, URLs, project id, streaming status, and masked headers/body preview; `logGeminiDebugResponse` logs status, headers, body preview, and error information. These logs are the primary file writes in the plugin and are separate from auth storage.

## Code References

- `benedict-provider.el:19-24` — `cl-defstruct benedict-provider` and registry.
- `benedict-provider.el:27-40` — Provider registration and lookup functions.
- `benedict-provider.el:58-74` — `benedict-provider-dispatch` entrypoint for provider calls.
- `benedict.el:28-31` — `defcustom benedict-provider` (default provider id).
- `benedict-chat.el:2297-2313` — `benedict-chat--build-request` neutral request construction.
- `benedict-chat.el:2505-2523` — `benedict-chat--start-dispatch` bridging chat to provider dispatch.
- `benedict-http.el:43-76` — `benedict-http-request` shared HTTP wrapper.
- `benedict-http.el:113-131` — `benedict-http--make-command` header-to-curl conversion.
- `test/benedict-http-test.el:10-29` — Header (including Authorization) formatting test.
- `benedict-provider-openrouter.el:70-79` — OpenRouter env var and auth-source user configuration.
- `benedict-provider-openrouter.el:1215-1246` — OpenRouter credential resolution (auth-source then env var).
- `benedict-provider-openrouter.el:905-915` — OpenRouter header construction with Authorization, Referer, X-Title.
- `benedict-provider-vercel.el:85-94` — Vercel env var and auth-source user configuration.
- `benedict-provider-vercel.el:1253-1284` — Vercel credential resolution (auth-source then env var).
- `benedict-provider-vercel.el:943-953` — Vercel header construction with Authorization, Referer, X-Title.
- `benedict-provider-ollama.el:149-196` — Ollama request dispatch (no auth) and HTTP call.
- `benedict-provider-ollama.el:881-883` — Ollama content-type-only headers.
- `benedict-provider-fake.el:227-331` — Fake provider in-process send path (no HTTP/auth).
- `README.org:80-89` — OpenRouter credentials configuration.
- `README.org:241-321` — Provider-specific options including env vars and header-related settings.
- `ROADMAP.org:28-44` — Roadmap items specifying key management and auth integration expectations.
- `opencode/packages/opencode/src/global/index.ts:6-31` — `Global.Path` XDG directory layout for Opencode data/config.
- `opencode/packages/opencode/src/auth/index.ts:6-69` — `Auth` credential types and `auth.json` read/write.
- `opencode/packages/opencode/src/mcp/auth.ts:7-123` — `McpAuth` token/state storage in `mcp-auth.json`.
- `opencode/packages/opencode/src/provider/auth.ts:10-127` — Provider auth methods, OAuth callbacks, and `Auth.set` integration.
- `opencode/packages/opencode/src/provider/provider.ts:615-682` — Provider credentials from env, `auth.json`, and plugins.
- `opencode/packages/opencode/src/cli/cmd/auth.ts:170-390` — CLI `auth` commands for listing, login, and logout.
- `opencode/packages/opencode/src/server/server.ts:1537-1636` — HTTP endpoints for provider OAuth flows.
- `opencode/packages/opencode/src/mcp/index.ts:416-559` — MCP OAuth start/authenticate/finish flows.
- `opencode/packages/console/function/src/auth.ts:21-215` — OpenAuth issuer configuration and account provisioning.
- `opencode/packages/console/core/src/schema/auth.sql.ts:4-20` — Console `auth` table mapping external identities to accounts.
- `opencode/packages/console/app/src/context/auth.ts:10-89` — Console session and actor resolution from OpenAuth.
- `opencode-gemini-auth/src/plugin/types.ts:3-8` — `OAuthAuthDetails` structure used for stored Gemini auth.
- `opencode-gemini-auth/src/plugin/auth.ts:12-36` — `parseRefreshParts`/`formatRefreshParts` packed refresh string helpers.
- `opencode-gemini-auth/src/gemini/oauth.ts:77-156` — Gemini OAuth URL construction and token exchange.
- `opencode-gemini-auth/src/plugin/token.ts:64-153` — Access-token refresh and persistence via `client.auth.set`.
- `opencode-gemini-auth/src/plugin/project.ts:260-325` — Project context derivation and persistence inside `auth.refresh`.
- `opencode-gemini-auth/src/plugin.ts:29-37,130-199` — Plugin entrypoint and Gemini OAuth auth method definition.
- `opencode-gemini-auth/src/plugin/request.ts:55-159` — Request rewriting with `Authorization` and `project` fields.

## Architecture Documentation

- **Benedict provider-neutral vs provider-specific responsibilities**
  - Chat and tool layers (`benedict-chat.el`, `benedict-tools.el`, `benedict-context.el`) operate on provider-neutral request and message plists and do not include auth or credential fields. Providers are responsible for turning these plists into HTTP payloads.
  - Provider modules (`benedict-provider-openrouter.el`, `benedict-provider-vercel.el`, `benedict-provider-ollama.el`, `benedict-provider-fake.el`) interpret neutral requests, resolve credentials, build JSON bodies and headers, and call `benedict-http-request`.
  - The HTTP wrapper (`benedict-http.el`) handles curl execution and streaming vs non-streaming responses, translating header alists into curl flags without interpreting auth details.

- **Benedict credential sources and precedence**
  - OpenRouter and Vercel resolve credentials in a shared pattern:
    1. Use `auth-source-search` with host derived from the endpoint and an optional `*-auth-source-user` value.
    2. If auth-source yields a secret, wrap it as a `:token` in a credential plist with `:source 'auth-source`.
    3. If auth-source fails, read a provider-specific env var (e.g., `OPENROUTER_API_KEY` or `AI_GATEWAY_API_KEY`) and wrap it as `:token` with `:source 'env`.
    4. If neither yields a token, signal an error describing expected auth-source entries and env vars.
  - Ollama and Fake have no credential resolution; they rely on unauthenticated local behavior or in-process simulation.

- **Benedict auth header injection and logging**
  - OpenRouter and Vercel attach `Authorization: Bearer TOKEN` and optional branding headers at the provider level via `*-build-headers` helpers; these headers are passed directly to `benedict-http-request` as part of the header alist.
  - Redaction helpers in provider modules mask `Authorization` and `Proxy-Authorization` values to support logging policies stated in `README.org` and `ROADMAP.org`.

- **Opencode auth data stores**
  - Opencode stores provider credentials in `auth.json` under `Global.Path.data`, with entries typed as simple API keys (`Auth.Api`), OAuth tokens and metadata (`Auth.Oauth`), or well-known tokens (`Auth.WellKnown`). File permissions are locked to the user (`0o600`).
  - MCP OAuth credentials and state (tokens, client info, PKCE verifier, OAuth state, server URL) live in `mcp-auth.json` under the same data directory and are accessed via `McpAuth` helpers.
  - Console auth uses OpenAuth for token and session management, Drizzle ORM tables (`AuthTable`, `UserTable`) for persistent mappings from external identities to internal accounts and users, and a browser cookie-based `AuthSession` for per-client account selection.
  - Additional ephemeral or environment-sourced tokens (e.g., GitHub OIDC/PATs in GitHub Actions) are handled via HTTP endpoints and environment variables, not stored in `auth.json`.

- **Opencode provider auth aggregation**
  - Provider authentication is centralized via `ProviderAuth` and `Provider` modules. `ProviderAuth` exposes pluggable auth methods for each provider, backed by plugins. `Auth.json` (via `Auth`) and environment variables supply stored credentials.
  - During provider discovery, env-based credentials (`provider.env`) and `auth.json` (`Auth.Api`) entries are combined into a provider map with fields like `source` and `key` describing where the credential came from.
  - For providers with plugin-provided auth (like Gemini via `opencode-gemini-auth`), the plugin's `auth.loader` is invoked when credentials exist. The loader can return a wrapped `fetch` and additional options (`apiKey`, `baseURL`, project id configuration) that override or augment base provider behavior.

- **Opencode server and CLI auth flows**
  - The `opencode` CLI and HTTP server expose the same underlying auth primitives. CLI commands (`opencode auth *`) use HTTP endpoints that wrap `ProviderAuth` and `Auth` to list, create, and delete credentials.
  - OAuth flows for providers are mediated via HTTP endpoints (`/provider/:providerID/oauth/authorize` and `/provider/:providerID/oauth/callback`) that call plugin hooks and then update `auth.json`.
  - MCP OAuth flows are exposed via `/mcp/:name/auth*` endpoints that start local callback servers, store state in `mcp-auth.json`, exchange codes for tokens, and reconnect MCP transports.

- **opencode-gemini-auth storage and flow within Opencode**
  - The `opencode-gemini-auth` plugin does not define its own on-disk storage. Instead, it uses Opencode's plugin client API (`client.auth.get`/`client.auth.set`) to read/write `OAuthAuthDetails` entries for provider id `"google"` in the shared `auth.json` file.
  - The plugin encodes both the Gemini OAuth refresh token and project context into a single `refresh` string, which is stored as part of the `OAuthAuthDetails` record. On subsequent runs, Opencode loads this record from `auth.json` and supplies it to the plugin via `getAuth` and `auth.loader`.
  - Token refresh flows and project onboarding update the same `auth.json` entry using `client.auth.set`, preserving project ids while rotating tokens.

- **opencode-gemini-auth request shaping and header injection**
  - For Gemini requests, the plugin's loader returns a `fetch` implementation that uses the current `OAuthAuthDetails` and project context to construct requests. It injects `Authorization: Bearer <accessToken>` and removes any `x-api-key` header, ensuring Gemini is always accessed via user-specific OAuth.
  - Request bodies are rewritten to include `project` and `request` fields compatible with Gemini Code Assist, and URLs are routed through `GEMINI_CODE_ASSIST_ENDPOINT` with internal action paths. The plugin therefore handles both auth-level and protocol-level adaptation for Gemini.
  - Debug logging is optional and controlled by `OPENCODE_GEMINI_DEBUG`. When enabled, detailed (but redacted) logs are written to local log files independent of `auth.json`.

## Historical Context (from previous efforts)

- `efforts/tool-schema-generation/research.md` documents how providers share a common tool-schema and argument encoding layer while retaining provider-specific HTTP and auth details.
- `efforts/file-and-buffer-mutation-tools/research.md` identifies the provider registry (`benedict-provider.el`) and HTTP layer (`benedict-http.el`) as the main integration points for external requests, with provider modules responsible for translating neutral requests into concrete HTTP calls.

## Open Questions

- There are no tests in `test/` that directly exercise auth-source or env-var credential resolution for Benedict providers (e.g., missing keys, multiple auth-source entries, or invalid env vars); behavior in such cases is inferred from provider code and README, not verified by automated tests.
- Provider-specific redaction helpers for headers are defined in Benedict provider modules, but their integration points with logging (e.g., `lgr` configuration in `benedict-http.el` or provider logging) are not fully documented within this research; following log call sites would clarify where and how header redaction is applied.
- Only chat-related code paths were examined for Benedict provider dispatch; if other subsystems (e.g., future tools or Flywire integrations) gain independent provider or HTTP usage, additional research would be needed to confirm that they follow the same auth and credential-resolution patterns.
- In Opencode, the exact on-disk representation and location of the auth store used by `client.auth.set`/`getAuth` in the plugin context are inferred from `auth.json` and `Auth` helpers; the plugin itself treats the auth store as an abstraction.
- How Opencode surfaces Gemini-specific auth errors and revocation events (such as `invalid_grant`) to users is not fully visible from the plugin alone; this likely involves CLI and UI layers that consume plugin logs and provider error messages.
