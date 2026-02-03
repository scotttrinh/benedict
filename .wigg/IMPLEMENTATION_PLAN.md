# Implementation Plan

## Priority Tasks

### Test Infrastructure

- [x] **Add shared VUI test helpers for real-buffer interaction** (refs: 07_harness_and_skills.md)
  - Scope: Create a small, reusable helper module for clicking buttons and driving fields via widgets; keep helpers user-level (widget actions), not internal component fns.
  - Files: `test/benedict-vui-test-utils.el`
  - Tests: N/A (helpers are exercised by downstream tests)
  - Dependencies: None
  - Notes: Include helpers like `benedict-vui-test--click-button-at`, `benedict-vui-test--click-button-labeled`, `benedict-vui-test--set-first-field`; require `widget` inside the helper module.

### Leaf Component Behavior Tests (Render + Interaction)

- [ ] **ToolResultBlock: mount + truncation/actions interaction tests** (refs: 03_ui_ux.md, 06_tools.md)
  - Scope: Convert/extend tests to mount `benedict-vui-tool-result-block` into a real buffer and assert header/body rendering, error styling, truncation toggles, and action buttons.
  - Files: `test/benedict-vui-tool-result-block-test.el`
  - Tests: Add ERTs that (1) prefer `:ui :header`/`:ui :body`, (2) render fallback `:content`, (3) show `... [truncated]` + “Show more/less” toggle, (4) render actions and invoke handlers via widget click, (5) apply `benedict-message-key`/`benedict-block-id` text properties.
  - Dependencies: `test/benedict-vui-test-utils.el`
  - Notes: Use a harness component for controlled collapse if needed; call `vui-flush-sync` after clicks.

- [ ] **ThinkingBlock: mount + collapse toggle tests with props assertions** (refs: 03_ui_ux.md)
  - Scope: Add behavior tests for collapsed-by-default, toggle expansion, and rendered thinking content properties.
  - Files: `test/benedict-vui-thinking-block-test.el`
  - Tests: Mount with `:collapsed t`, assert content absent; click toggle, `vui-flush-sync`, assert thinking text appears with `benedict-region-kind` = `thinking`, `face` = `benedict-chat-thinking`, and `benedict-message-key`/`benedict-block-id`.
  - Dependencies: `test/benedict-vui-test-utils.el`
  - Notes: Cover at least one “streaming chunks / encrypted placeholder” case via rendered output (not only helper fns).

- [ ] **Collapsible: mount + indicator toggle behavior test** (refs: 03_ui_ux.md)
  - Scope: Ensure `benedict-vui-collapsible` is tested from the user perspective (indicator + content visibility) instead of only helper fns.
  - Files: `test/benedict-vui-collapsible-test.el`
  - Tests: Harness renders header/content strings; assert “▶” and hidden content initially; click toggle, `vui-flush-sync`, assert “▼” and content visible.
  - Dependencies: `test/benedict-vui-test-utils.el`
  - Notes: Keep existing helper-level tests only if they still add value.

- [ ] **CodeBlock: mount + Copy/Copied! behavior without real timers** (refs: 03_ui_ux.md)
  - Scope: Add behavior tests that validate what the user sees (label, code, copy feedback) without leaking timers.
  - Files: `test/benedict-vui-code-block-test.el`
  - Tests: Mount renders language label + “Copy”; click “Copy”, `vui-flush-sync`, assert “Copied!” appears; optionally assert region props (`benedict-message-key`, `benedict-block-id`) when code is rendered as text.
  - Dependencies: `test/benedict-vui-test-utils.el`
  - Notes: Stub `run-at-time`/`cancel-timer` with `cl-letf` to prevent background timers while still asserting immediate UI.

- [ ] **ComposeField: mount + field change/submit integration tests** (refs: 03_ui_ux.md)
  - Scope: Add widget-driven tests for typing and submit behavior (user-level), not just helper unit tests.
  - Files: `test/benedict-vui-compose-field-test.el`
  - Tests: Harness owns `value` state; simulate typing via widget (`widget-field-list`, `widget-value-set`, `widget-apply :notify`), `vui-flush-sync`, assert rendered value/callback; test submit via field submit path or `benedict-vui-compose-field-submit` after mount and assert callback.
  - Dependencies: `test/benedict-vui-test-utils.el`
  - Notes: Ensure buffer-local variables set by the component are cleaned up by unmount/teardown.

