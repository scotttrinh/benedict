# Unbreak Tests Implementation Plan

## Overview
Fix test failures caused by the switch to magit-section UI and session-backed history by aligning code paths and tests with the new behavior. The focus is to make noninteractive test runs stable, ensure tool results are included in session-backed request history, and make magit-section navigation/folding consistent with item markers.

**Updated Analysis**: Running the full test suite reveals 6 failing tests, 4 of which (`benedict-chat-integration-agent-run-preserves-ordering`, `benedict-chat-integration-inserts-blank-line-between-blocks`, `benedict-chat-integration-streaming-preserves-body-across-header-refresh`, `benedict-chat-section-end-marker-advances`) pass when run individually but fail in the full suite. This indicates both **real bugs** (item ordering, marker advancement, gap insertion, header refresh) and **test isolation issues** (global state pollution between tests).

## Current State Analysis
- Compose flow calls `benedict-chat` from `benedict-chat-ask-region` and prompts for session selection via `completing-read` when multiple sessions exist, which fails in batch tests (`benedict-chat.el:3466`, `benedict-chat.el:3519`, `benedict-chat.el:3926`, `test/benedict-chat-logic-test.el:54`).
- Request building uses session messages when a session exists, but tool results are stored only in buffer history, so tool entries are missing from session-backed requests (`benedict-chat.el:2651`, `benedict-chat.el:2110`, `test/benedict-chat-logic-test.el:206`).
- Item sections are registered using `magit-current-section`, which can point to the parent section rather than the newly inserted item, leading `magit-section-goto` to jump to the wrong place (`benedict-chat.el:316`, `benedict-chat.el:3559`, `test/benedict-chat-thinking-test.el:107`, `test/benedict-chat-thinking-test.el:148`).
- Tool folding relies on magit-section visibility toggles and can hit stale/invalid sections in tests (`benedict-chat-render.el:537`, `benedict-chat.el:223`, `test/benedict-chat-render-test.el:97`).
- Session registry is global and persists across tests unless explicitly rebound, contributing to multiple-session prompts (`benedict-session.el:24`, `test/benedict-chat-session-test.el:23`).

### Additional Failures Discovered (Tests pass individually but fail in full suite)
- **Test isolation failure**: Several tests pass when run individually but fail when run with the full test suite, indicating global state pollution between tests. This includes `benedict-chat-integration-agent-run-preserves-ordering`, `benedict-chat-integration-inserts-blank-line-between-blocks`, `benedict-chat-integration-streaming-preserves-body-across-header-refresh`, and `benedict-chat-section-end-marker-advances`.
- **Section end marker not advancing** (`benedict-chat-section-end-marker-advances`): The root section's end marker stays at position 188 after inserting content, indicating markers are not being updated correctly when child sections are added (`test/benedict-chat-integration-test.el:403`).
- **Item ordering bug** (`benedict-chat-integration-agent-run-preserves-ordering`): Assistant content appears at position 257 while user content appears at position 391, meaning items are rendering out of order (assistant before user). This is a **real rendering bug** (`test/benedict-chat-integration-test.el:349`).
- **Missing blank line** (`benedict-chat-integration-inserts-blank-line-between-blocks`): Only one newline appears between blocks instead of two, indicating the gap insertion logic (`benedict-chat--maybe-insert-item-gap`) isn't working correctly (`test/benedict-chat-integration-test.el:287`).
- **Streaming body corruption** (`benedict-chat-integration-streaming-preserves-body-across-header-refresh`): The `[ASSISTANT]` header disappears after header refresh operations, suggesting `benedict-chat--update-message-header` is deleting more than intended (`test/benedict-chat-integration-test.el:42`).

## Desired End State
- `benedict-chat-ask-region` and related compose flows do not prompt for session selection during batch tests; tests can run noninteractively without `end-of-file` errors.
- All chat state (messages, tool calls, tool results, errors) is accumulated in the session, regardless of buffer attachment, and session-backed request history includes tool result entries.
- Navigation helpers using magit sections land on item header markers as tests expect.
- Tool folding tests pass without stale section or read-only buffer errors.
- Tests clear the session registry per test to avoid cross-test state leakage, and they pass under `nix run .#test`.
- **Section end markers advance correctly** when child sections are inserted.
- **Items render in chronological order** (user → assistant → thinking → tools).
- **Blank lines appear between blocks** as expected for visual separation.
- **Streaming content is preserved** across header refresh operations.

