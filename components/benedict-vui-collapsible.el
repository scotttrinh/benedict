;;; benedict-vui-collapsible.el --- Vui collapsible container -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provides a generic collapsible container with a header and toggle.

;;; Code:

(require 'vui)

(defun benedict-vui-collapsible--controlled-p (props)
  "Return non-nil when PROPS includes a :collapsed key."
  (not (null (plist-member props :collapsed))))

(defun benedict-vui-collapsible--collapsed-p (props state)
  "Return non-nil when PROPS/STATE indicate collapse."
  (if (benedict-vui-collapsible--controlled-p props)
      (plist-get props :collapsed)
    (plist-get state :collapsed)))

(defun benedict-vui-collapsible--indicator (collapsed)
  "Return a fold indicator for COLLAPSED state."
  (if collapsed "▶" "▼"))

(defun benedict-vui-collapsible--apply-toggle (collapsed controlled on-toggle)
  "Toggle COLLAPSED, call ON-TOGGLE, and return next local state value.

When CONTROLLED is non-nil, returns COLLAPSED to avoid local state changes."
  (let ((next (not collapsed)))
    (when (functionp on-toggle)
      (funcall on-toggle next))
    (if controlled collapsed next)))

(defun benedict-vui-collapsible--render-header (header)
  "Return HEADER content, defaulting to an empty node."
  (if (functionp header)
      (funcall header)
    (vui-text "")))

(defun benedict-vui-collapsible--render-content (collapsed content)
  "Return CONTENT when not COLLAPSED."
  (when (and (not collapsed) (functionp content))
    (funcall content)))

(vui-defcomponent benedict-vui-collapsible (props state)
  :state ((collapsed nil))
  :render
  (let* ((header (plist-get props :header))
         (content (plist-get props :content))
         (on-toggle (plist-get props :on-toggle))
         (controlled (benedict-vui-collapsible--controlled-p props))
         (collapsed (benedict-vui-collapsible--collapsed-p props state))
         (toggle-handler (vui-use-callback (collapsed controlled on-toggle)
                           (let ((next (benedict-vui-collapsible--apply-toggle
                                        collapsed controlled on-toggle)))
                             (unless controlled
                               (vui-set-state :collapsed next))))))
    (vui-vstack
     (vui-hstack
      (vui-button (benedict-vui-collapsible--indicator collapsed)
                  :on-click toggle-handler)
      (benedict-vui-collapsible--render-header header))
     (benedict-vui-collapsible--render-content collapsed content))))

(provide 'benedict-vui-collapsible)
;;; benedict-vui-collapsible.el ends here
