---
date: 2025-12-18T00:00:00-05:00
planner: GPT-5.1
status: draft
related_research: efforts/tool-schema-generation/research.md
---

# Plan: Centralized Tool Schema & Argument Encoding

## Goal & Non-Goals

**Goal**

- Redefine `:schema` on tool specs to be a JSON-Schema-shaped descriptor (Elisp plist).
- Centralize:
  - Schema → JSON Schema `"parameters"` encoding.
  - Tool-argument (`args`) → JSON string encoding.
- Update all existing tools to the new schema shape, correctly marking logically optional arguments.
- Update all providers to use the centralized encoders.
- Lock in behavior via strong unit + property tests.

**Non-Goals**

- No array support yet (we’ll add when needed).
- No runtime validation of arguments inside Emacs (schema stays provider-facing).
- No Anthropic/other provider styles yet; this prepares the ground but doesn’t add them.

## Canonical Registry Schema Format

We redefine `:schema` to be as close to JSON Schema as practical while staying Elisp-friendly.

### Object schema shape

A `:schema` value is always an **object** schema, represented as a plist:

```elisp
:schema
'(:type object
  :description "Human-readable description"        ; optional
  :properties
  (:prop1 (:type string  :description "...")
   :prop2 (:type integer :description "...")
   :nested-object
   (:type object
    :properties
    (:inner1 (:type string)
     :inner2 (:type boolean)))
   :optional-prop
   (:type string :description "..." ))             ; optional
  :required (:prop1 :prop2 :nested-object))         ; list of required properties
```

**Rules**

- `:type`:
  - Must be `object` at the top level and for any nested object.
  - For scalar properties, `:type` is one of `string`, `integer`, `number`, `boolean`.
- `:properties`:
  - Plist of `keyword-or-symbol → property-schema`.
  - Property schema is itself a plist using JSON Schema-like keys (`:type`, `:description`, `:properties`, `:required`, `:default`, etc.).
- `:required`:
  - A list of property keys (keywords or symbols) that are required.
  - If omitted: **all properties are optional** (JSON Schema semantics).
  - Optionality is encoded solely via `:required`; we do not use a separate `:optional` flag.
- Allowed property-schema fields (current effort):
  - `:type` — `string`, `integer`, `number`, `boolean`, `object`.
  - `:description` — string.
  - `:default` — any JSON-encodable value (not used by tools yet, but safe).
  - `:properties`, `:required` — for nested objects.

Type tags **must** be symbols (e.g. `'string`, `'integer`, `'boolean`, `'object`). Any non-symbol `:type` is considered a programming error and should cause the encoder to signal.

## Central Encoding APIs (in `benedict-tools.el`)

Add a new internal section (e.g. `;;; Tool schemas`) with the following functions.

### `benedict-tool-schema->json-parameters`

- **Signature**: `(benedict-tool-schema->json-parameters schema)`
- **Input**: `schema` — registry schema plist as above.
- **Output**: JSON Schema `"parameters"` object as an alist, ready for `json-encode`, e.g.:

  ```elisp
  '(("type" . "object")
    ("properties"
     . (("path"       . (("type" . "string")))
        ("start-line" . (("type" . "integer")))
        ("end-line"   . (("type" . "integer")))))
    ("required" . ["path"]))  ; when applicable
  ```

- **Behavior**:
  - Ensures top-level `"type"` is `"object"`.
  - Converts `:properties`:
    - Keys: `:prop-name` or `'prop-name` → `"prop-name"` via `symbol-name` and stripping initial `:` if present.
    - Values: encoded via `benedict-tool--encode-property-schema`.
  - Handles `:required`:
    - If present: converts list of property keys to a JSON array (vector) of corresponding string names.
    - If absent: omits `"required"` (all properties optional).

### `benedict-tool--encode-property-schema` (internal)

- **Signature**: `(benedict-tool--encode-property-schema prop-schema)`
- **Input**: `prop-schema` — plist for a single property.
- **Output**: JSON Schema property object as an alist, e.g. `(("type" . "string") ("description" . "foo"))`.
- **Behavior**:
  - Reads `:type` (required).
  - If `:type` is `object`:
    - Reads `:properties` and optional `:required`, and recursively calls `benedict-tool-schema->json-parameters` to build a nested `"type": "object"` with `"properties"` and (optional) `"required"`.
  - If `:type` is scalar (`string`, `integer`, `number`, `boolean`):
    - Builds `(("type" . <json-type>))`, plus pass-through of allowed metadata keys like `"description"`, `"default"`.
  - Normalizes type via `benedict-tool-type->json-type`.

### `benedict-tool-type->json-type`

