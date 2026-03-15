# Implementation Plan

## Goal

Refine Benedict's chat UI so each exchange reads as a coherent turn rather than a flat stream of unrelated blocks. The UI should make it obvious:

- which user prompt the assistant is working on
- which intermediate blocks are execution details versus the answer
- what the final outcome of the turn is

The target interaction model is:

1. An active turn presents the user prompt as a persistent prompt header.
2. Streaming thinking/tool/status content appears beneath that header as activity for that prompt.
3. When the assistant finishes, the turn settles into a compact historical record where the final assistant answer is dominant and intermediate execution detail is collapsed by default.

## Design Principles

- Turn-first, not message-first: render a user prompt and its resulting assistant work as one visual group.
- Outcome-first: once complete, the final assistant answer should visually outweigh thinking and tool chatter.
- Theme-safe polish: use faces that derive from existing Emacs theme surfaces rather than hardcoded colors.
- Progressive disclosure: preserve detailed execution history, but hide most of it by default after completion.
- Stable interaction: avoid layout tricks that fight Emacs buffer mechanics; emulate "sticky" behavior with deliberate component structure.

## Target UX Model

### Active Turn

- The current user message is rendered as a prompt header for the active turn.
- The prompt header remains visually persistent while tool/thinking/streaming blocks accumulate.
- Execution blocks appear in an activity lane beneath the prompt header.
- Partial assistant text may appear as a draft response area, but it remains visually secondary until completion.

### Completed Turn

- The turn is "solidified" once the assistant finishes.
- The final assistant message becomes the primary content block for the turn.
- Thinking, tool use, and verbose tool results collapse into a summary section by default.
- High-signal execution facts remain visible, such as tool names, error status, and whether approvals were involved.

### Historical Turn

- Old turns are compact and easy to scan.
- The user prompt remains attached to the final answer.
- Hidden execution details can be expanded on demand.
- Spacing between turns is larger than spacing between blocks inside a turn.

## Proposed Visual Hierarchy

Within a single completed turn, the reading order should be:

1. Prompt header
2. Final assistant answer
3. Execution summary
4. Expandable execution details

The active turn should use the same structure, except that the execution summary is replaced by a live activity lane until completion.

## Implementation Phases

### Phase 1: Turn Model and State

Status: completed 2026-03-15

Completed:

- Added turn-derived lifecycle metadata at the conversation/turn layer.
- Added canonical helpers for prompt text, final assistant outcome, and execution summary data.
- Moved active draft handling into the turn model so streaming state attaches to the active turn instead of a synthetic top-level message.
- Added focused tests covering derived turn metadata and active-turn draft assembly.

Objective: make the UI explicitly aware of the difference between an active turn, a completed turn, and execution detail within a turn.

Work:

- Extend turn-level UI props/state so a turn can distinguish:
  - active versus historical
  - streaming versus completed
  - presence of intermediate execution blocks
  - whether execution detail is manually expanded
- Add turn-derived metadata helpers to compute:
  - prompt text used as the turn header
  - final assistant message block for the turn
  - execution summary for collapsed historical display
- Keep this logic at the turn/conversation layer rather than scattering it across individual block components.

Acceptance criteria:

- A turn can render differently based on lifecycle state without special-casing every block type.
- The UI has a canonical way to identify the "final assistant outcome" for a turn.

### Phase 2: Active Turn Layout

Objective: make the active turn read like "assistant working on this prompt."

Work:

- Introduce a dedicated prompt header region in the turn component.
- Render the active turn as:
  - prompt header
  - activity lane
  - optional in-progress answer area
- Avoid trying to implement literal sticky positioning in the transcript body.
- Instead, emulate stickiness through one of these approaches:
  - render the prompt header as the topmost sub-block of the active turn and preserve viewport behavior
  - optionally mirror the active prompt in a lightweight session/header area while streaming
- Visually subordinate tool/thinking/status blocks relative to the prompt header.

Acceptance criteria:

- During streaming, it is always obvious which prompt the current activity belongs to.
- Tool/thinking/status blocks no longer feel like peer chat messages.

### Phase 3: Completion and Collapse Behavior

Objective: make completed turns outcome-first while preserving inspectability.

Work:

- On completion, promote the final assistant text block into a primary answer card.
- Auto-collapse thinking/tool/tool-result blocks for completed turns.
- Replace hidden detail with a compact execution summary row, for example:
  - tool count
  - tool names
  - errors/warnings
  - approval involvement
