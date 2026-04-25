# EPIC-001: Extract the Benedict Kernel

## Purpose

Benedict has grown a useful set of pieces: sessions, messages, providers, tools,
approvals, a safety harness, persistence, chat buffers, and VUI components. The
problem is not that these pieces are useless. The problem is that the current
center of gravity is still too close to "AI chat in Emacs" instead of an
Emacs-native agent runtime with chat as one frontend.

This epic defines the next phase of work: extract, rewrite, or replace the true
kernel of Benedict so the system has a small, testable control-plane runtime.

This does not need to be a literal mechanical extraction. We should reuse
existing code when it still fits the new architecture, but we should be willing
to rewrite kernel code from the target model rather than preserve accidental
structure.

Backwards compatibility is explicitly not the priority for this epic. The
priority is to define a solid, coherent kernel interface that can become the
foundation for the rest of the system. If current chat behavior, tests, or
module boundaries need to break temporarily to get the interface right, that is
acceptable.

## Working Thesis

Benedict is a session runtime with frontends.

The kernel owns:

- session lifecycle
- canonical transcript state
- provider request/response flow
- outer run state and explicit inner turn state
- first-class turn execution contexts
- control ownership and yields between model, harness, and user
- tool call execution
- loop continuation policy
- outstanding turn yields, including approval requests
- runtime events
- harness/policy integration

Everything else is downstream:

- chat buffers are a frontend
- VUI is a renderer
- providers are adapters
- tools are registered capabilities
- workers are a future tool/backend type
- plugins are future bundles of capabilities and guidance
- persistence is storage over kernel state

## Desired Shape

Introduce a compact `benedict-core.el` module that exposes the public runtime
contract. It should be small enough to understand as the "agent loop kernel,"
but it should not become a mega-file that absorbs all supporting definitions.

The core interface is the deliverable. The implementation underneath can be
incomplete, fake-backed, or temporarily disconnected from old UI flows as long
as the API, state model, events, and tests establish the right foundation.

Supporting modules may remain separate:

- `benedict-message.el`: canonical transcript entries
- `benedict-turn.el`: active and completed model-turn execution contexts
- `benedict-session.el`: session struct and basic state mutation
- `benedict-event.el`: stable runtime events
- `benedict-provider.el`: provider registry and dispatch protocol
- `benedict-tools.el`: tool registry and invocation protocol
- `benedict-harness.el`: scope, budget, policy, and audit enforcement

The intended dependency direction is:

```text
frontends / UI / persistence / workers
  -> benedict-core
    -> session, message, provider, tools, harness, events
```

`benedict-chat.el` should eventually call into `benedict-core.el` rather than
owning or shaping loop behavior.

## Module Responsibilities

The kernel boundary is only useful if each module has a sharply limited job.
The intended responsibilities are:

- `benedict-message.el`: own the canonical transcript model and helpers for
  manipulating messages, blocks, roles, metadata, and display-friendly
  projections. It should not know about provider auth, transport, or provider
  wire shapes.
- `benedict-provider.el`: own the provider registry and abstract provider
  protocol. This is the sibling abstraction to `benedict-message.el` that
  bridges canonical transcript state to provider-specific request/response
  formats and transport behavior.
- `benedict-provider-*.el`: own provider-specific translation, auth, request
  construction, response decoding, streaming delta handling, API affordances,
  and cancellation for each concrete provider.
- `benedict-core.el`: own the agent loop, outer run state, active-turn
  lifecycle, yields, tool orchestration, and control ownership. Core should
  reason in canonical terms and call provider adapters through the provider
  protocol, not assemble or parse provider wire formats itself. Core creates
  turns, advances their state, attaches messages/results/yields to them, and
  completes or cancels them.
