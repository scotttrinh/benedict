;;; benedict-vui-checkpoint-block.el --- Vui checkpoint block -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders persistent checkpoint controls inside the chat buffer.

;;; Code:

(require 'subr-x)
(require 'vui)
(require 'benedict-vui-badge)

(defun benedict-vui-checkpoint-block--reason-label (reason)
  "Return a human-readable label for checkpoint REASON."
  (pcase reason
    ('turn-limit "Turn limit reached")
    ('time-limit "Time limit reached")
    ('token-limit "Token limit reached")
    (_ (format "Checkpoint: %s" (or reason "pending")))))

(defun benedict-vui-checkpoint-block--detail-lines (checkpoint)
  "Return descriptive lines for CHECKPOINT."
  (let ((reason (plist-get checkpoint :reason))
        (limit (plist-get checkpoint :limit))
        (turn-count (plist-get checkpoint :turn-count))
        (elapsed (plist-get checkpoint :elapsed))
        (total-tokens (plist-get checkpoint :total-tokens))
        lines)
    (push (benedict-vui-checkpoint-block--reason-label reason) lines)
    (when turn-count
      (push (format "Turns: %s / %s" turn-count (or limit "?")) lines))
    (when elapsed
      (push (format "Elapsed: %.2fs / %s" elapsed (or limit "?")) lines))
    (when total-tokens
      (push (format "Tokens: %s / %s" total-tokens (or limit "?")) lines))
    (nreverse lines)))

(vui-defcomponent benedict-vui-checkpoint-block (checkpoint on-continue on-stop)
  "Render a persistent checkpoint block for CHECKPOINT."
  :render
  (when checkpoint
    (let ((detail-nodes
           (mapcar (lambda (line)
                     (vui-text line :face 'benedict-chat-system))
                   (benedict-vui-checkpoint-block--detail-lines checkpoint))))
      (apply #'vui-vstack
             (append
              (list
               (vui-hstack
                :spacing 1
                (vui-component 'benedict-vui-badge :status 'pending)
                (vui-text "Checkpoint"
                          :face 'benedict-chat-tool-label)))
              detail-nodes
              (list
               (vui-hstack
                :spacing 1
                (vui-button "Continue" :on-click on-continue)
                (vui-button "Stop" :on-click on-stop))))))))

(provide 'benedict-vui-checkpoint-block)
;;; benedict-vui-checkpoint-block.el ends here
