# Benedict: Emacs-Native AI Assistant Specification

## 1. Vision & Core Philosophy

Benedict is designed to be an **Emacs-native** AI assistant. It rejects the paradigm of being a thin wrapper around a CLI tool or a webview. Instead, it leverages the intrinsic power of Emacs:
- **Buffers as Interface:** Interactions happen in buffers, manipulatable by standard Emacs commands.
- **Text as Data:** Responses are streamed, rendered, and structured as text properties and overlays, not HTML widgets.
- **Deep Integration:** It connects directly to Emacs APIs for file editing, buffer management, project navigation (`project.el`), and searching (`ripgrep`).
- **Safe-by-Default:** Safety is primarily enforced by a modern harness (sandbox + budgets + scope), with user confirmations used only when crossing boundaries or requesting privileged effects.

### 1.1 Artifact-First Usage (v0.1 MVP)

In v0.1, the primary "output" of a conversation is an artifact (side effect) the user can immediately use:
- write or edit project files
- draft content (email, note, summary) into a buffer or file
- capture a structured note into Org (optional integration)

Persistent chat history is valuable, but not required for day-to-day usefulness if the default workflow consistently produces artifacts.

## 2. Core Mandates

### 2.1 Emacs-First
- **UI:** Uses standard Emacs faces, text properties, and keymaps.
- **Navigation:** Supports standard motion commands.
- **Customization:** Fully configurable via `defcustom` and `defgroup`.
- **Dependencies:** Relies on standard Emacs packages (`json`, `project`, `url`) and high-quality community packages (`magit-section`, `markdown-mode`, `svg-lib`).

### 2.2 Provider Agnostic
- Benedict acts as a neutral client. It supports multiple backends (OpenRouter, Vercel, Gemini, Ollama) through a unified adapter layer.
- It handles differences in API capabilities (streaming vs. non-streaming, tool calling formats) transparently to the user.

### 2.3 Transparent & Safe
- **Harness Controls:** The agent runs under a harness that enforces safety constraints (scopes, budgets, sandboxing), and produces auditable events.
- **Approvals Are Exceptions:** Confirmations exist, but the default experience should not feel like "y/n spam". Prompts happen when the agent requests to widen scope or perform privileged effects.
- **Isolation:** Potentially disruptive operations run in an isolated environment (`benedict-flywire`) to avoid polluting the user's active windows/buffers.
- **Telemetry:** The user can see what context is sent, what tools ran, and what files/buffers were affected.

## 3. High-Level Architecture Summary

The system is composed of several loosely coupled modules:

1.  **Agent Core (`benedict-session.el`, refactored target):**
    - The smallest useful runtime.
    - Owns turn execution, tool execution, loop state, and event emission.
    - Must remain UI-agnostic and headless-friendly.

2.  **Session & Persistence Layer:**
    - Owns durable transcript storage, branching, resume, and compaction.
    - Must use a stable provider-agnostic on-disk format with room for extension metadata.
    - Should be designed early, because session durability and branchability are part of the product, not an afterthought.

3.  **Chat UI (`benedict-chat.el` and VUI components):**
    - The "face" of the assistant.
    - Renders the runtime/session state into an Emacs buffer.
    - Handles user input, streaming updates, queued messages, and rich rendering.
    - Presents the transcript as turn-oriented work records rather than a flat stream of peer messages.
    - Must consume the core event stream rather than reaching into runtime internals.

4.  **Provider Layer (`benedict-provider.el`):**
    - The "voice" and "ears".
    - Standardized interface for talking to LLMs.
    - Implementations for OpenRouter, Vercel, Gemini, Ollama, etc.

5.  **Tooling System (`benedict-tools.el`):**
    - The "hands".
    - Registry of capabilities (read file, search project, edit buffer).
    - Schema definition for LLM consumption plus effect/scope metadata for harness policy.

6.  **Extension Runtime:**
    - Public registration surfaces for tools, providers, profiles, context providers, renderers, prompts, and lifecycle hooks.
    - The primary mechanism for customization and ecosystem growth.

7.  **Isolation (`benedict-flywire.el`):**
    - The "safety sandbox".
    - Executes tools in a controlled frame/environment.

### 3.1 Stable Internal Contracts

To stay extensible, Benedict must standardize these contracts early:

- **Message model:** provider-agnostic, typed message/content blocks instead of ad hoc plists.
- **Event model:** stable lifecycle events for message start/update/end, tool execution, checkpoints, persistence, and UI state.
- **Tool result model:** structured outputs with text, metadata, actions, provenance, and effect summaries.
- **Transcript model:** durable session format that survives provider changes and supports branching.

### 3.2 Near-Term Priorities

The architectural priority order should be:

1. small agent core with explicit message/event contracts
2. durable session persistence with branching and compaction hooks
3. public extension API
4. richer Emacs-native workflows and UI polish
5. broader tool and provider surface area

## 4. Key Workflows

- **Chat:** Standard Q&A with context awareness.
- **Task Execution:** User gives a high-level goal ("Refactor this module"), and Benedict runs an agent loop that produces artifacts and can optionally delegate bounded sub-tasks.
- **Context Gathering:** Commands to pull in regions, buffers, or project context into the chat.
- **Agent Bootstrap (Skills/Instructions):** Each session can be bootstrapped from project-local agent instructions (e.g., `AGENTS.md`, `SKILL.md`, `.wigg/specs/`), with a good default and full user customization.
- **Queued Interaction While Busy:** Users can steer the agent mid-run or queue follow-up requests without interrupting the current tool execution at arbitrary points.
- **Org-Mode Integration:**
    - Benedict views Org-mode as the "long-term memory" and "planning substrate."
    - Chat is for ephemeral interaction and execution.
    - Org is for heavy thinking, shaping plans, and archiving decisions.
    - Workflows allow capturing chat content into Org nodes and conversely, using Org subtrees as context for agents.

## 4.1 Product Positioning

Benedict should learn architectural discipline from battle-tested CLI agents, but it should not aim for CLI parity as the end goal.

The differentiator is Emacs-native work:
- diff/ediff and review-first write flows
- compile/xref/imenu/project integration
- Org as planning and memory substrate
- action-bearing tool results that jump to files, buffers, hunks, or captures
- turn-centric chat UI where prompts, execution detail, and outcomes have a clear visual hierarchy
- richer interaction than a terminal can provide, without abandoning text-first UX

## 5. Packaging & Delivery

- **Distribution:** Installable via MELPA.
- **Quality:**
    - Comprehensive CI/CD pipeline running ERT and Buttercup tests.
    - Strict linting (`package-lint`, `checkdoc`).
- **Documentation:**
    - Self-documenting commands (docstrings).
    - Comprehensive "Cookbook" for common agent patterns.