## What We're NOT Doing
- No UI redesign or new magit-section features beyond fixing registration/navigation.
- No changes to session persistence format or storage backend.
- No refactor of unrelated chat rendering logic.

## Implementation Approach
Address each failure mode in a focused phase: stabilize noninteractive session selection, ensure tool results are captured in session-backed history, fix magit-section registration to use the correct section object, and harden tool folding behavior for tests. Update tests to set up isolated session registries or stubs as needed. Verification is primarily via ERT tests and targeted `nix run .#test` commands.

## Phase 1: Noninteractive Session Selection + Session Isolation in Tests
### Overview
Eliminate interactive session prompts during batch tests by providing a noninteractive path and ensure each test isolates the session registry to avoid cross-test leakage.

### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: Add a noninteractive-safe selection path in `benedict-chat` or `benedict-chat--ensure-chat-buffer` that avoids `completing-read` when `noninteractive` is true or when a test override variable is set. Ensure it selects a deterministic session (e.g., most recent) or creates a new session when multiple exist.
  - ```elisp
    ;; Pattern: when noninteractive, avoid completing-read
    (if (or noninteractive benedict-chat--noninteractive-session)
        (benedict-session-latest-or-create)
      (benedict-chat--prompt-session ...))
    ```
- **File**: `test/benedict-chat-logic-test.el`
  - **Changes**: Rebind the session registry (`benedict-session--registry`) to a fresh hash table in each test or common setup so all tests start with an empty registry. Only stub `completing-read` as needed for unrelated prompts.
  - ```elisp
    (let ((benedict-session--registry (make-hash-table :test #'equal)))
      ...)
    ```

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-logic-test.el`
#### Manual Verification
- [ ] Confirm no `end-of-file` prompt errors appear when running tests in batch mode.

## Phase 2: Session-Authoritative State (Tool Results Included)
### Overview
Ensure all chat state (messages, tool calls, tool results, errors) is recorded in the session, and session-backed request history includes tool result entries.

### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: When a tool result is stored via `benedict-chat--invoke-tool-call`, also write a corresponding message into the session via `benedict-session-add-message` (or route through `benedict-chat--record-message` with a tool-result type) if a session is present. Extend this to any other non-session-recorded chat state (tool errors or similar) so session is authoritative.
  - ```elisp
    (when-let ((session (benedict-chat--session)))
      (benedict-session-add-message session tool-message))
    ```
- **File**: `test/benedict-chat-logic-test.el`
  - **Changes**: Validate that tool entries appear in the built request, aligning with session-authoritative state.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-logic-test.el`
#### Manual Verification
- [ ] Inspect a built request in a test to confirm tool result presence aligns with updated behavior.

## Phase 3: Correct Magit-Section Registration for Items
### Overview
Ensure items store the section object for the newly inserted magit section rather than its parent so navigation via `magit-section-goto` lands on the item header markers.

### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: Modify `benedict-chat--insert-section` and/or `benedict-chat--register-section` to capture the section created by `magit-insert-section` (prefer `magit-insert-section--current` when bound; fall back to `magit-current-section`) so item sections always refer to the newly inserted section.
  - ```elisp
    ;; Pattern: use magit-insert-section--current when bound
    (let ((section (or (and (boundp 'magit-insert-section--current)
                             magit-insert-section--current)
                        (magit-current-section))))
      (benedict-chat--register-section item section))
    ```
- **File**: `test/benedict-chat-thinking-test.el`
  - **Changes**: Keep assertions comparing point to item header markers; ensure they pass under updated section registration.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-thinking-test.el`
#### Manual Verification
- [ ] In a chat buffer, navigate between items and confirm point lands at item headers.

## Phase 4: Tool Folding Reliability
### Overview
Make tool folding tests resilient by ensuring magit sections used for toggling are valid and belong to the current buffer.

### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: In `benedict-chat--set-section-folded` or the caller path, confirm the section is live and in the current buffer; if not, resolve via item markers or skip folding with a safe fallback.
  - ```elisp
    ;; Pattern: guard against stale sections
    (when (and section (magit-section-match (magit-section-parent section) ...))
      (magit-section-hide section))
    ```
- **File**: `test/benedict-chat-render-test.el`
  - **Changes**: Ensure the test keeps the buffer alive for the duration of the folding toggle or asserts updated behavior when sections are missing.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-render-test.el`
