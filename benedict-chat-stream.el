;;; benedict-chat-stream.el --- Streaming support for Benedict chat -*- lexical-binding: t; -*-

;; Author: Benedict maintainers

;;; Commentary:
;; Manages streaming state, throttling, and delta buffering.
;; Interfaces with benedict-chat-render to update the buffer.

;;; Code:

(require 'benedict-chat-render)

(defvar-local benedict-stream-state nil
  "Plist containing streaming state for the current buffer.
Keys: :content-start, :content-end, :pending-text.")

(defun benedict-chat--stream-init (buffer)
  "Initialize streaming state in BUFFER."
  (with-current-buffer buffer
    (let ((start (copy-marker (point) nil))
          (end (copy-marker (point) t)))
      (setq benedict-stream-state
            (list :content-start start
                  :content-end end
                  :pending-text "")))))

(defun benedict-chat--stream-insert-delta (stream text)
  "Buffer TEXT into STREAM for throttled application.
Currently inserts immediately."
  (let ((end (plist-get stream :content-end))
        (inhibit-read-only t))
    (when (and end (marker-position end))
      (with-current-buffer (marker-buffer end)
        (save-excursion
          (goto-char end)
          (insert (propertize text 'benedict-region-kind 'body)))))))

(defun benedict-chat--apply-buffered-faces (stream)
  "Apply any buffered faces held by STREAM and reset state."
  (let ((start (plist-get stream :content-start))
        (end (plist-get stream :content-end)))
    (when (and start end (marker-buffer start))
      (with-current-buffer (marker-buffer start)
        (font-lock-flush start end)
        (font-lock-ensure start end)))))

(provide 'benedict-chat-stream)
;;; benedict-chat-stream.el ends here
