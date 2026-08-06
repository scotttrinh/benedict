# EPIC-002: Worker Delegation Vertical Slice

## Purpose

Benedict now has the beginning of a headless control-plane kernel: sessions,
explicit turns, provider dispatch, tool execution, approval yields, and runtime
events. The next architectural step is to prove that the control plane can
delegate meaningful work to an isolated worker and reason about the result
without relying on a shared mutable environment or transcript replay.

This epic implements the first worker-plane vertical slice. The concrete slice
is a coding worker, because code changes exercise repo resources, command
execution, artifact return, review, and patch application. The worker protocol
must remain more general than coding work, though: repo snapshots are one
resource type, and patches are one artifact type. Future workers may return
draft emails, org updates, research notes, screenshots, browser traces, or other
reviewable artifacts.

The primary goal is not breadth. The primary goal is to validate the
control-plane-to-worker round trip:

1. The model asks Benedict to spawn a worker through the normal tool pipeline.
2. The control plane resolves and serializes the resources the worker needs.
3. Benedict runs a worker task loop whose tools execute through a bounded
   sandbox Emacs runtime.
4. The worker writes a structured artifact envelope.
5. The control plane ingests the envelope, attaches it to the session/turn, and
   presents it for review.
6. The user approves an explicit host-side effect, such as applying a patch.

## Working Thesis

Workers are task-scoped units of work with explicit input/output contracts. The
control plane owns the agentic loop: model dispatch, worker task state,
capability checks, approvals, runtime events, review, and final host mutation.
The worker backend owns isolated execution. In the default architecture, the
backend is a sandboxed Emacs tool runtime rather than an autonomous remote agent.

This distinction matters. Spawning a worker does not require copying the whole
agent brain into a remote VM. Benedict can create a child worker task and run
that task's model/tool loop from the control-plane Emacs process. When the
worker task calls tools, those tools are routed to a sandbox Emacs runtime that
has access only to the resources prepared for that worker.

For this epic, the control plane should send any required resources directly to
the sandbox runtime as serialized inputs. A worker should not need the user's
GitHub SSH key, a live Emacs session object, provider credentials, or ambient
access to the host checkout. This keeps the first slice honest about sandbox
boundaries and avoids designing around shared filesystem assumptions.

Emacs remains Benedict's runtime on both sides of the boundary:

- Control-plane Emacs owns the agent loop and Benedict kernel state.
- Sandbox Emacs owns the bounded tool runtime over prepared resources.
- The sandbox OS provides the machine-level isolation boundary.

Flywire is the expected transport/runtime foundation for the sandbox Emacs side.
Once Flywire has remote RPC support, Benedict should use it as a worker runtime
adapter rather than inventing a separate remote command protocol.

Remote GitHub access can be added later through explicit credential grants, but
the baseline contract should work without passing GitHub credentials into the
worker. For repository resources, the initial implementation should prefer
control-plane-prepared snapshots such as git bundles, archives, or copied test
fixtures. If a future backend needs direct GitHub access, it should receive a
typed, scoped, expiring credential grant rather than a broad user identity.

### Control Plane, Worker Task, And Runtime

Use these terms consistently:

- `worker task`: a bounded child task with a task prompt, resource list,
  capability envelope, backend/runtime handle, events, and expected artifact
  envelope
- `worker loop`: the model/tool loop for the worker task, owned by Benedict's
  control-plane kernel
- `worker runtime`: the Emacs process that executes tool calls against prepared
  resources
- `sandbox backend`: the system that provisions the worker runtime, resource
  mounts/copies, and artifact collection
- `artifact envelope`: the structured output returned from the worker task

The first implementation may fake the worker loop synchronously, but the target
model is not an opaque remote agent. The target model is a control-owned worker
task whose tools execute through a sandboxed Emacs runtime.

## Non-Goals

This epic should not attempt to build the full personal agent system.

Defer:

