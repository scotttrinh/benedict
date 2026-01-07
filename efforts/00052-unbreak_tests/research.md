---
date: 2026-01-07T12:15:54-0500
researcher: Codex
git_commit: 60fd5b949173b4c9649da016a1ce4d89eef7be63
branch: initial-benedict-session
repository: benedict
topic: "Investigate test failures after magit-section UI + session state"
tags: [research, tests, chat, magit-section, session]
status: draft
last_updated: 2026-01-07
---

# Research: Investigate test failures after magit-section UI + session state

**Date**: 2026-01-07T12:15:54-0500
**Researcher**: Codex
**Git Commit**: 60fd5b949173b4c9649da016a1ce4d89eef7be63
**Branch**: initial-benedict-session

## Research Question
User request: trace why tests fail (no code changes) after switching `benedict-chat-mode` to magit-section UI and switching history to session state.

## Summary
Several chat tests now route through session-backed history and magit-section navigation, which changes the test environment assumptions. The compose flow calls `benedict-chat` to create/attach a chat buffer, which prompts for session selection when multiple sessions exist; this causes batch tests to error with `end-of-file` on stdin. Tool-result tests build provider requests from session history, but tool results are stored only in buffer history, so the session-backed request lacks tool entries. Navigation tests now rely on `magit-section-goto` when items have sections; these sections are registered using `magit-current-section`, which can point at the parent section rather than the newly inserted one, shifting navigation positions away from item header markers.

## Detailed Findings
### Compose flow now prompts for session selection in batch
- `benedict-chat-ask-region` calls `benedict-chat--deliver-context-slices`, which ensures a chat buffer by calling `benedict-chat` when no chat buffer exists (`benedict-chat.el:3466`, `benedict-chat.el:3519`).
- `benedict-chat` prompts with `completing-read` when multiple sessions exist, which fails in batch tests that have no stdin (`benedict-chat.el:3964`).
- The failing test uses `benedict-chat-ask-region` without stubbing `completing-read` or session list (`test/benedict-chat-logic-test.el:54`).

### Provider requests now read session history, not buffer history
- `benedict-chat--build-request` maps messages from `benedict-session-messages-chronological` when a session is present, making the session the authoritative message source (`benedict-chat.el:2651`).
- Tool results are stored with `benedict-chat--history-store` (buffer-local only) in `benedict-chat--invoke-tool-call`; no corresponding session write occurs there (`benedict-chat.el:2110`).
- The tool error test asserts the tool entry exists in the request messages; it will be missing if the session history lacks tool entries (`test/benedict-chat-logic-test.el:206`).

### Magit-section navigation depends on section registration
- `benedict-chat--goto-item` uses `magit-section-goto` when the item has a `:section`, otherwise uses header/start markers (`benedict-chat.el:3559`).
- Item sections are attached in `benedict-chat--insert-section`, which registers `magit-current-section` as the section (`benedict-chat.el:316`).
- `benedict-chat--register-section` sets the section on the item (`benedict-chat.el:341`). If `magit-current-section` is not the newly inserted section, the item’s section can point at the parent and navigation will move to the parent section start instead of the item header.
- Navigation tests compare point against item header markers and now fail by small offsets (`test/benedict-chat-thinking-test.el:107`, `test/benedict-chat-thinking-test.el:148`).

### Tool folding uses magit-section visibility and requires valid sections
- Tool toggling updates visibility via `benedict-chat--update-tool-visibility`, which calls `benedict-chat--set-section-folded` (magit hide/show) when a section is present (`benedict-chat-render.el:537`, `benedict-chat.el:223`).
- The folding test builds a tool item within `benedict-chat--with-section`, then toggles visibility; a killed-buffer read-only error during toggle indicates the section or buffer context is stale/invalid (`test/benedict-chat-render-test.el:97`).

## Hypotheses & Potential Causes
- Hypothesis (high confidence): The `completing-read` prompt in `benedict-chat` causes `end-of-file` in batch tests whenever multiple sessions exist, because test setup now creates sessions in `benedict-chat--init-buffer` and `benedict-chat` is called from `benedict-chat-ask-region` (`benedict-chat.el:3810`, `benedict-chat.el:3926`).
- Hypothesis (medium confidence): Tool-result tests fail because session-backed request history does not include tool messages stored only in buffer history (`benedict-chat.el:2110`, `benedict-chat.el:2651`, `test/benedict-chat-logic-test.el:206`).
- Hypothesis (medium confidence): Navigation/folding tests fail because section registration uses `magit-current-section` (possibly the parent section) rather than the newly inserted section, so `magit-section-goto` positions point at the parent (`benedict-chat.el:316`, `benedict-chat.el:3559`).

