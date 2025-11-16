;;; benedict-tools.el --- Tool registry skeleton -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Minimal registry to register/list/call tool functions. Approval UX is a
;; placeholder and will be implemented later in Phase 1.

;;; Code:

(defvar benedict--tools (make-hash-table :test 'eq)
  "Registry of tool specs keyed by :id symbol.")

(cl-defun benedict-tools-register (&key id fn schema approval doc)
  "Register a tool with ID and FN.
SCHEMA is a plist describing arguments; APPROVAL is one of
'auto, 'confirm, or 'always. DOC is an optional string."
  (puthash id (list :id id :fn fn :schema schema :approval approval :doc doc)
           benedict--tools))

(defun benedict-tools-list ()
  "Return a list of tool specs."
  (let (acc) (maphash (lambda (_k v) (push v acc)) benedict--tools) (nreverse acc)))

(defun benedict-tool-call (id &rest args)
  "Invoke tool ID with ARGS."
  (let* ((spec (gethash id benedict--tools))
         (fn (plist-get spec :fn)))
    (unless spec (signal 'benedict-error (list (format "Unknown tool: %S" id))))
    (apply fn args)))

;; Example demo tool used by echo provider later
(defun benedict--tool-uppercase (&key text)
  "Return TEXT uppercased."
  (upcase (or text "")))

;; Seed demo tool
(benedict-tools-register :id 'uppercase :fn #'benedict--tool-uppercase
                         :schema '(:text string) :approval 'auto
                         :doc "Uppercase a string")

(provide 'benedict-tools)
;;; benedict-tools.el ends here
