# UI/UX Specification (vui.el Architecture)

This document describes Benedict's UI as the target end-state after refactoring to `vui.el`.

## 1. Core UI Model

Benedict's UI is a tree of `vui` components mounted into Emacs buffers. Components render virtual nodes describing UI structure; vui.el reconciles and commits changes while preserving cursor/scroll positions.

### 1.1 Unidirectional Data Flow

- **Data flows down** through props (inputs to child components)
- **Events flow up** through callback props (children never reach into parent state)
- **Shared state** lives at the nearest common ancestor; local-only state stays colocated

### 1.2 Component Hierarchy

```
BenedictRoot
├── ChatHeader
│   ├── ProviderBadge (clickable model selector)
│   ├── StatusIndicator (streaming/error/idle)
│   └── SessionTitle
├── ConversationView
│   └── TurnList (vui-list with stable turn-id keys)
│       └── Turn
│           ├── TurnHeader (role badge, timestamp)
│           └── ContentBlockList
│               ├── TextBlock
│               ├── ThinkingBlock (collapsible)
│               ├── ToolUseBlock (collapsible)
│               ├── ToolResultBlock (collapsible)
│               └── CodeBlock (syntax highlighted)
├── StreamingIndicator (visible during active streaming)
├── InputArea
│   ├── ContextIndicators
│   └── ComposeField (controlled input)
└── StatusBar
    └── TokenCount, CostEstimate, ErrorMessages
```

### 1.2 State, Effects, and Async

- **Local state**: `:state` declaration + `vui-set-state` (use functional updates in async)
- **Batching**: Wrap multiple `vui-set-state` calls in `vui-batch` to avoid intermediate re-renders
- **Lifecycle**:
  - `:on-mount` for one-time setup (may return cleanup function)
  - `:on-unmount` for final cleanup when removed during reconciliation
  - `:on-update` for reacting to prop/state changes
- **Effects**: `vui-use-effect` runs side effects based on dependencies; must return cleanup
- **Async**: `vui-use-async` manages loading/error/success states with cancellation safety
- **Async context**: Callbacks in timers/processes must use `vui-with-async-context` or `vui-async-callback`

### 1.3 Context for Cross-Cutting Concerns

Use `vui-defcontext` to avoid prop drilling for truly global values:
- UI theme/face palette
- Active provider configuration
- Feature flags and debug toggles

Context is *not* for frequently-changing data (streaming content) to avoid broad re-renders.

---

## 2. State Management

### 2.1 Root-Level State

The `BenedictRoot` component owns all shared application state:

```elisp
(:conversation       ; List of turn plists - canonical conversation data
 :streaming          ; (:status pending|active|complete|error
                     ;  :turn-id current-turn-id
                     ;  :content accumulated-streaming-content)
 :provider           ; :anthropic | :openai | :bedrock | :openrouter
 :model              ; "claude-sonnet-4-20250514" etc.
 :collapsed-blocks   ; Set of block-ids that are collapsed
 :error)             ; Current error state or nil
```

### 2.2 Component-Local State

State that only one component cares about stays local:

- **InputArea**: `:input-text`, `:input-history-index`
- **CodeBlock**: `:copied-feedback` (temporary "Copied!" message)
- **CollapsibleBlock**: `:local-hover-state`

### 2.3 Derived State

Values computed from state are calculated on-the-fly, not stored:

```elisp
;; Use vui-use-memo for expensive computations
(let ((token-count (vui-use-memo
                     (lambda () (benedict--count-tokens conversation))
                     (list conversation))))
  ...)
```

---

## 3. Chat Buffer Design

The Chat Buffer is the primary interface, rendered as a vui.el component tree.

 ### 3.1 Layout

- **Header**: Provider/Model badge, status indicator, session title
- **Conversation Stream**: `vui-list` of turns with stable keys
- **Compose Area**: Controlled `vui-field` at buffer bottom with context indicators
  - Keybindings for submit/history are set up by parent buffer, not by component render

### 3.2 Visual Elements

#### Roles (via faces)
- **USER**: `benedict-user-face` (bold, keyword-like)
- **ASSISTANT**: `benedict-assistant-face` (doc-style)
- **SYSTEM**: `benedict-system-face` (shadow/dimmed)

