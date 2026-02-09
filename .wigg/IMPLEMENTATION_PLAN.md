# Implementation Plan

## Goal

Replace broad mount-smoke confidence with behavior-driven coverage that proves the VUI chat UI works end-to-end from `benedict-vui-root` through `benedict-session` using `benedict-provider-fake`, while also deepening per-component behavior tests.

## Testing Principles

- Test through mounted buffers and user-like interaction (`vui-mount`, widget/button interaction, keyboard simulation when relevant).
- Assert user-visible output and text properties used for navigation/styling.
- Prefer public behavior and session events; avoid targeting private `--` helpers unless unavoidable.
- Keep async deterministic (fake provider scripts, explicit `vui-flush-sync`, timer stubs where needed).
- Validate both steady-state rendering and state transitions (start/update/finalize/error/cancel).

## Known Reality Check (Important)

- The current VUI chat buffer implementation is known to be broken in real interactive use, even when many tests pass.
- Future tasks must treat this as a bug-hunting effort, not a test-green effort: do not encode current broken behavior into new assertions just to make tests pass.
- Prefer assertions that reflect expected user behavior from the specs and real mounted-buffer interaction, and investigate failing E2E tests as likely product defects first.

## Current Coverage Snapshot (Reset Baseline)

- Strong today: `tool-use-block`, `tool-result-block`, `compose-field`, `context-indicator`.
- Medium today: `turn`, `turn-list`, `conversation-view`, `status-bar`, `chat-header`, `input-area`, `streaming-indicator`, `thinking-block`, `code-block`, `text-block`, `provider-badge`, `badge`, `turn-header`, `collapsible`.
- Weak today (highest risk): `root`, `content-block-list`, and full root-to-provider streaming/error/tool-call paths.

## Priority Tasks

### Phase -1 - Highest Priority: Reproduce and Fix Non-Reactive Chat Buffer

- [x] Add a dedicated integration regression test (new file or extension of existing chat integration tests) that mounts the real `benedict-chat` buffer path and reproduces this failure mode explicitly: provider/session events are emitted (visible in `*Messages*`) but chat UI does not update.
- [ ] Ensure the test drives the same production path users hit (chat command + mounted buffer + submit flow), not direct root-only mounting.
- [ ] Add assertions that fail on the current bug and prove end-user-visible reactivity across request lifecycle (`draft-started`, `draft-updated`, `message-added`, `request-completed`, `state-changed`).
- [ ] Implement production code changes required to make the new regression test pass (subscription/mount/event wiring), then keep the regression test as a permanent guardrail.
- [ ] Treat this regression as the next task before all remaining unchecked work in later phases.

### Phase 0 - Harness and Test Utilities

- [x] Expand `test/benedict-vui-test-utils.el` with helpers for:
  - mounting root with session + fake provider defaults,
  - driving submit/input consistently,
  - waiting/flush patterns for fake streaming steps,
  - asserting common text properties (`benedict-message-key`, `benedict-block-id`, `benedict-region-kind`).
- [x] Add helper coverage tests only where behavior cannot be naturally exercised downstream.

### Phase 1 - Root Session Event Contract Tests

- [x] Extend `test/benedict-vui-root-test.el` to cover every event handled by `benedict-vui-root--handle-session-event`:
  - `message-added` appends conversation,
  - `draft-started` creates active streaming payload,
  - `draft-updated` appends deltas,
  - `draft-updated` appends tool-call entries,
  - `draft-finalized` clears streaming,
  - `request-completed` success updates provider/model/usage and clears error,
  - `request-completed` failure renders error,
  - `state-changed` error/idle transitions clear or set error messaging correctly.
- [x] Add tests for root local behavior:
  - submit clears input and appends history,
  - retain-context true/false behavior for slices,
  - collapsed block toggling for list and hash-table representations.

### Phase 2 - End-to-End Root -> Fake Provider Matrix

