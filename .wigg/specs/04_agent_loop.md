# Agent Loop Specification

This document defines the autonomous loop logic that allows Benedict to perform multi-step tasks.

## 0. Core Idea: Agent Programs (Programmable Loop)

The "agent loop" is not a single hard-coded behavior. Benedict must support configurable, testable loop policies that determine how the agent thinks/acts/verifies and how it produces artifacts.

However, the runtime should start from a **small core**:
- prompt/continue
- stream assistant response
- execute tools
- continue until stop/tool boundary/checkpoint
- emit stable lifecycle events

More specialized behavior such as step graphs, subagents, or custom planning policies should layer on top of that core rather than be baked into its minimal contract.

An agent program is data (and optionally small amounts of Elisp) that configures:
- step sequence (observe/plan/act/verify/capture)
- budgets (turn/time/token/cost/tool-call limits)
- tool access by phase
- subagent spawning rules
- stop/continue/checkpoint conditions

## 1. The Loop Logic (`benedict-session.el`)

The Agent Loop is a state machine that drives the conversation forward until a termination condition is met.

**Cycle:**
1.  **Observe:** Collect message history, including the latest User message or Tool Result.
2.  **Plan/Think:** Dispatch request to LLM (optionally under a specific agent program phase).
3.  **Act:** Receive LLM response (text and/or tool calls).
    - If response is text only -> **Stop** (Task Complete).
    - If response contains Tool Calls -> **Execute**.
4.  **Execute:**
    - Parse tool calls.
    - Check harness policy (scope, budgets, sandbox).
    - Run Tools.
    - Append Tool Results to history.
    - **Loop:** Go back to Step 1.

### 1.1 Core Runtime Contract

The loop must expose a stable event sequence similar to:
- `agent-start`
- `turn-start`
- `message-start`
- `message-update`
- `message-end`
- `tool-started`
- `tool-updated` (optional)
- `tool-completed`
- `turn-end`
- `agent-end`

The UI, persistence layer, and extensions should be able to build on this without depending on runtime internals.

**Artifact-first completion:**
- The loop should prefer producing a durable artifact (file, buffer, draft, org capture) as the "result" of work.
- Persistence of the chat transcript is valuable but not required for v0.1 usefulness if artifacts are consistently produced.

## 2. Safety & Autonomy Constraints

To prevent runaway agents (infinite loops, excessive costs), the loop is bounded by strict constraints.

### 2.1 Limits (Configurable per Profile/Session)
- **`max-turns`**: Maximum number of autonomous steps allowed (default: ~5-10).
- **`max-time`**: Maximum wall-clock duration (default: ~60s).
- **`max-tokens`**: Maximum total tokens consumed in the session (optional).

### 2.2 Checkpoints
When a limit is reached, the loop enters the **`checkpoint`** state.
- **Behavior:** Execution pauses.
- **UI:** User is presented with a persistent checkpoint block in the chat UI, not only an ephemeral yes/no prompt.
- **Resolution:**
    - `y`: Reset counters/timers and continue.
    - `n`: Stop loop.

### 2.3 Repetition Guard
- The system monitors for identical consecutive tool calls (same tool, same args).
- **Trigger:** If detected, the loop terminates immediately with a `repetition` error to prevent "stuck" agents.

## 3. Tool Execution Flow

1.  **Parser:** Extract `tool_calls` from the LLM response message.
2.  **Validator:** Ensure tool exists in registry and args match schema.
3.  **Harness Policy Check (Primary Safety Mechanism):**
    - Validate that the tool call stays inside the sandbox scope (paths, buffers, commands).
    - Enforce budgets (turn/time/token/cost/tool-call caps).
    - Evaluate configured permission predicate (`tool`, `args`) when present.
      - `t`: allow.
      - `nil`: deny with structured result.
      - no predicate configured: use interactive approval fallback.
    - If the agent requests a privileged effect (scope expansion), prompt the user to approve *the scope change*.
      - If user denies scope expansion: feed back a structured "scope denied" tool result so the model can recover.
4.  **Invocation:**
    - Run the tool function (potentially in `flywire` sandbox).
    - Capture `stdout`/`return value` or `error`.
5.  **Result Formatting:**
    - Create a typed tool result message.
    - `tool_call_id`: Links back to the assistant's call.
    - `content`: The output of the tool.
    - `details`: Structured metadata for UI/persistence/extensions.
    - `actions`: Optional Emacs-native follow-up actions.
    - `effects`: Summary of what changed (files, buffers, subprocesses, network).

### 3.1 Queueing During Active Runs

The loop must support two classes of user input while busy:
- **steering** messages: delivered at the next safe interruption boundary
- **follow-up** messages: delivered after the loop would otherwise stop

This should be part of the runtime contract, not a UI-only trick.

## 4. Sub-Agents & Delegation

Complex tasks require specialized contexts. The Main Agent can spawn Sub-Agents.

- **Concept:** A "Main" agent (generalist) delegates a sub-task (e.g., "Research this error") to a specialized Sub-Agent.
- **Mechanism:**
    - Main agent calls a `delegate` tool.
    - A new, ephemeral `benedict-session` is created with a specific Profile (e.g., "Researcher") and restricted Tools.
    - The Sub-Agent runs its own loop.
    - Result is summarized and returned to the Main Agent as the tool output.
- **Safety:** Sub-Agents inherit (or have stricter) autonomy limits than the parent.

### 4.1 First-Class Subagents (v0.1 MVP direction)

Subagents are useful for context hygiene, but they are not a substitute for a clean core/runtime contract.

When introduced:
- A subagent runs in an isolated session with a narrow task and narrower tool access.
- The output contract is explicit: summary + optional artifacts (files/buffers/patches) + citations to local evidence when applicable.
- The main agent decides whether to merge subagent output into the main thread history.

The persistence layer must record subagent provenance explicitly.

## 5. Multi-Model Experiments

Users can verify results by running parallel checks.

- **Parallel Dispatch:** The system can dispatch the same prompt to multiple models (e.g., GPT-4 vs Claude 3) simultaneously.
- **Comparison:** The UI renders side-by-side or tabbed outputs.
- **Merging:** The user selects the best response to commit to the conversation history.

## 6. Telemetry & Environment Awareness

The agent requires implicit context to be effective.

- **Environment Telemetry:**
    - On session start, Benedict gathers lightweight metadata:
        - Open buffers (names, modes).
        - Project root structure (top-level files).
        - Recent files.
    - This "System Context" is prepended to the message history, giving the agent awareness of what the user is currently working on without explicit user action.
- **Usage Metrics:**
    - The session tracks elapsed time, token usage, and estimated cost per request.
    - This data is displayed in the UI and used to enforce `max-tokens` limits.

## 7. Loop Programming Interface (Ralph Wiggum Loop)

The system must allow defining and selecting an "agent program" per profile/session.

Requirements:
- Programs are declarative where possible (easy to diff, version, and test).
- Programs can define:
  - step graph (not only a linear loop)
  - tool allowlists per step
  - subagent spawn points (e.g., "research" step always delegates)
  - verification steps (tests, lint, compilation) as explicit phases
- Programs must be observable in UI (current step, budgets, why a tool is allowed/denied).

## 8. Delivery Order

Recommended implementation order:

1. stable core loop and event contract
2. typed message/tool-result model
3. queued steering/follow-up inputs
4. persistence and branching integration
5. programmable loop policies
6. subagents and multi-model orchestration