- Keep the final assistant answer expanded by default.
- Allow per-turn expansion/collapse of execution detail.
- Preserve failed or high-signal tool output in the summary if it materially affected the answer.

Acceptance criteria:

- The final assistant answer is the visually dominant block in completed turns.
- Historical transcript scanning is faster because verbose execution detail is hidden by default.

### Phase 4: Theme-Safe Face System

Objective: add polish without breaking compatibility across Doom/themes.

Work:

- Introduce dedicated faces for:
  - prompt header
  - active turn container
  - final assistant outcome
  - execution summary
  - execution detail blocks
- Derive backgrounds and emphasis from theme-safe base faces such as:
  - `default`
  - `shadow`
  - `fringe`
  - `region`
  - `mode-line-inactive`
- Use subtle background differences, padding, box/line styling, and weight changes instead of relying on color alone.
- Increase spacing inside turn containers and increase separation between turn groups.

Acceptance criteria:

- The UI remains legible and visually coherent across light and dark themes.
- User prompt, outcome, and execution detail are distinguishable even in low-color themes.

### Phase 5: Component Restructuring

Objective: align the current VUI component tree with the new turn-centric presentation model.

Likely component changes:

- `benedict-vui-turn.el`
  - becomes the primary orchestrator for turn lifecycle layout
- `components/benedict-vui-turn-header.el`
  - may be repurposed into a prompt header / turn meta header split
- `components/benedict-vui-content-block-list.el`
  - may need separate rendering paths for:
    - primary answer content
    - execution summary
    - expandable execution details
- `components/benedict-vui-conversation-view.el`
  - may need awareness of the active turn so it can support viewport/persistence behavior

Potential new components:

- `benedict-vui-prompt-header`
- `benedict-vui-turn-outcome`
- `benedict-vui-execution-summary`
- `benedict-vui-execution-detail-group`

Acceptance criteria:

- The new layout is expressed through a small number of clear components with stable responsibilities.
- The conversation view remains keyed by turn identity rather than transient block ordering.

### Phase 6: Interaction and Navigation

Objective: keep the new presentation efficient for keyboard users.

Work:

- Ensure `TAB` and navigation commands behave sensibly with collapsed execution detail.
- Add obvious focus/jump targets for:
  - prompt header
  - final answer
  - execution summary
- Preserve current message navigation semantics where possible, but bias toward turn-level navigation for the transcript.
- Consider commands for:
  - toggle execution details on current turn
  - jump to current turn outcome
  - jump between prompts rather than every block

Acceptance criteria:

- Collapsing execution detail does not make the transcript harder to navigate.
- Keyboard-first usage still feels native and predictable.

### Phase 7: Test Coverage

Objective: lock the new behavior down with focused VUI tests.

Work:

- Add tests covering:
  - active turn renders prompt header and live execution detail together
  - completed turn promotes the final assistant message
  - execution detail auto-collapses after completion
  - expansion toggles reveal the expected blocks
  - failed tool results remain visible in summary state when needed
  - face/structure regressions for prompt header vs outcome vs detail blocks
- Prefer component-level tests around turn rendering plus one end-to-end transcript test for turn progression.

Acceptance criteria:

- The active-to-completed turn transition is exercised in automated tests.
- The turn structure is stable against regressions during future UI work.

## Open Design Decisions

These should be resolved before implementation gets too deep:

- Should partial assistant prose appear in the primary outcome area while streaming, or in a visually subordinate draft area until completion?
- Should the active prompt be mirrored into a session-level header, or remain only inside the active turn container?
- What summary information should always remain visible after collapse?
- Should user prompts always stay expanded, or should long prompts clamp by default in historical turns?
- How should multi-assistant-message turns be normalized into one final outcome presentation?

## Non-Goals

- Replacing the current VUI architecture
- Building a fully custom layout engine to emulate GUI sticky positioning
- Hiding all execution detail permanently
- Introducing theme-specific hardcoded palettes

## Suggested Delivery Order

1. Turn state/model helpers
2. Active turn prompt header layout
3. Completion-state outcome promotion
4. Execution summary + collapse behavior
5. Face and spacing polish
6. Navigation updates
7. Regression tests

## Definition of Done

This effort is complete when:

- active turns clearly communicate "the assistant is working on this prompt"
- completed turns clearly communicate "this was the outcome"
- execution details are available but no longer dominate the transcript
- spacing and face treatment make turn boundaries obvious without clashing with existing themes
- the active-to-completed transition is covered by automated tests
