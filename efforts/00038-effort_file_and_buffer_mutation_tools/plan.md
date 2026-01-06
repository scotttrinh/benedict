---
date: 2025-12-18
planner: GPT-5.1
repository: benedict
effort: file-and-buffer-mutation-tools
status: draft
---

# Plan: Unified File and Buffer Mutation Tools (`write` and `edit`)

## 1. Context and Motivation

Benedict currently exposes multiple file mutation tools via `benedict-tools.el`:

- `create-file` – create a new file with content.
- `update-file` – line-range based replacement.
- `write-file` – whole-file overwrite.
- `propose-edit` – unified diff application with review buffer.

These have proven error-prone for LLMs, especially lower-capability models, in two ways:

1. **Path handling:** Confusion about how to provide a correct project-root–relative path vs absolute paths.
2. **Line-range APIs:** Misuse of `:start-line` / `:end-line` semantics and reliance on fragile line numbers that drift as the file changes.

At the same time, Benedict needs file and buffer mutation that is:

- Safe (confined to the project root for files).
- Expressive enough for both heavy rewrites and small local edits.
- Simple and obvious for low-intelligence models.
- Unified across files and arbitrary Emacs buffers.

This plan replaces the existing file mutation tools with two new tools: `write` and `edit`, built around a shared "target" abstraction and Emacs-native editing primitives.


## 2. Goals and Non-Goals

### 2.1 Goals

1. **Unify file and buffer mutation** under a small, clear set of tools:
   - `write` for creation and whole-buffer overwrites.
   - `edit` for safe snippet-based in-place edits.
2. **Eliminate line-number–based editing** (`:start-line`, `:end-line`) in favor of:
   - Whole-buffer writes.
   - Literal snippet replacement with strict safety checks.
3. **Improve robustness for low-capability models** by:
   - Using a simple, explicit `target` object for all operations.
   - Providing clear, deterministic error messages when edits cannot be applied.
4. **Keep operations Emacs-native and safe**:
   - Always operate through buffers.
   - Confine file operations to the project root.
   - Automatically save file-backed buffers on success.
5. **Replace legacy tools** (`create-file`, `update-file`, `write-file`, `propose-edit`) in profiles and code paths with `write` and `edit`.

### 2.2 Non-Goals

- No patch/diff-based editing in this effort (the `propose-edit` tool will be removed).
- No line-range–based editing.
- No regex-based editing.
- No review-only mode; edits apply immediately once the user approves the tool call. Git remains the primary diff/review interface.
- No content size limits in the tools themselves (this can be addressed at the chat/message level if needed).


## 3. High-Level Design

We introduce two tools registered in `benedict-tools.el`:

- **`write`**
  - Purpose: Create or overwrite an entire file or buffer so that its text exactly equals the provided `content`.
  - Supports creating new files (and parent directories) and new buffers.

- **`edit`**
  - Purpose: Modify an existing file or buffer by replacing one specific snippet (`old_text`) with another (`new_text`).
  - Enforces **literal** matching and strictly **exactly one** occurrence.

Both tools share a **unified target abstraction** that covers both files and arbitrary buffers:

```jsonc
{
  "target": {
    "kind": "file" | "buffer",
    "path": "src/foo.el",        // required if kind == "file"
    "buffer_name": "*scratch*"   // required if kind == "buffer"
  },
  ...
}
```

Under the hood, all operations are buffer-centric:

- Files are always edited via a visiting buffer (`find-file-noselect`).
- Arbitrary buffers are addressed by name (`get-buffer` / `get-buffer-create`).
- File-backed buffers (`buffer-file-name` non-nil) are always saved on success.


## 4. Detailed Tool Specifications

### 4.1 Shared Target Abstraction

All tools accept a `target` object with the following semantics:

- `target.kind` (string, required):
  - One of: `"file"`, `"buffer"`.

