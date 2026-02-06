;;; benedict-vui-collapsible.el --- Vui collapsible container -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provides a generic collapsible container with a header and toggle.

;;; Code:

(require 'vui)

(defun benedict-vui-collapsible--indicator (collapsed)
  "Return a fold indicator for COLLAPSED state."
  (if collapsed "▶" "▼"))

(vui-defcomponent benedict-vui-collapsible (header content on-toggle collapsed)
  :render
  (let* ((toggle-handler (lambda (&rest _)
                           (let ((next (not collapsed)))
                               (funcall on-toggle next)))))
    (vui-vstack
     (vui-hstack
      (vui-button (benedict-vui-collapsible--indicator collapsed)
                  :on-click toggle-handler)
      (if (functionp header) (funcall header) (vui-text "")))
     (when (and (not collapsed) (functionp content))
       (funcall content)))))

;; Re-export internal helpers used by tests
(defalias 'benedict-vui-collapsible--collapsed-p
  (lambda (props state)
    (if (not (null (plist-member props :collapsed)))
        (plist-get props :collapsed)
      (plist-get state :collapsed))))

(defalias 'benedict-vui-collapsible--apply-toggle
  (lambda (collapsed controlled on-toggle)
    (let ((next (not collapsed)))
      (when (functionp on-toggle)
        (funcall on-toggle next))
      (if controlled collapsed next))))

(defalias 'benedict-vui-collapsible--render-header
  (lambda (header)
    (if (functionp header)
        (funcall header)
      (vui-text ""))))

(defalias 'benedict-vui-collapsible--render-content
  (lambda (collapsed content)
    (when (and (not collapsed) (functionp content))
      (funcall content))))


(provide 'benedict-vui-collapsible)
;;; benedict-vui-collapsible.el ends here
