;;; benedict-log.el --- Level-gated logging with a debug ring  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Two thresholds and a ring buffer, which is the whole of it.
;;
;; The thing worth explaining is why there are two thresholds rather than one.
;; The interesting failures in this system happen inside process filters and
;; timer callbacks -- a stream that stopped, a frame that did not parse -- and
;; by the time a human notices, the bytes that would explain it are gone.  So
;; the default is to RECORD at `info' into a ring the agent can read back with
;; `benedict-log-history', and to ECHO almost nothing.  A log that costs a
;; minibuffer flash per event is a log that gets turned off; a log that costs a
;; cons is one that can be left on.
;;
;; The level entry points are macros so that an argument is never formatted for
;; a record that will not be kept.  `benedict-http' traces every SSE frame; at
;; the default level that has to cost one integer comparison, not a `format'.
;;
;; Nothing here writes to a file and nothing here has a mode.  When a session
;; needs a durable record it has `benedict-store' (SPEC-001 5.4); this is for
;; the last few hundred things that happened, and it is deliberately cheap
;; enough to be always on.
;;
;; NEVER log a credential.  Callers holding one -- `benedict-http' with a
;; header alist, `benedict-auth' with a stored key -- log the shape and not the
;; value.  There is no redaction pass here to rely on.
;;
;; See SPEC-001 3.2.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'benedict)

;;;; Configuration

(defconst benedict-log-levels '(error warn info debug trace)
  "Log levels, most severe first.
A threshold names a level and admits it and everything before it.")

(defun benedict-log-level-rank (level)
  "Return LEVEL's position in `benedict-log-levels'.
Signal `benedict-error' when LEVEL is not a known level.  A lower rank is
more severe, so a record is admitted by a threshold when its rank is less
than or equal to the threshold's."
  (or (cl-position level benedict-log-levels)
      (signal 'benedict-error (list "Unknown log level" level))))

(defcustom benedict-log-level 'info
  "Least severe level kept in the log ring.
Set to nil to record nothing.  Recording is cheap -- one plist per
record, bounded by `benedict-log-limit' -- so this is deliberately more
permissive than `benedict-log-echo-level'."
  :type '(choice (const :tag "Nothing" nil)
                 (const error) (const warn) (const info)
                 (const debug) (const trace))
  :group 'benedict)

(defcustom benedict-log-echo-level 'error
  "Least severe level echoed to the echo area with `message'.
Set to nil to echo nothing.  Kept at `error' by default because a log
that interrupts is a log that gets turned off; read the rest back with
`benedict-log-history'."
  :type '(choice (const :tag "Nothing" nil)
                 (const error) (const warn) (const info)
                 (const debug) (const trace))
  :group 'benedict)

