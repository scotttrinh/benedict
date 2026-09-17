;;; benedict.el --- An agent runtime whose medium is Emacs Lisp  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (markdown-mode "2.5") (vui "1.3.0"))
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
;; The two frontend dependencies above are a packaging compromise, not a claim
;; about this file: nothing in core/, support/, api/, providers/, or ext/ touches
;; either one, and the boundaries test is what keeps that true.  SPEC-001 12.2
;; wants `benedict' to require only Emacs and curl, with ui/ living in a separate
;; `benedict-distro' -- but there is one package today and one manifest with it,
;; so a kernel-only install currently pulls a render library it never loads.
;; That cost is the concrete argument for making the 12.2 split real.
;;
;; This file is deliberately a LEAF: it requires nothing else from the project.
;; Every other Benedict module requires it for the customization group and the
;; root error condition, so if this file required them back, loading any module
;; would recurse -- `benedict' is not yet in `features' while it is loading.
;;
;; This is not an umbrella that pulls in the rest of the system.  UI commands
;; are exposed below as lazy autoloads; loading this leaf never loads the UI.
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

(autoload 'benedict-chat-revert "benedict-chat" nil t)
(autoload 'benedict-chat-send "benedict-chat" nil t)
(autoload 'benedict-chat-abort "benedict-chat" nil t)
(autoload 'benedict-chat-retry "benedict-chat" nil t)
(autoload 'benedict-chat-next-sibling "benedict-chat" nil t)
(autoload 'benedict-chat-previous-sibling "benedict-chat" nil t)

(provide 'benedict)

;;; benedict.el ends here