- multiple worker classes beyond the coding-worker slice
- messaging gateways
- temporal primitives
- recursive worker spawning
- durable memory beyond session/turn artifact references
- broad plugin packaging
- full remote VM fleet management
- full GitHub App credential lifecycle
- worker-side GitHub push or PR creation
- applying non-patch artifacts, such as email drafts or org updates
- automatic host mutation without explicit review/approval

## Core Concepts

### Worker Request

A worker request is the serialized task contract passed from the control plane
to a worker runtime/backend. It should be plain data, suitable for writing to
disk and transporting to a remote environment.

Initial shape:

```elisp
(:id "worker-001"
 :worker-class coding
 :task "Fix the failing auth test"
 :resources ((:type repo
              :id "benedict"
              :role primary
              :mount "/workspace/benedict"
              :access read-write
              :source (:type git-bundle
                       :path "resources/benedict.bundle")
              :checkout-ref "main"
              :base-commit "abc123"
              :metadata (:uri "git@github.com:scotttrinh/benedict.git"))
             (:type file
              :id "notes"
              :role context
              :mount "/context/notes.md"
              :access read-only
              :source (:type inline
                       :content "Relevant notes...")))
 :capabilities (project-read project-write project-execute)
 :artifact-root "artifacts/worker-001"
 :metadata (:session-id "ses-001"
            :turn-id "turn-001"))
```

Important constraints:

- `:resources` is a list. Cross-repo work is a first-class case.
- `repo` is one resource type, not the worker abstraction.
- Resource sources should be serialized inputs prepared by the control plane.
- Workers receive snapshots/bundles/copies, not live Emacs objects.
- Each resource has a stable `:id` used for tool routing and artifact
  attribution.
- Runtime-facing resources should include a sandbox `:mount` and `:access`
  mode once provisioned.
- Credential grants are optional future resource metadata, not baseline
  behavior.

### Resource Types

Minimum resource types for this epic:

- `repo`: a repository snapshot prepared by the control plane
- `file`: a supporting context file or generated instruction file
- `inline`: small structured context embedded directly in the request
- `artifact-root`: the directory where the sandbox runtime may write worker
  artifacts

Useful future resource types:

- `org-node`
- `mail-thread`
- `browser-state`
- `artifact`
- `secret-reference`

The first implementation only needs behavior for repo resources, but validators
should tolerate unknown future resource types by producing structured
unsupported-resource errors instead of assuming every resource is a repo.

### Workspace And Resource Scope

For a fully isolated remote sandbox, the machine boundary is the primary
security boundary. The sandbox should be provisioned fresh and should contain
only the resources the control plane sends. Even so, Benedict still needs an
explicit workspace/resource model for correctness, artifact attribution, and
local/fake backend safety.

Resource scope is not only about preventing access to host secrets. It also
answers:

- Which repo should this tool operate on?
- Which resources are read-only versus writable?
- Which artifact belongs to which resource?
- How should cross-repo patches be applied back to the host?
- How can fake/local tests behave like remote sandboxes without relying on
  ambient host paths?

Initial provisioned shape:

```elisp
(:resources
 ((:id "main"
   :type repo
   :mount "/workspace/main"
   :access read-write)
  (:id "dependency"
   :type repo
   :mount "/workspace/dependency"
   :access read-only)
  (:id "notes"
   :type file
   :mount "/context/notes.md"
   :access read-only)
  (:id "artifacts"
   :type artifact-root
   :mount "/artifacts/worker-001"
   :access write-only)))
```

The sandbox backend should enforce these access modes through provisioning when
possible, for example with read-only mounts or copied read-only resources.
Flywire-side path checks are still useful as defense-in-depth and for
local/fake backends, but they are not the main security boundary for properly
isolated remote workers.

### Artifact Envelope

A worker returns an artifact envelope. The envelope is a manifest, not a patch
file and not a transcript. It describes the worker outcome and points at
artifact files relative to the artifact root.

Initial shape:

