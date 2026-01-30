;;; benedict-vui-provider-badge.el --- Vui provider/model badge component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a clickable provider/model badge for the Vui chat UI.

;;; Code:

(require 'cl-lib)
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
  (if model
      (let ((parts (split-string model "/")))
        (car (last parts)))
    "unknown"))

(vui-defcomponent benedict-vui-provider-badge (props)
  :render
  (let* ((provider (plist-get props :provider))
         (model (plist-get props :model))
         (on-click (plist-get props :on-click))
         (provider-label (vui-component 'benedict-vui-provider-badge--format-provider provider))
         (model-label (vui-component 'benedict-vui-provider-badge--format-model model)))
    (vui-hstack
      :spacing 1
      :on-click on-click
      (vui-text provider-label
        :face 'benedict-chat-header-provider)
      (vui-text "·"
        :face 'benedict-chat-header-separator)
      (vui-text model-label
        :face 'benedict-chat-header-model))))

(defun benedict-vui-provider-badge (&rest props)
  "Create a provider badge component node from PROPS."
  (apply #'vui-component 'benedict-vui-provider-badge props))

(provide 'benedict-vui-provider-badge)
;;; benedict-vui-provider-badge.el ends here
