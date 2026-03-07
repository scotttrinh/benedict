# Deliver a Spec-Aligned Core Runtime, Harness, Persistence, and Instruction Bootstrap

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

## Purpose / Big Picture

The repository already ships an Emacs chat experience with provider adapters, a VUI-based conversation view, an in-memory session loop, and a basic tool registry. The specs in `.wigg/specs/` define a much larger v0.1 target: Benedict should load project instructions automatically, execute tools through a real safety harness, persist provider-agnostic transcripts, and expose stable runtime events that the UI can render without reaching into internals.

After this change, a developer should be able to open `*Benedict Chat*`, have the session automatically seeded from `AGENTS.md` and `.wigg/specs/`, run a multi-step tool-using task under explicit scope and budget limits, see audit/checkpoint information in the chat UI, close Emacs or detach the buffer, reload the session from disk, and continue from the same canonical transcript. The working behavior must be observable entirely from this repository with `nix run .#test`, targeted ERT tests, and a manual chat run using the `fake` provider.

## Progress

- [x] (2026-03-07 15:43Z) Audit `.wigg/specs/` and current implementation; identify existing seams in `benedict-session.el`, `benedict-chat.el`, `benedict-tools.el`, and current tests.
- [ ] (YYYY-MM-DD HH:MMZ) Introduce a canonical message and event model that sits between provider adapters, runtime state, persistence, and UI.
- [ ] (YYYY-MM-DD HH:MMZ) Add a harness module that enforces scope, budgets, permission predicates, and audit event emission for every tool call.
- [ ] (YYYY-MM-DD HH:MMZ) Add a provider-agnostic session store with save/load, branch metadata hooks, and replay into the runtime.
- [ ] (YYYY-MM-DD HH:MMZ) Add instruction bootstrap that loads `AGENTS.md`, selected `SKILL.md` files, and `.wigg/specs/` into session startup context with progressive disclosure.
- [ ] (YYYY-MM-DD HH:MMZ) Update the chat/VUI surface to render checkpoints, audit/tool results, and persistence-backed session metadata without relying on ephemeral minibuffer prompts.
- [ ] (YYYY-MM-DD HH:MMZ) Prove the feature with focused ERT coverage and a manual fake-provider transcript round-trip.

## Surprises & Discoveries

The current codebase is closer to the target than the specs suggest in a few areas. `benedict-session.el` already has a real loop skeleton, repetition detection, turn/time/token checkpoint checks, request telemetry accumulation, and event emission such as `draft-started`, `tool-started`, and `request-completed`. That lowers the amount of new runtime code required.

The largest gap is architectural, not UI polish. Messages are still loose plists stored directly inside the session struct, `benedict-session--build-request` translates those plists directly into provider payloads, tool execution runs straight from `benedict-session--invoke-tool` into `benedict-tool-invoke`, and there is no dedicated persistence layer or instruction bootstrap module. This means the current system cannot satisfy the specs for cross-provider replay, durable session recovery, or a modern harness boundary without refactoring the runtime contract first.

The current chat checkpoint flow also still uses `y-or-n-p` inside `benedict-chat--handle-session-event` even though the specs require a persistent checkpoint block in the chat buffer. That is an implementation smell worth removing early because it couples runtime safety to transient UI prompts.

Baseline validation for this run succeeded without code changes. `git status --short` showed only the intentional modification to `.wigg/IMPLEMENTATION_PLAN.md`, `rg --files .wigg/specs` found the seven numbered spec files plus `benedict-assistant.md`, and `nix run .#test -- test/benedict-session-test.el test/benedict-agent-loop-test.el test/benedict-chat-integration-test.el test/benedict-tools-test.el` exited `0` after running 83 tests.

## Decision Log

- **Decision:** Build the missing features around a new canonical message/event layer instead of extending the current raw plist history directly.
- **Rationale:** The specs require provider-agnostic persistence, cross-provider replay, stable UI subscriptions, and extension-owned metadata. Those are difficult to implement safely if raw provider-shaped plists remain the canonical history format.
- **Date/Author:** 2026-03-07 / Codex

- **Decision:** Keep `benedict-session.el` as the runtime owner, but move safety and persistence responsibilities into new dedicated modules.
- **Rationale:** The existing session loop and tests already anchor runtime behavior. Replacing it wholesale would create unnecessary regression risk. New modules should narrow responsibilities instead: `benedict-harness.el` for enforcement, `benedict-store.el` for disk format, and `benedict-instructions.el` for startup context.
- **Date/Author:** 2026-03-07 / Codex