## Code References
- `benedict-chat.el:3466` - `benedict-chat-ask-region` triggers compose delivery.
- `benedict-chat.el:3519` - `benedict-chat--ensure-chat-buffer` calls `benedict-chat` if no buffer.
- `benedict-chat.el:3926` - `benedict-chat` prompts with `completing-read` when multiple sessions exist.
- `benedict-chat.el:3810` - `benedict-chat--init-buffer` creates and attaches a session.
- `benedict-chat.el:2651` - `benedict-chat--build-request` reads history from session.
- `benedict-chat.el:2110` - `benedict-chat--invoke-tool-call` stores tool result only in buffer history.
- `benedict-chat.el:316` - `benedict-chat--insert-section` registers `magit-current-section`.
- `benedict-chat.el:341` - `benedict-chat--register-section` attaches section to item.
- `benedict-chat.el:3559` - `benedict-chat--goto-item` uses `magit-section-goto` when section exists.
- `benedict-chat-render.el:537` - tool visibility updates via magit section folding.
- `test/benedict-chat-logic-test.el:54` - compose context test uses `benedict-chat-ask-region`.
- `test/benedict-chat-logic-test.el:206` - tool error test expects tool entry in request.
- `test/benedict-chat-thinking-test.el:107` - thinking navigation test compares point to header markers.
- `test/benedict-chat-thinking-test.el:148` - last-assistant-with-tools navigation test compares point to header markers.
- `test/benedict-chat-render-test.el:97` - tool folding test exercises magit-section toggle.

## Architecture Documentation
- Chat UI uses magit sections for message, thinking, and tool items, with sections registered at insertion time and stored on item plists (`benedict-chat.el:316`, `benedict-chat.el:341`).
- Provider requests are built from session history when `benedict-chat--session` is present, making sessions the authoritative message source (`benedict-chat.el:2651`).

## Historical Context (from previous efforts)
- None referenced in this research.

## Open Questions
- Does `magit-current-section` reliably reference the newly inserted section inside `magit-insert-section`, or does it return the parent in this buffer context?
- Are any tests stubbing `benedict-session-list` or `completing-read` to avoid interactive prompts during batch runs?

## Additional Evidence & Context
### Session registry persistence across tests
- Session registry is a global hash table (`benedict-session--registry`) shared across tests unless explicitly rebound (`benedict-session.el:24`).
- Many session-related tests explicitly rebind `benedict-session--registry` to a fresh hash table, but not all chat tests do so (`test/benedict-chat-session-test.el:23`, `test/benedict-chat-logic-test.el:54`).
- Only one test currently stubs `completing-read` and it targets provider selection, not the session prompt path (`test/benedict-chat-logic-test.el:300`).

### Tool results vs session history
- `benedict-chat--record-message` writes non-streaming messages (including user messages) into the session via `benedict-session-add-message`, but tool results are not routed through this path (`benedict-chat.el:1638`).
- Tool result messages are stored with `benedict-chat--history-store` in `benedict-chat--invoke-tool-call`, which writes to buffer history only (`benedict-chat.el:2110`).
- The headless success path records assistant messages with `:tool-calls` in the session, but this does not add separate tool result entries (`benedict-chat.el:2878`).

### Section registration uses magit-current-section
- Conversation root and turn sections capture `magit-insert-section--current` (if bound) instead of `magit-current-section`, but `benedict-chat--insert-section` always registers `magit-current-section` for the item section (`benedict-chat.el:254`, `benedict-chat.el:316`).
- `benedict-chat--goto-item` prefers `magit-section-goto` when a section is attached, so a mis-registered section would move point to the wrong location, diverging from header marker expectations in navigation tests (`benedict-chat.el:3559`, `test/benedict-chat-thinking-test.el:107`).

## Code References (Additional)
- `benedict-session.el:24` - global session registry definition.
- `test/benedict-chat-session-test.el:23` - tests resetting registry per test.
- `test/benedict-chat-logic-test.el:54` - compose test does not reset registry or stub session prompt.
- `test/benedict-chat-logic-test.el:300` - completing-read stub only for provider selection.
- `benedict-chat.el:1638` - session writes in `benedict-chat--record-message` exclude streaming assistant messages.
- `benedict-chat.el:2110` - tool result history stored without session update.
- `benedict-chat.el:2878` - headless success stores assistant message with tool-calls in session.
- `benedict-chat.el:254` - conversation root uses `magit-insert-section--current` fallback.
- `benedict-chat.el:316` - item section registration uses `magit-current-section`.
