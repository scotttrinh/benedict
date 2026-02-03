;;; benedict-vui-test-utils.el --- Helpers for VUI behavior tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers for rendering and interacting with VUI components in tests.

;;; Code:

(require 'widget)

(defun benedict-vui-test--click-button-at (pos)
  "Invoke the button widget at POS."
  (let ((widget (widget-at pos)))
    (when widget
      (widget-apply widget :action))))

(defun benedict-vui-test--click-button-labeled (label)
  "Click the first button labeled LABEL in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (if (search-forward label nil t)
        (benedict-vui-test--click-button-at (match-beginning 0))
      (error "No button labeled %s" label))))

(defun benedict-vui-test--set-first-field (value)
  "Set the first widget field to VALUE and notify."
  (let ((widget (car widget-field-list)))
    (unless widget
      (error "No widget field found in buffer"))
    (widget-value-set widget value)
    (widget-apply widget :notify widget)))

(provide 'test/benedict-vui-test-utils)
;;; benedict-vui-test-utils.el ends here