- [x] Add `test/benedict-vui-root-e2e-test.el` for full mounted-root flows driven by `benedict-provider-fake` scripts.
- [x] Cover these scenarios with explicit assertions on visible UI output and session state:
  - simple success (user + assistant message lifecycle),
  - streaming text chunks (incremental draft then final message),
  - streaming + tool-calls (tool-use + tool-result blocks appear with statuses),
  - streaming + thinking payload (thinking block visibility/toggle behavior),
  - provider/model changes returned in result update header badge,
  - usage data appears in status bar,
  - provider error path displays error and stops streaming indicator,
  - cancellation mid-stream clears draft/indicator without corrupting transcript,
  - empty assistant response path (no crash, correct fallback text if applicable).
- [ ] Add one multi-turn scripted run asserting conversation continuity and stable navigation properties across turns.

### Phase 3 - Composition Layer Hardening

- [ ] `test/benedict-vui-content-block-list-test.el`:
  - mixed block types in one message,
  - unknown block fallback behavior,
  - empty block list behavior,
  - `:on-toggle-block` callback arguments and propagation,
  - block/message property propagation.
- [ ] `test/benedict-vui-turn-test.el`:
  - role-specific rendering and faces,
  - assistant/tool message composition,
  - metadata/error styling,
  - timestamp/header behavior with and without metadata.
- [ ] `test/benedict-vui-turn-list-test.el`:
  - grouping/ordering correctness,
  - streaming synthetic message handling,
  - navigation properties across multiple turns,
  - empty conversation behavior.
- [ ] `test/benedict-vui-conversation-view-test.el`:
  - streaming indicator visibility transitions,
  - malformed/nil streaming payload safety,
  - integration with turn-list output for multi-turn conversations.

### Phase 4 - Leaf Component Behavior Expansion

- [ ] `test/benedict-vui-chat-header-test.el`: click handler wiring, nil provider/model/title variants, status badge transitions.
- [ ] `test/benedict-vui-input-area-test.el`: slice remove wiring, placeholder/size propagation, history prop behavior.
- [ ] `test/benedict-vui-status-bar-test.el`: separator logic across token/cost/error combinations and nil/partial usage payloads.
- [ ] `test/benedict-vui-streaming-indicator-test.el`: visible false->true->false transitions, timer cleanup on unmount.
- [ ] `test/benedict-vui-thinking-block-test.el`: empty payload handling, controlled/uncontrolled collapse behavior, multi-detail/chunk rendering.
- [ ] `test/benedict-vui-code-block-test.el`: copy result assertions (including kill-ring effect), unknown language fallback, large content display safety.
- [ ] `test/benedict-vui-text-block-test.el`: whitespace/empty/long content behavior and property coverage.
- [ ] `test/benedict-vui-provider-badge-test.el`: click handler wiring and model formatting edge cases.
- [ ] `test/benedict-vui-turn-header-test.el` and `test/benedict-vui-badge-test.el`: metadata/status fallback and face mapping edge cases.
- [ ] `test/benedict-vui-collapsible-test.el`: nil callback safety and function-valued header/content behavior.

### Phase 5 - Chat/Session Integration Guardrails for VUI

- [ ] Extend `test/benedict-chat-session-test.el` and/or `test/benedict-chat-integration-test.el` with UI-facing assertions that mounted chat buffers reflect live session changes during:
  - attach during active stream,
  - headless continuation then reattach,
  - tool-call execution and result insertion,
  - request failure and recovery on next submit.
- [ ] Add regression test for post-request metadata mutation path so UI updates remain observable after assistant message finalization.

## Test Execution Gates

- Fast loop while implementing:
  - `nix run .#test -- test/benedict-vui-root-test.el`
  - `nix run .#test -- test/benedict-vui-root-e2e-test.el`
  - targeted file under change.
- Phase completion gates:
  - `nix run .#test -- test/benedict-vui-*-test.el`
  - `nix run .#test -- test/benedict-chat-session-test.el test/benedict-chat-integration-test.el test/benedict-chat-logic-test.el`
- Final confidence gate:
  - `nix run .#test`

## Definition of Done

- [ ] Root event contract fully exercised with explicit assertions for every handled event.
- [ ] Dedicated root->fake-provider E2E file exists and passes for success/streaming/tools/errors/cancel/update scenarios.
- [ ] Each `components/benedict-vui-*.el` file has behavior tests beyond mount-only smoke coverage.
- [ ] Navigation/styling text properties used by chat navigation are asserted in representative integration paths.
- [ ] Targeted VUI and chat/session test suites pass locally.