- **Decision:** Use an s-expression transcript file for the first persistence milestone.
- **Rationale:** The specs explicitly prefer JSONL or s-expressions over early SQLite lock-in. This repository is Emacs Lisp-first, so readable s-expressions are simpler to debug in tests and easier for novice contributors to inspect and repair.
- **Date/Author:** 2026-03-07 / Codex

- **Decision:** Treat the pre-existing edit to `.wigg/IMPLEMENTATION_PLAN.md` as intentional local work and continue the audit against the current working tree.
- **Rationale:** Concrete Step 1 allows intentional local changes, and this run's task is to update the ExecPlan itself. Resetting or ignoring that file would violate the instruction to rely on the current tree and not rewrite history.
- **Date/Author:** 2026-03-07 / Codex

## Artifacts and Notes

  - `git status --short`
    ```text
     M .wigg/IMPLEMENTATION_PLAN.md
    ```
  - `rg --files .wigg/specs`
    ```text
    .wigg/specs/03_ui_ux.md
    .wigg/specs/02_architecture.md
    .wigg/specs/04_agent_loop.md
    .wigg/specs/01_overview.md
    .wigg/specs/06_tools.md
    .wigg/specs/05_providers.md
    .wigg/specs/benedict-assistant.md
    .wigg/specs/07_harness_and_skills.md
    ```
  - `nix run .#test -- test/benedict-session-test.el test/benedict-agent-loop-test.el test/benedict-chat-integration-test.el test/benedict-tools-test.el`
    ```text
    warning: Git tree '/Users/scotttrinh/github.com/scotttrinh/benedict' has uncommitted changes
    ................................................................................

    Ran 83 tests in 0.985 seconds
    ```

## Outcomes & Retrospective

Placeholder for the final implementation summary, remaining gaps, production risks, and lessons learned after the feature is complete.

## Context and Orientation

The current package entry point is `benedict.el`. It defines the package groups and faces, loads provider implementations, and connects the session runtime to the tool registry by assigning `benedict-session-tool-invoke-fn` after `benedict-session` and `benedict-tools` load.

The current runtime lives in `benedict-session.el`. A “session” is an in-memory `cl-defstruct` that stores messages, draft state, telemetry, loop counters, current provider/model, and attached frontends. The runtime already exposes event hooks, request dispatch, streaming accumulation, tool execution, repetition detection, and checkpoint logic. It does not currently persist sessions to disk and it stores messages as loose property lists rather than a canonical typed format.

The current UI entry point is `benedict-chat.el`. It opens the `*Benedict Chat*` buffer, mounts the VUI root component from `components/benedict-vui-root.el`, sends prompts, listens to session events, and currently handles checkpoint approvals with `y-or-n-p`. Supporting modules such as `benedict-chat-profiles.el`, `benedict-chat-status.el`, `benedict-chat-compose.el`, and the files under `components/` provide provider/model selection, compose flow, and block renderers.

The current tool system lives in `benedict-tools.el`. It already supports tool registration, schema encoding, several built-in tools such as `project-search`, `read-file`, `find-files`, `write`, `edit`, and `exec-elisp`, plus a configurable permission predicate. What is missing is a separate harness object that owns scope, budgets, audit events, and structured denials as a first-class contract rather than as ad hoc checks around the tool call.

Provider adapters live in `benedict-provider.el` and the provider-specific files `benedict-provider-openrouter.el`, `benedict-provider-vercel.el`, `benedict-provider-gemini.el`, `benedict-provider-ollama.el`, and `benedict-provider-fake.el`. These providers currently accept provider-ready request plists. The specs require them to remain adapters, not become the source of truth for transcript history.

Tests already cover the most relevant surfaces. `test/benedict-session-test.el` exercises session behavior, `test/benedict-agent-loop-test.el` covers the loop/checkpoint skeleton, `test/benedict-tools-test.el` covers permission behavior, `test/benedict-chat-integration-test.el` covers end-to-end chat flow with the fake provider, and the `test/benedict-vui-*.el` files cover individual UI components. Extend those tests instead of inventing a new test style.

Terms used in this plan:

“Canonical message model” means a provider-independent Emacs Lisp structure for a chat item such as a user message, assistant text, thinking block, tool call, tool result, checkpoint entry, provider change, or custom extension event. It is the only format that should be persisted to disk.

“Harness” means the safety layer that decides whether a tool call is allowed, denied, or requires scope expansion. It enforces path, buffer, command, network, and budget limits and emits structured audit events.

“Transcript store” means the disk-backed persistence layer that saves and loads canonical session entries. It is not a provider payload cache.

“Progressive disclosure” means instruction loading should discover candidate skills/specs cheaply and only load full file bodies when the task clearly needs them or the user explicitly asks for them.

