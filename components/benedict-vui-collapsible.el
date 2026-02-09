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
                              (when (functionp on-toggle)
                                (funcall on-toggle next))))))
    (vui-vstack
     (vui-hstack
      (vui-button (benedict-vui-collapsible--indicator collapsed)
                  :on-click toggle-handler)
      (if (functionp header) (funcall header) (vui-text "")))
     (when (and (not collapsed) (functionp content))
       (funcall content)))))

;; Re-export internal helpers used by tests
(provide 'benedict-vui-collapsible)
;;; benedict-vui-collapsible.el ends here
