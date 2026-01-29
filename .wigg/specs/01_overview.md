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

1.  **Session Core (`benedict-session.el`):**
    - The "brain" of the assistant.
    - Manages conversation state, message history, and the agent loop.
    - Independent of the UI; can run headless.

2.  **Chat UI (`benedict-chat.el` & `benedict-chat-render.el`):**
    - The "face" of the assistant.
    - Renders the session state into an Emacs buffer.
    - Handles user input, streaming updates, and rich rendering (markdown, badges).

3.  **Provider Layer (`benedict-provider.el`):**
    - The "voice" and "ears".
    - Standardized interface for talking to LLMs.
    - Implementations for OpenRouter, Vercel, Gemini, Ollama, etc.

4.  **Tooling System (`benedict-tools.el`):**
    - The "hands".
    - Registry of capabilities (read file, search project, edit buffer).
    - Schema definition for LLM consumption.

5.  **Isolation (`benedict-flywire.el`):**
    - The "safety sandbox".
    - Executes tools in a controlled frame/environment.

## 4. Key Workflows

- **Chat:** Standard Q&A with context awareness.
- **Task Execution:** User gives a high-level goal ("Refactor this module"), and Benedict runs a programmable agent loop (an "agent program") that can spawn subagents and produce artifacts.
- **Context Gathering:** Commands to pull in regions, buffers, or project context into the chat.
- **Agent Bootstrap (Skills/Instructions):** Each session can be bootstrapped from project-local agent instructions (e.g., `AGENTS.md`, `SKILL.md`, `.wigg/specs/`), with a good default and full user customization.
- **Org-Mode Integration:**
    - Benedict views Org-mode as the "long-term memory" and "planning substrate."
    - Chat is for ephemeral interaction and execution.
    - Org is for heavy thinking, shaping plans, and archiving decisions.
    - Workflows allow capturing chat content into Org nodes and conversely, using Org subtrees as context for agents.

## 5. Packaging & Delivery

- **Distribution:** Installable via MELPA.
- **Quality:**
    - Comprehensive CI/CD pipeline running ERT and Buttercup tests.
    - Strict linting (`package-lint`, `checkdoc`).
- **Documentation:**
    - Self-documenting commands (docstrings).
    - Comprehensive "Cookbook" for common agent patterns.
