# Tools Specification

This document defines the Tooling System, the capabilities exposed to the Agent.

## 1. Tool Registry (`benedict-tools.el`)

Tools are defined using `benedict-tools-register`.

### 1.1 Tool Definition Structure
- **`:id`** (symbol): Unique name (e.g., `'read-file`).
- **`:fn`** (function): Elisp function to execute.
- **`:doc`** (string): Human-readable description.
- **`:approval`** (symbol):
    - `'auto`: Safe, read-only. Run without prompt (unless global policy overrides).
    - `'confirm`: Side-effects (write/edit). Require user confirmation.
    - `'always`: Dangerous (exec-elisp). Always require confirmation.
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

## 3. Tool Execution Environment (`benedict-flywire`)

To ensure safety and stability, tools are executed in an isolated context.

- **Agent Frame:** A dedicated Emacs frame (visible or invisible) where side-effects like "switch buffer" or "open file" happen, preventing the agent from hijacking the user's primary window layout.
- **Sandboxing:** File access is restricted to the Project Root by default to prevent accidental modification of system files or unrelated projects.

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