- `benedict-turn.el`: own the first-class model-turn execution context. A turn
  represents one logical unit of work from user input through final assistant
  response, policy stop, cancellation, or error. It owns transient inner state:
  control-owner/turn-state, message IDs that belong to the turn, prompt and
  outcome message IDs, outstanding turn yields, request/draft linkage, usage and
  timing telemetry, phase, and turn-local metadata. It should expose small
  mutation helpers for adding message IDs, setting state, creating/removing
  yields, marking completion, and producing display/store projections.
- `benedict-session.el`: remain a session data structure and mutation layer for
  in-memory state. It stores canonical transcript entries, configuration,
  completed turns, and at most one active turn. It should not own provider loop
  policy, turn-state transitions, outstanding turn yields, or provider
  translation logic once the kernel boundary is in place.
- `benedict-tools.el`: own tool registry, tool specs, invocation, and tool
  authorization helpers.
- `benedict-harness.el`: own scope, budgets, policy, and audit enforcement for
  tool execution decisions.
- `benedict-event.el`: own the stable runtime event data model used by the
  kernel, tests, logs, and frontends.
- `benedict-store.el`: own persistence and reload of session state, completed
  turn records, and active-turn recovery when supported, separate from runtime
  loop behavior.
- `benedict-credentials.el`: own credential lookup and provider-auth material
  management.
- `benedict-http.el`: own HTTP transport helpers shared by provider
  implementations.
- `benedict-flywire.el`: own the Flywire integration layer, if present, as a
  transport or coordination adapter rather than kernel logic.
- `benedict-instructions.el` and `benedict-context.el`: own instruction and
  context assembly helpers that feed session or provider configuration without
  taking over loop control.
- `benedict-logging.el`: own logging and diagnostics plumbing.
- `benedict-errors.el`: own shared error types and error-reporting helpers.
- `benedict-chat.el` and `benedict-chat-*.el`: own chat UI orchestration,
  buffer interaction, navigation, compose behavior, status display, and other
  frontend concerns. These modules should render or invoke core state, not
  implement the agent loop themselves.
- `components/benedict-vui-*.el`: own VUI rendering components and stateful UI
  widgets. They should render explicit turn records and user interaction
  affordances without inferring turn boundaries from a flat message list or
  owning the runtime contract.
- `test/*.el`: own executable specifications for the modules they cover. Tests
  are not runtime dependencies, but they are part of the contract surface and
  should mirror the boundaries above.

## Non-Goals

This epic should not attempt to complete the full personal agent architecture.
Specifically, defer:

- preserving all existing chat behavior during the first kernel pass
- maintaining compatibility wrappers for every old session/chat function
- remote VM workers
- artifact sync from transient sandboxes
- plugin package format
- messaging gateways
- durable memory taxonomy
- built-in budget, compaction, or checkpoint policy
- runtime self-modification
- advanced transient approval UI
- full persistence redesign

Those systems should be built after the kernel has a stable contract. During
this epic, it is better to leave an old path broken or temporarily unwired than
to compromise the kernel API to preserve it.

## Core Runtime Contract

The first version of `benedict-core.el` should make the headless runtime easy
to exercise without chat buffers, VUI, Flywire, or storage.

This contract should be designed from the target architecture, not from the
current call graph. Existing function names and control flow are useful
references, but they should not dictate the public interface.

Candidate public API:

```elisp
(benedict-core-create-session &rest options)
(benedict-core-add-user-input session text &optional metadata)
(benedict-core-run session &rest options)
(benedict-core-step session)
(benedict-core-continue session)
(benedict-core-resume session yield-id decision)
(benedict-core-stop session)
```

This API can change during implementation, but the goal should remain stable:
a caller can create a session, add input, run the loop, observe events, resolve
outstanding turn yields, and inspect final transcript state without creating a
chat buffer.

The important interface shape is not the exact function names. It is that the
core exposes the current outer run state, the active turn when one exists, the
active turn's inner state, and any outstanding turn yield that must be resolved
before execution can continue. Callers should not reconstruct "the current
turn" by scanning messages.

## Control Flow Model

