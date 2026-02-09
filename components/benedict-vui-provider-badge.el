;;; benedict-vui-provider-badge.el --- Vui provider/model badge component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a clickable provider/model badge for the Vui chat UI.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict)
(require 'benedict-vui-badge)

(defun benedict-vui-provider-badge--format-provider (provider)
  "Return a display label for PROVIDER."
  (if provider
      (let ((name (symbol-name provider)))
        (upcase (substring name 0 (min 3 (length name)))))
    "???"))

(defun benedict-vui-provider-badge--format-model (model)
  "Return a display label for MODEL."
  (cond
   ((null model) "unknown")
   ((stringp model)
    (let* ((trimmed (string-trim model))
           (parts (and (> (length trimmed) 0) (split-string trimmed "/" t)))
           (tail (car (last parts))))
      (if (and tail (> (length tail) 0))
          tail
        "unknown")))
   (t (format "%s" model))))

(vui-defcomponent benedict-vui-provider-badge (provider model on-click)
  :render
  (let* ((provider-label (benedict-vui-provider-badge--format-provider provider))
         (model-label (benedict-vui-provider-badge--format-model model)))
    (vui-hstack
      :spacing 1
      (if (functionp on-click)
          (vui-button provider-label
            :on-click (lambda (&rest _)
                        (funcall on-click))
            :face 'benedict-chat-header-provider
            :no-decoration t)
        (vui-text provider-label
          :face 'benedict-chat-header-provider))
      (vui-text "·"
        :face 'benedict-chat-header-separator)
      (vui-text model-label
        :face 'benedict-chat-header-model))))

(provide 'benedict-vui-provider-badge)
;;; benedict-vui-provider-badge.el ends here
