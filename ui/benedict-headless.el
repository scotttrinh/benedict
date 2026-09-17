;;; benedict-headless.el --- Non-interactive frontend for Benedict  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;;; Commentary:

;; A frontend with no buffer, no mode, and no render library: submit a prompt,
;; accumulate the transcript as plain text, call back when the run goes idle.
;;
;; SPEC-001 11.1 asks for this and says why it is worth building even though
;; nobody will use it much.  The chat UI must be implementable using only the
;; public API of 4.1 and the hooks of 4.4; asserting that about a single
;; frontend proves little, because the frontend and the API can drift together.
;; A SECOND frontend, written independently against the same surface, is the
;; falsifiable form of the claim.  This one is also deliberately vui-free, so it
;; additionally shows that `ui/' is not shaped around one render library.
;;
;; It is the cheapest place in the repo to test hook coverage: with no display
;; there are no render timers, so a run under `benedict-test-with-manual-defer'
;; is fully deterministic.

;;; Code:

(require 'benedict)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-core)

(defvar benedict-headless--sinks
  (make-hash-table :test 'eq :weakness 'key)
  "Weak map from session to its output sink.

A sink is a plist carrying `:insert', a function of one string, and
`:on-finish', a function of one session or nil.  Weak on the key so a
finished session is not held alive by having once been rendered.")

(defun benedict-headless--sink (session)
  "Return SESSION's output sink, or nil when it has none."
  (gethash session benedict-headless--sinks))

(defun benedict-headless--emit (session text)
  "Write TEXT to SESSION's sink, if it has one."
  (when-let* ((sink (benedict-headless--sink session)))
    (funcall (plist-get sink :insert) text)))

;;;; Formatting

(defun benedict-headless-format-block (block)
  "Return BLOCK rendered as plain text.

Every block type of SPEC-001 4.5 has a representation here, including the
ones a terminal cannot show, because a frontend that silently omits a
block type turns a rendering gap into an apparent gap in the transcript."
  (pcase (benedict-block-type block)
    ('text (or (benedict-block-get block :text) ""))
    ('thinking
     (if (benedict-block-get block :redacted)
         "[reasoning: redacted]"
       (format "[reasoning] %s" (or (benedict-block-get block :thinking) ""))))
    ('image (format "[image: %s]"
                    (or (benedict-block-get block :mime-type) "unknown")))
    ('tool-call
     (format "[tool %s] %S"
             (benedict-block-get block :name)
             (benedict-block-get block :arguments)))
    ('tool-result
     (format "[%s %s] %s"
             (if (benedict-block-get block :error-p) "failed" "result")
             (benedict-block-get block :name)
             (let ((content (benedict-block-get block :content)))
               (if (stringp content) content (format "%S" content)))))
    (type (format "[unrenderable block: %s]" type))))

(defun benedict-headless-format-entry (entry)
  "Return ENTRY rendered as plain text, role header included."
  (let ((blocks (mapcar #'benedict-headless-format-block
                        (benedict-entry-content entry)))
        (stop-reason (benedict-entry-meta-get entry :stop-reason)))
    (concat (format "%s:\n" (benedict-entry-role entry))
            (string-join (seq-remove #'string-empty-p blocks) "\n")
            (when (memq stop-reason '(error aborted))
              (format "\n[%s: %s]" stop-reason
                      (or (benedict-entry-meta-get entry :error-message)
                          "no message")))
            "\n")))

;;;; Hook handlers

(defun benedict-headless-on-entry-end (session entry)
  "Write ENTRY to SESSION's sink.  Return nil.

Intended for `benedict-entry-end-functions', whose calling convention is
\(SESSION ENTRY) and whose return value is ignored.  Entry end rather than
the streaming hooks: a non-interactive frontend has nothing to gain from
partial output, and waiting for the entry means every line it writes is
one the transcript actually holds."
  (benedict-headless--emit session (benedict-headless-format-entry entry))
  nil)

(defun benedict-headless-on-run-end (session)
  "Notify SESSION's sink that the run finished.  Return nil.

Intended for `benedict-run-end-functions', whose calling convention is
\(SESSION) and whose return value is ignored.  Fires however the run
ended, so the callback must read `benedict-session-stop-reason' to tell
a finished run from a vetoed, errored, or aborted one."
  (when-let* ((sink (benedict-headless--sink session))
              (on-finish (plist-get sink :on-finish)))
    (funcall on-finish session))
  nil)

;;;; Installation

;;;###autoload
(defun benedict-headless-install ()
  "Subscribe the headless frontend to the kernel's hooks.  Return t.
Idempotent, because `add-hook' with a named function is."
  (add-hook 'benedict-entry-end-functions #'benedict-headless-on-entry-end)
  (add-hook 'benedict-run-end-functions #'benedict-headless-on-run-end)
  t)

(defun benedict-headless-uninstall ()
  "Unsubscribe the headless frontend from the kernel's hooks.  Return t."
  (remove-hook 'benedict-entry-end-functions #'benedict-headless-on-entry-end)
  (remove-hook 'benedict-run-end-functions #'benedict-headless-on-run-end)
  t)

;;;; Entry points

(defun benedict-headless-attach (session insert &optional on-finish)
  "Send SESSION's rendered transcript to INSERT.  Return SESSION.

INSERT is called with one string per completed entry.  ON-FINISH, when
given, is called with SESSION once the run returns to idle.  MUTATES the
global sink map; `benedict-headless-detach' undoes it."
  (puthash session (list :insert insert :on-finish on-finish)
           benedict-headless--sinks)
  session)

(defun benedict-headless-detach (session)
  "Stop rendering SESSION.  Return t when it had a sink."
  (remhash session benedict-headless--sinks))

(defun benedict-headless-collector (session &optional on-finish)
  "Attach SESSION to a string collector.  Return a thunk yielding the text.

The simplest useful sink, and the one the tests use: everything the run
renders accumulates in order, and calling the returned function at any
point gives the transcript so far.  ON-FINISH is passed through to
`benedict-headless-attach'."
  (let ((chunks nil))
    (benedict-headless-attach
     session
     (lambda (text) (push text chunks))
     on-finish)
    (lambda () (apply #'concat (reverse chunks)))))

;;;###autoload
(defun benedict-headless-run (session input &optional on-finish)
  "Submit INPUT to SESSION headlessly.  Return a thunk yielding the transcript.

ON-FINISH is called with SESSION when the run reaches idle.  Installs the
handlers if they are not already installed, which is safe because
installation is idempotent.  Asynchronous like every other run: the thunk
is meaningful once ON-FINISH has fired."
  (benedict-headless-install)
  (let ((collect (benedict-headless-collector session on-finish)))
    (benedict-session-submit session input)
    collect))

(provide 'benedict-headless)
;;; benedict-headless.el ends here