- **Signature**: `(benedict-tool-type->json-type type-tag)`
- **Behavior**:
  - Accepts symbols: `string`, `integer`, `number`, `boolean`, `object` (and optional synonyms like `int`, `float`, `bool`).
  - Returns one of `"string"`, `"integer"`, `"number"`, `"boolean"`, `"object"`.
  - Any non-symbol `type-tag` or unknown symbol should signal an error; tests will enforce correct usage.

### Argument encoding

#### `benedict-tool-args->alist`

- **Signature**: `(benedict-tool-args->alist args)`
- **Behavior**:
  - Accepts `args` as plist or alist.
  - Normalizes to a string-keyed alist:
    - Keys: symbols/keywords/strings → string names (`"arg-name"`).
    - Values: unchanged.
  - Does not validate against schema (yet).

#### `benedict-tool-encode-args-json`

- **Signature**: `(benedict-tool-encode-args-json args)`
- **Behavior**:
  - `json-encode` of `(benedict-tool-args->alist args)`.
  - Used by providers to set `"function.arguments"`.

## Updating Tool Schemas in `benedict-tools.el`

Migrate all existing tool schemas to the new JSON-Schema-shaped format and explicitly mark optional arguments using `:required`.

Below are exemplar conversions; all tools must be updated analogously.

### `write` tool (was at `benedict-tools.el:313`)

Old (conceptual):

```elisp
'(:target (:kind string :path string :buffer_name string)
  :content string
  :create_if_missing boolean)
```

New:

```elisp
:schema
'(:type object
  :description "Write content to a file or buffer."
  :properties
  (:target
   (:type object
    :description "Target file or buffer."
    :properties
    (:kind        (:type string  :description "Either 'file' or 'buffer'.")
     :path        (:type string  :description "Filesystem path when kind is 'file'.")
     :buffer_name (:type string  :description "Buffer name when kind is 'buffer'.")))
   :content (:type string :description "New content to write.")
   :create_if_missing (:type boolean :description "Whether to create missing files."))
  :required (:target :content))
```

Here `:create_if_missing` is logically optional.

### `edit` tool (was at `benedict-tools.el:322`)

```elisp
:schema
'(:type object
  :description "Edit text in a file or buffer."
  :properties
  (:target
   (:type object
    :properties
    (:kind        (:type string)
     :path        (:type string)
     :buffer_name (:type string)))
   :old_text (:type string)
   :new_text (:type string))
  :required (:target :old_text :new_text))
```

### `project-search` tool (was at `benedict-tools.el:331`)

```elisp
:schema
'(:type object
  :description "Search project files for a string."
  :properties
  (:query (:type string :description "Search query."))
  :required (:query))
```

### `read-file` tool (was at `benedict-tools.el:582`)

```elisp
:schema
'(:type object
  :description "Read a file, optionally by line range."
  :properties
  (:path       (:type string  :description "Filesystem path.")
   :start-line (:type integer :description "1-based start line (optional).")
   :end-line   (:type integer :description "1-based end line (optional)."))
  :required (:path))
```

### `find-files` tool (was at `benedict-tools.el:616`)

```elisp
:schema
'(:type object
  :description "Find files matching a pattern."
  :properties
  (:pattern (:type string :description "Glob-like pattern.")
   :path    (:type string :description "Base directory (optional)."))
  :required (:pattern))
```

### `exec-elisp` tool (was at `benedict-tools.el:662`)

```elisp
:schema
'(:type object
  :description "Execute Emacs Lisp code."
  :properties
  (:code (:type string :description "Emacs Lisp to evaluate."))
  :required (:code))
```

All other tools in `benedict-tools.el` must be updated to the same pattern: top-level `:type object`, `:properties` for each argument, and `:required` listing only those arguments that are logically required. Update `benedict-tools-register` docstring to state that `:schema` follows this JSON-Schema-like contract.

## Provider Integration

For each provider, delegate schema and argument encoding to the centralized functions.

### OpenRouter (`benedict-provider-openrouter.el`)

- `benedict-provider-openrouter--encode-tool-schema`:
  - Replace body with:

    ```elisp
    (benedict-tool-schema->json-parameters schema)
    ```

- `benedict-provider-openrouter--tool-type-string`:
  - Remove and replace uses with `benedict-tool-type->json-type` if anything still calls it; otherwise delete.

- `benedict-provider-openrouter--tool-arguments->alist` and `benedict-provider-openrouter--encode-tool-arguments`:
  - Replace with calls to `benedict-tool-args->alist` and `benedict-tool-encode-args-json`.

### Vercel (`benedict-provider-vercel.el`) and Ollama (`benedict-provider-ollama.el`)

- Make analogous changes:
  - Delegate `"parameters"` to `benedict-tool-schema->json-parameters`.
  - Delegate argument encoding to shared functions.
  - Remove duplicated type/argument helpers.

Provider-specific wrapping (e.g., `"type": "function"`, `"function": {...}`) stays where it is.

## Testing Strategy

