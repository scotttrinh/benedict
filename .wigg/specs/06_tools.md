# Tools Specification

This document defines the Tooling System, the capabilities exposed to the Agent.

## 1. Tool Registry (`benedict-tools.el`)

Tools are defined using `benedict-tools-register`.

### 1.1 Tool Definition Structure
- **`:id`** (symbol): Unique name (e.g., `'read-file`).
- **`:fn`** (function): Elisp function to execute.
- **`:doc`** (string): Human-readable description.
- **`:effects`** (list of symbols): Declares the effect category for harness enforcement.
    - Examples: `read`, `write`, `exec`, `network`, `ui`, `process`.
- **`:scope`** (plist): Declares what the tool intends to touch (harness uses this for policy).
    - Examples: `(:paths ("./" ".wigg/") :buffers ("*scratch*") :commands (rg git))`
- **`:approval`** (symbol, legacy): Back-compat hint only. The primary mechanism is the harness policy.
    - `'auto`: No prompt expected within allowed scope.
    - `'confirm`: Prompt if scope expansion is required.
    - `'always`: Always prompt (reserved for privileged effects like arbitrary eval).
- **`:schema`** (plist): JSON Schema definition of arguments.

### 1.2 Schema Format
A simplified plist representation of JSON Schema:
```elisp
'(:type object
  :description "Read a file."
  :properties (:path (:type string :description "Path to file"))
  :required (:path))
```

## 2. Standard Library (Built-in Tools)

### 2.1 File System
- **`read-file`**
    - **Args:** `:path` (string), `:start-line` (int), `:end-line` (int).
    - **Behavior:** Reads content. Supports line ranges to reduce token usage.
    - **Approval:** `auto`.
- **`find-files`**
    - **Args:** `:pattern` (glob string), `:path` (optional root).
    - **Behavior:** Lists files matching pattern.
    - **Approval:** `auto`.
- **`write`**
    - **Args:** `:target` (object: path/buffer), `:content` (string), `:create_if_missing` (bool).
    - **Behavior:** Overwrites (or creates) file/buffer with *full* content.
    - **Approval:** `confirm`.

### 2.1.1 Context Capture (Compose-First)

These tools support adding context while composing, without requiring the user to switch buffers.

- **`list-buffers`**
    - **Args:** optional filters (mode, name regex).
    - **Behavior:** Return buffer names and lightweight metadata (major-mode, file path).
    - **Effects:** `read`.

- **`context-add-buffer`**
    - **Args:** `:buffer_name`, optional `:start-line`, `:end-line`, optional `:handle`.
    - **Behavior:** Add a buffer slice as a context slice to the compose context.
    - **Effects:** `read`.

- **`context-add-file`**
    - **Args:** `:path`, optional `:start-line`, `:end-line`, optional `:handle`.
    - **Behavior:** Add a file slice as a context slice to the compose context.
    - **Effects:** `read`.

### 2.2 Navigation & Search
- **`project-search`**
    - **Args:** `:query` (string - regex/literal).
    - **Behavior:** Runs `ripgrep` (rg) and returns structured matches (file, line, preview).
    - **Approval:** `auto`.

### 2.3 Editing
- **`edit`**
    - **Args:** `:target` (object), `:old_text` (string), `:new_text` (string).
    - **Behavior:** Exact string replacement. Fails if `old_text` matches 0 or >1 times.
    - **Approval:** `confirm`.

### 2.4 Meta
- **`exec-elisp`**
    - **Args:** `:code` (string).
    - **Behavior:** Evals arbitrary Elisp. High power, high risk.
    - **Approval:** `always`.

### 2.5 Elisp Reliability (Repair and Guards)

Agents frequently produce unparsable Elisp. Benedict must provide first-class support for diagnosing and repairing Elisp before attempting to execute or load it.

- **`check-elisp`**
    - **Args:** `:target` (buffer/file), optional `:kind` (parens, byte-compile, checkdoc).
    - **Behavior:** Validate syntax and return structured diagnostics (location + message).
    - **Effects:** `read`.

- **`repair-elisp`**
    - **Args:** `:target` (buffer/file), optional `:strategy` (minimal-parens, reindent, rewrite-form).
    - **Behavior:** Propose a repair as a patch/diff or an `edit` tool call plan.
    - **Effects:** `write` (when applied), otherwise `read` for proposal generation.

Guideline:
- `exec-elisp` should be wrapped by a guard that refuses to run when `check-elisp` reports syntax errors, unless the user explicitly overrides.

## 3. Tool Execution Environment (`benedict-flywire`)

To ensure safety and stability, tools are executed in an isolated context.

- **Agent Frame:** A dedicated Emacs frame (visible or invisible) where side-effects like "switch buffer" or "open file" happen, preventing the agent from hijacking the user's primary window layout.
- **Sandboxing:** File access is restricted to the Project Root by default to prevent accidental modification of system files or unrelated projects.

In v0.1, "modern safety" means:
- the default experience should not rely on constant user confirmation
- the harness enforces scope and budgets, and only prompts on scope expansion

## 4. Custom Tools API

Users can extend Benedict with their own capabilities.

- **`benedict-register-tool`**:
    - Users define an Elisp function and a JSON Schema.
    - The tool becomes available to the agent immediately.
    - Custom tools share the same approval policies as built-ins.

## 5. Error Handling

- Tools must return useful error messages on failure (e.g., "File not found", "Match not unique").
- Errors are captured and returned to the LLM as a Tool Result with `status: failure`.
- The LLM uses this feedback to self-correct (e.g., refine search query, fix file path).