#### Badges
Rendered as `vui-box` components with appropriate faces:
```elisp
(vui-defcomponent status-badge (props state)
  (let ((status (plist-get props :status))
        (theme (vui-use-benedict-theme-context)))
    (vui-box :class (format "badge badge-%s" status)
             :face (badge-face-for status theme)
      (vui-text (badge-label status)))))
```

#### Code Blocks
```elisp
(vui-defcomponent code-block (props state)
  (let* ((language (plist-get props :language))
         (code (plist-get props :code))
         (fontified (vui-use-memo
                      (lambda () (benedict--fontify-code code language))
                      (list code language))))
    (vui-box :class "code-block"
             :face 'benedict-code-block-face
      (vui-text fontified))))
```

### 3.3 Collapsible Sections

Thinking blocks, tool calls, and tool results use a compound component pattern:

```elisp
(vui-defcomponent collapsible-block (props state)
  (let ((collapsed (plist-get state :collapsed))
        (header (plist-get props :header))
        (content (plist-get props :content))
        (on-toggle (plist-get props :on-toggle)))
    (vui-vstack
      (vui-hstack
        (vui-button (if collapsed "▶" "▼")
                    :on-click on-toggle)
        (funcall header))
      (unless collapsed
        (funcall content)))))
```

### 3.4 Interactive Elements

#### Buttons
```elisp
(vui-button "Switch Model"
  :on-click (lambda () (benedict--show-model-selector)))
```

 #### Keybindings
Keybindings are registered in `benedict-mode-map` and dispatch actions to a root component:

| Key       | Action                        |
|-----------|-------------------------------|
| `C-c C-s` | Send prompt / Stream response |
| `C-c C-k` | Cancel streaming/loop         |
| `g r`     | Retry last request            |
| `w`       | Copy last response            |
| `n` / `p` | Next/Prev turn                |
| `TAB`     | Toggle block collapse         |

##### Keybinding Pattern Guidelines

Components should NOT set keymaps during render (avoiding side effects in `vui-use-effect`). Instead:

1. **Define named keymap variable** for component-specific bindings:
   ```elisp
   (defvar my-component-mode-map
     (let ((map (make-sparse-keymap)))
       (define-key map (kbd "C-c C-c") #'my-component-submit)
       map)
     "Keymap for my-component.")
   ```

2. **Define interactive commands** that operate on component state:
   ```elisp
   (defun my-component-submit ()
     "Submit the component."
     (interactive)
     (let ((value (vui-field-value 'my-input)))
       (when my-component--on-submit-callback
         (funcall my-component--on-submit-callback value))))
   ```

3. **Parent buffer initializes keymaps** once (not per render):
   ```elisp
   (define-derived-mode benedict-chat-mode vui-mode "Benedict Chat"
     (use-local-map benedict-chat-mode-map)  ; Compose maps together
     ...)
   ```

4. **Users can customize** by modifying keymap variables before loading:
   ```elisp
   (with-eval-after-load 'benedict-vui-compose-field
     (define-key benedict-vui-compose-field-mode-map (kbd "RET") 'my-submit))
   ```

## 4. Streaming Architecture

### 4.1 State Machine

```
         ┌──────────┐
send-msg │          │  error
────────►│ pending  │◄─────────┐
         │          │          │
         └────┬─────┘          │
              │ first-chunk    │
              ▼                │
         ┌──────────┐          │
         │          │──────────┘
         │  active  │
         │          │──┐ chunk (accumulate)
         └────┬─────┘  │
              │◄───────┘
              │ done
              ▼
         ┌──────────┐
         │ complete │────► idle (reset)
         └──────────┘
```

### 4.2 Async Context Handling

Streaming updates must use `vui-with-async-context` and `vui-async-callback`:

```elisp
(defun benedict--send-message (text)
  (vui-with-async-context
    ;; Add user turn optimistically
    (vui-set-state :conversation
      (lambda (conv) (append conv (list (benedict--make-user-turn text)))))

    ;; Start streaming
    (benedict--stream-request text
      :on-chunk (vui-async-callback
                  (lambda (chunk)
                    (vui-set-state :streaming
                      (lambda (s)
                        (list :status 'active
                              :turn-id (plist-get s :turn-id)
                              :content (concat (plist-get s :content) chunk))))))
      :on-complete (vui-async-callback
                     (lambda (final)
                       (vui-batch
                         (vui-set-state :streaming '(:status 'complete))
                         (vui-set-state :conversation
                           (lambda (conv)
                             (append conv (list (benedict--make-assistant-turn final)))))))))))
```