The kernel should distinguish between the outer run lifecycle and the inner
model-turn lifecycle. The inner lifecycle is represented by a first-class
`benedict-turn` object, not by ambient conventions over message order.

A normal assistant message is a conversational yield. A tool call is an
execution yield. Both pause control flow, but they have different semantics:

- final assistant text yields from the model to the user and completes the
  current turn
- a tool call yields from the model to the harness with the expectation that the
  harness will return a tool result or another structured outcome
- an approval request yields from the harness to the user because the harness
  cannot complete its response without an external decision
- a tool result yields from the harness back to the model and allows the logical
  model turn to continue
- plugins may create other user-facing yields, such as budget reviews,
  compaction reviews, phase boundaries, or continuation prompts

This means a provider response containing tool calls does not simply "end" the
model's turn. It transfers control to the harness inside the same logical turn.
The turn only completes when the model produces a final response, the harness
or policy stops the run, or the user cancels. All messages, tool calls, tool
results, yields, request handles, draft state, and telemetry produced while
servicing that user input should be associated with the active turn.

Tool calls should pass through a guarded action pipeline before execution.  The
model proposes a tool call, but the kernel/harness/plugins transform that
proposal into actions describing what the kernel should do next.  Policy is one
kind of pipeline stage, not a special-case mechanism: other extensions may
normalize arguments, attach metadata, narrow scope, request a review, reject an
invocation, or ask the kernel to stop.

The important boundary is that pipeline stages do not directly mutate kernel
run state, active-turn state, transcript state, or outstanding turn yields.
They receive a small extension context plus the current invocation, then return
a structured action.  The kernel validates that action, attributes it to the
stage that returned it, and applies the corresponding effect to the active turn
and canonical transcript.

The action boundary should be a small disjoint shape:

```elisp
(:action update-invocation
 :invocation (:type tool-invocation
              :original-tool-call ...
              :tool-call ...
              :tool-spec ...
              :required-capabilities ...
              :metadata ...))

(:action execute-tool
 :invocation ...)

(:action request-yield
 :effect yield
 :yield-type approval-request
 :reason capability-approval-required
 :invocation ...)

(:action append-tool-result
 :effect tool-result
 :reason policy-denied
 :invocation ...)

(:action stop-run
 :effect stop
 :reason budget-exceeded
 :invocation ...)

(:action fail-stage
 :effect error
 :error ...
 :invocation ...)
```

The `tool-invocation` object should have a stable baseline shape but remain
extensible through metadata and extension-owned keys.  Tools only execute after
the kernel accepts an `execute-tool` action.  They should not understand
approvals, user prompts, policy reviews, stop conditions, or other pipeline
effects.

Each pipeline stage output should be validated at the boundary before the next
stage runs.  Validation failures should produce structured blame data and a
runtime event, not an ambiguous downstream error:

```elisp
(:type contract-violation
 :boundary tool-action-pipeline
 :stage benedict-harness-authorize
 :path (:invocation :tool-call :arguments :path)
 :expected string
 :actual 42)
```

This should be implemented with Benedict-local predicates and validators rather
than by depending on Custom-type validation.  `cl-defstruct` is still useful for
kernel-owned objects, but slot `:type` declarations should be treated as
documentation rather than runtime enforcement.

Tool call/result pairing is a kernel invariant.  When the model emits a tool
call, the session transcript should eventually contain exactly one paired tool
result for that call, except while the session is waiting on an unresolved
yield.  A non-executing action is not ignored: it either immediately becomes a
denied, skipped, cancelled, or failed tool result, creates a durable yield that
will later resolve into one, or stops the run after recording an appropriate
paired result.

Useful conceptual yields:

```elisp
(:yield tool-call
 :from model
 :to harness
 :tool-call ...)

(:yield approval-request
 :from harness
 :to user
 :approval ...)

(:yield tool-result
 :from harness
 :to model
 :result ...)

(:yield final-message
 :from model
 :to user
 :message ...)

(:yield policy-review
 :from plugin
 :to user
 :reason budget-limit
 :summary ...)
```

