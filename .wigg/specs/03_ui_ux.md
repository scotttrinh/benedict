# UI/UX Specification

This document defines the user interface and user experience for Benedict, built using the **vui.el** declarative component framework.

## 1. Architecture Overview

Benedict's UI is built using **vui.el**, a React-inspired declarative UI library for Emacs. Instead of imperatively manipulating buffer contents, we declare *what* the UI should look like for any given state, and the framework handles reconciliation and updates.

### 1.1 Core Principles

- **Declarative Rendering**: Components describe UI as a function of state, not how to update it
- **Unidirectional Data Flow**: Props flow down, callbacks flow up
- **Component Composition**: Small, focused components compose into complex UIs
- **Automatic Reconciliation**: vui.el diffs virtual trees and applies minimal DOM updates

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

### 2.4 Context for Cross-Cutting Concerns

```elisp
;; Theme context (consumed anywhere without prop drilling)
(vui-defcontext benedict-theme-context
  :default '(:dark-mode nil :accent-color "blue"))

;; Provider context (API configuration)
(vui-defcontext benedict-provider-context
  :default '(:provider :anthropic :api-key nil :endpoint nil))
```

## 3. Chat Buffer Design

The Chat Buffer is the primary interface, rendered as a vui.el component tree.

### 3.1 Layout

- **Header**: Provider/Model badge, status indicator, session title
- **Conversation Stream**: `vui-list` of turns with stable keys
- **Compose Area**: Controlled `vui-text-field` at buffer bottom

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
Keybindings are registered in `benedict-mode-map` and dispatch actions to the root component:

| Key       | Action                        |
|-----------|-------------------------------|
| `C-c C-s` | Send prompt / Stream response |
| `C-c C-k` | Cancel streaming/loop         |
| `g r`     | Retry last request            |
| `w`       | Copy last response            |
| `n` / `p` | Next/Prev turn                |
| `TAB`     | Toggle block collapse         |

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

### 5.1 UX Flow

1. User invokes context command
2. Content gathered and formatted
3. Chat buffer opens (or focuses existing)
4. Content inserted as `ContextSlice` component (collapsible preview)
5. User types query in InputArea and sends

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

## 7. Tool Approval UI

When an agent requests tool execution with `confirm` policy:

### 7.1 Simple Approval

```elisp
(vui-defcomponent tool-approval-prompt (props state)
  (let ((tool (plist-get props :tool))
        (args (plist-get props :args))
        (on-approve (plist-get props :on-approve))
        (on-reject (plist-get props :on-reject)))
    (vui-vstack
      (vui-text (format "Benedict wants to run tool: %s" tool))
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

## 9. Debugging & Development

### 9.1 vui.el Debug Tools

- `vui-inspect`: Display component tree with state and props
- `vui-debug-enabled`: Log render cycle events with timing
- `vui-timing-enabled`: Measure performance across phases

### 9.2 Benedict-Specific Debug

- `benedict-debug-state`: Dump current root state
- `benedict-inspect-turn`: Show full turn data at point

## 10. Component Design Guidelines

### 10.1 Container vs Presentational

- **Containers**: Manage state, data fetching, business logic
- **Presentational**: Pure rendering, receive all data via props

### 10.2 Extraction Triggers

Extract a new component when:
- Render function exceeds 20-30 lines
- Same UI pattern appears in multiple places
- Logic would benefit from isolation/testing

### 10.3 Prop Drilling Threshold

If passing the same prop through 3+ intermediate components that don't use it, consider using Context instead.
