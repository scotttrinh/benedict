# Implementation Plan

## Goal

Raise the overall quality of the Benedict repository without expanding the product surface area.

This plan is intentionally biased toward:

- tightening contracts that already exist
- removing transitional or historical scaffolding
- improving test signal-to-noise
- reconciling docs with reality
- finishing work that is already substantially underway

It is not a feature roadmap. Work that only exists in aspirational specs should remain out of scope unless it is required to complete or stabilize code that already exists in-tree.

## Source of Truth

When deciding intended behavior:

1. code + matching spec win
2. code wins over stale README prose
3. aspirational spec text does not, by itself, force new feature work into scope

Practical rule:

- if code and spec already agree, update the README to match them
- if code is clearly mid-transition toward a spec and most of the implementation already exists, finish that transition
- if a spec describes a future system that does not materially exist yet, document the gap but do not treat it as an immediate implementation requirement

## Current Quality Themes

The current repo is strongest in:

- turn-centric VUI rendering
- session lifecycle basics
- fake-provider integration flows
- tool and provider smoke coverage

The current repo is weakest in:

- consistency between runtime contracts and provider dispatch
- consistency between harness/spec approval behavior and actual tool execution
- documentation accuracy
- removal of transitional compatibility paths
- test portfolio discipline

## Quality Principles

### 1. Runtime contracts must be real

If a session stores provider/model/tool state, dispatch and persistence must honor it end-to-end. Avoid "configuration-shaped" state that is ignored by the actual execution path.

### 2. Transitional code must either graduate or be removed

Compatibility shims, legacy render paths, and placeholder comments are acceptable only while actively migrating. Once a new path is clearly the intended one, the old path should stop accumulating support.

### 3. Tests should buy confidence, not inventory

Prefer:

- end-to-end chat/session/provider flows
- property tests for invariants
- thin unit tests for failure edges and normalization boundaries

De-emphasize:

- existence tests
- registry/listing trivia
- schema shape snapshots that restate implementation details without protecting behavior

### 4. Docs must describe the current product honestly

The README should help a user succeed with the code that exists today. It should not act as a second speculative spec.

## Workstreams

### Workstream 1: Contract Reconciliation

Objective: make the implemented runtime behavior match its existing non-aspirational contracts.

Primary targets:

- provider selection is session-scoped all the way through dispatch and abort
- persistence and replay continue to use canonical message forms
- harness approval behavior matches the currently implemented interaction model

Concrete tasks:

- done: provider dispatch/abort now resolve against request/handle provider metadata instead of global process state
- done: regression coverage now proves provider override is honored by the real chat send path, not only by resolution helpers
- done: v0.1 scope expansion is narrowed to the implemented deny-with-structured-result path; specs/README now describe audit-backed structured denials instead of a separate approval UI
- audit session events and request/result metadata so the VUI, persistence, and runtime are all consuming the same contract

Acceptance criteria:

- per-session provider/model configuration is exercised in end-to-end tests
- there is no silent fallback to unrelated global provider state
- harness approval behavior is described consistently across code, tests, and docs

Current note:

- scope denials are part of the harness/tool-result contract today; only per-tool approval requests enter `approval-pending`

### Workstream 2: Finish Near-Complete Transitions

Objective: close out abandoned or nearly-finished migrations that are currently leaving the repo in a mixed state.

Primary targets:

- VUI turn model migration
- tool/harness approval migration
- provider logging migration

Concrete tasks:

- remove or retire legacy VUI rendering paths once all current turn-centric behavior is covered through the canonical path
- finish replacing Vercel logging compatibility stubs with the current logging approach
- remove obsolete variables and stale comments once callers are migrated
- clean up misleading "skeleton", "placeholder", and "stub" commentary where the implementation is no longer stubbed

Acceptance criteria:

- every remaining compatibility shim has a clear reason to exist, or is removed
- comments describe what the code does now, not what it used to do
- the canonical turn model is the only path exercised by mainline tests

### Workstream 3: Test Portfolio Reshape

Objective: concentrate test effort on behavior that protects user-facing reliability and architectural invariants.

Target distribution:

- high-value end-to-end tests for complete chat/session flows
- property-based tests for stable invariants
- selective unit tests for parser/normalizer/error edges

Concrete tasks:

- inventory the current suite and classify tests as:
  - end-to-end
  - invariant/property
  - focused unit
  - low-value structural
- keep and expand tests that cover:
  - provider override through real dispatch
  - session save/load/replay
  - tool approval and denial recovery
  - turn progression from active to completed state
  - cancellation, recovery, and error propagation
