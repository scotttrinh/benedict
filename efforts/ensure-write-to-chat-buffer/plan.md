;;; efforts/ensure-write-to-chat-buffer/plan.md -*- lexical-binding: t; -*-

# Plan: ensure-write-to-chat-buffer

## Goal
Guarantee that all chat buffer writes (message rendering, tool UI, thinking blocks, streaming deltas) are targeted to a stable chat buffer reference rather than `current-buffer`, preventing writes into unrelated buffers during async callbacks or tool actions.

## Phase 1: Stabilize chat buffer identity (completed)
- Add a buffer-local variable (e.g., `benedict-chat--buffer`) and set it during `benedict-chat--init-buffer` to `(current-buffer)` so it remains stable for the life of the chat buffer (`benedict-chat.el:3354`).
- Ensure compose buffers keep a pointer to the parent chat buffer (already present) and use that pointer to resolve the stable chat buffer reference (`benedict-chat.el:2573`, `benedict-chat.el:2768`).

## Phase 2: Thread explicit buffer arguments through entrypoints (completed)
- Update entrypoints that create markers or insert text to accept a `buffer` argument and wrap their work in `with-current-buffer buffer`.
  - Message rendering: `benedict-chat--record-message`, `benedict-chat--render-message`, `benedict-chat--replace-message-content`, `benedict-chat--maybe-insert-item-gap`.
  - Tool UI: `benedict-chat--record-tool-block`, `benedict-chat--update-tool-block`, `benedict-chat--refresh-tool-block`.
  - Thinking: `benedict-chat--record-thinking`, `benedict-chat--display-thinking-detail`, `benedict-chat--write-thinking-content`.
  - Streaming: `benedict-chat--streaming-reset`, `benedict-chat--ensure-streaming-message`, `benedict-chat--handle-provider-delta`, `benedict-chat--handle-provider-success`, `benedict-chat--handle-provider-error`, `benedict-chat--stream-init`.
- Update render helpers in `benedict-chat-render.el` to accept buffer or rely solely on marker-buffer once markers exist; ensure marker creation always happens inside `with-current-buffer buffer`.

## Phase 3: Update call sites to pass the stable buffer (completed)
- Capture the stable buffer at interaction entrypoints (e.g., `benedict-chat`, `benedict-chat--send-text`, compose send) via the stored buffer-local reference.
- Update streaming callbacks to pass the stable buffer into the handler functions rather than relying on `current-buffer`.
- Ensure any helper using `benedict-chat--resolve-chat-buffer` returns the stable buffer reference.

## Phase 4: Verification (completed)
- Add/adjust tests that simulate buffer switching during streaming to ensure deltas land in the correct chat buffer.
- Manual sanity check: open chat, switch buffers mid-stream, verify writes only appear in the chat buffer.

## Success criteria
- No function that inserts chat content relies on `current-buffer` implicitly; all writes are directed through an explicit buffer argument or marker-buffer.
- Streaming and tool UI updates remain correct when the user switches buffers mid-response.