## Interfaces and Dependencies

Use only the repository’s current stack plus standard Emacs Lisp libraries already aligned with the project: `cl-lib`, `subr-x`, `json`, `project`, `seq`, `map`, `lgr`, and the existing VUI components. Do not introduce a database dependency for the first milestone.

At the end of this work, the following modules and functions should exist:

`benedict-message.el`
Defines constructors, predicates, and translation helpers for canonical entries. At minimum:

```elisp
(cl-defstruct (benedict-message (:constructor benedict-message-create))
  id kind role blocks metadata timestamp)

(defun benedict-message-user-text (text &optional metadata) ...)
(defun benedict-message-assistant-text (text &optional metadata) ...)
(defun benedict-message-tool-result (tool-call-id name status content &optional details) ...)
(defun benedict-message->provider-message (message provider-id) ...)
```

`benedict-event.el`
Defines a stable event payload builder so runtime, UI, and tests do not rely on ad hoc property lists:

```elisp
(cl-defstruct (benedict-event (:constructor benedict-event-create))
  type session-id timestamp payload)
```

`benedict-harness.el`
Owns scope, budgets, permission decisions, and audit events:

```elisp
(cl-defstruct (benedict-harness (:constructor benedict-harness-create))
  scope budgets permission-predicate audit-log)

(defun benedict-harness-authorize-tool-call (harness tool-spec args session) ...)
(defun benedict-harness-record-effect (harness effect-plist session) ...)
(defun benedict-harness-request-scope-expansion (harness request session) ...)
```

`benedict-store.el`
Owns provider-agnostic persistence using s-expressions under a session directory such as `.benedict/sessions/` or another project-local/customizable root:

```elisp
(defun benedict-store-session-path (session-id root) ...)
(defun benedict-store-save-session (session) ...)
(defun benedict-store-load-session (path) ...)
(defun benedict-store-append-entry (session entry) ...)
```

`benedict-instructions.el`
Owns session bootstrap from `AGENTS.md`, `SKILL.md`, and `.wigg/specs/`:

```elisp
(defun benedict-instructions-discover (root) ...)
(defun benedict-instructions-select (discovered task-text) ...)
(defun benedict-instructions-build-system-prompt (selection) ...)
(defun benedict-instructions-bootstrap-session (session &optional task-text) ...)
```

`benedict-session.el`
Must stop treating provider-shaped plists as the canonical source of truth. Update or add these functions:

```elisp
(defun benedict-session-add-entry (session entry) ...)
(defun benedict-session-entries-chronological (session) ...)
(defun benedict-session-build-provider-request (session) ...)
(defun benedict-session-attach-harness (session harness) ...)
(defun benedict-session-save (session) ...)
(defun benedict-session-load (path) ...)
```

`benedict-tools.el`
Should keep `benedict-tools-register` and built-in tool functions, but `benedict-tool-invoke` must accept session or harness context and return the richer result contract the specs require:

```elisp
(defun benedict-tool-invoke (tool-id args &key session harness) ...)
```

`benedict-chat.el` and `components/`
Must subscribe to structured events and render checkpoint/audit/session markers in the buffer. The chat layer should expose interactive commands for at least session save/load/resume, branch later if implemented, and checkpoint continue/stop without minibuffer-only prompts.

## Plan of Work (Milestones)

Milestone 1 is the contract refactor. Add `benedict-message.el` and `benedict-event.el`, then refactor `benedict-session.el` so sessions append canonical entries instead of raw provider-shaped message plists. Keep compatibility shims only where tests need temporary bridging. Update request building so provider adapters receive translated provider-ready messages derived from canonical history. At the end of this milestone, `test/benedict-session-test.el` and `test/benedict-agent-loop-test.el` should pass using the new internal model, and no provider module should be responsible for canonical transcript storage.

Milestone 2 is the harness boundary. Add `benedict-harness.el`, move permission resolution and denial metadata out of the middle of `benedict-tools.el`, and route all session-driven tool execution through the harness before the tool implementation runs. Encode scope as explicit paths, buffers, commands, and network rules; encode budgets as turn/time/token/tool caps. Represent denials and scope expansion requests as structured tool results or checkpoint entries, never as silent failures. At the end of this milestone, a denied tool call should still leave a recoverable, human-readable result in the session transcript and an audit event in the UI/test state.

Milestone 3 is persistence. Add `benedict-store.el` and make session save/load explicit, deterministic, and idempotent. Persist canonical entries, provider/model changes, harness audit items, and loaded instruction metadata. Keep the on-disk format simple: one session directory per session, a transcript file of s-expressions, and a metadata file if needed. Add tests that save a session built with the fake provider, reload it, rebuild a provider request, and verify that the reloaded transcript still dispatches correctly.

