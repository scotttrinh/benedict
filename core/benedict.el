;;; benedict.el --- An agent runtime whose medium is Emacs Lisp  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Benedict is an agent runtime whose operating medium is Emacs Lisp.  Every
;; agent harness gives its model an escape hatch into a general-purpose
;; execution environment; for most, that hatch is `bash'.  Benedict's is `eval'
;; and the environment is the running Emacs image, so self-extension is a form
;; evaluation rather than a file write plus a reload.
;;
;; This file is deliberately a LEAF: it requires nothing else from the project.
;; Every other Benedict module requires it for the customization group and the
;; root error condition, so if this file required them back, loading any module
;; would recurse -- `benedict' is not yet in `features' while it is loading.
;;
;; That means this is not an umbrella that pulls in the rest of the system.  If
;; a future phase wants one, put the umbrella `require' forms BELOW an early
;; `(provide 'benedict)' so the cycle stays broken, or add a separate
;; `benedict-distro.el'.  Decide deliberately; discovering this at frontend
;; time is expensive.
;;
;; See SPEC-001--Core_Architecture.md for the full specification.

;;; Code:

(defconst benedict-version "0.1.0"
  "Version of the Benedict runtime.")

(defgroup benedict nil
  "An agent runtime whose operating medium is Emacs Lisp."
  :group 'tools
  :prefix "benedict-")

(define-error 'benedict-error
  "Benedict encountered an error")

(provide 'benedict)

;;; benedict.el ends here