### 4.3 Performance Considerations

- **Debounce rapid updates**: Consider batching chunk updates every 50ms
- **Use `vui-use-ref` for non-render state**: Scroll position, accumulated but unflushed content
- **Memoize expensive computations**: Syntax highlighting, token counting

## 5. Context Management UI

Commands for feeding Emacs context into the chat:

| Command                       | Description              |
|-------------------------------|--------------------------|
| `benedict-chat-ask-region`    | Sends selected text      |
| `benedict-chat-ask-defun`     | Sends current function   |
| `benedict-chat-ask-buffer`    | Sends whole buffer       |
| `benedict-chat-ask-project`   | Sends project structure  |
| `benedict-chat-ask-git-context` | Sends git status/diff  |
| `benedict-chat-ask-file`      | Pick a file and send it  |
| `benedict-chat-ask-buffer-pick` | Pick a buffer and send it |

### 5.1 UX Flow

1. User invokes context command (or uses an in-compose picker)
2. Content gathered and formatted
3. Chat buffer opens (or focuses existing)
4. Content inserted as `ContextSlice` component (collapsible preview)
5. User types query in InputArea and sends

In-compose pickers (MVP):
- In the compose/input area, provide "Add file..." and "Add buffer..." actions that open native completion (like projectile/project.el switching) and add slices without requiring window/buffer switching.

### 5.2 ContextSlice Component

```elisp
(vui-defcomponent context-slice (props state)
  (let ((content (plist-get props :content))
        (source (plist-get props :source))
        (collapsed (plist-get state :collapsed)))
    (collapsible-block
      :header (lambda ()
                (vui-hstack
                  (status-badge :status 'context)
                  (vui-text (format "Context: %s" source))))
      :content (lambda ()
                 (vui-box :class "context-preview"
                   (vui-text (truncate-for-preview content)))))))
```

## 6. History Browsing

### 6.1 Thread Browser

A dedicated vui.el application for browsing conversation history:

```elisp
(vui-defcomponent thread-browser (props state)
  (let* ((threads (plist-get state :threads))
         (filter (plist-get state :filter))
         (filtered (vui-use-memo
                     (lambda () (filter-threads threads filter))
                     (list threads filter))))
    (vui-vstack
      (thread-browser-header
        :filter filter
        :on-filter-change (lambda (f) (vui-set-state :filter f)))
      (vui-table
        :columns '("Date" "Title" "Model" "Status")
        :data filtered
        :on-row-click (lambda (thread)
                        (benedict--open-thread (plist-get thread :id)))))))
```

### 6.2 Features

- **Columns**: Date, Title (generated summary), Model, Status
- **Filtering**: By Project, Profile, or Date range
- **Restoration**: Selecting a thread rehydrates full conversation
- **Forking**: Create branch from any conversation point

MVP note:
- Persistence and thread browsing are important, but v0.1 usefulness should not depend on it if the primary interaction produces artifacts (notes, drafts, file edits).

## 7. Tool Approval UI

Approvals should not be the primary UX. The main safety mechanism is the harness (scope + budgets + sandbox). The approval UI is used when:
- a tool call requests privileged effects, or
- a tool call requests scope expansion (paths, commands, network), or
- the user has configured a stricter policy.

### 7.1 Simple Approval

```elisp
(vui-defcomponent tool-approval-prompt (props state)
  (let ((tool (plist-get props :tool))
        (args (plist-get props :args))
        (scope (plist-get props :scope))        ;; requested scope/effects
        (policy (plist-get props :policy))      ;; why this prompt is shown
        (on-approve (plist-get props :on-approve))
        (on-reject (plist-get props :on-reject)))
    (vui-vstack
      (vui-text (format "Benedict requests: %s" tool))
      (vui-text (format "Reason: %s" policy))
      (when scope
        (vui-box :class "tool-scope"
          (vui-text (pp-to-string scope))))
      (vui-box :class "tool-args"
        (vui-text (pp-to-string args)))
      (vui-hstack :spacing 2
        (vui-button "Approve (y)" :on-click on-approve)
        (vui-button "Reject (n)" :on-click on-reject)))))
```

### 7.2 Diff Preview (Advanced)

For `edit` or `write` operations:

