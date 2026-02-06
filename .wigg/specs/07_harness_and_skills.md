# Harness and Skills Specification

This document defines two v0.1 MVP pillars:
1) a modern safety harness (sandbox + budgets + scopes)
2) first-class support for agent instructions and skills (AGENTS.md / SKILL.md)

## 1. Safety Harness (Modern Permissions)

The harness is the primary safety mechanism. Interactive approval prompts are an exception, not the default.

### 1.1 Scope Model

Scope is represented as a declarative object that the harness can enforce and the UI can render:
- paths: allowed roots and glob allow/deny lists
- buffers: allowed buffer names or predicates (major mode, file-backed)
- commands: allowed interactive commands (when running in an agent frame)
- network: allowed endpoints, or "none"

The harness must support scope expansion requests:
- the agent can request an expanded scope with a reason
- the user approves or denies the scope expansion
- denial must be represented as a structured result the model can react to

### 1.2 Budgets

Budgets prevent runaway behavior:
- max turns
- wall clock budget
- token/cost budget (when available)
- tool call cap per turn and per session
- max bytes read/written per tool and per session (optional)

Budgets are configured by:
- profile defaults
- project overrides
- per-session overrides (interactive)

### 1.3 Effect Categories

Tools declare their effect category so the harness can enforce policies consistently:
- read: observe state without mutation
- write: mutate files/buffers
- exec: evaluate code or run commands
- process: spawn subprocesses
- network: make HTTP requests
- ui: manipulate windows/buffers/frame state

### 1.4 Audit Events

The harness emits structured events for:
- scope expansion requests and outcomes
- tool start/completion
- file/buffer mutations (paths, counts, summaries)
- subprocess executions (command + exit status, redacted)

These events are shown in the UI and form the basis for persistence later.

## 2. Agent Instructions and Skills (AGENTS.md / SKILL.md)

### 2.1 Instruction Sources (Ordered)

Each session builds its instruction context from sources, in order:
1) project-local agent instructions (AGENTS.md)
2) relevant skill definitions (SKILL.md files, selected by user or inferred from task)
3) project specs (.wigg/specs/)
4) user overrides (session-local)

This must be configurable, but the default should "just work" for new projects.

### 2.2 Session Bootstrap Hook

The system must support a hook that runs when creating a new session/thread:
- computes instruction context (sources + selection)
- sets the agent program (loop policy)
- sets the harness policy (scope + budgets)
- seeds initial context (optional, minimal)

The hook should be user-extensible, and projects should be able to provide defaults via dir-locals.

### 2.3 Skills as Reusable Workflows

A "skill" is a reusable workflow bundle:
- task framing (what questions to ask)
- steps and success criteria
- tool preferences and constraints
- output format expectations

Skills can apply to:
- planning work
- research work
- implementation work
- review work

### 2.4 Dynamic Skills (Self-Extension)

Benedict supports **Dynamic Skills**: tools written by the agent itself during a session.

**The Skill Lifecycle:**
1.  **Prototype:** Agent identifies a missing capability (e.g., "Read unread emails"). It writes a prototype Elisp function to a scratch buffer.
2.  **Verify:** Agent runs the code using `exec-elisp` and verifies the output against expectations.
3.  **Persist:** Agent calls `skill-save` with the tested code.
    - System saves code to `~/.benedict/skills/<name>.el`.
    - System generates a `SKILL.md` (or header comments) describing the tool.
    - System registers the new tool in the current session.

This allows Benedict to accumulate capabilities ("Learn") over time without requiring core codebase updates.

## 3. Subagents (Context Hygiene)

Subagents are first-class in v0.1:
- a subagent has a smaller context window and stricter harness budgets
- subagents should be the default mechanism for "broad search" or "deep dive" tasks
- the UI must clearly surface subagent work as collapsible blocks, not interleaved noise
