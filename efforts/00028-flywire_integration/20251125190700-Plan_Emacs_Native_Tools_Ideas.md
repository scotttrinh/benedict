Here is the specification package for the "Phase 0" toolset. You can feed this directly to a coding assistant to generate the Elisp implementation.

***

### 1. Intent and Architecture
We are building the "Bio-API" for an autonomous Emacs agent. Unlike CLI-based agents, this agent lives inside the Emacs process. The goal of "Phase 0" is to provide the minimum viable set of primitives to enable a `Find -> Read -> Edit -> Execute` loop. These tools must prioritize token efficiency (reading only relevant segments) and safety (using line numbers over search-and-replace). While these tools handle basic file IO, their underlying implementation in Elisp implicitly manages the buffer state (the "point"), paving the way for advanced future tools (Magit, LSP) without requiring explicit cursor management commands yet.

### 2. Tool Specifications

**1. `agent-search-project`**
*   **Description:** Searches the codebase for a string or regex pattern using a fast backend (ripgrep/grep).
*   **Arguments:**
    *   `query` (string): The search term.
    *   `root` (string, optional): The directory to search in. Defaults to the current project root.
*   **Returns:** A list of matches formatted as strings: `path/to/file:line_number: match_content`.

**2. `agent-read-file`**
*   **Description:** Opens a file (if not already open) and returns its content. Can return a specific slice to save tokens. Implicitly sets the buffer's point to the start of the read segment.
*   **Arguments:**
    *   `filepath` (string): The absolute or relative path to the file.
    *   `start-line` (integer, optional): The first line to read. If null/nil, reads from start.
    *   `end-line` (integer, optional): The last line to read. If null/nil, reads to end.
*   **Returns:** A string containing the content with line numbers prepended (e.g., `12 | (defun foo...`).

**3. `agent-update-file`**
*   **Description:** Replaces a specific range of lines in a file with new content and saves the buffer to disk.
*   **Arguments:**
    *   `filepath` (string): The path to the file.
    *   `start-line` (integer): The starting line number to replace.
    *   `end-line` (integer): The ending line number to replace.
    *   `content` (string): The new text to insert.
*   **Returns:** A success message string or an error message if the file/lines don't exist.

**4. `agent-exec-elisp`**
*   **Description:** Evaluates an arbitrary string of Emacs Lisp code. This is the mechanism for the agent to hot-load new tools or inspect internal state.
*   **Arguments:**
    *   `code` (string): The Elisp code to evaluate.
*   **Returns:** A string representation of the result or the error traceback.

### 3. Example Workflow
To verify the system works, the agent should perform this sequence:
1.  **Find:** `agent-search-project("init.el")` to find the user's config.
2.  **Read:** `agent-read-file("path/to/init.el", 1, 10)` to read the header.
3.  **Bootstrap:** `agent-update-file("path/to/init.el", 5, 5, ";; Agent was here")` to verify write access.
4.  **Verify:** `agent-exec-elisp("(message \"Hello from Agent\")")` to verify execution capability.

### 4. Definition of Done
The implementation is complete when you can:
1.  Load the tools file in Emacs.
2.  Call `(agent-exec-elisp "(+ 1 1)")` and get `"2"`.
3.  Call the read/write functions on a dummy file and see the changes persist to disk without the buffer interaction causing Emacs to hang or lose focus.

