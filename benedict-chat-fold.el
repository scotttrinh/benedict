;;; benedict-chat-fold.el --- Chat folding adapter  -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Adapts benedict-fold-core to chat buffers. Declares fold specs for
;; thinking blocks (overlay backend) and tool details (text-property
;; backend) and provides helpers to keep item plists in sync.

;;; Code:

(require 'benedict-fold-core)

(defconst benedict-chat-fold-thinking-spec
  (benedict-fold-core-define-spec 'benedict-chat-thinking
    :alias 'benedict-chat-thinking
    :priority 0
    :front-sticky t
    :rear-sticky t
    :backend benedict-fold-core-overlay-backend)
  "Fold spec for thinking blocks (overlay-backed).")

(defconst benedict-chat-fold-tool-spec
  (benedict-fold-core-define-spec 'benedict-tool-details
    :alias 'benedict-tool-details
    :priority 0
    :backend benedict-fold-core-text-property-backend)
  "Fold spec for tool call detail bodies (text-property-backed).")

(defun benedict-chat-fold-init-buffer (&optional backend)
  "Initialize folding defaults for the current chat buffer.
Optional BACKEND overrides the default overlay backend."
  (benedict-fold-core-set-backend (or backend benedict-fold-core-overlay-backend)))

(defun benedict-chat-fold--region (item)
  "Return (START . END) markers for ITEM content."
  (let ((start (plist-get item :content-start))
        (end (plist-get item :content-end)))
    (when (and start end (marker-position start) (marker-position end))
      (cons start end))))

(defun benedict-chat-fold--ensure (item key spec)
  "Ensure ITEM has a fold stored at KEY using SPEC.
Returns the fold object or nil if boundaries are missing."
  (when-let* ((range (benedict-chat-fold--region item))
              (raw-start (marker-position (car range)))
              (raw-end (marker-position (cdr range))))
    (let* ((start (min raw-start raw-end))
           (end (max raw-start raw-end))
           (fold (plist-get item key)))
      (if (and fold (benedict-fold-core-fold-p fold))
          (progn
            (benedict-fold-core-resize fold start end)
            fold)
        (let ((created (benedict-fold-core-fold-region start end spec)))
          (plist-put item key created)
          created)))))

(defun benedict-chat-fold-ensure-thinking (item)
  "Ensure ITEM has a thinking fold."
  (benedict-chat-fold--ensure item :thinking-fold benedict-chat-fold-thinking-spec))

(defun benedict-chat-fold-ensure-tool (item)
  "Ensure ITEM has a tool fold."
  (benedict-chat-fold--ensure item :tool-fold benedict-chat-fold-tool-spec))

(defun benedict-chat-fold-set-thinking-folded (item folded)
  "Set ITEM thinking fold to FOLDED."
  (plist-put item :thinking-folded folded)
  (when-let ((fold (benedict-chat-fold-ensure-thinking item)))
    (benedict-fold-core-set-folded fold folded)))

(defun benedict-chat-fold-set-tool-folded (item folded)
  "Set ITEM tool body fold to FOLDED."
  (plist-put item :tool-folded folded)
  (let ((range (benedict-chat-fold--region item)))
    (when-let ((fold (benedict-chat-fold-ensure-tool item)))
      (benedict-fold-core-set-folded fold folded))
    (when range
      (let* ((raw-start (marker-position (car range)))
             (raw-end (marker-position (cdr range)))
             (start (min raw-start raw-end))
             (end (max raw-start raw-end)))
        (when (> raw-start raw-end)
          (set-marker (car range) start)
          (set-marker (cdr range) end))
        (let ((inhibit-read-only t))
          (if folded
              (add-text-properties start end '(invisible benedict-tool-details))
            (remove-text-properties start end '(invisible benedict-tool-details))))))))

(defun benedict-chat-fold-update-thinking (item)
  "Refresh boundaries for ITEM thinking fold."
  (when-let ((fold (plist-get item :thinking-fold)))
    (benedict-chat-fold-ensure-thinking item)
    (benedict-fold-core-set-folded fold (plist-get item :thinking-folded))))

(defun benedict-chat-fold-update-tool (item)
  "Refresh boundaries for ITEM tool fold."
  (when-let ((fold (plist-get item :tool-fold)))
    (benedict-chat-fold-ensure-tool item)
    (benedict-fold-core-set-folded fold (plist-get item :tool-folded))))

(provide 'benedict-chat-fold)
;;; benedict-chat-fold.el ends here
