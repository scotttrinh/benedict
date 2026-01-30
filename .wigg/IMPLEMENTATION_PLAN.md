# Implementation Plan

## Priority Tasks

### vui.el Migration - Leaf Components

- [x] **TextBlock vui component** (refs: 03_ui_ux.md section 3.2)
  - Scope: Render plain text content with markdown fontification support
  - Files: Create `components/benedict-vui-text-block.el`, `test/benedict-vui-text-block-test.el`
  - Tests:
    - Renders text content correctly
    - Applies markdown font-lock to body regions
    - Handles empty content gracefully
  - Dependencies: vui.el must be available as dependency
  - Notes: Use `vui-defcomponent`, accept `:content` prop. No local state needed.

- [x] **CodeBlock vui component** (refs: 03_ui_ux.md section 3.2)
  - Scope: Render syntax-highlighted code with language detection, copy button
  - Files: Create `components/benedict-vui-code-block.el`, `test/benedict-vui-code-block-test.el`
  - Tests:
    - Renders code with correct face
    - Syntax highlighting via `vui-use-memo` for language fontification
    - Copy action sets `:copied-feedback` local state, clears after timeout
    - Handles unknown languages gracefully
  - Dependencies: TextBlock (for fallback)
  - Notes: Use `vui-use-memo` for expensive fontification. Local state: `:copied-feedback`.

- [x] **StatusBadge vui component** (refs: 03_ui_ux.md section 3.2)
  - Scope: Render role/status badges (USER, ASSISTANT, streaming, error, etc.)
  - Files: Create `components/benedict-vui-badge.el`, `test/benedict-vui-badge-test.el`
  - Tests:
    - Renders correct label for each status type
    - Applies correct face based on status
    - Handles unknown status gracefully
  - Dependencies: None
  - Notes: Pure presentational component. Props: `:status`, `:theme`.

- [x] **CollapsibleBlock vui component** (refs: 03_ui_ux.md section 3.3)
  - Scope: Generic collapsible container with header and toggle
  - Files: Create `components/benedict-vui-collapsible.el`, `test/benedict-vui-collapsible-test.el`
  - Tests:
    - Renders header always, content only when expanded
    - Toggle callback fires on click/keypress
    - Fold indicator shows ▶ (collapsed) or ▼ (expanded)
    - Supports controlled mode (`:collapsed` prop) and uncontrolled (local state)
  - Dependencies: None
  - Notes: Props: `:header` (function), `:content` (function), `:collapsed`, `:on-toggle`.

- [x] **ThinkingBlock vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Render reasoning/thinking content in collapsible block
  - Files: Create `components/benedict-vui-thinking-block.el`, `test/benedict-vui-thinking-block-test.el`
  - Tests:
    - Wraps content in CollapsibleBlock
    - Shows "Thinking" badge in header
    - Defaults to collapsed state
    - Handles streaming thinking deltas
  - Dependencies: CollapsibleBlock, StatusBadge
  - Notes: Compose CollapsibleBlock with thinking-specific header. Props: `:thinking-data`, `:collapsed`.

- [x] **ToolUseBlock vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Render tool invocation with name, args, and status
  - Files: Create `components/benedict-vui-tool-use-block.el`, `test/benedict-vui-tool-use-block-test.el`
  - Tests:
    - Shows tool name and status in header
    - Displays formatted arguments when expanded
    - Handles in-progress, success, and failure states
    - Shows spinner during in-progress
  - Dependencies: CollapsibleBlock, StatusBadge
  - Notes: Props: `:tool-call`, `:status`. Use CollapsibleBlock wrapper.

- [x] **ToolResultBlock vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Render tool execution result with optional actions
  - Files: Create `components/benedict-vui-tool-result-block.el`, `test/benedict-vui-tool-result-block-test.el`
  - Tests:
    - Displays result content (truncated if long)
    - Shows error state with error styling
    - Renders action buttons from `:actions` prop
    - Handles UI hints from tool output
  - Dependencies: CollapsibleBlock, StatusBadge
  - Notes: Props: `:result`, `:status`, `:actions`. Truncate content > 500 chars with expand option.

