# Agent Loop Specification

This document defines the autonomous loop logic that allows Benedict to perform multi-step tasks.

## 1. The Loop Logic (`benedict-session.el`)

The Agent Loop is a state machine that drives the conversation forward until a termination condition is met.

**Cycle:**
1.  **Observe:** Collect message history, including the latest User message or Tool Result.
2.  **Think:** Dispatch request to LLM.
3.  **Act:** Receive LLM response.
    - If response is text only -> **Stop** (Task Complete).
    - If response contains Tool Calls -> **Execute**.
4.  **Execute:**
    - Parse tool calls.
    - Check Approvals.
    - Run Tools.
    - Append Tool Results to history.
    - **Loop:** Go back to Step 1.

## 2. Safety & Autonomy Constraints

To prevent runaway agents (infinite loops, excessive costs), the loop is bounded by strict constraints.

### 2.1 Limits (Configurable per Profile/Session)
- **`max-turns`**: Maximum number of autonomous steps allowed (default: ~5-10).
- **`max-time`**: Maximum wall-clock duration (default: ~60s).
- **`max-tokens`**: Maximum total tokens consumed in the session (optional).

### 2.2 Checkpoints
When a limit is reached, the loop enters the **`checkpoint`** state.
- **Behavior:** Execution pauses.
- **UI:** User is presented with a prompt: "Benedict has run 5 steps. Continue? (y/n)".
- **Resolution:**
    - `y`: Reset counters/timers and continue.
    - `n`: Stop loop.

### 2.3 Repetition Guard
- The system monitors for identical consecutive tool calls (same tool, same args).
- **Trigger:** If detected, the loop terminates immediately with a `repetition` error to prevent "stuck" agents.

## 3. Tool Execution Flow

1.  **Parser:** Extract `tool_calls` from the LLM response message.
2.  **Validator:** Ensure tool exists in registry and args match schema.
3.  **Policy Check:**
    - `auto`: Proceed.
    - `confirm`: Ask user.
        - If User denies: Feed "Tool invocation canceled by user" error back to LLM.
        - If User approves: Proceed.
    - `always`: (Misnomer, means "Always Confirm" or "High Risk"). Treat as `confirm`.
4.  **Invocation:**
    - Run the tool function (potentially in `flywire` sandbox).
    - Capture `stdout`/`return value` or `error`.
5.  **Result Formatting:**
    - Create a `tool` role message.
    - `tool_call_id`: Links back to the assistant's call.
    - `content`: The output of the tool.

## 4. Sub-Agents & Delegation (Advanced Architecture)

Complex tasks require specialized contexts. The Main Agent can spawn Sub-Agents.

- **Concept:** A "Main" agent (generalist) delegates a sub-task (e.g., "Research this error") to a specialized Sub-Agent.
- **Mechanism:**
    - Main agent calls a `delegate` tool.
    - A new, ephemeral `benedict-session` is created with a specific Profile (e.g., "Researcher") and restricted Tools.
    - The Sub-Agent runs its own loop.
    - Result is summarized and returned to the Main Agent as the tool output.
- **Safety:** Sub-Agents inherit (or have stricter) autonomy limits than the parent.

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