(defcustom benedict-log-limit 500
  "Number of records the log ring retains, oldest dropped first."
  :type 'natnum
  :group 'benedict)

;;;; The ring

(defvar benedict-log--records nil
  "Retained log records, NEWEST first.
Newest first because that is the cheap end of a list to push onto;
`benedict-log-history' reverses for readers, who want oldest first.")

(defvar benedict-log--length 0
  "Number of records currently in `benedict-log--records'.
Tracked rather than measured: trimming is checked on every record, and
`length' on a five-hundred element list in a process filter is exactly
the kind of cost that makes a log worth disabling.")

(defvar benedict-log--dropped 0
  "Number of records evicted from the ring since the last clear.")

(defun benedict-log-enabled-p (level)
  "Return non-nil when a record at LEVEL would be kept or echoed.
The level macros consult this before formatting anything, so a disabled
`benedict-log-trace' costs one comparison rather than a `format'."
  (let ((rank (benedict-log-level-rank level)))
    (or (and benedict-log-level
             (<= rank (benedict-log-level-rank benedict-log-level)))
        (and benedict-log-echo-level
             (<= rank (benedict-log-level-rank benedict-log-echo-level))))))

(defun benedict-log-record (level message)
  "Record MESSAGE at LEVEL, and echo it when LEVEL is severe enough.

MESSAGE is a fully formatted string; the level macros are the usual way
in.  Returns MESSAGE, so it can be used as the value of a form that also
wants to log.  Never signals for an ordinary caller -- an unknown LEVEL
signals `benedict-error', which is a programming error rather than a
runtime condition."
  (let ((rank (benedict-log-level-rank level)))
    (when (and benedict-log-level
               (<= rank (benedict-log-level-rank benedict-log-level)))
      (if (<= benedict-log-limit 0)
          (cl-incf benedict-log--dropped)
        (push (list :level level :time (current-time) :message message)
              benedict-log--records)
        (cl-incf benedict-log--length)
        (when (> benedict-log--length benedict-log-limit)
          (let ((keep (nthcdr (1- benedict-log-limit) benedict-log--records)))
            (cl-incf benedict-log--dropped (- benedict-log--length benedict-log-limit))
            (setq benedict-log--length benedict-log-limit)
            (setcdr keep nil)))))
    (when (and benedict-log-echo-level
               (<= rank (benedict-log-level-rank benedict-log-echo-level)))
      (message "[benedict] %s" message)))
  message)

(defmacro benedict-log--at (level format-string args)
  "Record ARGS applied to FORMAT-STRING at LEVEL, if LEVEL is enabled.
Internal to the level macros: it exists so that FORMAT-STRING and ARGS
are evaluated only when something will keep the result."
  `(when (benedict-log-enabled-p ,level)
     (benedict-log-record ,level (format ,format-string ,@args))))

(defmacro benedict-log-error (format-string &rest args)
  "Log FORMAT-STRING with ARGS at level `error'.
ARGS are evaluated only when the level is enabled."
  (declare (indent 1) (debug (form &rest form)))
  `(benedict-log--at 'error ,format-string ,args))

(defmacro benedict-log-warn (format-string &rest args)
  "Log FORMAT-STRING with ARGS at level `warn'.
ARGS are evaluated only when the level is enabled."
  (declare (indent 1) (debug (form &rest form)))
  `(benedict-log--at 'warn ,format-string ,args))

(defmacro benedict-log-info (format-string &rest args)
  "Log FORMAT-STRING with ARGS at level `info'.
ARGS are evaluated only when the level is enabled."
  (declare (indent 1) (debug (form &rest form)))
  `(benedict-log--at 'info ,format-string ,args))

(defmacro benedict-log-debug (format-string &rest args)
  "Log FORMAT-STRING with ARGS at level `debug'.
ARGS are evaluated only when the level is enabled."
  (declare (indent 1) (debug (form &rest form)))
  `(benedict-log--at 'debug ,format-string ,args))

(defmacro benedict-log-trace (format-string &rest args)
  "Log FORMAT-STRING with ARGS at level `trace'.
ARGS are evaluated only when the level is enabled."
  (declare (indent 1) (debug (form &rest form)))
  `(benedict-log--at 'trace ,format-string ,args))

;;;; Reading it back

(defun benedict-log-history (&optional level)
  "Return retained log records, OLDEST first.

Each record is a plist of `:level', `:time', and `:message'.  With LEVEL,
return only records at LEVEL or more severe.  The list is fresh; mutating
it does not disturb the ring."
  (let ((records (reverse benedict-log--records)))
    (if (null level)
        records
      (let ((limit (benedict-log-level-rank level)))
        (seq-filter (lambda (record)
                      (<= (benedict-log-level-rank (plist-get record :level))
                          limit))
                    records)))))

(defun benedict-log-lines (&optional level)
  "Return retained log records as formatted strings, oldest first.
LEVEL filters as in `benedict-log-history'.  The format is
\"HH:MM:SS.mmm LEVEL MESSAGE\", which is meant to be read rather than
parsed."
  (mapcar (lambda (record)
            (format "%s %-5s %s"
                    (format-time-string "%H:%M:%S.%3N" (plist-get record :time))
                    (plist-get record :level)
                    (plist-get record :message)))
          (benedict-log-history level)))

(defun benedict-log-dropped ()
  "Return how many records the ring has evicted since the last clear.
A non-zero value means `benedict-log-history' has a hole at its old end."
  benedict-log--dropped)

(defun benedict-log-clear ()
  "Discard every retained log record.  Return nil."
  (setq benedict-log--records nil
        benedict-log--length 0
        benedict-log--dropped 0)
  nil)

(provide 'benedict-log)

;;; benedict-log.el ends here
