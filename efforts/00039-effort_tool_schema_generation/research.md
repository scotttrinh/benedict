---
date: 2025-12-18T00:00:00-05:00
researcher: GPT-5.1
git_commit: be927adf1e565ebc3aaf462c029e9287958e18f0
branch: main
repository: benedict
topic: "Tool schema generation and ownership"
tags: [research, codebase, tools, schema, json-schema]
status: complete
last_updated: 2025-12-18
---

# Research: Tool schema generation and ownership

**Date**: 2025-12-18T00:00:00-05:00
**Researcher**: GPT-5.1
**Git Commit**: be927adf1e565ebc3aaf462c029e9287958e18f0
**Branch**: main

## Research Question
How are tool argument schemas defined and owned in Benedict today, and how are they turned into JSON Schema for providers and tool calls?

## Summary
Tool argument schemas in Benedict are defined and owned centrally by the tool registry in `benedict-tools.el`, where each tool spec now stores a JSON-Schema-shaped plist (top-level `:type object` with nested `:properties` and optional `:required`). The chat layer discovers and filters these tool specs without altering the schemas, then attaches them to provider requests as a `:tools` list. Conversion to provider payloads is centralized in `benedict-tools.el` via `benedict-tool-schema->json-parameters`, `benedict-tool-args->alist`, and `benedict-tool-encode-args-json`, and every provider backend (OpenRouter, Vercel, Ollama) simply calls these helpers when constructing `"function.parameters"` and `"function.arguments"`. Argument schemas are not currently used for in-Emacs validation; they are provider-facing metadata that define how LLM APIs see and call tools.

## Detailed Findings

### Registry ownership of tool schemas
- `benedict-tools.el:16` — `benedict--tools` is a hash-table registry keyed by tool ID symbols, where each entry is a plist with `:id`, `:fn`, `:schema`, `:approval`, and `:doc`. This table is the single, authoritative catalogue for all tools and their argument schemas.
- `benedict-tools.el:370` — `benedict-tools-register` constructs tool specs by accepting keyword arguments `:id`, `:fn`, `:schema`, `:approval`, and `:doc`, then storing the resulting plist in `benedict--tools`. Its docstring now spells out that `:schema` must follow the JSON-Schema-like contract consumed by `benedict-tool-schema->json-parameters`, but the registry still stores schemas as opaque metadata.
- `benedict-tools.el:271` — `benedict-tools-list` returns a list of all spec plists from `benedict--tools`. Downstream code (chat and providers) use this function to discover tools and to retrieve the schema owned by the registry.
- `benedict-tools.el:115` — `benedict-tool-schema->json-parameters` enforces that registry schemas are top-level objects with symbol `:type` tags and recursively encodes `:properties`/`:required`; `benedict-tool-type->json-type` raises when encountering an unknown type tag, catching registry mistakes early.
- `benedict-tools.el:275–311` — `benedict--tool-call-direct` and `benedict-tool-invoke` rely only on the `:fn` and `:approval` fields of a spec when invoking a tool, treating the argument plist `ARGS` as already well-formed. They do not read or validate `:schema`, which reinforces that schema ownership lives in the registry but enforcement is not performed locally.

### Shape of argument schemas in benedict-tools.el
- `benedict-tools.el:421` — The `write` tool now declares a JSON-Schema-style object with `:type object`, nested `:properties`, and `:required (:target :content)`, leaving `:create_if_missing` optional while the nested `:target` schema lists its own required keys.
- `benedict-tools.el:445` — The `edit` tool mirrors that structure, requiring the nested `:target` object plus `:old_text` and `:new_text` while still documenting each leaf with a `:description` and `:type`.
- `benedict-tools.el:463` — `project-search` remains the scalar baseline, but the schema is now wrapped in `(:type object :properties (:query (:type string ...)) :required (:query))` to match the canonical contract.
- `benedict-tools.el:715` — `read-file` exposes `:path`, `:start-line`, and `:end-line` inside a JSON-Schema object; only `:path` appears in `:required`, so callers can omit the range bounds.
- `benedict-tools.el:755` — `find-files` likewise marks `:pattern` as required and `:path` optional within the shared object schema.
- `benedict-tools.el:807` — `exec-elisp` uses the same pattern with a single string property `:code` listed under `:required`.
- Across these examples the schema vocabulary now explicitly encodes optionality via `:required` lists and limits types to JSON-Schema scalars (`string`, `integer`, `number`, `boolean`) plus nested `object`s; defaults and arrays remain out of scope for this iteration.