Milestone 4 is instruction bootstrap. Add `benedict-instructions.el` and integrate it into session creation from `benedict-chat--init-buffer` or a session bootstrap helper. Discovery order must match the spec: `AGENTS.md`, relevant `SKILL.md`, `.wigg/specs/`, then user overrides. Use progressive disclosure: always discover candidate files, but only load full bodies for selected skills/specs. At the end of this milestone, a new chat in this repository should automatically include the local agent guidance and the relevant spec content without the user manually pasting those files into the prompt.

Milestone 5 is UI integration. Replace `y-or-n-p` checkpoint handling in `benedict-chat.el` with persistent chat-visible blocks rendered through the VUI tree. Add components or extend existing ones such as `components/benedict-vui-tool-result-block.el`, `components/benedict-vui-status-bar.el`, and `components/benedict-vui-conversation-view.el` so the user can see audit events, checkpoint reasons, loaded instruction sources, and saved-session state. Keep the UI event-driven: no component should need to inspect private session slots directly if the event/state layer can expose what it needs.

Milestone 6 is validation and cleanup. Update README-facing behavior only after the tests pass. Ensure all new public functions have docstrings, all new files start with `-*- lexical-binding: t; -*-`, and `benedict.el` or the appropriate modules `require` the new files in a load-order-safe way. This milestone is complete when the fake-provider manual flow and the Nix test/lint commands both succeed.

## Concrete Steps

Run all commands from the repository root: `/Users/scotttrinh/github.com/scotttrinh/benedict`.

1. Inspect the current state before changing code.

   ```sh
   git status --short
   rg --files .wigg/specs
   nix run .#test -- test/benedict-session-test.el test/benedict-agent-loop-test.el test/benedict-chat-integration-test.el test/benedict-tools-test.el
   ```

   Expected result: `git status --short` is empty or only shows intentional local work; `rg --files .wigg/specs` lists the seven numbered spec files plus `benedict-assistant.md`; the test command exits `0`. If the test command already fails before edits, copy the failing ERT names into `Surprises & Discoveries` before proceeding.

2. Implement the canonical entry layer and refactor session internals.

   Edit `benedict-session.el` and add `benedict-message.el` plus `benedict-event.el`. Then run:

   ```sh
   nix run .#test -- test/benedict-session-test.el test/benedict-agent-loop-test.el
   ```

   Expected result: exit `0`, with an ERT summary ending in all tests passing. If failures mention stale plist field names such as `:tool-calls` or `:content`, add temporary translation helpers rather than rewriting multiple callers blindly.

3. Implement the harness and migrate tool execution through it.

   Edit `benedict-tools.el`, add `benedict-harness.el`, update the session tool path, and add or extend focused tests, likely in `test/benedict-tools-test.el` and `test/benedict-session-test.el`.

   ```sh
   nix run .#test -- test/benedict-tools-test.el test/benedict-session-test.el test/benedict-agent-loop-test.el
   ```

   Expected result: exit `0`. A denied tool call should now produce a passing assertion on structured denial metadata rather than a raw thrown error unless the test is explicitly checking the interactive fallback path.

4. Implement persistence and reload behavior.

   Add `benedict-store.el`, wire save/load entry points, and create targeted persistence tests such as `test/benedict-session-store-test.el` if coverage does not fit cleanly into existing files.

   ```sh
   nix run .#test -- test/benedict-session-test.el test/benedict-chat-integration-test.el
   ```

   Expected result: exit `0`. The chat integration test should still pass after a session reload path is introduced.

5. Implement instruction bootstrap and UI checkpoint rendering.

   Edit `benedict-chat.el`, `benedict-chat-profiles.el`, the new `benedict-instructions.el`, and the relevant files under `components/`.

   ```sh
   nix run .#test -- test/benedict-chat-integration-test.el test/benedict-vui-root-test.el test/benedict-vui-conversation-view-test.el
   ```

   Expected result: exit `0`. The UI should display checkpoint and audit state in-buffer; failures that only mention snapshot-like text mismatches usually mean the new structured state is correct but a renderer or test fixture has not been updated.

6. Run the full project verification pass.

   ```sh
   nix run .#lint
   nix run .#test
   ```

   Expected result: both commands exit `0`. For `nix run .#test`, expect the ERT runner to report all test files passing with no unexpected failures. For `nix run .#lint`, expect no `checkdoc`, packaging, or formatting errors. Any non-zero exit code is a release blocker for this milestone.

