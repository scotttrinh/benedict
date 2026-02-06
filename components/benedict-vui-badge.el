;;; benedict-vui-badge.el --- Vui status badge component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders role and status badges for the Vui chat UI.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict)

(defconst benedict-vui-badge--labels
  '((user . "USER")
    (assistant . "ASSISTANT")
    (system . "SYSTEM")
    (error . "ERROR")
    (streaming . "STREAMING")
    (empty . "EMPTY")
    (running . "RUNNING")
    (success . "SUCCESS")
    (failure . "FAILURE"))
  "Mapping of status symbols to badge labels.")

(defconst benedict-vui-badge--faces
  '((user . benedict-chat-user)
    (assistant . benedict-chat-assistant)
    (system . benedict-chat-system)
    (error . benedict-chat-header-error)
    (streaming . benedict-chat-header-time)
    (empty . benedict-chat-header-separator)
    (running . benedict-chat-tool-running)
    (success . benedict-chat-tool-success)
    (failure . benedict-chat-tool-error))
  "Mapping of status symbols to badge faces.")

(defun benedict-vui-badge--normalize-status (status)
  "Return STATUS normalized to a symbol or nil."
  (cond
   ((symbolp status) status)
   ((stringp status) (intern (downcase status)))
   (t nil)))

(defun benedict-vui-badge--coerce-face (face)
  "Return FACE coerced to a single face symbol or nil."
  (cond
   ((and (symbolp face) (facep face)) face)
   ((listp face)
    (cl-find-if (lambda (candidate)
                  (and (symbolp candidate) (facep candidate)))
                face))
   ((facep face) face)
   (t nil)))

(defun benedict-vui-badge--label (status)
  "Return a display label for STATUS."
  (let* ((normalized (benedict-vui-badge--normalize-status status))
         (label (cdr (assq normalized benedict-vui-badge--labels))))
    (cond
     (label label)
     (normalized (upcase (symbol-name normalized)))
     (t "UNKNOWN"))))

(defun benedict-vui-badge--face (status theme)
  "Return a face for STATUS with optional THEME fallback."
  (let* ((normalized (benedict-vui-badge--normalize-status status))
         (theme-face (benedict-vui-badge--coerce-face theme))
         (face (cdr (assq normalized benedict-vui-badge--faces))))
    (or face theme-face 'benedict-chat-header)))

(defun benedict-vui-badge--propertize (label face)
  "Return LABEL with FACE applied."
  (let* ((label (format "%s" label))
         (face (or (benedict-vui-badge--coerce-face face) 'benedict-chat-header))
         (text (copy-sequence label)))
    (when (> (length text) 0)
      (add-face-text-property 0 (length text) face t text))
    text))

(vui-defcomponent benedict-vui-badge (status theme)
  :render
  (let* ((label (benedict-vui-badge--label status))
         (face (benedict-vui-badge--face status theme)))
    (vui-text (benedict-vui-badge--propertize label face))))

(provide 'benedict-vui-badge)
;;; benedict-vui-badge.el ends here
