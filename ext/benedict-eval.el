;;; benedict-eval.el --- The eval-elisp tool  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (benedict "0.1.0"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The escape hatch.  Every agent harness gives its model a way out into a
;; general-purpose execution environment; for most that way out is `bash' and
;; the environment is a POSIX shell.  Here it is `eval' and the environment is
;; the Emacs image currently running the agent, which is why self-extension
;; costs a form evaluation rather than a file write plus a reload.
;;
;; Three decisions shape this file.
;;
;; ONE FORM PER CALL.  A caller wanting several wraps them in `progn', which
;; also makes it explicit which value comes back.  Trailing input is refused
;; rather than quietly evaluated, and the refusal happens before anything runs
;; -- a call that is going to be rejected must not have already had half its
;; effect.
;;
;; OUTPUT IS PART OF THE RESULT.  A form whose work is `princ' or `message'
;; returns nil, and returning only that nil would throw away everything the
;; model asked for.  Both are captured around the evaluation and returned
;; alongside the value, including when the form fails partway -- the output a
;; half-finished `dolist' produced is often the only diagnostic there is.
;;
;; NO TIMEOUT, DELIBERATELY.  `with-timeout' needs the form to yield and an
;; elisp loop does not, so a timeout here would look like a safety net without
;; being one.  SPEC-001 13.3 accepts that this tool can wedge or corrupt its own
;; runtime: preventing it would forfeit the whole advantage of the medium, and
;; the mitigations are structural -- entries are written through as they are
;; created, sessions are resumable, and a dispatch filter can route this tool to
;; a subordinate Emacs when isolation is wanted.
;;
;; See SPEC-001 6.1, 6.5, 10.1, and 13.3.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict)
(require 'benedict-tool)
(require 'benedict-session)

;;;; Errors

(define-error 'benedict-eval-error
  "Benedict eval error"
  'benedict-error)

;;;; Configuration

(defcustom benedict-eval-max-output-length 20000
  "Characters of value, output, or messages returned before truncation.

Each of the three is truncated on its own, and a truncated section says
so, because a result that was silently shortened is worse than one that
reports it: the model cannot tell that it is missing something and will
reason from the fragment.  nil returns everything."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'benedict)

;;;; Execution context

(cl-defstruct (benedict-eval-context
               (:constructor benedict-eval-context--create)
               (:copier nil))
  "Captured execution context for `benedict-eval-run'."
  (project-root nil
                :documentation "Absolute directory used as `default-directory'.")
  (target-buffer nil
                 :documentation "Captured live buffer to evaluate in, or nil for an isolated temporary buffer."))

(cl-defun benedict-eval-context-create (&key project-root target-buffer)
  "Capture and return an eval context for PROJECT-ROOT and TARGET-BUFFER.

PROJECT-ROOT is made absolute now, rather than when a later tool call runs.
TARGET-BUFFER may be a live buffer or nil.  Nil deliberately selects a fresh
temporary buffer for each evaluation.  Signal `benedict-eval-error' for an
invalid root or a buffer that is already dead."
  (unless (and (stringp project-root) (file-name-absolute-p project-root))
    (signal 'benedict-eval-error
            (list "Eval project root must be an absolute directory")))
  (when (and target-buffer (not (buffer-live-p target-buffer)))
    (signal 'benedict-eval-error (list "Eval target buffer is not live")))
  (benedict-eval-context--create
   :project-root (file-name-as-directory (expand-file-name project-root))
   :target-buffer target-buffer))

(cl-defun benedict-eval-attach (session &key project-root target-buffer)
  "Attach a captured eval context to SESSION and return it.

PROJECT-ROOT and TARGET-BUFFER have the meanings documented by
`benedict-eval-context-create'.  Later tool calls never consult the ambient
current buffer or `default-directory'."
  (let ((context (benedict-eval-context-create
                  :project-root project-root :target-buffer target-buffer)))
    (benedict-session-put session :benedict-eval-context context)
    context))

(defun benedict-eval-detach (session)
  "Remove SESSION's eval context and return the previous context."
  (let ((context (benedict-session-get session :benedict-eval-context)))
    (benedict-session-put session :benedict-eval-context nil)
    context))

;;;; Reading

(defun benedict-eval--blank-from-p (source start)
  "Return non-nil when only whitespace and comments follow START in SOURCE.
START is a position in SOURCE, as `read-from-string' returns.  Trailing
comments are blank because a form is often sent with an explanation after
it, and refusing that would be a rejection over punctuation."
  (let ((position start)
        (length (length source))
        (blank t))
    (while (and blank (< position length))
      (let ((character (aref source position)))
        (cond
         ((memq character '(?\s ?\t ?\n ?\r ?\f)) (cl-incf position))
         ((eq character ?\;)
          (setq position (or (cl-position ?\n source :start position) length)))
         (t (setq blank nil)))))
    blank))

(defun benedict-eval--read (source)
  "Return the one Emacs Lisp form found in SOURCE.

Signal `benedict-eval-error' when SOURCE is not a readable string holding
exactly one form, carrying a message written for the model that sent it.
A reader failure is re-signalled the same way rather than escaping as
`end-of-file', because \"your syntax is wrong\" and \"your form failed\"
are different problems and the model has to be able to tell them apart.

Reads without evaluating, so a call this refuses has had no effect."
  (unless (stringp source)
    (signal 'benedict-eval-error (list (format "Form is not a string: %S" source))))
  (when (string-blank-p source)
    (signal 'benedict-eval-error (list "No form to evaluate")))
  (pcase-let ((`(,form . ,end)
               (condition-case error
                   (read-from-string source)
                 ((end-of-file invalid-read-syntax)
                  (signal 'benedict-eval-error
                          (list (format "Cannot read form: %s"
                                        (error-message-string error))))))))
    (unless (benedict-eval--blank-from-p source end)
      (signal 'benedict-eval-error
              (list (format "Expected a single form, found more input at %d.  \
Wrap several forms in `progn'" end))))
    form))

;;;; Formatting

(defun benedict-eval--print (value)
  "Return VALUE printed the way the model should see it.

`print-circle' is on because a cyclic value would otherwise hang `prin1'
and take the image with it.  `print-length' and `print-level' are off
because their truncation is an unannounced \"...\" that reads like part
of the data; truncation here is explicit and says how much it dropped."
  (let ((print-circle t)
        (print-length nil)
        (print-level nil)
        (print-quoted t))
    (prin1-to-string value)))

(defun benedict-eval--truncate (string)
  "Return STRING cut to `benedict-eval-max-output-length', saying so if it was."
  (let ((limit benedict-eval-max-output-length))
    (if (and limit (> (length string) limit))
        (concat (substring string 0 limit)
                (format "\n[truncated: %d of %d characters shown]"
                        limit (length string)))
      string)))

(defun benedict-eval--section (label text)
  "Return TEXT under LABEL, or nil when TEXT is empty."
  (unless (or (null text) (string-empty-p (string-trim text)))
    (concat label ":\n" (benedict-eval--truncate (string-trim-right text)))))

(defun benedict-eval--content (head output messages)
  "Return the result content: HEAD, then OUTPUT and MESSAGES when present."
  (string-join (delq nil (list head
                               (benedict-eval--section "Output" output)
                               (benedict-eval--section "Messages" messages)))
               "\n\n"))

;;;; Evaluating

(defun benedict-eval-run (source context)
  "Evaluate SOURCE in captured CONTEXT and return a tool result.

SOURCE is a string holding one Emacs Lisp form.
Return a `benedict-tool-result-value' carrying the printed value, plus
anything the form wrote to standard output or logged with `message'.

Never signals: a form that fails becomes a failed result explaining why,
alongside whatever output it managed to produce first.  A tool that broke
has to tell the model what happened so it can try something else.

Evaluates with lexical binding.  CONTEXT supplies the project root and an
optional captured target buffer.  If that buffer has since been killed, return
a failed result without evaluating SOURCE."
  (if (not (benedict-eval-context-p context))
      (benedict-tool-result-error "Error: Invalid eval execution context")
    (let* ((log (messages-buffer))
         ;; A marker rather than a position: `message-log-max' truncates the
         ;; log from the top, which would leave a recorded integer pointing
         ;; into the middle of some older message.
         (mark (with-current-buffer log (copy-marker (point-max))))
         (output (generate-new-buffer " *benedict-eval-output*"))
         (value nil)
         (failure nil))
    (unwind-protect
        (let ((target (benedict-eval-context-target-buffer context))
              (root (benedict-eval-context-project-root context)))
          (if (and target (not (buffer-live-p target)))
              (setq failure "Captured eval target buffer was killed")
            (let ((work-buffer (or target
                                   (generate-new-buffer " *benedict-eval-context*"))))
              (unwind-protect
                  (with-current-buffer work-buffer
                    (let ((default-directory root))
                      (condition-case error
                          (let* ((form (benedict-eval--read source))
                                 (standard-output output))
                            (setq value (benedict-eval--print (eval form t))))
                        (benedict-eval-error (setq failure (cadr error)))
                        (error (setq failure (error-message-string error))))))
                (when (and (null target) (buffer-live-p work-buffer))
                  (kill-buffer work-buffer)))))
          (let ((written (with-current-buffer output (buffer-string)))
                (logged (with-current-buffer log
                          (buffer-substring-no-properties mark (point-max)))))
            (if failure
                (benedict-tool-result-error
                 (benedict-eval--content (concat "Error: " failure) written logged))
              (benedict-tool-result
               :content (benedict-eval--content
                         (benedict-eval--truncate value) written logged)))))
      (set-marker mark nil)
      (kill-buffer output)))))

(defun benedict-eval--run (source)
  "Evaluate SOURCE using an explicit standalone context captured now.

Compatibility helper for callers outside a session.  It captures the caller's
current buffer and `default-directory' before evaluation; session tool calls
use `benedict-eval-attach' instead."
  (benedict-eval-run
   source
   (benedict-eval-context-create
    :project-root default-directory :target-buffer (current-buffer))))

;;;; The tool

(defun benedict-eval--handler (invocation)
  "Evaluate INVOCATION's `form' argument and return the result."
  (let ((source (benedict-tool-arg invocation :form)))
    (if (null benedict-current-session)
        (benedict-eval--run source)
      (if-let ((context (benedict-session-get
                         benedict-current-session :benedict-eval-context)))
          (benedict-eval-run source context)
        (benedict-tool-result-error
         "No eval execution context is attached to this session; call `benedict-eval-attach' with an explicit project root and optional target buffer")))))

(benedict-deftool eval-elisp
  :label "Evaluate Elisp"
  :description "Evaluate an Emacs Lisp form in the running Emacs image and \
return its value.

This is the primary mechanism for inspecting and modifying Benedict \
itself.  The image is live: a function you define or redefine here takes \
effect immediately, with no reload and no restart, and is callable on \
your very next turn.

Pass exactly one form.  Wrap several in `progn' when you need them, which \
also makes it explicit which value comes back.

The value is printed with `prin1'.  Anything the form writes with `princ' \
or `print', and anything it logs with `message', is returned alongside \
it.  A form that signals an error comes back as a failed result \
explaining what went wrong, together with the output it produced before \
failing."
  :parameters '((form :type string :required t
                      :description "A single Emacs Lisp form.  \
Wrap several in `progn'."))
  :sync t
  :handler #'benedict-eval--handler)

(provide 'benedict-eval)

;;; benedict-eval.el ends here