7. Perform a manual fake-provider acceptance run inside Emacs.

   Start Emacs in the repo, evaluate Benedict, set the fake provider, open a chat, and send a prompt that triggers at least one tool call or checkpoint-worthy loop.

   Human-verifiable result:

   - The chat buffer opens as `*Benedict Chat*`.
   - The session shows loaded instruction sources from `AGENTS.md` and `.wigg/specs/`.
   - A tool call creates a visible tool result block plus an audit/checkpoint block when limits are hit.
   - Saving and reloading the session preserves the visible conversation and still allows another prompt to be sent.

## Validation and Acceptance

The feature is accepted only if all of the following are true:

Running

```sh
nix run .#lint
nix run .#test
```

from `/Users/scotttrinh/github.com/scotttrinh/benedict` exits with status `0`.

Running

```sh
nix run .#test -- test/benedict-session-test.el test/benedict-agent-loop-test.el test/benedict-tools-test.el test/benedict-chat-integration-test.el
```

also exits with status `0`, proving the core runtime, harness, tool path, and chat integration still work together.

Revision Note (2026-03-07 15:43Z): Marked the initial audit milestone complete after running the baseline repo-state and targeted test commands, and recorded the resulting evidence and working-tree observation for the next implementation run.

Manual acceptance in Emacs must show the following behavior:

- Opening a new Benedict chat automatically includes project-local instruction context from `AGENTS.md` and discovered `.wigg/specs/` material.
- Sending a prompt with the `fake` provider produces a visible assistant response without crashing the VUI.
- If a tool call is denied by the configured harness policy, the transcript shows a structured denial result rather than disappearing or only printing an error in `*Messages*`.
- If a checkpoint is reached, the chat buffer shows a persistent checkpoint block with a way to continue or stop; the flow must not depend solely on an ephemeral `y-or-n-p` prompt.
- Saving the session writes a provider-agnostic transcript to disk; loading that transcript restores the conversation and allows another prompt to complete successfully.

Failure modes to watch for:

- “Unknown tool” or raw plist shape errors after the message-model refactor usually mean a caller is still constructing provider-specific message payloads too early.
- A session that reloads but cannot dispatch often indicates provider/model metadata was not persisted as an explicit canonical entry.
- UI updates that only appear after a manual refresh usually mean a session event was emitted but not translated into root component state.

## Idempotence and Recovery

Each milestone should be safe to rerun. File creation must use deterministic paths and overwriting behavior that replaces only the generated artifact for the active session, never unrelated project files.

For persistence work, write to a temporary file and rename atomically into place. If save fails halfway, the previous transcript file must remain readable. Do not delete an old transcript until a replacement has been fully written and parsed successfully in a smoke check.

For the session/message refactor, keep narrow compatibility helpers while tests migrate. That is safer than changing every consumer in one pass. Remove the shims only after the full test suite passes.

For harness work, preserve the existing interactive approval fallback until the structured harness path is fully wired. If a new permission predicate or scope rule misbehaves, the recovery path is to disable the harness custom variable or return to the legacy prompt path while keeping audit logging enabled.

For UI checkpoint changes, keep a temporary command that can continue or stop the session even if the checkpoint renderer is broken. A broken visual control should not trap the session in the `checkpoint` state with no escape hatch.

If a step fails halfway, record the failure in `Surprises & Discoveries`, revert only the incomplete change you made, rerun the targeted test command for that milestone, and continue from the last known green state. Never use destructive repository-wide rollback commands when a smaller file-level revert is sufficient.

## Artifacts and Notes

Important repository evidence gathered while drafting this plan:

- `.wigg/specs/01_overview.md`, `.wigg/specs/02_architecture.md`, `.wigg/specs/03_ui_ux.md`, `.wigg/specs/04_agent_loop.md`, `.wigg/specs/05_providers.md`, `.wigg/specs/06_tools.md`, and `.wigg/specs/07_harness_and_skills.md` collectively require a canonical runtime contract, a durable session store, a real harness boundary, and startup instruction loading.
- `benedict-session.el` already contains loop state, repetition detection, checkpoint checks, draft streaming, and event emission. Reuse that spine.
- `benedict-chat.el` currently handles checkpoints with `y-or-n-p`; replace that with chat-visible checkpoint UI.
- `benedict-tools.el` already contains built-in tools and permission predicate support; evolve it into a harness-driven execution path instead of rewriting the tool catalog.
- Existing validation anchors are `test/benedict-session-test.el`, `test/benedict-agent-loop-test.el`, `test/benedict-tools-test.el`, and `test/benedict-chat-integration-test.el`.

When implementation is complete, append the final test transcripts and one saved-session file example here so a novice can compare their result directly against a known-good artifact.
