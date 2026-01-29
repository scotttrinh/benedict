;;; benedict-errors.el --- Shared error definitions -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Central location for the `benedict-error` hierarchy so that tools can
;; rely on the condition hierarchy even when the rest of `benedict.el`
;; is not loaded.

;;; Code:

(unless (get 'benedict-error 'error-conditions)
  (define-error 'benedict-error "Benedict error"))

(unless (get 'benedict-provider-error 'error-conditions)
  (define-error 'benedict-provider-error "Benedict provider error"
                'benedict-error))

(provide 'benedict-errors)
;;; benedict-errors.el ends here