These may not become literal data structures, but the core state machine should
be designed as if control is always owned by one actor and yielded deliberately
to the next.

## Kernel State Model

The kernel should make both run state and turn state explicit, with different
owners. Session run state is the outer lifecycle. Turn state is inner execution
ownership and belongs to the active `benedict-turn`.

Run state describes the lifecycle of the overall request/run:

- `idle`: no active request or pending decision
- `running`: the loop is active
- `waiting`: execution is blocked on an outstanding turn yield
- `error`: the current run failed
- `cancelled`: the current run was stopped by the user

A completed model turn should normally return the session run state to `idle`.
Completion is a turn-level fact recorded on the turn, not a durable session
lifecycle state: a session can receive new user input and resume work at any
time.

Turn state describes who currently owns control inside the logical model turn:

- `model-dispatch`: the model/provider owns control
- `model-yielded-tool-calls`: the model yielded proposed tool calls to the
  harness
- `harness-evaluating`: the harness is evaluating policy/capabilities
- `harness-executing`: the harness is executing an allowed tool
- `harness-yielded-approval`: the harness yielded an approval request to the
  user
- `tool-results-ready`: tool results are available to feed back to the model
- `turn-complete`: the model turn is complete

The exact symbols may change, but the important part is that runtime state and
control ownership belong to the kernel and are not inferred from chat UI state.

`benedict-session` should not retain stale turn-state or outstanding-yield slots
after a run completes. Those are turn-owned facts. Session may expose accessors
for `active-turn` and completed `turns`, but it should not preserve old
session-level turn-state/yield APIs as compatibility shims. New code should call
turn/core APIs directly, and old callers should be migrated to the explicit
turn model.

The initial turn shape should be small and explicit:

```elisp
(cl-defstruct (benedict-turn (:constructor benedict-turn--create))
  id
  session-id
  created-at
  updated-at
  completed-at
  state
  phase
  prompt-message-id
  outcome-message-id
  message-ids
  outstanding-yields
  request-id
  draft-message-id
  usage
  elapsed
  metadata)
```

Messages remain canonical session transcript entries. Turns reference messages
by ID rather than owning duplicate message bodies. This keeps storage and
provider request assembly simple while giving the kernel and VUI an authoritative
turn boundary.

The session should contain:

```elisp
active-turn
turns
entries
run-state
```

`active-turn` is the only mutable live execution context. `turns` contains
completed turn records. A turn moves from `active-turn` to `turns` when it
finishes, is cancelled, or fails. The renderer and store should consume these
turn records directly rather than deriving them from entry order.

## Runtime Events

The kernel should emit stable events suitable for frontends, logs, tests, and
future worker orchestration.

Initial event vocabulary:

- `session-created`
- `message-added`
- `run-started`
- `turn-started`
- `request-started`
- `request-completed`
- `yield-created`
- `yield-resolved`
- `tool-started`
- `tool-completed`
- `approval-requested`
- `approval-resolved`
- `run-completed`
- `run-stopped`
- `run-failed`
- `state-changed`

Events should carry structured payloads and should not require a chat buffer to
be meaningful.

## Loop Semantics

The basic loop is:

1. Add the user message to the session transcript.
2. Create an active `benedict-turn` for that input and attach the user message
   ID as its prompt message.
3. Build a provider request from system prompt, tools, and transcript state.
4. Dispatch the request through the configured provider and associate the
   request/draft state with the active turn.
5. Normalize the provider response into canonical assistant message state and
   attach the assistant message ID to the active turn.
6. If there are no tool calls, mark the assistant message as the turn outcome
   and complete the turn.
7. If there are tool calls, record a model-to-harness tool-call yield on the
   active turn.
8. Run each tool call through the guarded action pipeline.
9. Validate each stage action, emit blame for contract violations, and apply
   kernel effects: update the invocation, execute a tool, append a tool result,
   create an outstanding turn yield, stop the run, or fail the stage.