### New test file: `test/benedict-tool-schema-test.el`

- Require `benedict-tools.el` plus `ert` and `propcheck`.

**Unit tests for schema encoding**

- For each known tool (`write`, `edit`, `project-search`, `read-file`, `find-files`, `exec-elisp`, plus any others):
  - Extract its `:schema` and assert that `benedict-tool-schema->json-parameters` produces expected structure:
    - Top-level `"type"` is `"object"`.
    - `"properties"` has the expected keys and `"type"` values.
    - `"required"` matches the `:required` list (correct required/optional semantics).
- For nested object properties (`:target` on `write`/`edit`):
  - Assert nested `"type": "object"`, correct nested `"properties"`, and nested `"required"` if present.
- Tests for `benedict-tool-type->json-type` mapping across all supported type tags and unknown fallbacks.

**Unit tests for argument encoding**

- `benedict-tool-args->alist`:
  - Plist and alist inputs yield the same normalized alist.
  - Keyword and symbol keys normalize to the same string key.
- `benedict-tool-encode-args-json`:
  - JSON strings match expected encoding for simple sample arguments.

### Property-based tests (propcheck)

- Define a generator for JSON-Schema-shaped schemas within our subset:
  - Always `:type object`.
  - `:properties`:
    - Random 1–5 property names (symbols like `:arg-<n>`).
    - Each property schema:
      - Either scalar: `(:type <scalar-type>)`.
      - Or nested object (depth 0–1): `(:type object :properties (...))`.
  - `:required`:
    - Random subset of the property names or omitted entirely.

- Properties to assert:
  1. `benedict-tool-schema->json-parameters` never errors.
  2. Result always has `"type" = "object"` and `"properties"` as an alist.
  3. Every name listed in `"required"` corresponds to a key in `"properties"`.
  4. If `:required` is absent in input, `"required"` is absent in output.
  5. Each property subschema has `"type"` ∈ {"string", "integer", "number", "boolean", "object"}.

### Provider tests

- For each provider (OpenRouter, Vercel, Ollama):
  - Construct a minimal tool spec mirroring registry output (with one of the new schemas).
  - Run the provider’s serialization function (e.g., `benedict-provider-openrouter--serialize-tool`).
  - Assert:
    - `"function.parameters"` equals `benedict-tool-schema->json-parameters` on the same schema.
    - `"function.arguments"` for a sample argument plist equals `benedict-tool-encode-args-json`.

### End-to-end / regression

- Run the full suite (`nix run .#test`) after changes.
- Confirm any existing provider tests continue to pass and still exercise request-building with tools.

## Work Breakdown

1. **Define schema API & tests (test-first)**
   - Add `test/benedict-tool-schema-test.el` with unit and property tests for:
     - `benedict-tool-schema->json-parameters` and nested objects.
     - `benedict-tool-type->json-type`.
     - `benedict-tool-args->alist` and `benedict-tool-encode-args-json`.
   - Iterate on tests until they clearly express the desired API and behavior.

2. **Implement central encoders in `benedict-tools.el`**
   - Implement:
     - `benedict-tool-schema->json-parameters`.
     - `benedict-tool--encode-property-schema` (internal).
     - `benedict-tool-type->json-type`.
     - `benedict-tool-args->alist`.
     - `benedict-tool-encode-args-json`.
   - Make the new tests pass.

3. **Migrate tool schemas**
   - Update every `:schema` in `benedict-tools.el` to the new JSON-Schema-shaped format, with explicit `:required` listing only logically required arguments.
   - Extend tests to cover any additional tool schemas beyond the core ones listed above.
   - Update `benedict-tools-register` docstring to describe the new contract.

4. **Provider refactor**
   - For OpenRouter, Vercel, and Ollama providers:
     - Delegate schema encoding to `benedict-tool-schema->json-parameters`.
     - Delegate argument encoding to `benedict-tool-args->alist` / `benedict-tool-encode-args-json`.
     - Remove duplicated schema and argument helpers.
   - Add or update provider tests to assert correct wiring.

5. **Documentation & clean-up**
   - Note the new centralized schema/argument encoding and schema format in `efforts/tool-schema-generation/log.md`.
   - Optionally add a short note to higher-level docs (e.g., a tools section) describing how to define schemas for new tools.

## Acceptance Criteria

- All tool schemas in `benedict-tools.el` are JSON-Schema-shaped (no legacy formats).
- `benedict-tool-schema->json-parameters` and argument encoders are used by all providers; no duplicated schema/argument encoding logic remains.
- Optional vs required arguments are correctly modeled via `:required` for all existing tools (e.g., `find-files` `:path`, `read-file` line bounds, `write` `:create_if_missing`).
- New unit and property tests exist and pass; they would catch accidental changes to schema or argument encoding.
- `nix run .#test` and `nix run .#lint` succeed.