```elisp
(vui-defcomponent diff-preview (props state)
  (let* ((before (plist-get props :before))
         (after (plist-get props :after))
         (diff (vui-use-memo
                 (lambda () (generate-diff before after))
                 (list before after))))
    (vui-vstack
      (vui-text "Proposed Changes:" :face 'bold)
      (diff-view :diff diff)
      (vui-hstack :spacing 2
        (vui-button "Accept (y)" :on-click (plist-get props :on-accept))
        (vui-button "Reject (n)" :on-click (plist-get props :on-reject))
        (vui-button "Edit (e)" :on-click (plist-get props :on-edit))))))
```

### 7.3 Elisp Repair

If a tool invokes some elisp, we should pre-parse the s-exp and if it fails, we should automatically reject the tool call with diagnostic information.

## 8. Notifications

### 8.1 Minibuffer Status

Short updates via `message`:
- "Streaming..."
- "Tool 'search' finished"
- "Error: API rate limit exceeded"

### 8.2 Mode Line

```elisp
(vui-defcomponent mode-line-indicator (props state)
  (let ((status (plist-get props :status)))
    (vui-hstack
      (vui-text "Benedict")
      (when (eq status 'streaming)
        (spinner-component)))))
```

## 9. Pitfall Avoidance (Critical)

These rules prevent the most common vui.el bugs:

### 9.1 State Rules

- **Never mutate state directly**; always replace with a new value via `vui-set-state`
- **Use functional updates in async callbacks** to avoid stale closures:
  ```elisp
  ;; WRONG - captures stale value
  (lambda (chunk) (vui-set-state :content (concat content chunk)))
  ;; RIGHT - receives current value
  (lambda (chunk) (vui-set-state :content (lambda (c) (concat c chunk))))
  ```
- **Batch multiple state changes** to prevent intermediate re-renders

### 9.2 Hook Rules

- **Never call hooks conditionally or inside loops**; hook call order must remain stable across renders
- **Effects that allocate resources must return cleanup** (timers, subscriptions, processes)
- **All async callbacks must use `vui-with-async-context`** or `vui-async-callback`

### 9.3 List Rules

- **Always provide stable keys** for list items (IDs, not indices)
- Keys must be unique within the list and stable across re-renders

### 9.4 Performance Rules

- **Avoid blocking work inside `vui-use-async` loaders**; loaders must use true async primitives
- **Don't put frequently-changing data in context**; it causes cascading re-renders
- **Stabilize callback references** with `vui-use-callback` when passing to children with `:should-update`

---

## 10. Debugging & Development

### 10.1 vui.el Debug Tools

- `vui-inspect`: Display component tree with state and props
- `vui-debug-enabled`: Log render cycle events with timing
- `vui-timing-enabled`: Measure performance across phases

### 10.2 Benedict-Specific Debug

- `benedict-debug-state`: Dump current root state
- `benedict-inspect-turn`: Show full turn data at point

---

## 11. Component Design Guidelines

### 11.1 Container vs Presentational

- **Containers**: Manage state, subscriptions, business logic
- **Presentational**: Pure rendering from props, easily reusable/testable

### 11.2 Extraction Triggers

Extract a new component when:
- Render function exceeds 20-30 lines
- Same UI pattern appears in multiple places
- Logic would benefit from isolation/testing

 ### 11.3 Prop Drilling Threshold

If passing the same prop through 3+ intermediate components that don't use it, use Context instead.

### 11.4 Keybinding Patterns

Components must follow separation of concerns for keybindings:

- **Don't set keymaps in render**: Avoid `use-local-map` in `vui-use-effect` - it clobbers maps and recreates on every render
- **Define named keymap variables**: Allow users to customize by setting variables before loading
- **Define interactive commands**: Commands that read from component state (via `vui-field-value` or callbacks)
- **Parent initializes keymaps**: Buffer setup (mode init or `:on-mount`) composes keymaps once
- **Component renders only**: Pure function that takes props and returns vnodes

Example pattern:
```elisp
;; Component file - pure rendering
(vui-defcomponent my-component (props state)
  :render
  (vui-field :key 'my-input ...))

;; Commands file - interactive functions
(defvar my-component-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'my-component-submit)
    map))

(defun my-component-submit ()
  "Submit component."
  (interactive)
  (let ((value (vui-field-value 'my-input)))
    (when my-component--on-submit
      (funcall my-component--on-submit value))))

;; Parent buffer - initialization
(define-derived-mode my-mode vui-mode "My Mode"
  (use-local-map my-component-mode-map))
```