### Chat layer: passing schemas through unchanged
- `benedict-chat.el:559` — `benedict-chat--registered-tool-ids` retrieves all `:id` values from `benedict-tools-list`, forming the base set of available tools before any profile filtering.
- `benedict-chat.el:571` — `benedict-chat--tools-for-capabilities` maps configured profile capabilities to tool IDs using `benedict-chat-capability-tool-map`, but does not interpret or alter schemas.
- `benedict-chat.el:581` — `benedict-chat--effective-tool-ids` combines registered tool IDs with profile allowlists, denylists, and capabilities to produce the final set of tool IDs for a chat session. This step still works purely at the ID level.
- `benedict-chat.el:597` — `benedict-chat--resolve-tools` takes the effective tool IDs and filters the list from `benedict-tools-list` to return just the matching spec plists. It uses `copy-tree` on each spec but does not modify `:schema`, treating it as a registry-owned value passed through to providers.
- `benedict-chat.el:2297` — `benedict-chat--build-request` constructs the provider request plist with keys such as `:provider`, `:model`, `:profile`, `:messages`, and `:tools`. The `:tools` field is set directly to the list returned by `benedict-chat--resolve-tools`, meaning provider backends receive schemas exactly as defined in `benedict-tools.el`.

### Provider backends: JSON Schema generation from registry schemas

#### OpenRouter provider
- `benedict-provider-openrouter.el:941` — `benedict-provider-openrouter--build-body` assembles the JSON body alist for an OpenRouter chat request. It serializes messages, sets the model, and, when the `:tools` key is present in the request, pushes a "tools" entry produced by `benedict-provider-openrouter--serialize-tools`.
- `benedict-provider-openrouter.el:1007` — `benedict-provider-openrouter--serialize-tools` maps each tool spec plist to a provider tool entry by calling `benedict-provider-openrouter--serialize-tool`, forwarding the registry-owned `:schema` to the shared encoder.
- `benedict-provider-openrouter.el:1018` — `benedict-provider-openrouter--serialize-tool` now delegates `"parameters"` to `benedict-tool-schema->json-parameters`, so the provider no longer implements its own schema walker or type mapping; it still sets the provider-specific "type"/"function" envelope and passes along the registry `:doc`.
- `benedict-provider-openrouter.el:1041` — `benedict-provider-openrouter--serialize-tool-call` converts tool call plists into JSON by calling `benedict-tool-encode-args-json`; string arguments are passed through, while plist/alist inputs are normalized via `benedict-tool-args->alist` before encoding.


#### Vercel provider
- `benedict-provider-vercel.el:979` — `benedict-provider-vercel--build-body` builds the Vercel request body, and, analogous to OpenRouter, inserts a "tools" array when `:tools` is present in the request.
- `benedict-provider-vercel.el:1045` — `benedict-provider-vercel--serialize-tools` iterates over tool specs from the registry and calls `benedict-provider-vercel--serialize-tool` for each one.
- `benedict-provider-vercel.el:1050` — `benedict-provider-vercel--serialize-tool` uses the same shared helpers as OpenRouter: it keeps the provider-specific "type"/"function" wrapper but sources `"parameters"` from `benedict-tool-schema->json-parameters` and descriptions directly from the registry spec.
- `benedict-provider-vercel.el:1079` — `benedict-provider-vercel--serialize-tool-call` also relies on `benedict-tool-encode-args-json` so both providers share identical argument JSON.


#### Ollama provider
- `benedict-provider-ollama.el:909` — `benedict-provider-ollama--build-body` constructs the Ollama request body and, if tools are present, attaches a "tools" array built by `benedict-provider-ollama--serialize-tools`.
- `benedict-provider-ollama.el:975` — `benedict-provider-ollama--serialize-tools` maps over tool specs and calls `benedict-provider-ollama--serialize-tool` for each one.
- `benedict-provider-ollama.el:980` — `benedict-provider-ollama--serialize-tool` mirrors the other providers: it wraps registry specs in the provider's "type"/"function" shape while sourcing `"parameters"` from `benedict-tool-schema->json-parameters`.
- `benedict-provider-ollama.el:1009` — `benedict-provider-ollama--serialize-tool-call` also delegates to `benedict-tool-encode-args-json`, ensuring Ollama emits the same argument payloads as the other providers.


### Tool schemas vs tool calls and UI
- `benedict-chat.el:1761` — `benedict-chat--invoke-tool-call` is the dispatcher that calls `benedict-tool-invoke` for a given tool call, catches errors, updates the chat tool block UI, and records a history entry. It passes the argument plist as-is and does not consult `:schema` at runtime.
- `benedict-chat.el:1716–1760` — Helpers such as `benedict-chat--tool-call-metadata`, `benedict-chat--normalize-tool-output`, and `benedict-chat--tool-result-history-entry` work with tool results (`:text`, `:ui`, `:raw`). These functions interact with tool outputs and UI but are agnostic to schemas.
- `benedict-chat-render.el:433` — `benedict-chat--render-tool-actions` renders interactive actions from a tool result’s `:ui` plist. Actions are defined by tool implementations and normalized by `benedict-chat--normalize-actions`, not by schemas.
- Tests in `test/benedict-tools-test.el` and `test/benedict-tool-actions-test.el` focus on tool implementation behavior and UI normalization. They do not reference `:schema` or JSON tool definitions, which further indicates that schemas are external-facing metadata rather than internal validation structures.