```elisp
(:id "envelope-001"
 :worker-id "worker-001"
 :worker-class coding
 :status completed
 :summary "Fixed the failing auth test by normalizing the token branch."
 :artifacts ((:type patch-series
              :id "patches"
              :resource-id "benedict"
              :files ("0001-normalize-token-branch.patch"))
             (:type command-log
              :id "test-log"
              :file "test.log")
             (:type note
              :id "summary"
              :content "Ran focused auth tests."))
 :open-questions nil
 :escalations nil
 :metadata (:session-id "ses-001"
            :turn-id "turn-001"))
```

Important constraints:

- Artifact paths are relative to the artifact root.
- Artifact paths must not escape the artifact root.
- `patch-series` is one artifact type, not the envelope model.
- Unknown artifact types should remain inspectable/reviewable even when Benedict
  does not yet know how to apply them.
- The control plane should consume this manifest without replaying worker
  transcript text.

### Credential Strategy

The EPIC-002 baseline should not pass GitHub credentials into workers. The
control plane resolves required resources and sends serialized snapshots to the
worker backend.

Preferred baseline:

- local control plane authenticates to GitHub if needed
- control plane creates repo snapshots, git bundles, archives, or fixture copies
- sandbox Emacs receives only the prepared resources
- worker returns artifacts
- control plane performs final host-side effects after review

Future direct-fetch credential grants may include:

```elisp
(:credential-grants
 ((:type github-app-installation-token
   :resource-id "repo-a"
   :permissions (:contents read)
   :expires-at ...)
  (:type deploy-key
   :resource-id "repo-b"
   :access read-only
   :expires-at ...)))
```

These grants should be explicit, scoped to resources, short-lived when possible,
and auditable. They should not be represented as a broad ambient GitHub identity.

## Phase 1: General Worker Contract And Fake Backend

Goal: define the worker-plane data contract and exercise it headlessly.

Deliverables:

- Add `benedict-worker.el`.
- Define worker request creation, validation, and projection helpers.
- Define artifact envelope loading, validation, and projection helpers.
- Define resource validation for at least `repo`, `file`, and `inline`.
- Define artifact validation for at least `note`, `file`, `command-log`, and
  `patch-series`.
- Add a fake worker runtime that writes a valid envelope into an artifact root.
- Ensure all paths in requests/envelopes are relative where required and cannot
  escape their root.

Tests:

- a worker request can contain multiple repo resources
- a worker request can contain non-repo resources
- invalid resource shapes produce structured validation errors
- a fake runtime writes a valid artifact envelope on disk
- invalid envelope paths are rejected when they escape the artifact root
- unknown artifact types remain loadable as review-only artifacts
- a `patch-series` artifact is validated as an artifact type, not as the entire
  envelope

Acceptance:

- `nix run .#test -- test/benedict-worker-test.el` passes.
- No provider, chat buffer, VUI, GitHub credential, or real sandbox is required.
- A test can create a worker request, run the fake runtime, load the envelope,
  and validate the returned artifacts.

## Phase 2: Worker Delegation As A Core Tool

Goal: make delegation enter through the same kernel path as any other model
tool call.

Deliverables:

- Add a built-in general worker tool, likely `benedict.spawn_worker`.
- Tool arguments include `:worker-class`, `:task`, `:resources`, and requested
  `:capabilities`.
- The tool maps validated arguments into a worker task request.
- The tool creates or runs a child worker task managed by Benedict.
- Worker task tools execute through the configured worker runtime backend.
- Core records the worker result as a canonical tool result message containing
  an envelope reference and structured summary.
- Missing `worker-spawn` or resource capabilities create normal core approval
  yields.

Tests:

- a fake provider emits a `benedict.spawn_worker` tool call for a coding worker
- the core action pipeline approves the tool under granted capabilities
- the fake worker runtime receives tool calls and writes an envelope
- the transcript contains user input, assistant tool call, worker tool result,
  and final assistant response
- the completed turn references all messages created during delegation
- missing worker capabilities create an approval yield and resume correctly
- the provider continuation sees a tool result with an envelope reference, not a
  pasted worker transcript

Acceptance:

- `nix run .#test -- test/benedict-core-test.el test/benedict-worker-test.el`
  passes.