10. Allow policy/plugins to inspect the run and optionally create additional
   yields or stop conditions.
11. Decide whether to continue, stop, or wait for user input.
12. Repeat until completion, unresolved yield, cancellation, or error.
13. Move the completed/cancelled/failed turn from `active-turn` into the
    session's completed turn list and return the session run state to `idle`
    when appropriate.

The loop decision should be testable independently from any UI.

## Policy And Approvals

The first kernel pass should keep approvals simple but structured.

Principles:

- read-only tools may run automatically when the guarded pipeline returns an
  accepted `execute-tool` action
- writes and high-risk invocations should produce `request-yield`,
  `append-tool-result`, or `stop-run` actions when the needed capabilities are
  not already approved
- approval is a harness-to-user yield, not a generic pause
- outstanding turn yields should live on the active turn, not in the session or
  frontend
- frontends should render and resolve approvals through core APIs
- headless sessions should be able to produce an in-band non-executed tool result,
  create a durable yield, or stop when approval is impossible

The existing harness is a useful starting point, but the kernel should treat it
as an action-producing authorization boundary, not as UI behavior.

Non-executing actions should be explicit about continuation behavior. A tool
invocation that must not execute can either be returned to the model as a
denied/skipped tool result, create a user-facing yield, or stop the run after
recording a paired tool result.  The action name should describe the kernel
operation, while the optional `:effect` field can classify the externally
visible outcome for renderers and logs.

Examples:

```elisp
(:action append-tool-result
 :effect tool-result
 :reason "Path outside project root"
 :invocation ...)

(:action stop-run
 :effect stop
 :reason "Attempted irreversible account action"
 :invocation ...)

(:action request-yield
 :effect yield
 :yield-type approval-request
 :reason capability-approval-required
 :required-capabilities (project-write)
 :invocation ...)
```

This avoids baking in the assumption that denial always ends the turn or always
returns control to the model.

Budget limits, compaction points, phase-boundary reviews, and similar
continuation controls should not be hard-coded as first-class kernel concepts.
They should be implemented by pipeline stages or plugins that inspect runtime
state and return structured actions.

## Testing Strategy

Add headless tests before adapting chat.

Minimum tests:

- a session can run one provider response with no tool calls and complete
- a run creates an active `benedict-turn`, attaches the user prompt message,
  attaches the assistant outcome message, and stores the completed turn
- a session can run a provider response with one auto-approved tool call
- tool results are appended as canonical messages
- tool result messages are attached to the active turn by ID
- tool calls are represented as model-to-harness execution yields
- tool-call, approval, and policy-review yields live on the active turn
- the loop continues after tool results when policy allows
- the loop stops when the assistant response has no tool calls
- repeated tool calls can be handled by policy/plugins rather than built-in
  kernel logic
- policy/plugins can create additional outstanding turn yields
- malformed pipeline stage output is rejected with structured blame that names
  the stage and boundary
- action validation happens after each pipeline stage, before the next stage or
  kernel effect runs
- approval-required tools create a harness-to-user yield
- outstanding turn yields can be resolved through core APIs
- a denied tool can either return a denied tool result, create another yield, or
  stop the run
- runtime events are emitted in a stable order for a simple run
- VUI turn rendering receives explicit turn records and does not infer turn
  boundaries by scanning flat message history

Use fake providers and fake tools heavily. Kernel tests should be fast and
should not require network, VUI, chat buffers, or Doom.

## Migration Plan

### Phase 1: Define The Kernel Contract

- Add `benedict-core.el`.
- Add `test/benedict-core-test.el`.
- Implement the smallest headless run path using fake provider/tool behavior.
- Define the first guarded action pipeline contract for tool invocation
  processing.
- Do not optimize for old chat compatibility.

Acceptance:

- `nix run .#test -- test/benedict-core-test.el` passes.
- The tests demonstrate a complete provider -> tool -> provider loop without a
  chat buffer.
- The core API feels like the primary way to drive Benedict, not an adapter over
  the old chat/session implementation.
- The core can report both the run state and the current turn/yield state.
- Tool pipeline stages return validated actions rather than directly mutating
  core state or returning untyped ad hoc data.
- Contract violations identify the failing stage, boundary, and path.

### Phase 2: Move Or Rewrite Loop Logic

- Move or rewrite loop orchestration out of `benedict-session.el`.
- Leave `benedict-session.el` focused on session data and mutation helpers.
- Move runtime mutation behind kernel-owned functions where invariants matter,
  especially run state, active-turn state, transcript appends, tool
  result-pairing, and outstanding turn yields.
- Delete, rename, or strand old compatibility functions when they obscure the
  new core model.

Acceptance:

- Existing agent loop tests either move to core tests or become compatibility
  tests.
- `benedict-session.el` no longer owns provider/tool loop policy.
- The new kernel tests are treated as the source of truth even if old chat tests
  need to be repaired afterward.

### Phase 3: Adapt Chat To Core

- Change `benedict-chat.el` to call `benedict-core` for sending, continuing,
  stopping, and resolving outstanding turn yields.
- Keep chat responsible for rendering, keymaps, compose buffers, and user
  interaction only.

Acceptance:

- Chat behavior remains functional.
- Core tests still pass without loading VUI/chat modules.

### Phase 4: Redraw The Provider Boundary

- Keep `benedict-message.el` purely canonical and remove provider translation
  duties from its public role.
- Move request construction, message serialization, response normalization,
  streaming delta decoding, auth strategy selection, and provider-specific API
  affordances into `benedict-provider.el` and the concrete provider modules.
- Make `benedict-core.el` depend on the provider protocol and canonical
  messages, not on provider wire payloads.
- Treat each concrete provider module as the owner of its own auth, wire
  format, policy quirks, and cancellation behavior.

Acceptance:

- `benedict-message.el` is canonically about transcript state, not provider
  transport.
- `benedict-provider.el` exposes a clean adapter seam that `core` can use
  without knowing provider-specific payload shapes.
- `benedict-core.el` can run the loop through the provider abstraction without
  needing to build or parse provider wire messages itself.
- Provider implementations own provider-specific auth and API-policy details.

### Phase 5: Replace Ambient Turns With Explicit Turn Objects

The goal of this phase is to fully replace the ad-hoc/ambient "turn" concept
with a first-class `benedict-turn` model. This is not a compatibility layer over
the old session fields. The implementation should migrate core, session, store,
chat, and VUI callers to the explicit turn model and remove the old
session-level turn-state/yield source of truth.

- Add `benedict-turn.el`.
- Define a `benedict-turn` struct for the live execution context and completed
  turn record.
- Include slots for at least: `id`, `session-id`, timestamps, `state`, `phase`,
  `prompt-message-id`, `outcome-message-id`, `message-ids`,
  `outstanding-yields`, request/draft linkage, usage/timing telemetry, and
  metadata.
- Add turn helper functions for creating turns, setting state, adding message
  IDs, marking prompt/outcome messages, adding/removing yields, checking
  whether a turn is blocked, completing/cancelling/failing a turn, and producing
  display/store projections.
- Update `benedict-session.el` so the session stores canonical transcript
  entries, configuration, completed turns, and at most one `active-turn`.
- Remove `turn-state` and `outstanding-yields` as independent session slots.
  Do not replace them with compatibility shims that keep ambient turn state
  alive. If old call sites need those values, migrate them to ask core or the
  active turn directly.
- Keep message bodies canonical in session entries. A turn references messages
  by ID and should not duplicate the message payloads.
- Update `benedict-core.el` so `benedict-core-run` creates an active turn,
  `benedict-core-step` advances that turn, tool-call and approval yields are
  stored on that turn, and turn completion moves the turn into the session's
  completed turn list.
