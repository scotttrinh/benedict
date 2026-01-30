;;; benedict-test-helpers.el --- Shared test helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; Utilities for ERT/ert-async tests to manage temporary bindings and cleanup.

;;; Code:

(defmacro benedict-test-with-bindings (done bindings &rest body)
  "Evaluate BODY with BINDINGS applied; clean up before calling DONE.

BINDINGS is a list where each element is either:
- (VAR VALUE) to `set' VAR to VALUE.
- ((symbol-function FN) NEW) to `fset' FN to NEW.

The macro wraps DONE so that cleanup happens before the real test
completion signal.  This keeps async tests from leaking global state."
  (declare (indent 2))
  `(let* ((origins
           (mapcar (lambda (binding)
                     (let ((target (car binding)))
                       (cons target
                             (if (and (consp target)
                                      (eq (car target) 'symbol-function))
                                 (symbol-function (cadr target))
                               (symbol-value target)))))
                   ',bindings))
          (cleanup (lambda ()
                     (dolist (pair origins)
                       (let ((target (car pair))
                             (value (cdr pair)))
                         (if (and (consp target)
                                  (eq (car target) 'symbol-function))
                             (fset (cadr target) value)
                           (set target value)))))))
     ;; Apply bindings
     (dolist (binding ',bindings)
       (let ((target (car binding))
             (value (eval (cadr binding))))
         (if (and (consp target) (eq (car target) 'symbol-function))
             (fset (cadr target) value)
           (set target value))))
     ;; Wrap done to ensure cleanup
     (let ((,done (lambda (&optional err)
                    (funcall cleanup)
                    (funcall done err))))
       ,@body)))

(provide 'benedict-test-helpers)

;;; benedict-test-helpers.el ends here
