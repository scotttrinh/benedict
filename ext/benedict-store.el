;;; benedict-store.el --- Append-only transcript log  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (benedict "0.1.0"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Session logs, written one entry at a time as the entry is created.
;;
;; Durability is a design requirement rather than a nicety here.  Benedict's
;; escape hatch is `eval' in the running image, so the agent can break its own
;; runtime -- there is no subprocess boundary to contain a mistake.  Writing
;; every entry through to disk as it is created means a corrupted image loses at
;; most the turn in flight; restart, reload the log, continue.
;;
;; The log is a flat sequence of `read'-able forms, one per line: `prin1' out,
;; `read' in, no schema translation and no JSON round trip, so entries survive
;; with their Lisp types intact.  Because the transcript is a tree stored as an
;; append-only log, nothing is ever rewritten -- there is no update-in-place
;; operation that could tear, and a fork costs one extra line.
;;
;; This file lives in ext/ rather than in the kernel on purpose: the kernel
;; emits entries and the store subscribes.  The kernel never touches the
;; filesystem.  See `benedict-store-on-entry-end' for the subscription that
;; Phase 2 will wire up.
;;
;; See SPEC-001 5.4 and 5.5.

;;; Code:

(require 'cl-lib)
(require 'xdg)
(require 'benedict)
(require 'benedict-message)

;; The store identifies a session only by object identity, and never reads its
;; slots.  That is what lets the kernel keep the store as an opaque handle, and
;; what lets these tests use any object at all as a stand-in for a session.
;;
;; Named rather than required, deliberately.  Reading a log is useful with no
;; kernel loaded at all -- a session browser, a migration script, a test -- and
;; `declare-function' plus these `defvar' declarations create no load-time
;; dependency.  `add-hook' works on a hook variable that is not yet bound, so
;; `benedict-store-install' is correct whether or not the kernel is present.
(declare-function benedict-session-store "benedict-session" (session))
(declare-function benedict-session-p "benedict-session" (object))
(defvar benedict-entry-end-functions)
(defvar benedict-head-change-functions)

;;;; Errors

(define-error 'benedict-store-error
  "Benedict store error"
  'benedict-error)

(define-error 'benedict-store-invalid-session-id
  "Invalid Benedict session id"
  'benedict-store-error)

(define-error 'benedict-store-format-error
  "Unsupported Benedict session log format"
  'benedict-store-error)

;;;; Configuration

(defconst benedict-store-format-version 1
  "Version of the session log record format this file reads and writes.
A log declaring a higher version is refused rather than parsed on the
assumption that the shapes still match.")

(defcustom benedict-store-directory nil
  "Directory holding Benedict session logs.

When nil, resolved at call time to \"benedict/sessions\" under
`xdg-data-home' -- normally ~/.local/share/benedict/sessions.  Resolving
at call time rather than at load time means XDG_DATA_HOME can change
after Emacs starts, and lets tests redirect writes without reloading."
  :type '(choice (const :tag "XDG data directory" nil) directory)
  :group 'benedict)

(defcustom benedict-store-strict-load nil
  "When non-nil, signal rather than warn on a malformed session log.

The default is to warn and return everything that did parse.  A crash can
leave a partial final line, and a transcript that loads all but its last
entry is far more useful than one that refuses to load at all -- being
able to recover is the entire point of writing through in the first
place.  Set this when a test or a tool needs to know that a log was
clean."
  :type 'boolean
  :group 'benedict)

(defconst benedict-store-session-id-regexp "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'"
  "Regexp a session id must match to be usable as a filename.")

(defun benedict-store--directory ()
  "Return the directory session logs are written to."
  (or benedict-store-directory
      (expand-file-name "benedict/sessions" (xdg-data-home))))

(defun benedict-store--check-session-id (session-id)
  "Signal `benedict-store-invalid-session-id' unless SESSION-ID is usable.

Deliberately refuses rather than sanitizing.  Two ids that sanitize to
the same filename would silently write into one log, which is data loss
wearing the costume of robustness."
  (unless (and (stringp session-id)
               (string-match-p benedict-store-session-id-regexp session-id))
    (signal 'benedict-store-invalid-session-id (list session-id))))

(defun benedict-store-session-file (session-id &optional directory)
  "Return the absolute path of SESSION-ID's log file.
DIRECTORY defaults to `benedict-store--directory'.  Signal
`benedict-store-invalid-session-id' when SESSION-ID is not usable as a
filename."
  (benedict-store--check-session-id session-id)
  (expand-file-name (concat session-id ".eld")
                    (or directory (benedict-store--directory))))

;;;; Records

;; A log holds three kinds of record, told apart by a top-level `:type'.  Entry
;; records have no top-level `:type' -- content blocks carry one, entries do
;; not -- so the discriminator is unambiguous and needs no version-specific
;; parsing.
;;
;;   (:type header :format 1 :session-id "..." :created 1785000000.0)
;;   (:id "...-e0001" :parent nil :role user :timestamp 1785000000.5
;;    :content ((:type text :text "hi")) :meta nil)
;;   (:type head :id "...-e0001" :timestamp 1785000042.0)
;;
;; Replay is last-write-wins with no special cases: an entry record inserts the
;; entry and moves head to it; a head record moves head to its id; an unknown
;; `:type' is ignored so a future record kind does not break an older reader.
;;
;; That single rule covers the awkward case.  A session that appends A and B,
;; forks back to A, and then quits logs A, B, and a head record naming A; replay
;; walks head A, B, A and stops on A, which is where the session actually left
;; off.

(defun benedict-store-entry->form (entry)
  "Return ENTRY as the plist written to a session log."
  (list :id (benedict-entry-id entry)
        :parent (benedict-entry-parent entry)
        :role (benedict-entry-role entry)
        :timestamp (benedict-entry-timestamp entry)
        :content (benedict-entry-content entry)
        :meta (benedict-entry-meta entry)))

(defun benedict-store-form->entry (form)
  "Return the `benedict-entry' that FORM, a log record plist, describes.
Signal `benedict-entry-error' when FORM does not describe a valid entry."
  (benedict-entry-create
   :id (plist-get form :id)
   :parent (plist-get form :parent)
   :role (plist-get form :role)
   :content (plist-get form :content)
   :timestamp (plist-get form :timestamp)
   :meta (plist-get form :meta)))

;;;; Writing

(defun benedict-store--write-form (file form)
  "Append FORM to FILE as a single line.

Every binding here prevents a specific failure.  `print-length' and
`print-level' must be nil or an Emacs configured for interactive
printing truncates long content to \"...\", and the log reads back wrong
with no error anywhere -- the quietest corruption available.
`print-circle' is the only setting under which a cyclic structure cannot
hang `prin1' and take the image with it; the reader understands the
labels it emits, and they only appear for structure genuinely shared
twice.  Escaping newlines and control characters is what actually makes
the one-form-per-line promise true, since assistant text is full of
newlines.  Forcing utf-8-emacs-unix keeps Emacs's internal
representation lossless and keeps the line ending LF everywhere.

`write-region-inhibit-fsync' defaults to t in batch mode, so it is bound
back to nil: otherwise every batch and --script run would be silently
non-durable, which is exactly the case durability is for."
  (let ((print-length nil)
        (print-level nil)
        (print-circle t)
        (print-escape-newlines t)
        (print-escape-control-characters t)
        (print-quoted t)
        (coding-system-for-write 'utf-8-emacs-unix)
        (write-region-inhibit-fsync nil))
    (with-file-modes #o600
      (write-region (concat (prin1-to-string form) "\n")
                    nil file 'append 'no-message))))

(cl-defstruct (benedict-store (:constructor benedict-store--create)
                              (:copier nil))
  "A handle on one session's append-only log."
  (session-id nil
              :documentation "Session id this log belongs to.")
  (file nil
        :documentation "Absolute path of the .eld log file.")
  (last-id nil
           :documentation "Id named by the most recently written record.
Used to skip a head record that would only repeat where the log already
is."))

(cl-defun benedict-store-open (session-id &key directory)
  "Open the append-only log for SESSION-ID and return a `benedict-store'.

Creates the log and its DIRECTORY when missing, and never truncates:
reopening an existing session appends to it, because a log is history and
history is not rewritten.

DIRECTORY defaults to `benedict-store--directory'.  Signal
`benedict-store-invalid-session-id' when SESSION-ID cannot be a
filename."
  (let* ((directory (or directory (benedict-store--directory)))
         (file (benedict-store-session-file session-id directory)))
    (unless (file-directory-p directory)
      (with-file-modes #o700 (make-directory directory t)))
    (unless (file-exists-p file)
      (benedict-store--write-form
       file (list :type 'header
                  :format benedict-store-format-version
                  :session-id session-id
                  :created (float-time))))
    (benedict-store--create :session-id session-id :file file)))

(defun benedict-store-append (store entry)
  "Write ENTRY to STORE's log and return ENTRY.

Does nothing when ENTRY is already the last record written, so a hook
that fires twice cannot double-write.  ENTRY must already have an id;
`benedict-transcript-append' assigns one."
  (let ((id (benedict-entry-id entry)))
    (unless id
      (signal 'benedict-entry-error (list "Entry has no id" entry)))
    (unless (equal id (benedict-store-last-id store))
      (benedict-store--write-form (benedict-store-file store)
                                  (benedict-store-entry->form entry))
      (setf (benedict-store-last-id store) id)))
  entry)

(defun benedict-store-set-head (store id)
  "Record in STORE's log that the session's head is now ID.  Return ID.

Writes nothing when ID is already where the log left off, which is the
common case -- appending an entry moves head to it, and only a fork needs
a record of its own."
  (unless (equal id (benedict-store-last-id store))
    (benedict-store--write-form (benedict-store-file store)
                                (list :type 'head :id id :timestamp (float-time)))
    (setf (benedict-store-last-id store) id))
  id)

(defun benedict-store-close (store &optional head-id)
  "Finish writing to STORE, optionally recording HEAD-ID as the final head.
Return STORE.

There is no file handle to release -- each record is written and flushed
on its own -- so this exists to record where a session ended, which
matters when it ended on a fork rather than on its last entry."
  (when head-id
    (benedict-store-set-head store head-id))
  store)

;;;; Reading

(defun benedict-store--problem (message data)
  "Report a malformed log: signal when strict, otherwise warn.
MESSAGE describes the problem and DATA locates it."
  (if benedict-store-strict-load
      (signal 'benedict-store-error (list message data))
    (display-warning 'benedict (format "%s: %S" message data) :warning)))

(defun benedict-store--check-format (form)
  "Signal `benedict-store-format-error' unless FORM's format is readable.
Always signals, even when `benedict-store-strict-load' is nil: guessing
at the shapes of a future format is worse than refusing to load it."
  (let ((format (plist-get form :format)))
    (unless (and (integerp format) (<= format benedict-store-format-version))
      (signal 'benedict-store-format-error
              (list format benedict-store-format-version)))))

(defun benedict-store--consume (form transcript)
  "Apply one log record FORM to TRANSCRIPT."
  (cond
   ((not (consp form))
    (benedict-store--problem "Log record is not a record" form))
   ((eq (plist-get form :type) 'header)
    (benedict-store--check-format form))
   ((eq (plist-get form :type) 'head)
    (setf (benedict-transcript-head transcript) (plist-get form :id)))
   ;; An unrecognized control record belongs to a newer writer within the same
   ;; format version; skip it rather than mistaking it for an entry.
   ((plist-get form :type) nil)
   (t
    (condition-case error
        (let ((entry (benedict-store-form->entry form)))
          (benedict-transcript-insert transcript entry)
          (setf (benedict-transcript-head transcript) (benedict-entry-id entry)))
      ((benedict-entry-error benedict-transcript-error)
       (benedict-store--problem (error-message-string error) form))))))

(defun benedict-store--blank-from-p (start)
  "Return non-nil when only whitespace and comments follow START in this buffer."
  (save-excursion
    (goto-char start)
    (let ((blank t))
      (while (and blank (not (eobp)))
        (skip-chars-forward " \t\n\r\f")
        (cond
         ((eobp) nil)
         ((eq (char-after) ?\;) (forward-line 1))
         (t (setq blank nil))))
      blank)))

(defun benedict-store-load-file (file &optional session-id)
  "Read the session log at FILE and return a `benedict-transcript'.

SESSION-ID names the transcript and defaults to FILE's base name, which
is where `benedict-store-open' put it.  It matters because it is what
subsequent entry ids are minted from.

A log whose final line was truncated by a crash loads everything before
it and reports the truncation through `benedict-store--problem', so
recovery is the default and strictness is opt-in.  A log declaring an
unreadable format version always signals `benedict-store-format-error'."
  (let ((transcript (benedict-transcript-create
                     :session-id (or session-id (file-name-base file))))
        (done nil))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-emacs-unix))
        (insert-file-contents file))
      (goto-char (point-min))
      (while (not done)
        (let ((start (point)))
          (condition-case error
              ;; `read' returning nil is not end of input -- nil is a form --
              ;; so termination has to come from the signal.
              (benedict-store--consume (read (current-buffer)) transcript)
            (end-of-file
             (setq done t)
             (unless (benedict-store--blank-from-p start)
               (benedict-store--problem "Session log ends mid-record" file)))
            (invalid-read-syntax
             (setq done t)
             (benedict-store--problem
              (format "Unreadable form in session log at %d" start)
              (cons file error)))))))
    (benedict-store--validate transcript file)
    transcript))

(defun benedict-store--validate (transcript file)
  "Check TRANSCRIPT, loaded from FILE, for references it cannot resolve."
  (let ((head (benedict-transcript-head transcript)))
    (when (and head (not (benedict-transcript-entry transcript head)))
      (benedict-store--problem "Head refers to a missing entry" (cons file head))
      (setf (benedict-transcript-head transcript)
            (car (benedict-transcript-order transcript))))))

(cl-defun benedict-store-load (session-id &key directory)
  "Read SESSION-ID's log and return a `benedict-transcript'.
DIRECTORY defaults to `benedict-store--directory'.  See
`benedict-store-load-file' for the handling of malformed logs."
  (benedict-store-load-file
   (benedict-store-session-file session-id directory)
   session-id))

;;;; Subscribing a store to a session

;; The kernel emits entries; the store subscribes.  Two hooks carry everything
;; a log needs: `benedict-entry-end-functions' fires once an entry is complete
;; and appended, and `benedict-head-change-functions' fires when head moves any
;; other way -- in practice a fork, without which a session that ends on a
;; branch reloads on the wrong one.
;;
;; Installation is `benedict-store-install' rather than a bare `add-hook' at
;; load time, so that requiring this file to read a log does not quietly
;; subscribe the caller to every session in the image.

(defvar benedict-store--attached
  (make-hash-table :test #'eq :weakness 'key)
  "Hash table mapping a session object to its `benedict-store'.
Weak on its keys so that attaching a store does not keep a finished
session alive.")

(defun benedict-store-attach (session store)
  "Attach STORE to SESSION so that its entries are persisted.  Return STORE.

The weak attachment takes precedence over a real session's `:store' slot.
Replacing an attachment does not close the previous store; callers own every
store handle they attach."
  (puthash session store benedict-store--attached))

(defun benedict-store-detach (session)
  "Stop persisting SESSION's entries and return its effective store.

Removes the weak attachment and, when SESSION is a real session, clears its
`:store' slot too.  Thus a `:store' created session is detached completely,
while arbitrary identity objects retain weak-table attachment support.  The
returned store is not closed or deleted; callers own its lifetime."
  (let ((store (benedict-store-for-session session)))
    (remhash session benedict-store--attached)
    (when (and (fboundp 'benedict-session-p)
               (benedict-session-p session))
      (setf (cl-struct-slot-value 'benedict-session 'store session) nil))
    store))

(defun benedict-store-for-session (session)
  "Return the `benedict-store' persisting SESSION, or nil.

Checks stores attached with `benedict-store-attach' first, then the
session's own store slot when the kernel is loaded and SESSION really is
one.  Anything else is treated as an identity and nothing else, so a
caller may use any object at all as a stand-in for a session."
  (or (gethash session benedict-store--attached)
      (and (fboundp 'benedict-session-p)
           (benedict-session-p session)
           (benedict-session-store session))))

(defun benedict-store-on-entry-end (session entry)
  "Persist ENTRY for SESSION.  Return ENTRY.

Intended for `benedict-entry-end-functions', whose calling convention is
\(SESSION ENTRY) and whose return value is ignored.  Does nothing when
SESSION has no store, so it is safe to install globally."
  (when-let* ((store (benedict-store-for-session session)))
    (benedict-store-append store entry))
  entry)

(defun benedict-store-on-head-change (session _old new)
  "Record NEW as SESSION's head.  Return NEW.

Intended for `benedict-head-change-functions', whose calling convention
is \(SESSION OLD-ID NEW-ID); OLD is ignored, since the log records where
head went rather than how it moved.  Does nothing when SESSION has no
store."
  (when-let* ((store (benedict-store-for-session session)))
    (benedict-store-set-head store new))
  new)

;;;###autoload
(defun benedict-store-install ()
  "Subscribe the store to every session in this image.  Return t.

Adds `benedict-store-on-entry-end' and `benedict-store-on-head-change' to
the kernel's entry and head hooks.  Both no-op for a session with no
store, so installing globally is safe and a session opts in simply by
being created with one.

Idempotent, because `add-hook' with a named function is: calling this
twice, or reloading this file, subscribes nothing twice."
  (add-hook 'benedict-entry-end-functions #'benedict-store-on-entry-end)
  (add-hook 'benedict-head-change-functions #'benedict-store-on-head-change)
  t)

(defun benedict-store-uninstall ()
  "Unsubscribe the store from the kernel's hooks.  Return t.
Sessions keep their stores; nothing further is written to them."
  (remove-hook 'benedict-entry-end-functions #'benedict-store-on-entry-end)
  (remove-hook 'benedict-head-change-functions #'benedict-store-on-head-change)
  t)

(provide 'benedict-store)

;;; benedict-store.el ends here
