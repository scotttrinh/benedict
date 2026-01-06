;;; efforts/ensure-write-to-chat-buffer/research.md -*- lexical-binding: t; -*-

# Research: ensure-write-to-chat-buffer

## Current chat buffer identity
- Chat buffer is created via `benedict-chat` and initialized in `benedict-chat--init-buffer` (`benedict-chat.el:3342`, `benedict-chat.el:3354`).
- `benedict-chat--resolve-chat-buffer` resolves an active chat buffer based on `current-buffer` or the compose buffer’s parent pointer (`benedict-chat.el:606`).

## Rendering and marker creation depend on current buffer
- Core render path `benedict-chat--record-message` -> `benedict-chat--render-message` inserts into `current-buffer` and creates message markers at point (`benedict-chat.el:1169`, `benedict-chat.el:1211`).
- Marker-backed render helpers use `point-marker` in the current buffer (`benedict-chat-render.el:151`).
- Thinking blocks are recorded via `benedict-chat--record-thinking`, which renders in the current buffer, and write helpers apply text using marker buffers after creation (`benedict-chat.el:1242`, `benedict-chat.el:1952`).
- Tool UI blocks are rendered via `benedict-chat--record-tool-block` and `benedict-chat--render-tool-item` in the current buffer (`benedict-chat.el:1655`, `benedict-chat-render.el:458`).

## Streaming callbacks are buffered via current buffer at dispatch
- Provider callbacks run under `with-current-buffer buffer` captured at dispatch time (`benedict-chat.el:2505`).
- Streaming state initialization uses `current-buffer` and stores the item in `benedict-stream-state` (`benedict-chat.el:2066`, `benedict-chat-stream.el:17`).
- Streaming deltas append through markers, using marker buffers once the item exists (`benedict-chat-stream.el:26`, `benedict-chat-render.el:237`).