### vui.el Migration - Container Components

- [x] **TurnHeader vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Render turn header with role badge and timestamp
  - Files: Create `components/benedict-vui-turn-header.el`, `test/benedict-vui-turn-header-test.el`
  - Tests:
    - Shows correct role badge (user/assistant/system)
    - Formats timestamp correctly
    - Handles missing timestamp gracefully
  - Dependencies: StatusBadge
  - Notes: Props: `:role`, `:timestamp`, `:metadata`.

- [x] **ContentBlockList vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Render list of content blocks (text, thinking, tool) for a message
  - Files: Create `components/benedict-vui-content-block-list.el`, `test/benedict-vui-content-block-list-test.el`
  - Tests:
    - Dispatches to correct block type based on content type
    - Maintains stable keys for list reconciliation
    - Handles mixed content types in sequence
  - Dependencies: TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock, CodeBlock
  - Notes: Use `vui-list` with `:key` for stable identity. Props: `:blocks`.

- [x] **Turn vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Render complete turn (header + content blocks)
  - Files: Create `components/benedict-vui-turn.el`, `test/benedict-vui-turn-test.el`
  - Tests:
    - Composes TurnHeader and ContentBlockList
    - Passes correct props to children
    - Handles user vs assistant turn styling
  - Dependencies: TurnHeader, ContentBlockList
  - Notes: Props: `:message` (full message plist), `:collapsed-blocks` (set).

- [x] **TurnList vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Render conversation as list of turns with stable keys
  - Files: Create `components/benedict-vui-turn-list.el`, `test/benedict-vui-turn-list-test.el`
  - Tests:
    - Uses `vui-list` with message ID as key
    - Correctly groups user/assistant pairs
    - Handles streaming turn at end
    - Scrolls to bottom on new content
  - Dependencies: Turn
  - Notes: Props: `:conversation` (list of messages), `:collapsed-blocks`.

 - [x] **StreamingIndicator vui component** (refs: 03_ui_ux.md section 1.2)
   - Scope: Visual indicator during active streaming
   - Files: Create `components/benedict-vui-streaming-indicator.el`, `test/benedict-vui-streaming-indicator-test.el`
   - Tests:
     - Visible only when `:visible` prop is true
     - Shows animated spinner
     - Cleans up timer on unmount
   - Dependencies: None
   - Notes: Use `vui-use-effect` for timer-based animation. Props: `:visible`.

### vui.el Migration - Input Components

 - [x] **ContextIndicator vui component** (refs: 03_ui_ux.md section 5.2)
   - Scope: Show attached context slices in compose area
   - Files: Create `components/benedict-vui-context-indicator.el`, `test/benedict-vui-context-indicator-test.el`
   - Tests:
     - Displays count and size of attached slices
     - Shows slice labels on hover/expand
     - Remove button clears individual slices
   - Dependencies: StatusBadge
   - Notes: Props: `:slices`, `:on-remove`.

  - [x] **ComposeField vui component** (refs: 03_ui_ux.md section 1.2)
    - Scope: Controlled text input for composing messages
    - Files: Create `components/benedict-vui-compose-field.el`, `test/benedict-vui-compose-field-test.el`
    - Tests:
      - Controlled input via `:value` and `:on-change`
      - Submit on configured key (via parent keymap)
      - History navigation with M-p/M-n (via parent keymap)
      - Multiline support
    - Dependencies: None
    - Notes:
      - Local state: `:history-index` for tracking history position
      - Props: `:value`, `:on-change`, `:on-submit`, `:placeholder`, `:key` (for vui-field-value)
      - Pattern: Define `benedict-vui-compose-field-mode-map` variable with keybindings to interactive commands
      - Component renders only - uses dynamic variables for callbacks/state
      - Parent buffer (e.g., BenedictRoot or InputArea) sets up keymaps during initialization
      - All 9 tests pass

 - [ ] **InputArea vui component** (refs: 03_ui_ux.md section 1.2)
   - Scope: Compose area with context indicators and input field
   - Files: Create `components/benedict-vui-input-area.el`, `test/benedict-vui-input-area-test.el`
   - Tests:
     - Composes ContextIndicator and ComposeField
     - Passes callbacks correctly
     - Handles empty state
   - Dependencies: ContextIndicator, ComposeField
   - Notes:
     - Props: `:slices`, `:input-text`, `:on-input-change`, `:on-submit`, `:on-slice-remove`
     - Sets up keymaps using `benedict-vui-compose-field-mode-map` during buffer initialization
     - Keybindings composed with parent mode map (not set by child components)