- Update state-change events so turn-state transitions include the turn ID and
  mutate the active turn, not the session.
- Update yield events so `yield-created` and `yield-resolved` identify the turn
  that owns the yield.
- Update provider request/draft handling so request IDs, draft message IDs, and
  final outcome message IDs are associated with the active turn.
- Update `benedict-store.el` to persist completed turn records and, if supported
  in this phase, the active turn needed to resume a waiting session. The store
  should not serialize stale session-level turn-state or outstanding-yield
  fields.
- Update `components/benedict-vui-*.el` so turn rendering consumes explicit
  turn records from the kernel/session. Delete grouping heuristics whose purpose
  is to infer prompt/outcome/activity boundaries from a flat message list.
- Update `benedict-chat.el` and status modules to inspect the active turn and
  its yields through core/turn APIs. Chat should not infer active work from
  message order or own approval state.
- Update tests to assert the new ownership model directly.

Implementation guidance:

- Treat `benedict-turn` as the inner execution context, not as a provider
  message format and not as a UI-only projection.
- The session is still the canonical owner of message entries. The turn owns
  membership and lifecycle: which messages belong to this unit of work, which
  message is the prompt, which message is the final outcome, what state the
  inner loop is in, and which yields block continuation.
- Prefer breaking and migrating old call sites over preserving old APIs with
  adapter functions. This phase should leave the codebase organized around
  explicit turns, not around old session fields with new names.
- Keep the first turn model small. Do not introduce worker artifacts, checkpoint
  policy, or durable branch graphs in this phase. Those features should attach
  to explicit turns later.

Acceptance:

- A headless run creates exactly one active turn for a user input and stores it
  as a completed turn when the run finishes.
- `benedict-session` no longer has independent `turn-state` or
  `outstanding-yields` slots.
- Turn state transitions mutate the active `benedict-turn` and emit events that
  include the turn ID.
- Approval/tool/policy yields are stored on the active turn and resolved through
  core APIs.
- Provider request IDs, draft state, tool result message IDs, and final outcome
  message IDs are associated with the active turn.
- VUI receives explicit turn records and no longer infers turn boundaries from
  flat message history.
- Store output contains completed turn records rather than stale session-level
  turn-state/yield artifacts.
- Tests fail if a new module relies on ambient turn inference or session-level
  turn-state/yield state.

## Open Design Questions

- Should `benedict-core-create-session` wrap `benedict-session-create`, or should
  session creation remain outside the core facade?
- Should provider dispatch remain callback-based internally, or should the core
  normalize it behind a simpler continuation protocol?
- How much streaming behavior belongs in the kernel versus in frontend/provider
  adapters?
- What is the smallest yield object that supports tool calls, approvals,
  policy/plugin review prompts, chat UI, and worker orchestration later?
- Should approval-specific APIs exist, or should all external decisions flow
  through a generic `benedict-core-resume` operation?
- What is the smallest extension context that gives pipeline stages enough
  information without handing them the full mutable session or active turn?
- Should contract violations become failed tool results, run failures, or both,
  depending on which boundary produced them?
- How much active-turn persistence is required for restart/resume, and what
  fields can remain live-only until checkpointing is designed?

## Success Criteria

This epic is successful when Benedict has a boring, headless runtime kernel that
can be tested and reasoned about without the chat UI.

Specifically:

- the kernel can run a complete agent loop in tests
- the public core API is clear enough to build frontends, workers, and plugins
  against
- run state, explicit turns, turn state, and outstanding turn yields are explicit
  kernel concepts with clear owners
- frontend code no longer owns loop semantics, even if frontend migration is
  temporarily incomplete
- tool execution and approvals are kernel runtime concerns attached to the
  active turn
- future worker delegation has a clear place to attach
- the codebase feels organized around an Emacs-native agent runtime rather than
  an Emacs chat buffer with extra capabilities