- add or strengthen property tests for:
  - canonical message normalization round-trips
  - persistence round-trips
  - session/tool event ordering invariants where deterministic
- delete, merge, or demote shallow tests that only assert:
  - a function returns a string
  - a registry contains known symbols
  - an internal schema/property name exists without behavioral consequence

Acceptance criteria:

- the suite has a clear bias toward behavior over structure
- fragile implementation-detail tests are reduced
- important regressions are caught by fewer, more meaningful tests

### Workstream 4: Documentation Reconciliation

Objective: make the README a trustworthy guide to current behavior.

Concrete tasks:

- compare README claims against code and the non-aspirational portions of the specs
- update README sections where code and spec already agree
- remove or rewrite outdated claims about:
  - credential precedence
  - secret storage behavior
  - rendering architecture
  - provider capabilities
  - supported Emacs baseline
- keep future-looking material only when clearly labeled as planned and non-current

Acceptance criteria:

- users can follow the README without being misled by outdated behavior
- README no longer contradicts the code on implemented behavior
- spec/README disagreements that remain are explicitly future-looking rather than accidental

### Workstream 5: Boundary Tightening

Objective: reduce hidden coupling between modules without broad redesign.

Primary targets:

- runtime/tool injection
- session/frontend approval coupling
- provider/runtime boundaries

Concrete tasks:

- reduce reliance on global mutation for session tool invocation setup
- make runtime dependencies explicit where possible
- isolate UI-only behavior from headless runtime behavior
- review modules for places where "headless-friendly" code actually depends on frontend attachment

Acceptance criteria:

- session/runtime modules can be reasoned about without tracing buffer-local side effects through the UI
- approval and tool execution paths have explicit dependency points
- provider dispatch boundaries are testable without incidental global setup

## Sequenced Phases

### Phase 1: Audit to Decision

Produce a short reconciliation matrix covering:

- code behavior
- matching spec behavior
- README claim
- required action: keep, finish, narrow, or delete

This phase should end with explicit decisions on:

- session-scoped provider dispatch
- scope-expansion behavior for current quality work
- supported Emacs baseline
- credential precedence and storage wording

### Phase 2: Contract Repairs

Implement the minimum code changes needed to make existing contracts true:

- provider dispatch/abort complete
- done: approval/scope handling decision narrowed to structured scope denials
- event/request/result cleanup where required

Add end-to-end tests before removing old scaffolding.

### Phase 3: Transitional Code Removal

After contract repairs are covered:

- remove compatibility shims that no longer serve a live migration
- remove legacy rendering fallbacks that no longer represent intended behavior
- delete stale comments and obsolete knobs

### Phase 4: Test Suite Consolidation

Refactor the test suite around the new portfolio:

- strengthen e2e and property coverage
- collapse redundant unit tests
- remove low-signal structural checks

### Phase 5: Documentation Pass

Update:

- README
- inline commentary/docstrings where misleading
- any spec wording that accidentally implies already-shipped behavior when the code does not support it yet

## Candidate First Tasks

The best first batch is:

1. done: fix provider dispatch to respect session/request provider end-to-end
2. done: add an end-to-end regression test for provider override through actual dispatch
3. decide and implement the v0.1 scope-expansion behavior
4. remove or complete the Vercel logging compatibility layer
5. rewrite the README sections on credentials, rendering, and current capabilities

## Recent Progress

- 2026-03-15: provider dispatch and abort now honor per-request/per-handle provider metadata, closing the silent fallback to global `benedict-provider`.
- 2026-03-15: added regression coverage at two levels: provider helper dispatch/abort and chat-session send path with a provider override.
- Next slice: reconcile approval/scope-expansion behavior between harness specs and the current deny-with-structured-result implementation before touching README wording.

This batch improves correctness, test value, and documentation accuracy with minimal feature expansion.

## Out of Scope

Unless needed to complete in-progress work, this plan does not include:

- queued steering/follow-up support
- branching/forking UX
- subagents and delegation
- programmable loop policies
- extension middleware surface expansion
- broad new tool or provider features

Those remain future work unless a code path already present in the repo is clearly halfway through implementation and currently harming quality by being left incomplete.

## Definition of Done

This quality plan is complete when:

- major code/spec-aligned contracts are actually enforced by the implementation
- transitional code paths are either finished or removed
- the README accurately describes current behavior
- the test suite is visibly more behavior-oriented
- the repo is easier to reason about because fewer historical paths and hidden couplings remain