- If `target.kind == "file"`:
  - `target.path` (string, required):
    - A **project-root–relative** path (e.g., `"src/foo.el"`).
    - May not be absolute.
    - May not escape the project root (enforced via existing helpers like `benedict--resolve-target-file`).

- If `target.kind == "buffer"`:
  - `target.buffer_name` (string, required):
    - Name of the buffer to target (e.g., `"*scratch*"`).

Resolution rules:

- For file targets:
  - Use existing project-root resolution (`project-current`, `benedict--resolve-target-file`, etc.).
  - Always operate via a buffer visiting the file: `find-file-noselect`.
- For buffer targets:
  - `get-buffer` (for `edit`, which requires existing buffers).
  - `get-buffer` / `get-buffer-create` (for `write`, when `create_if_missing` is true).

Saving behavior:

- After a **successful** mutation:
  - If `(buffer-file-name)` is non-nil in the target buffer, call `save-buffer`.
  - Otherwise, do not attempt to write to disk (even if `target.kind == "buffer"`).


### 4.2 `write` Tool

**ID:** `write`  
**Approval:** `'confirm`  
**Intent:** Create or overwrite an entire file or buffer so its contents equal `content`.

#### 4.2.1 Arguments

- `target` (object, required)
  - `kind`: `"file"` | `"buffer"` (required).
  - `path` (string, required if `kind == "file"`).
  - `buffer_name` (string, required if `kind == "buffer"`).

- `content` (string, required)
  - The **entire text** the target should contain after the operation.

- `create_if_missing` (boolean, optional, default `true`)
  - If `kind == "file"`:
    - `true`: create file and parent directories if needed.
    - `false`: error if file does not exist.
  - If `kind == "buffer"`:
    - `true`: create the buffer if missing.
    - `false`: error if buffer does not exist.

#### 4.2.2 Behavior

1. **Resolve target**

   - If `kind == "file"`:
     - Validate `path` is project-root–relative and under the project root.
     - If file does not exist:
       - If `create_if_missing` is `false` → error: e.g., "File does not exist and create_if_missing is false."
       - If `true` → ensure parent directories exist, then use `find-file-noselect` to create buffer.
     - If file exists:
       - Use `find-file-noselect` to get visiting buffer.

   - If `kind == "buffer"`:
     - If `create_if_missing` is `true` (or omitted):
       - `get-buffer` or `get-buffer-create` `buffer_name`.
     - If `false`:
       - `get-buffer`; if nil → error: "Buffer <name> does not exist and create_if_missing is false."

2. **Apply write**

   - In `with-current-buffer` + `atomic-change-group`:
     - `erase-buffer`.
     - `insert` `content`.
     - If buffer is file-backed (`buffer-file-name` non-nil), enforce a trailing newline policy consistent with existing tools (e.g., ensure final `?\n` unless `content` is empty).

3. **Save if file-backed**

   - If `(buffer-file-name)` is non-nil, call `save-buffer`.

4. **Return result**

   - Normalized plist, e.g.:

     ```elisp
     (:target (:kind "file"
               :path "src/foo.el"
               :visited_file "src/foo.el")
      :operation "write"
      :lines_written 37
      :summary "Wrote 37 lines to file src/foo.el")
     ```

   - `benedict-chat` will normalize this into the standard `:text` / `:ui` structure for display and history.


### 4.3 `edit` Tool

**ID:** `edit`  
**Approval:** `'confirm`  
**Intent:** Modify an **existing** file or buffer by replacing one specific snippet (`old_text`) with `new_text`, with strict, literal, exactly-one semantics.

Key constraints:

- **No `create_if_missing`:** the target must already exist.
- **No `match_policy` knob:** behavior is fixed to "exactly one" occurrence.
- **`old_text` and `new_text` must differ:** the tool refuses no-op edits.

#### 4.3.1 Arguments

- `target` (object, required)
  - Same shape and semantics as in `write`.

- `old_text` (string, required)
  - Literal text to search for in the buffer (no regex).

- `new_text` (string, required)
  - Replacement text to insert in place of `old_text`.