- [ ] **ContextIndicator: mount + slice label + remove button interaction tests** (refs: 03_ui_ux.md)
  - Scope: Add real-buffer tests for summary rendering and slice removal click behavior.
  - Files: `test/benedict-vui-context-indicator-test.el`
  - Tests: Mount with nil slices => “No context”; mount with slices => summary + labels; click “×” calls `:on-remove` with slice id; `vui-flush-sync` after click.
  - Dependencies: `test/benedict-vui-test-utils.el`
  - Notes: Keep existing pure formatting tests for `--summary`/`--slice-label` if still valuable.

- [ ] **StatusBar: mount + token/cost/error render tests** (refs: 03_ui_ux.md)
  - Scope: Add UI-level assertions for what renders given usage/error inputs.
  - Files: `test/benedict-vui-status-bar-test.el`
  - Tests: Mount with usage => “N tokens”; with cost => `$…`; with error => error text + separators; optionally assert face props on rendered segments.
  - Dependencies: None

- [ ] **StreamingIndicator: mount visible state with stubbed timers** (refs: 03_ui_ux.md)
  - Scope: Add a render smoke test for `:visible t` without leaving running timers.
  - Files: `test/benedict-vui-streaming-indicator-test.el`
  - Tests: Mount `:visible t` asserts spinner frame text exists; stub `run-with-timer`/`cancel-timer` to no-op; mount `:visible nil` asserts no spinner text.
  - Dependencies: None
  - Notes: Keep deterministic frame unit tests.

### Container / Composition Tests

- [ ] **ContentBlockList: mount mixed blocks + toggle callback wiring** (refs: 03_ui_ux.md, 06_tools.md)
  - Scope: Verify that a list of mixed blocks renders expected user-visible output and that toggling collapsibles calls `:on-toggle-block` with `(block-id next)`.
  - Files: `test/benedict-vui-content-block-list-test.el`
  - Tests: Mount blocks including text/code/thinking/tool-use/tool-result; assert key labels/snippets in buffer; click a collapsible toggle and assert callback args; `vui-flush-sync` after click.
  - Dependencies: `test/benedict-vui-test-utils.el`; leaf block behavior tests (ToolResultBlock/ThinkingBlock/Collapsible) should land first.
  - Notes: Keep existing stable-key unit tests (stubbing `vui-list`) if they still catch regressions.

- [ ] **Turn: mount renders header + blocks and preserves role styling** (refs: 03_ui_ux.md)
  - Scope: Add real render tests proving `benedict-vui-turn` composes header + content blocks and applies role faces to user-visible text.
  - Files: `test/benedict-vui-turn-test.el`
  - Tests: Mount a user message and assert “USER” badge and content present; mount assistant and assert “ASSISTANT”; for `:role 'tool` assert tool-result block label/content appears.
  - Dependencies: Leaf component tests (Badge/TextBlock/ToolResultBlock) should land first.

- [ ] **TurnList + ConversationView: mount conversation rendering + streaming indicator behavior** (refs: 03_ui_ux.md, 04_agent_loop.md)
  - Scope: Add mount-based tests for composing turns and showing streaming indicator when streaming is active.
  - Files: `test/benedict-vui-turn-list-test.el`, `test/benedict-vui-conversation-view-test.el`
  - Tests: TurnList renders multiple turns; ConversationView renders TurnList and shows spinner when `:streaming '(:status active ...)`.
  - Dependencies: `test/benedict-vui-streaming-indicator-test.el`; `test/benedict-vui-turn-test.el`
  - Notes: Keep the existing scroll effect unit test (stub `vui--register-effect`) as a non-UI behavioral check.

### Top-Level UI Smoke Tests

- [ ] **ChatHeader + InputArea: replace “can be loaded” tests with real render assertions** (refs: 03_ui_ux.md)
  - Scope: Ensure these tests validate actual rendered buffer output rather than `featurep`/`should t`.
  - Files: `test/benedict-vui-chat-header-test.el`, `test/benedict-vui-input-area-test.el`
  - Tests: ChatHeader shows provider/model and title; InputArea shows “No context” and includes a field widget.
  - Dependencies: `test/benedict-vui-test-utils.el` (optional)

- [ ] **Root: mount smoke test for baseline UI composition** (refs: 02_architecture.md, 03_ui_ux.md)
  - Scope: Validate `benedict-vui-root` renders the main layout (header, conversation view, input area, status bar) for an empty or minimal session.
  - Files: `test/benedict-vui-root-test.el`
  - Tests: Mount with `session nil` and assert key visible strings (e.g. title “Chat”, “No context”, placeholder “Ask Benedict...”).
  - Dependencies: ChatHeader/InputArea updates.

## Completed

- [x] **ToolUseBlock: real-buffer render + toggle behavior tests** (refs: 03_ui_ux.md, 06_tools.md)
  - Files: `test/benedict-vui-tool-use-block-test.el`
