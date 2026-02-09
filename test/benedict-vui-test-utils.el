;;; benedict-vui-test-utils.el --- Helpers for VUI behavior tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers for rendering and interacting with VUI components in tests.

;;; Code:

(require 'cl-lib)
(require 'widget)
(require 'vui)

(defmacro with-mounted-vui-component (component &rest body)
  "Mount COMPONENT in a temp buffer, run BODY, then unmount.

Flushes VUI before BODY and after teardown so tests observe settled state."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (let ((mount (vui-mount ,component (buffer-name))))
       (unwind-protect
           (progn
             (vui-flush-sync)
             ,@body)
         (when (and mount (fboundp 'vui-unmount))
           (ignore-errors (vui-unmount mount)))
         (vui-flush-sync)))))

(defun benedict-vui-test--click-button-at (pos)
  "Invoke the button widget at POS."
  (let ((widget (widget-at pos))
        (button (button-at pos)))
    (cond
     (widget (let ((action (widget-get widget :action)))
               (unless action
                 (error "No action on widget at %s" pos))
               (funcall action widget)))
     (button (button-activate button))
     (t (error "No button widget at %s" pos)))))

(defun benedict-vui-test--click-button-labeled (label)
  "Click the first button labeled LABEL in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (if (search-forward label nil t)
        (let ((start (match-beginning 0))
              (end (match-end 0))
              (clicked nil))
          (cl-loop for pos from (max (1- start) (point-min)) to (min (1+ end) (point-max))
                   when (or (widget-at pos) (button-at pos))
                   do (setq clicked t)
                   and do (benedict-vui-test--click-button-at pos)
                   and do (cl-return))
          (unless clicked
            (error "No button widget found for label %s" label)))
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
