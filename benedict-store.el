;;; benedict-store.el --- Session persistence for Benedict -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider-agnostic session persistence using readable s-expressions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict-harness)
(require 'benedict-message)

(declare-function benedict-session--create "benedict-session")
(declare-function benedict-session-id "benedict-session" (session))
(declare-function benedict-session-title "benedict-session" (session))
(declare-function benedict-session-created-at "benedict-session" (session))
(declare-function benedict-session-updated-at "benedict-session" (session))
(declare-function benedict-session-entries-chronological "benedict-session" (session))
(declare-function benedict-session-message-seq "benedict-session" (session))
(declare-function benedict-session-state "benedict-session" (session))
(declare-function benedict-session-draft "benedict-session" (session))
(declare-function benedict-session-pending-question "benedict-session" (session))
(declare-function benedict-session-last-error "benedict-session" (session))
(declare-function benedict-session-last-request "benedict-session" (session))
(declare-function benedict-session-root "benedict-session" (session))
(declare-function benedict-session-provider "benedict-session" (session))
(declare-function benedict-session-model "benedict-session" (session))
(declare-function benedict-session-profile "benedict-session" (session))
(declare-function benedict-session-meta "benedict-session" (session))
(declare-function benedict-session-tools "benedict-session" (session))
(declare-function benedict-session-system-prompt "benedict-session" (session))
(declare-function benedict-session-autonomy "benedict-session" (session))
(declare-function benedict-session-verbosity "benedict-session" (session))
(declare-function benedict-session-harness "benedict-session" (session))
(declare-function benedict-session-accumulated-usage "benedict-session" (session))
(declare-function benedict-session-accumulated-seconds "benedict-session" (session))
(declare-function benedict-session-last-phase "benedict-session" (session))
(declare-function benedict-session-last-usage "benedict-session" (session))
(declare-function benedict-session-last-elapsed "benedict-session" (session))
(declare-function benedict-session-loop-turn-count "benedict-session" (session))
(declare-function benedict-session-loop-start-time "benedict-session" (session))
(declare-function benedict-session-loop-config "benedict-session" (session))

(defgroup benedict-store nil
  "Session persistence for Benedict."
  :group 'benedict
  :prefix "benedict-store-")

(defcustom benedict-store-root
  (expand-file-name ".benedict/sessions" default-directory)
  "Root directory for Benedict session persistence."
  :type 'directory
  :group 'benedict-store)

(defconst benedict-store-metadata-file "metadata.sexp"
  "Filename used for serialized session metadata.")

(defconst benedict-store-transcript-file "transcript.sexp"
  "Filename used for serialized session transcript entries.")

(defun benedict-store--time-to-sexp (value)
  "Return VALUE converted into a readable time sexp."
  (when value
    (time-convert value 'list)))

(defun benedict-store--copy-plist (value)
  "Return VALUE as a deep-copied plist or list."
  (when value
    (copy-tree value)))

(defun benedict-store--message->sexp (message)
  "Serialize MESSAGE into a readable plist."
  (list :id (benedict-message-id message)
        :kind (benedict-message-kind message)
        :role (benedict-message-role message)
        :blocks (benedict-store--copy-plist (benedict-message-blocks message))
        :metadata (benedict-store--copy-plist (benedict-message-metadata message))
        :timestamp (benedict-store--time-to-sexp (benedict-message-timestamp message))))

(defun benedict-store--message-from-sexp (data)
  "Deserialize DATA into a canonical message."
  (benedict-message-create
   :id (plist-get data :id)
   :kind (plist-get data :kind)
   :role (plist-get data :role)
   :blocks (benedict-store--copy-plist (plist-get data :blocks))
   :metadata (benedict-store--copy-plist (plist-get data :metadata))
   :timestamp (plist-get data :timestamp)))

(defun benedict-store--harness->sexp (harness)
  "Serialize HARNESS into a plist."
  (when harness
    (list :scope (benedict-store--copy-plist (benedict-harness-scope harness))
          :budgets (benedict-store--copy-plist (benedict-harness-budgets harness))
          :audit-log (benedict-store--copy-plist (benedict-harness-audit-log harness)))))

(defun benedict-store--harness-from-sexp (data)
  "Deserialize DATA into a harness."
  (when data
    (benedict-harness-create
     :scope (benedict-store--copy-plist (plist-get data :scope))
     :budgets (benedict-store--copy-plist (plist-get data :budgets))
     :audit-log (benedict-store--copy-plist (plist-get data :audit-log)))))

(defun benedict-store-session-path (session-id &optional root)
  "Return the session directory path for SESSION-ID under ROOT."
  (expand-file-name session-id (or root benedict-store-root)))

(defun benedict-store--metadata-path (session-id &optional root)
  "Return the metadata file path for SESSION-ID under ROOT."
  (expand-file-name benedict-store-metadata-file
                    (benedict-store-session-path session-id root)))

(defun benedict-store--transcript-path (session-id &optional root)
  "Return the transcript file path for SESSION-ID under ROOT."
  (expand-file-name benedict-store-transcript-file
                    (benedict-store-session-path session-id root)))

(defun benedict-store--ensure-directory (path)
  "Ensure PATH exists as a directory."
  (make-directory path t)
  path)

(defun benedict-store--read-first-sexp (path)
  "Read and return the first sexp from PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-min))
    (read (current-buffer))))

(defun benedict-store--read-transcript (path)
  "Read all transcript entries from PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-min))
    (let (entries)
      (condition-case nil
          (while t
            (skip-chars-forward "\n\t\r ")
            (push (read (current-buffer)) entries))
        (end-of-file nil))
      (nreverse entries))))

(defun benedict-store--write-atomically (path writer parser)
  "Write PATH atomically using WRITER and validate it with PARSER."
  (let* ((directory (file-name-directory path))
         (basename (file-name-nondirectory path))
         (temp-path (make-temp-file (expand-file-name (concat "." basename ".tmp-")
                                                      directory))))
    (unwind-protect
        (progn
          (funcall writer temp-path)
          (funcall parser temp-path)
          (rename-file temp-path path t))
      (when (file-exists-p temp-path)
        (delete-file temp-path)))))

(defun benedict-store--session-metadata (session)
  "Return SESSION metadata as a serializable plist."
  (list :format-version 1
        :id (benedict-session-id session)
        :title (benedict-session-title session)
        :created-at (benedict-store--time-to-sexp (benedict-session-created-at session))
        :updated-at (benedict-store--time-to-sexp (benedict-session-updated-at session))
        :message-seq (benedict-session-message-seq session)
        :state (benedict-session-state session)
        :draft (benedict-store--copy-plist (benedict-session-draft session))
        :pending-question (benedict-store--copy-plist (benedict-session-pending-question session))
        :last-error (benedict-store--copy-plist (benedict-session-last-error session))
        :last-request (benedict-store--copy-plist (benedict-session-last-request session))
        :root (benedict-session-root session)
        :provider (benedict-session-provider session)
        :model (benedict-session-model session)
        :profile (benedict-session-profile session)
        :meta (benedict-store--copy-plist (benedict-session-meta session))
        :tools (benedict-store--copy-plist (benedict-session-tools session))
        :system-prompt (benedict-store--copy-plist (benedict-session-system-prompt session))
        :autonomy (benedict-session-autonomy session)
        :verbosity (benedict-session-verbosity session)
        :harness (benedict-store--harness->sexp (benedict-session-harness session))
        :accumulated-usage (benedict-store--copy-plist (benedict-session-accumulated-usage session))
        :accumulated-seconds (benedict-session-accumulated-seconds session)
        :last-phase (benedict-session-last-phase session)
        :last-usage (benedict-store--copy-plist (benedict-session-last-usage session))
        :last-elapsed (benedict-session-last-elapsed session)
        :loop-turn-count (benedict-session-loop-turn-count session)
        :loop-start-time (benedict-store--time-to-sexp (benedict-session-loop-start-time session))
        :loop-config (benedict-store--copy-plist (benedict-session-loop-config session))))

(defun benedict-store--metadata->session (metadata entries)
  "Create a session from METADATA and ENTRIES."
  (benedict-session--create
   :id (plist-get metadata :id)
   :created-at (plist-get metadata :created-at)
   :updated-at (or (plist-get metadata :updated-at)
                   (plist-get metadata :created-at)
                   (current-time))
   :title (plist-get metadata :title)
   :entries (reverse (copy-sequence entries))
   :message-seq (or (plist-get metadata :message-seq) (length entries))
   :state (or (plist-get metadata :state) 'idle)
   :draft (benedict-store--copy-plist (plist-get metadata :draft))
   :pending-question (benedict-store--copy-plist (plist-get metadata :pending-question))
   :last-error (benedict-store--copy-plist (plist-get metadata :last-error))
   :last-request (benedict-store--copy-plist (plist-get metadata :last-request))
   :root (plist-get metadata :root)
   :provider (plist-get metadata :provider)
   :model (plist-get metadata :model)
   :profile (plist-get metadata :profile)
   :meta (benedict-store--copy-plist (plist-get metadata :meta))
   :tools (benedict-store--copy-plist (plist-get metadata :tools))
   :system-prompt (benedict-store--copy-plist (plist-get metadata :system-prompt))
   :autonomy (plist-get metadata :autonomy)
   :verbosity (plist-get metadata :verbosity)
   :harness (benedict-store--harness-from-sexp (plist-get metadata :harness))
   :accumulated-usage (benedict-store--copy-plist (plist-get metadata :accumulated-usage))
   :accumulated-seconds (or (plist-get metadata :accumulated-seconds) 0.0)
   :last-phase (plist-get metadata :last-phase)
   :last-usage (benedict-store--copy-plist (plist-get metadata :last-usage))
   :last-elapsed (plist-get metadata :last-elapsed)
   :loop-turn-count (or (plist-get metadata :loop-turn-count) 0)
   :loop-start-time (plist-get metadata :loop-start-time)
   :loop-config (benedict-store--copy-plist (plist-get metadata :loop-config))))

(cl-defun benedict-store-save-session (session &key root)
  "Persist SESSION under ROOT and return the session directory path."
  (let* ((session-id (benedict-session-id session))
         (session-path (benedict-store--ensure-directory
                        (benedict-store-session-path session-id root)))
         (metadata-path (benedict-store--metadata-path session-id root))
         (transcript-path (benedict-store--transcript-path session-id root))
         (metadata (benedict-store--session-metadata session))
         (entries (mapcar #'benedict-store--message->sexp
                          (benedict-session-entries-chronological session))))
    (benedict-store--write-atomically
     metadata-path
     (lambda (path)
       (with-temp-file path
         (let ((print-length nil)
               (print-level nil))
           (prin1 metadata (current-buffer))
           (insert "\n"))))
     #'benedict-store--read-first-sexp)
    (benedict-store--write-atomically
     transcript-path
     (lambda (path)
       (with-temp-file path
         (let ((print-length nil)
               (print-level nil))
           (dolist (entry entries)
             (prin1 entry (current-buffer))
             (insert "\n")))))
     #'benedict-store--read-transcript)
    session-path))

(cl-defun benedict-store-load-session (path &key root)
  "Load a persisted session from PATH or session id under ROOT."
  (let* ((session-path (if (file-directory-p path)
                           path
                         (benedict-store-session-path path root)))
         (metadata-path (expand-file-name benedict-store-metadata-file session-path))
         (transcript-path (expand-file-name benedict-store-transcript-file session-path))
         (metadata (benedict-store--read-first-sexp metadata-path))
         (entries (mapcar #'benedict-store--message-from-sexp
                          (benedict-store--read-transcript transcript-path))))
    (benedict-store--metadata->session metadata entries)))

(cl-defun benedict-store-append-entry (session entry &key root)
  "Persist SESSION after ENTRY was added, returning the session directory path."
  (ignore entry)
  (benedict-store-save-session session :root root))

(provide 'benedict-store)
;;; benedict-store.el ends here