### vui.el Migration - Header & Status

- [ ] **ProviderBadge vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Clickable provider/model selector in header
  - Files: Create `components/benedict-vui-provider-badge.el`, `test/benedict-vui-provider-badge-test.el`
  - Tests:
    - Displays current provider and model
    - Click triggers model selection callback
    - Tooltip shows full model ID
  - Dependencies: StatusBadge
  - Notes: Props: `:provider`, `:model`, `:on-click`.

- [ ] **ChatHeader vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Header bar with provider, status, and session title
  - Files: Create `components/benedict-vui-chat-header.el`, `test/benedict-vui-chat-header-test.el`
  - Tests:
    - Shows ProviderBadge, StatusIndicator, SessionTitle
    - Updates on provider/model change
    - Click handling works
  - Dependencies: ProviderBadge, StatusBadge
  - Notes: Props: `:provider`, `:model`, `:status`, `:title`, `:on-provider-click`.

- [ ] **StatusBar vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Footer with token count, cost estimate, errors
  - Files: Create `components/benedict-vui-status-bar.el`, `test/benedict-vui-status-bar-test.el`
  - Tests:
    - Displays token count formatted
    - Shows cost estimate when available
    - Displays error messages with error face
    - Handles missing usage data
  - Dependencies: None
  - Notes: Props: `:usage`, `:error`.

### vui.el Migration - Root & Integration

- [ ] **ConversationView vui component** (refs: 03_ui_ux.md section 1.2)
  - Scope: Main conversation area containing TurnList and StreamingIndicator
  - Files: Create `components/benedict-vui-conversation-view.el`, `test/benedict-vui-conversation-view-test.el`
  - Tests:
    - Renders TurnList with conversation
    - Shows StreamingIndicator during streaming
    - Scroll behavior on new content
  - Dependencies: TurnList, StreamingIndicator
  - Notes: Props: `:conversation`, `:streaming`, `:collapsed-blocks`.

- [ ] **BenedictRoot vui component** (refs: 03_ui_ux.md section 1.2, 2.1)
  - Scope: Root component owning all shared application state
  - Files: Create `components/benedict-vui-root.el`, `test/benedict-vui-root-test.el`
  - Tests:
    - State structure matches spec (:conversation, :streaming, :provider, :model, :collapsed-blocks, :error)
    - State updates propagate to children
    - Event handlers wire correctly to session
  - Dependencies: ChatHeader, ConversationView, InputArea, StatusBar
  - Notes: This is the integration point. Wire to `benedict-session` events.

- [ ] **Wire BenedictRoot to benedict-session events** (refs: 03_ui_ux.md, 02_architecture.md)
  - Scope: Connect vui state updates to session event system
  - Files: Modify `benedict-vui-root.el`, `benedict-chat.el`
  - Tests:
    - Session message-added updates :conversation state
    - Session draft-updated updates :streaming state
    - Session state-changed updates component state
    - Batched updates via `vui-batch`
  - Dependencies: BenedictRoot, existing session event system
  - Notes: Use `vui-use-effect` for session subscription. Return cleanup function.

- [ ] **Use vui.el rendering in chat buffer** (refs: 03_ui_ux.md)
  - Scope: Switch chat buffer to use BenedictRoot instead of magit-section
  - Files: Modify `benedict-chat.el`, remove `benedict-chat-render.el`, `benedict-chat-sections.el`
  - Tests:
    - All existing chat integration tests pass
    - Streaming works correctly
    - Navigation commands work
    - Context capture works
  - Dependencies: All vui components, BenedictRoot wired to session
  - Notes: Keep magit-section requires temporarily for gradual migration. Remove after verification.
