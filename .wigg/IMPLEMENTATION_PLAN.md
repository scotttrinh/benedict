# Implementation Plan

## Goal

Implement programmable tool permissions as the next vertical effort so Benedict can evaluate a predicate `(tool args) -> t|nil` from project dir-locals or global config, while preserving the current interactive approval flow as fallback.

## Priority Tasks

### Permission Engine (Core)

- [x] **Add predicate configuration and resolver primitives** (refs: 06_tools.md, 07_harness_and_skills.md)
  - Scope: Introduce a global defcustom for tool permission predicate, a project-local override path, and a single resolver that enforces precedence: dir-local -> global -> fallback.
  - Files: `benedict-tools.el`, `benedict-chat-profiles.el` (if project-root/dir-local helpers are reused), `benedict.el` (only if user-facing customization docs live there).
  - Tests: Add/extend `test/benedict-tools-test.el` to cover resolver precedence and "no configured predicate" behavior.
  - Dependencies: None.
  - Notes: Keep the contract strict: predicate is called with tool symbol + normalized plist args; no behavior changes to tool implementations yet.

- [x] **Integrate predicate decisions into tool invocation with safe fallback** (refs: 04_agent_loop.md, 06_tools.md)
  - Scope: Update tool invocation so predicate result gates execution (`t` allow, `nil` deny); predicate errors or non-boolean values trigger fallback to existing interactive approval prompt.
  - Files: `benedict-tools.el`.
  - Tests: Extend `test/benedict-tools-test.el` with cases for allow, deny, predicate error, and non-boolean return; assert fallback prompt path is used when required.
  - Dependencies: Add predicate resolver primitives.
  - Notes: Keep legacy `:approval` metadata behavior intact for backward compatibility.

### Session + Model Recovery Slice

- [x] **Return structured denial results through session tool flow** (refs: 04_agent_loop.md, 07_harness_and_skills.md)
  - Scope: Ensure denied tool calls surface as structured tool failures (permission denied) that the model can recover from, instead of opaque hard errors.
  - Files: `benedict-tools.el`, `benedict-session.el`.
  - Tests: Extend `test/benedict-session-test.el` for denied-call result formatting and `test/benedict-chat-logic-test.el` for recovery behavior in looped tool-call turns.
  - Dependencies: Predicate integration into tool invocation.
  - Notes: Preserve existing `tool-started`/`tool-completed` event ordering for denied calls.

- [x] **Add audit/event coverage for permission decision paths** (refs: 02_architecture.md, 07_harness_and_skills.md)
  - Scope: Emit and verify events for predicate-allow, predicate-deny, and fallback-on-error decisions so UI/logging can explain why a call ran or was blocked.
  - Files: `benedict-session.el`, `benedict-chat-status.el` (if surfaced), `benedict-flywire.el` (only if audit plumbing belongs there).
  - Tests: Extend `test/benedict-session-test.el` event assertions; add focused assertions in `test/benedict-chat-session-test.el` for visible telemetry path where available.
  - Dependencies: Structured denial results through session flow.
  - Notes: Keep this additive; avoid introducing new UI complexity before behavior is stable.

### Project Policy UX Slice

- [x] **Support dir-local permission policy and document usage** (refs: 06_tools.md, 07_harness_and_skills.md)
  - Scope: Finalize project-local configuration path for permission predicate and document a minimal `.dir-locals.el` recipe with expected function signature and safety notes.
  - Files: `benedict-tools.el` and/or `benedict-chat-profiles.el` (where resolver lives), `README.md` (or docs file used for customization guidance).
  - Tests: Add an integration-style test in `test/benedict-tools-test.el` or new `test/benedict-tool-permissions-test.el` that simulates project-local override winning over global.
  - Dependencies: Predicate resolver primitives.
  - Notes: Keep docs explicit that interactive approval remains the fallback when no predicate decision is available.

## Validation Gates

- Per-task fast loop:
  - `nix run .#test -- test/benedict-tools-test.el`
  - `nix run .#test -- test/benedict-session-test.el`
  - `nix run .#test -- test/benedict-chat-logic-test.el`
- End-of-chunk confidence:
  - `nix run .#test -- test/benedict-tools-test.el test/benedict-session-test.el test/benedict-chat-session-test.el test/benedict-chat-logic-test.el`
  - `nix run .#test`

## Completed

- [x] Previous VUI chat behavior and coverage implementation plan completed; next effort starts with programmable tool permissions.
