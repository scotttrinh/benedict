# UI/UX Specification

This document defines the user interface and user experience for Benedict.

## 1. Chat Buffer Design

The Chat Buffer is the primary interface. It mimics a standard Emacs buffer but adds rich, interactive elements.

### 1.1 Layout
- **Header:**
    - Provider/Model indicator (e.g., `[OPENROUTER: claude-3-opus]`).
    - Status badges (Streaming, Error, Tokens, Latency).
    - Session Title.
- **Conversation Stream:**
    - Chronological list of turns.
    - Differentiated visually by Roles (User, Assistant, System).
- **Compose Area:**
    - Users type directly at the bottom of the buffer (or in a dedicated compose buffer).

### 1.2 Visual Elements (Faces & Badges)
- **Roles:**
    - **USER:** Bold, keyword face.
    - **ASSISTANT:** Doc face.
    - **SYSTEM:** Shadow/dimmed.
- **Badges:**
    - SVG pills (if available) or bracketed text `[LABEL]`.
    - Usage: Roles, Tool Names, Status (Running/Success/Fail), Thinking blocks.
- **Markdown-Lite:**
    - Rendering of bold/italic using text properties.
    - **Code Blocks:**
        - Fontified using native `prog-mode` (via `markdown-fontify-code-blocks-natively`).
        - Distinct background face for separation.

### 1.3 Folding & Structure (`magit-section`)
The buffer is structured as a tree of sections:
- **Root Section**
    - **Turn Section** (User Request + Assistant Response)
        - **Message Block**
        - **Thinking Block** (Collapsible "Chain of Thought")
        - **Tool Call Block** (Collapsible)
            - **Header:** Tool Name + Args (Summary)
            - **Body:** Full Args (Hidden by default)
            - **Result:** Output/Diff (Visible)

### 1.4 Interactive Elements
- **Buttons:**
    - Provider/Model name is clickable to switch models.
    - Tool call headers are clickable to toggle visibility.
- **Keybindings (`benedict-mode-map`):**
    - `C-c C-s`: Send prompt / Stream response.
    - `C-c C-k`: Cancel streaming/loop.
    - `g r`: Retry last request.
    - `w`: Copy last response.
    - `n` / `p`: Next/Prev section.
    - `TAB`: Toggle section folding.

## 2. Context Management UI

Users need ways to feed Emacs context into the chat.

- **`benedict-chat-ask-region`**: Sends selected text.
- **`benedict-chat-ask-defun`**: Sends current function.
- **`benedict-chat-ask-buffer`**: Sends whole buffer.
- **`benedict-chat-ask-project`**: Sends project file structure.
- **`benedict-chat-ask-git-context`**: Sends git status/diff.

**UX Flow:**
1. User invokes command.
2. Content is gathered.
3. Chat buffer opens (if not open).
4. Content is inserted as a pre-filled "Context Slice" (potentially hidden or summarized).
5. User types query and sends.

## 3. History Browsing (Persistence UI)

Users can revisit past conversations.

- **Thread Browser:**
    - A dedicated mode (like `magit-log` or `elfeed`) listing past threads.
    - Columns: Date, Title (generated summary), Model, Status.
    - Filtering: By Project, Profile, or Date.
- **Restoration:**
    - Selecting a thread rehydrates a Chat Buffer with full history.
    - Users can fork conversations from any point (branching history).

## 4. Tool Approval UI

When an agent wants to execute a tool (and policy is `confirm`):

1. **Simple Phase:** Minibuffer `y-or-n-p`.
   - "Benedict tool `write` with args `{:path "foo.el" ...}`?"
2. **Advanced Phase (Diff Preview):**
   - For `edit` or `write` operations, pop up a temporary buffer.
   - Show a `diff` or `ediff` view of the proposed changes against the current buffer state.
   - Actions: Accept (`y`), Reject (`n`), or Edit (`e`) the arguments/patch before applying.

## 5. Notifications

- **Minibuffer:** Short status updates ("Streaming...", "Tool 'search' finished").
- **Mode Line:**
    - Benedict indicator.
    - Active Spinner during streaming.