#### Manual Verification
- [ ] Toggle tool fold in an interactive session and confirm no read-only or killed-buffer errors.

## Phase 5: Test Isolation - Session Registry and Magit Section State
### Overview
Tests pass individually but fail when run with the full suite due to global state pollution. The session registry (`benedict-session--registry`) is a global hash table that persists across tests, and magit-section state can also leak between test runs.

### Changes Required
- **File**: `test/benedict-chat-integration-test.el`
  - **Changes**: Add a test setup hook that rebinds `benedict-session--registry` to a fresh hash table before each test. Also reset any buffer-local magit state to ensure clean test environment.
  - ```elisp
    (ert-deftest benedict-chat-integration-...')
      (let ((benedict-session--registry (make-hash-table :test #'equal)))
        ...))
    ```
- **File**: `test/benedict-agent-loop-test.el`
  - **Changes**: Ensure test isolates buffer-local state like `benedict-chat--messages`, `benedict-chat--items`, and `benedict-chat--loop-turn-count` to avoid cross-test pollution.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-integration-test.el` (all tests pass)
- [x] `nix run .#test -- test/benedict-agent-loop-test.el` (all tests pass)
- [x] Full suite passes for these test files (229 tests pass)
#### Manual Verification
- [x] Run each failing test individually and confirm it passes
- [x] Run full suite and confirm the same tests still pass

## Phase 6: Fix Section End Marker Advancement
### Overview
The `benedict-chat-section-end-marker-advances` test fails because the root section end marker stays at position 188 after inserting content. The section's end marker should advance as child sections are inserted.

### Analysis
- The conversation root section (`benedict-chat--conversation-section`) has an end marker that should move when content is inserted
- `benedict-chat--section-end-position` reads the marker position, but the marker may not be advancing due to incorrect insertion type
- Markers need `set-marker-insertion-type` set appropriately to grow when text is inserted after them

### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: In `benedict-chat--ensure-conversation-root` and `benedict-chat--register-section`, ensure the end marker's insertion type is set correctly so it advances when content is appended.
  - ```elisp
    ;; Pattern: ensure end marker advances when content is inserted after it
    (when (markerp end)
      (set-marker-insertion-type end t))  ; t means marker moves when text is inserted at it
    ```
  - **Investigation needed**: Determine if the issue is in how the root section's end marker is created, or how child sections are being inserted.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-integration-test.el` (specifically `benedict-chat-section-end-marker-advances`)
#### Manual Verification
- [x] Insert messages in a chat buffer and verify the root section's end marker advances

## Phase 7: Fix Item Ordering in Chat Buffer
### Overview
The `benedict-chat-integration-agent-run-preserves-ordering` test fails because `user-pos < assistant-pos` is false (`391 < 257`). This indicates assistant content is appearing BEFORE user content in the buffer, which is the wrong order.

### Analysis
- The test expects: user < assistant < thinking < tool-header < tool-output
- Actual positions show: assistant (257) < user (391), meaning assistant rendered first
- This is a **real bug** - items are being inserted out of order
- The rendering paths use `benedict-chat--with-section` which navigates to `benedict-chat--section-end-position(parent)` before inserting
- Possible cause: the parent section's end position isn't being tracked correctly, or sections are being created in a different order than expected