- A headless provider -> core tool pipeline -> worker task -> fake runtime ->
  artifact envelope -> provider continuation loop works without chat or VUI.

## Phase 3: Artifact Registry And Review Projection

Goal: make worker artifacts first-class reviewable session/turn state.

Deliverables:

- Add an artifact registry or worker artifact index on session/store metadata.
- Attach worker envelopes to the active/completed turn that produced them.
- Add helpers to list envelopes and artifacts by session, turn, worker, resource,
  and artifact type.
- Add a review projection that groups artifacts by type and reports warnings for
  missing or malformed artifact files.
- Persist artifact references through session save/load.

Tests:

- a worker envelope is attached to the active turn and remains discoverable after
  turn completion
- artifact lookup by turn id works without scanning message text
- artifact lookup by type returns mixed artifact envelopes correctly
- review projection includes summary, status, patch metadata, command logs, and
  warnings
- missing artifact files create review warnings rather than crashes
- session save/load preserves envelope references

Acceptance:

- The control plane can answer "what artifacts did this turn produce?" from
  structured state.
- Message text is not the source of truth for artifact discovery.

## Phase 4: Coding Artifact Application Boundary

Goal: prove that reviewed worker artifacts can become host mutations only
through an explicit apply operation.

This phase intentionally narrows to coding artifacts. Applying a patch series is
the only artifact effect required by EPIC-002. Other artifact types remain
review-only.

Deliverables:

- Add patch application helpers for `patch-series` artifacts.
- Select target checkout by artifact `:resource-id`.
- Support dry-run/check mode before mutation.
- Apply patches through a clear git boundary, such as `git am`.
- Return a structured apply result containing status, target repo, patch ids,
  command log, and error details.
- Emit audit/runtime events for host mutation attempts and outcomes.

Tests:

- a temp multi-repo workspace can receive a patch for the correct repo
- a patch targeting an unknown `:resource-id` is rejected
- dry-run succeeds without mutating the worktree
- approved apply mutates the target repo correctly
- failed patch application returns structured error data and useful logs
- patch paths cannot escape the target repo
- applying a patch requires explicit capability or approval

Acceptance:

- A headless end-to-end test can run a worker, ingest a patch-series artifact,
  dry-run it, approve it, and apply it to a temp checkout.
- No non-patch artifact is applied by this epic.

## Phase 5: Minimal VUI Review Surface

Goal: expose worker artifact results in Emacs without moving worker or artifact
logic into the frontend.

Deliverables:

- Add a VUI worker artifact/review component.
- Render worker status, summary, artifact list, warnings, and command/test logs.
- Show an apply affordance only for applicable `patch-series` artifacts.
- Render unknown artifacts and future artifact types as inspectable review-only
  items.
- Wire apply/reject callbacks to artifact APIs, not to shell commands in the UI.

Tests:

- VUI renders a mixed artifact envelope
- `patch-series` artifacts show an apply affordance
- `draft-email` or unknown artifact examples render as review-only
- apply callback calls the artifact application API
- failed/missing artifact states render without crashing
- VUI does not infer artifact ownership from flat transcript order

Acceptance:

- A user can inspect a worker result from chat/VUI and invoke the explicit patch
  application path.
- Chat remains a frontend over core/session/artifact state.

## Phase 6: Sandbox Emacs Runtime Backend

Goal: define Benedict's worker runtime adapter protocol and add the first
non-fake sandbox Emacs runtime implementation.

Flywire should be the preferred runtime transport once its remote RPC support is
available. Benedict should not implement its own remote RPC protocol in this
epic. Instead, Benedict should define the worker-runtime adapter it needs and
provide implementations for fake/local testing and Flywire RPC.

Deliverables:

- Define worker runtime operations:
  - prepare/start runtime
  - call tool
  - snapshot runtime state
  - collect artifacts
  - teardown runtime
- Serialize worker requests to backend input files.
- Provision prepared resources into the sandbox workspace.
- Start or connect to a sandbox Emacs runtime.
- Add a fake runtime adapter for fast contract tests.
- Add a local Flywire/runtime adapter suitable for integration tests.
- Add a Flywire RPC adapter once Flywire supports remote sexp RPC over stdio or
  loopback TCP.
