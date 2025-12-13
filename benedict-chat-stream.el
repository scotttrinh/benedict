;;; benedict-chat-stream.el --- Streaming support for Benedict chat -*- lexical-binding: t; -*-

;; Author: Benedict maintainers

;;; Commentary:
;; Manages streaming state, throttling, and delta buffering.
;; Interfaces with benedict-chat-render to update the buffer.

;;; Code:

(require 'benedict-chat-render)

(defvar-local benedict-stream-state nil
  "Plist containing streaming state for the current buffer.
Keys: :item, :pending-text.")

(defun benedict-chat--stream-init (buffer &optional item)
  "Initialize streaming state in BUFFER.

ITEM is the marker-backed chat item whose body should receive streaming deltas."
  (with-current-buffer buffer
    (setq benedict-stream-state
          (list :item item
                :pending-text ""))))

(defun benedict-chat--stream-insert-delta (stream text)
  "Buffer TEXT into STREAM for throttled application.
Currently inserts immediately."
  (when-let ((item (plist-get stream :item)))
    (benedict-chat-render--append-item-content item text 'body)))

(provide 'benedict-chat-stream)
;;; benedict-chat-stream.el ends here