### Changes Required
- **File**: `benedict-chat.el`
  - **Changes**: Investigate `benedict-chat--with-section` and `benedict-chat--section-end-position` to understand why items render out of order.
  - The issue may be that `benedict-chat--section-end-position` returns a cached position that doesn't reflect the actual buffer state after previous insertions.
  - Consider whether sections should be inserted at `point-max` directly instead of navigating to section end positions.
  - ```elisp
    ;; Current pattern: navigate to section end, then insert
    (save-excursion
      (goto-char (benedict-chat--section-end-position parent))
      (benedict-chat--insert-section ...))
    ;; May need to ensure the parent section's end marker is up-to-date
    ```

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-integration-test.el` (specifically `benedict-chat-integration-agent-run-preserves-ordering`)
#### Manual Verification
- [x] Run an agent conversation and verify blocks appear in correct order (user, assistant, thinking, tools)

## Phase 8: Fix Blank Line Insertion Between Blocks
### Overview
The `benedict-chat-integration-inserts-blank-line-between-blocks` test fails because only `"\n"` appears between blocks instead of `"\n\n"`. The gap insertion logic isn't preserving the expected blank line separation.

### Analysis
- `benedict-chat--maybe-insert-item-gap` is responsible for inserting blank lines between blocks
- It checks trailing newlines and inserts more if needed to reach 2
- The test checks the gap between assistant-end and tool-start
- Possible causes: the gap is being inserted but then overwritten, or the calculation of trailing newlines is incorrect

### Changes Required
- **File**: `benedict-chat.el` or `benedict-chat-render.el`
  - **Changes**: Debug `benedict-chat--maybe-insert-item-gap` to ensure it correctly inserts `"\n\n"` between blocks.
  - The gap insertion may need to happen at a different point in the rendering flow, or the calculation of existing newlines may be off.
  - Investigate whether section insertion affects the gap calculation.
  - ```elisp
    ;; Current pattern in benedict-chat--maybe-insert-item-gap
    (let* ((end (point))
           (start (save-excursion (skip-chars-backward "\n") (point)))
           (trailing-newlines (- end start))
           (needed (max 0 (- 2 trailing-newlines))))
    ;; Verify this logic works correctly in all rendering contexts
    ```

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-integration-test.el` (specifically `benedict-chat-integration-inserts-blank-line-between-blocks`)
#### Manual Verification
- [x] Visually inspect chat buffer to confirm blank lines between message/tool blocks

## Phase 9: Fix Streaming Body Preservation Across Header Refresh
### Overview
The `benedict-chat-integration-streaming-preserves-body-across-header-refresh` test fails because `[ASSISTANT]` cannot be found in the buffer after header refresh operations. The header refresh may be deleting or corrupting buffer content.

### Analysis
- The test streams content ("Hello **bo"), refreshes the header with `benedict-chat--status-tick`, then streams more content
- After completion, it searches for `[ASSISTANT]` and fails to find it
- This suggests the header refresh (`benedict-chat--update-message-header`) may be deleting more than intended
- The test also checks that markdown fontification is preserved

### Changes Required
- **File**: `benedict-chat-render.el`
  - **Changes**: Investigate `benedict-chat--update-message-header` to ensure it only replaces the header text and doesn't delete the body or the marker.
  - The function deletes from `start` to `end`, but these markers may not be correctly positioned.
  - ```elisp
    ;; In benedict-chat--update-message-header
    (delete-region start end)
    ;; Verify 'start' and 'end' only cover the header, not the body
    ```
- **File**: `benedict-chat.el`
  - **Changes**: Verify that `benedict-chat--status-tick` (which triggers header refresh) is operating on the correct buffer region.

### Success Criteria
#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-integration-test.el` (specifically `benedict-chat-integration-streaming-preserves-body-across-header-refresh`)
#### Manual Verification
- [x] Send a long prompt that triggers multiple status ticks and verify the response remains intact

## Testing Strategy
- Targeted ERT runs:
  - `nix run .#test -- test/benedict-chat-logic-test.el`
  - `nix run .#test -- test/benedict-chat-thinking-test.el`
  - `nix run .#test -- test/benedict-chat-render-test.el`
  - `nix run .#test -- test/benedict-chat-integration-test.el`
  - `nix run .#test -- test/benedict-agent-loop-test.el`
- Full suite (optional after fixes): `nix run .#test`.
- If linting is needed after code changes: `nix run .#lint` (or `LINT_WARNINGS_ONLY=1 nix run .#lint`).

## References
- `efforts/00052-unbreak_tests/research.md`
- `benedict-chat.el:3466`
- `benedict-chat.el:3519`
- `benedict-chat.el:3926`
- `benedict-chat.el:2651`
- `benedict-chat.el:2110`
- `benedict-chat.el:316`
- `benedict-chat.el:3559`
- `benedict-chat-render.el:537`
- `test/benedict-chat-logic-test.el:54`
- `test/benedict-chat-logic-test.el:206`
- `test/benedict-chat-thinking-test.el:107`
- `test/benedict-chat-thinking-test.el:148`
- `test/benedict-chat-render-test.el:97`
- `test/benedict-chat-integration-test.el:349` (agent run ordering test)
- `test/benedict-chat-integration-test.el:287` (blank line test)
- `test/benedict-chat-integration-test.el:403` (section end marker test)
- `test/benedict-chat-integration-test.el:42` (streaming body preservation test)
