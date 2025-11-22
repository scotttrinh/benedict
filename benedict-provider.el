;;; benedict-provider.el --- Provider registry and helpers -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provides a minimal registry for provider implementations and helper
;; functions that dispatch requests to the active provider.

;;; Code:

(require 'cl-lib)
(require 'json)

(defgroup benedict-provider nil
  "Shared customization for Benedict providers."
  :group 'benedict
  :prefix "benedict-provider-")

(defcustom benedict-provider-log-level nil
  "Minimum severity for provider logs.
When nil logging is disabled. Set to `debug' to record request/response
traffic or `trace' for the most verbose output."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Errors" error)
                 (const :tag "Warnings" warn)
                 (const :tag "Info" info)
                 (const :tag "Debug" debug)
                 (const :tag "Trace" trace))
  :group 'benedict-provider)

(defcustom benedict-provider-log-file-level 'trace
  "Minimum severity for logs written to disk.
When nil, file logging is disabled. Defaults to `trace' so per-request files
capture the most verbose output without spamming *Messages*."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Errors" error)
                 (const :tag "Warnings" warn)
                 (const :tag "Info" info)
                 (const :tag "Debug" debug)
                 (const :tag "Trace" trace))
  :group 'benedict-provider)

(defcustom benedict-provider-log-directory nil
  "Directory where provider log files are written.
Each request writes JSONL entries to a file named
\"benedict-<provider>-<request-id>.log\". The directory is created
on demand."
  :type '(choice (const :tag "Disabled" nil) directory)
  :group 'benedict-provider)

(defcustom benedict-provider-log-retain-count 5
  "Number of per-request log files to retain.
When exceeded, the oldest request log is deleted."
  :type 'integer
  :group 'benedict-provider)

(defconst benedict-provider--log-level-ranks
  '((error . 4)
    (warn . 3)
    (info . 2)
    (debug . 1)
    (trace . 0))
  "Relative severity ordering for provider logs.")

(defun benedict-provider--log-level-rank (level)
  "Return numeric rank for LEVEL symbol or nil."
  (alist-get level benedict-provider--log-level-ranks nil nil #'eq))

(defun benedict-provider-log-enabled-p (level)
  "Return non-nil when LEVEL should be logged under `benedict-provider-log-level'."
  (let ((threshold (benedict-provider--log-level-rank benedict-provider-log-level))
        (value (benedict-provider--log-level-rank level)))
    (and threshold value (>= value threshold))))

(defun benedict-provider--log-file-enabled-p (level)
  "Return non-nil when LEVEL should be persisted to disk."
  (let ((threshold (benedict-provider--log-level-rank benedict-provider-log-file-level))
        (value (benedict-provider--log-level-rank level)))
    (and threshold value (>= value threshold))))

(defun benedict-provider--log-key (key)
  "Normalize KEY into a string for structured logs."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   (t (format "%s" key))))

(defun benedict-provider--log-normalize-plist (plist)
  "Convert PLIST into an alist with string keys."
  (let (result)
    (while plist
      (let* ((key (pop plist))
             (value (pop plist)))
        (push (cons (benedict-provider--log-key key) value) result)))
    (nreverse result)))

(defun benedict-provider--log-format (payload)
  "Return PAYLOAD (a plist) encoded for log output."
  (or (ignore-errors
        (json-encode (benedict-provider--log-normalize-plist payload)))
      (with-temp-buffer
        (let ((print-level nil)
              (print-length nil))
          (prin1 payload (current-buffer))
          (buffer-string)))))

(defvar benedict-provider--log-file-ring nil
  "Ring of recent per-request log files for cleanup.")

(defun benedict-provider--log-file-path (provider request-id)
  "Return file path for PROVIDER and REQUEST-ID, or nil when disabled."
  (when (and benedict-provider-log-directory request-id)
    (let* ((dir (file-name-as-directory benedict-provider-log-directory))
           (safe-id (replace-regexp-in-string "[^[:alnum:]._+-]" "-" (format "%s" request-id)))
           (safe-provider (replace-regexp-in-string "[^[:alnum:]._+-]" "-" (format "%s" provider))))
      (expand-file-name (format "benedict-%s-%s.log" safe-provider safe-id) dir))))

(defun benedict-provider--log-file-track (request-id path)
  "Track PATH for REQUEST-ID and evict old entries."
  (let ((existing (assoc request-id benedict-provider--log-file-ring)))
    (unless existing
      (push (cons request-id path) benedict-provider--log-file-ring)
      (when (> (length benedict-provider--log-file-ring)
               (max 1 benedict-provider-log-retain-count))
        (let* ((oldest (car (last benedict-provider--log-file-ring)))
               (file (cdr oldest)))
          (setq benedict-provider--log-file-ring
                (butlast benedict-provider--log-file-ring))
          (when (and file (file-exists-p file))
            (ignore-errors (delete-file file))))))))

(defun benedict-provider--log-write-file (provider level payload &rest data)
  "Append a log entry to the per-request file when enabled."
  (when (and (benedict-provider--log-file-enabled-p level)
             benedict-provider-log-directory)
    (let* ((request-id (plist-get data :request-id))
           (path (benedict-provider--log-file-path provider request-id)))
      (when path
        (condition-case err
            (progn
              (make-directory (file-name-directory path) t)
              (benedict-provider--log-file-track request-id path)
              (with-temp-buffer
                (insert (benedict-provider--log-format payload) "\n")
                (write-region (point-min) (point-max) path :append 'silent)))
          (error
           ;; Fall back to echoing the failure; avoid recursion by skipping file path here
           (message "[Benedict provider] %s"
                    (format "Failed to write log file %s: %s" path (error-message-string err)))))))))

(cl-defun benedict-provider-log (provider level event &rest data)
  "Emit a structured log for PROVIDER at LEVEL describing EVENT.
DATA is a plist merged into the log payload."
  (when (or (benedict-provider-log-enabled-p level)
            (benedict-provider--log-file-enabled-p level))
    (let* ((timestamp (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ" nil t))
           (payload (append (list :timestamp timestamp
                                  :provider provider
                                  :level level
                                  :event event)
                            data)))
      (when (benedict-provider-log-enabled-p level)
        (message "[Benedict provider] %s"
                 (benedict-provider--log-format payload)))
      (apply #'benedict-provider--log-write-file provider level payload data))))

(cl-defun benedict-provider-log-debug (provider event &rest data)
  "Convenience wrapper logging EVENT for PROVIDER at debug LEVEL.
DATA mirrors `benedict-provider-log'."
  (apply #'benedict-provider-log provider 'debug event data))

(cl-defun benedict-provider-log-trace (provider event &rest data)
  "Convenience wrapper logging EVENT for PROVIDER at trace LEVEL."
  (apply #'benedict-provider-log provider 'trace event data))

(cl-defstruct (benedict-provider
               (:constructor benedict-provider--create))
  "Structure describing a provider implementation."
  id name send capabilities cancel)

(defvar benedict-provider--registry (make-hash-table :test 'eq)
  "Internal registry of available Benedict providers keyed by ID symbol.")

(defun benedict-provider-register (provider)
  "Register PROVIDER (a `benedict-provider' struct) and return it."
  (puthash (benedict-provider-id provider) provider benedict-provider--registry)
  provider)

(defun benedict-provider-lookup (id)
  "Return provider struct registered under ID, or nil."
  (gethash id benedict-provider--registry))

(defun benedict-provider-list-ids ()
  "Return a list of all registered provider ID symbols."
  (let (ids)
    (maphash (lambda (id _provider) (push id ids)) benedict-provider--registry)
    (sort ids (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun benedict-provider-display-name (provider-id)
  "Return a human-readable name for PROVIDER-ID.
Falls back to capitalized ID if provider is not registered."
  (if-let ((provider (benedict-provider-lookup provider-id)))
      (benedict-provider-name provider)
    (when provider-id
      (capitalize (symbol-name provider-id)))))

(defun benedict-provider-current ()
  "Return the currently configured provider struct.
Signals an error when `benedict-provider' is not registered."
  (let ((provider (benedict-provider-lookup benedict-provider)))
    (unless provider
      (error "Provider %S is not registered" benedict-provider))
    provider))

(cl-defun benedict-provider-dispatch
    (request &key on-success on-error on-delta on-complete)
  "Send REQUEST to the active provider.
REQUEST is provider-specific data (typically a plist).
Callbacks:
- ON-SUCCESS: invoked with the final payload (non-streaming or fallback).
- ON-ERROR: invoked when the provider fails to service the request.
- ON-DELTA: optional streaming chunk callback (called zero or more times).
- ON-COMPLETE: optional final callback for streaming providers; when nil the
  provider should fall back to ON-SUCCESS."
  (let ((provider (benedict-provider-current)))
    (funcall (benedict-provider-send provider)
             provider request
             :on-success on-success
             :on-error on-error
             :on-delta on-delta
             :on-complete on-complete)))

(defun benedict-provider-abort (handle)
  "Ask the active provider to cancel HANDLE (a provider-specific token)."
  (when handle
    (let* ((provider (benedict-provider-current))
           (cancel-fn (benedict-provider-cancel provider)))
      (when (functionp cancel-fn)
        (funcall cancel-fn provider handle)))))

(provide 'benedict-provider)
;;; benedict-provider.el ends here