## Code References
- `benedict-tools.el:16` — `benedict--tools` registry holding `:id`, `:fn`, `:schema`, `:approval`, `:doc`.
- `benedict-tools.el:115` — `benedict-tool-schema->json-parameters` converts registry schemas to JSON Schema parameters; `benedict-tool-args->alist`/`benedict-tool-encode-args-json` live nearby (lines 129–147).
- `benedict-tools.el:370` — `benedict-tools-register` documents the JSON-Schema contract for `:schema` when storing specs.
- `benedict-tools.el:421` — `write` tool registration and schema plist.
- `benedict-tools.el:445` — `edit` tool registration and schema plist.
- `benedict-tools.el:463` — `project-search` tool registration and schema plist.
- `benedict-tools.el:715` — `read-file` tool registration and schema plist.
- `benedict-tools.el:755` — `find-files` tool registration and schema plist.
- `benedict-tools.el:807` — `exec-elisp` tool registration and schema plist.
- `benedict-chat.el:559` — `benedict-chat--registered-tool-ids` for discovering registered tool IDs.
- `benedict-chat.el:597` — `benedict-chat--resolve-tools` for hydrating tool specs (including schemas) for a profile.
- `benedict-chat.el:2297` — `benedict-chat--build-request` attaching `:tools` (with schemas) to provider requests.
- `benedict-provider-openrouter.el:1018` — `benedict-provider-openrouter--serialize-tool` delegating schema encoding to `benedict-tool-schema->json-parameters`.
- `benedict-provider-openrouter.el:1041` — `benedict-provider-openrouter--serialize-tool-call` encoding arguments via `benedict-tool-encode-args-json`.
- `benedict-provider-vercel.el:1050` — `benedict-provider-vercel--serialize-tool` using the shared schema encoder.
- `benedict-provider-vercel.el:1079` — `benedict-provider-vercel--serialize-tool-call` using `benedict-tool-encode-args-json`.
- `benedict-provider-ollama.el:980` — `benedict-provider-ollama--serialize-tool` delegating schema conversion to the shared helper.
- `benedict-provider-ollama.el:1009` — `benedict-provider-ollama--serialize-tool-call` encoding arguments through the shared helper.
- `test/benedict-tool-schema-test.el:1` — Unit/property tests covering schema encoding helpers and argument encoding.

## Architecture Documentation
- Tool definitions are owned by `benedict-tools.el`, which maintains a central hash-table of tool specs. Each spec includes a `:schema` plist that describes argument names and types in an implementation-agnostic way.
- The chat layer (`benedict-chat.el`) is responsible for deciding which tools are available in a given conversation via profile-based allowlists, denylists, and capability mappings. It passes the registry-owned tool specs, including `:schema`, through unchanged when constructing provider requests.
- Provider backends (`benedict-provider-openrouter.el`, `benedict-provider-vercel.el`, `benedict-provider-ollama.el`) still wrap registry specs in provider-specific envelopes, but they now call `benedict-tool-schema->json-parameters` and `benedict-tool-encode-args-json` for the heavy lifting instead of maintaining bespoke schema/type encoders.
- Tool schemas are not currently used by `benedict-tool-invoke` or the chat UI for validation; instead, they serve as metadata that informs external LLM APIs how to call tools. Runtime argument checking remains the responsibility of each tool implementation.
- Existing research in `efforts/file-and-buffer-mutation-tools/research.md` describes how file and buffer mutation tools are registered and invoked; this current effort focuses specifically on how their argument schemas are defined in the registry and consumed by providers for JSON Schema generation.

## Open Questions
- The JSON-Schema-shaped `:schema` format now encodes optionality via `:required`, but it still omits richer constructs such as arrays, enums, numeric bounds, or validation keywords; adding those would require expanding both the registry contract and the shared encoder helpers.
- Schemas are not used for in-Emacs validation of arguments passed to `benedict-tool-invoke`; it is not clear from the current code whether local schema-based validation is planned or if schemas will remain purely provider-facing metadata.
- Future schema evolution must happen inside `benedict-tool-schema->json-parameters` / `benedict-tool-encode-args-json`, so downstream providers will pick up changes automatically, but those helpers will need comprehensive tests to avoid regressions across providers.