- Ensure artifact collection runs on success and failure.

Runtime expectations:

- the control-plane Benedict kernel owns the worker task loop
- the sandbox Emacs runtime executes bounded tools over prepared resources
- the sandbox runtime does not receive provider credentials
- the sandbox runtime does not receive broad GitHub credentials by default
- runtime calls are serialized data, not live Elisp closures
- resource ids and mount/access metadata are available to the runtime
- machine-level sandboxing is the primary security boundary for remote workers
- optional Flywire-side workspace/path guardrails provide defense-in-depth and
  keep local/fake backends honest

Flywire requirements Benedict relies on:

- remote session creation with workspace/resource metadata
- synchronous tool/action calls over serialized RPC
- optional async calls and normalized events
- snapshot support for the remote Emacs runtime
- stdio over SSH as a secure first transport
- server-side policy hooks that can receive enough context to reason about
  action type, resource id, path, cwd, argv, and access mode
- no unauthenticated public network listener by default

Tests:

- runtime receives serialized request data, not live Emacs objects
- runtime receives prepared resources from the control plane
- runtime calls include resource ids rather than relying on ambiguous paths
- artifact collection runs after successful worker completion
- artifact collection runs after worker failure
- unsupported worker classes return structured errors
- local Flywire/runtime integration test is gated/skippable when environment support is
  unavailable

Acceptance:

- Runtime implementation can change without changing core/tool/artifact tests.
- The fake runtime remains the fast contract test backend.
- Remote Flywire support can be added behind the runtime adapter without
  changing worker request or artifact envelope contracts.

## Phase 7: Documentation, Events, And Policy Tightening

Goal: make the worker slice understandable and harden the behavioral contract.

Deliverables:

- Document worker request schema.
- Document artifact envelope schema.
- Document resource preparation rules and credential strategy.
- Document capability requirements for spawning workers and applying artifacts.
- Add a short walkthrough for "fix a failing test with a worker."
- Add stable runtime/audit events for worker spawn, worker completion, artifact
  ingestion, and artifact application.
- Update `PERSONAL_AGENT_IDEA.org` with what EPIC-002 proved and deferred.

Tests:

- documented schema examples parse and validate
- capability tests cover approved, denied, and missing-capability worker spawn
- artifact application tests cover approved and denied host mutation
- event ordering is stable for the core worker delegation loop

Acceptance:

- EPIC-002 can be marked complete because Benedict has a tested worker
  delegation slice, not merely worker abstractions.

## First Milestone

The first implementation milestone should cover Phases 1 and 2 together. Phase
1 defines the contract, but Phase 2 proves that the contract fits the existing
kernel.

Milestone acceptance test:

1. A fake provider asks to call `benedict.spawn_worker`.
2. Core approves the tool call under granted capabilities.
3. The control plane prepares serialized resources for the worker task.
4. The fake runtime receives worker tool calls and writes an artifact envelope
   and artifact files.
5. Core records a tool result that references the envelope.
6. The provider receives that tool result and returns a final assistant message.
7. The completed turn references the user prompt, assistant tool-call message,
   worker tool-result message, and final assistant outcome.

This test is the anchor for the epic. Later phases should strengthen one
boundary around this loop without replacing it.

## Success Criteria

This epic is successful when Benedict can complete a minimal but honest
control-plane-to-worker round trip:

- worker delegation is a normal core tool invocation
- worker inputs are serialized resources prepared by the control plane
- the control plane owns the worker task loop
- worker tools execute through a sandbox Emacs runtime adapter
- cross-repo resource lists are supported by the request model
- workers return structured artifact envelopes
- artifacts are attached to explicit turns and discoverable without transcript
  scanning
- coding worker patch artifacts can be dry-run and applied after explicit
  approval
- unknown/future artifact types remain reviewable without being applied
- tests cover each phase as a working vertical slice