#### 4.3.2 Preconditions

- If `target.kind == "file"`:
  - File must exist under the project root; otherwise error: "File <path> does not exist." (No auto-create.)

- If `target.kind == "buffer"`:
  - Buffer must exist; otherwise error: "Buffer <name> does not exist."

- Before touching any buffer:
  - If `(string= old_text new_text)`:
    - Error: e.g., "edit: old_text and new_text are identical; no change to apply."

#### 4.3.3 Behavior

1. **Resolve target**

   - For `kind == "file"`:
     - Validate project-root–relative `path` and file existence.
     - Use `find-file-noselect` to get visiting buffer.

   - For `kind == "buffer"`:
     - `get-buffer`; if nil → error as above.

2. **Search for `old_text` literally**

   - In `with-current-buffer` + `save-excursion` + `atomic-change-group`:
     - Scan from `point-min` to `point-max` using literal search (e.g., `search-forward` with `case-fold-search` as appropriate, likely defaulting to case-sensitive).
     - Record all match positions and count `N`.

3. **Enforce "exactly one" semantics**

   - If `N == 0`:
     - Abort the change group.
     - Return an error result with a clear summary, e.g.:
       - "edit: old_text not found; expected exactly one occurrence. Include more surrounding context in old_text."

   - If `N > 1`:
     - Abort the change group.
     - Return an error result including `N`, e.g.:
       - "edit: old_text matched N times; expected exactly one. Include more surrounding context in old_text."

4. **Replace the single match**

   - With the single recorded match:
     - Go to the match region.
     - Replace that region with `new_text` (e.g., `delete-region` + `insert`, or a constrained `perform-replace`).
   - If buffer is file-backed: `save-buffer`.

5. **Return result on success**

   - Normalized plist, e.g.:

     ```elisp
     (:target (:kind "buffer"
               :buffer_name "*scratch*"
               :visited_file nil)
      :operation "edit"
      :matches_found 1
      :replacements_made 1
      :summary "Replaced 1 snippet in buffer *scratch*")
     ```

6. **Return result on error**

   - Structured failure describing:
     - Why the edit failed (target missing, identical old/new, 0 matches, >1 matches).
     - `:matches_found` when known.
   - `benedict-chat--invoke-tool-call` wraps thrown errors into this structure and marks the tool UI state as failure.


## 5. Emacs Implementation Plan

### 5.1 New Tool Functions in `benedict-tools.el`

1. **Shared helpers**

   - Add a helper for resolving the target:

     - `benedict--tool-resolve-target-buffer (args)` → returns a plist:
       - `:buffer` (buffer object)
       - `:kind` (`"file"` or `"buffer"`)
       - `:path` or `:buffer_name`
       - `:file-backed-p` (boolean)

     Responsibilities:

     - Validate `target.kind`.
     - Enforce project-root-relative paths for `kind == "file"`.
     - Resolve or create buffers as required by the calling tool.

2. **`benedict--tool-write`**

   - Implementation of `write` tool using the shared resolver.
   - Behavior as described in §4.2.

3. **`benedict--tool-edit`**

   - Implementation of `edit` tool using the shared resolver.
   - Explicitly rejects missing targets and identical `old_text`/`new_text`.
   - Implements literal search and exactly-one semantics as described in §4.3.

4. **Registration**

   - Register tools in `benedict-tools.el` via `benedict-tools-register`:
     - `:id 'write`, `:fn #'benedict--tool-write`, `:approval 'confirm`, `:schema ...`, `:doc` explaining semantics.
     - `:id 'edit`, `:fn #'benedict--tool-edit`, `:approval 'confirm`, `:schema ...`, `:doc` explaining snippet semantics and the "exactly one" rule.

### 5.2 Provider Schema and Exposure

- Update the tool schema objects embedded in provider payloads (OpenAI/OpenRouter/Vercel) to describe `write` and `edit`:

  - `write` parameters: `target`, `content`, `create_if_missing`.
  - `edit` parameters: `target`, `old_text`, `new_text`.

- Adjust `benedict-chat--resolve-tools` / profile definitions so that:

  - `write` and `edit` are the primary mutation tools exposed to models.
  - Legacy tools (`create-file`, `update-file`, `write-file`, `propose-edit`) are removed from active profiles.


## 6. Testing Strategy

### 6.1 Unit Tests for `write`

Add tests to `test/benedict-tools-test.el` (or a new dedicated file if appropriate):

- `write` creates a new file when `create_if_missing` is `t`:
  - Target: `kind == "file"` with a nested path.
  - Assertions:
    - File exists on disk.
    - Contents match `content` (including trailing newline behavior).

- `write` errors on missing file when `create_if_missing` is `nil`:
  - Target a non-existent file.
  - Assert a structured error.

- `write` overwrites an existing file:
  - Seed file with known contents.
  - Call `write` with a different `content`.
  - Assert only new contents are present; old contents are gone.

- `write` writes to an existing buffer:
  - Create a non-file buffer and populate it.
  - Call `write` with `kind == "buffer"`, `buffer_name`.
  - Assert contents match exactly, no disk I/O.

- `write` creates a new buffer when `create_if_missing` is `t`.

### 6.2 Unit Tests for `edit`

- `edit` replaces one occurrence in a file:
  - File has a unique snippet.
  - Call `edit` with that snippet as `old_text` and a replacement.
  - Assert file contents changed only at that location; remainder unchanged.

- `edit` errors when `old_text` not found:
  - Ensure error summary indicates no matches and suggests adding more context.

- `edit` errors when `old_text` matches multiple times:
  - File contains the snippet twice.
  - Ensure error summary includes the count and suggests more context.

- `edit` rejects identical `old_text` and `new_text`:
  - Assert clear error message and no buffer changes.

- `edit` works in an existing non-file buffer:
  - Populate a buffer with a unique snippet.
  - Apply `edit` and assert in-memory changes.

### 6.3 Safety Tests

- Reject absolute paths in `target.path`.
- Reject paths that escape the project root.
- Ensure file-backed buffers are saved after both `write` and `edit` on success:
  - Using temp files; verify on-disk contents.


## 7. Migration and Rollout

1. Implement `write` and `edit` and their tests.
2. Update tool registration and provider schemas so that only `write` and `edit` are exposed for file/buffer mutation in supported profiles.
3. Remove legacy tools in `benedict-tools.el`:
   - Remove `create-file`, `update-file`, `write-file`, `propose-edit`.
   - Adjust tests that referenced them to instead use `write` and `edit`.
4. Update any user-facing documentation or system prompts that describe file mutation tools to:
   - Clearly explain `write` and `edit` usage patterns.
   - Emphasize:
     - `write` for creation/overwrite.
     - `edit` for single-snippet replacement with literal `old_text`/`new_text`.


## 8. Open Questions / Future Extensions

These are out-of-scope for this effort but worth noting for future work:

1. **Diff-producing results:**
   - The tools could eventually return a diff (computed from a temp copy) alongside the summary for better chat-buffer visualization.

2. **Additional `edit` policies:**
   - Introducing optional, carefully controlled modes like:
     - `first_only`: replace only the first occurrence.
     - `all`: replace all occurrences, with bounds on expected match counts.

3. **Regex-based edits:**
   - A separate advanced tool (not `edit`) for regex-powered refactors, restricted to more capable profiles.

4. **Buffer disallow lists:**
   - Future hardening could forbid operating on certain internal buffers (minibuffer, process buffers, etc.) once we identify problematic targets in practice.

5. **Tool-level size limits:**
   - If very large `content` payloads become an issue, consider integrating size checks or tying into a global maximum message size.

This plan defines the behavior and contracts for the new `write` and `edit` tools and outlines an incremental path to replace legacy file mutation tools with simpler, safer, and more model-friendly alternatives.
