;;; benedict-session.el --- Session management for Benedict -*- lexical-binding: t -*-

;;; Commentary:
;; In-memory session data structure that owns conversation state and runtime.
;; Sessions are independent of chat buffers (frontends) and can run headlessly.

;;; Code:

(require 'cl-lib)

;;; Session Struct

(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state and runtime."
  id created-at updated-at title
  messages (message-seq 0)
  (state 'idle) draft pending-question inflight last-error last-request
  root provider model profile meta
  flywire-session attached-frontends
  ;; Telemetry fields
  (accumulated-usage nil)    ; plist: :prompt :completion :total :cost
  (accumulated-seconds 0.0)  ; float: total elapsed time
  last-phase                 ; symbol: complete/error/canceled/idle
  last-usage                 ; raw usage payload from last request
  last-elapsed)              ; float: last request elapsed seconds

;;; Registry

(defvar benedict-session--registry (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session structs.")

(defvar benedict-session--request-seq 0
  "Sequence number for generating unique request IDs.")

(defun benedict-session--generate-id ()
  "Generate a unique session ID."
  (format "ses-%s-%s" (format-time-string "%Y%m%d%H%M%S")
          (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))

(cl-defun benedict-session-create (&key id title root provider model profile meta)
  "Create and register a new session.

Optional keyword arguments:
  :id - Explicit ID (generated if nil)
  :title - Human-readable session title
  :root - Project root directory
  :provider - Provider symbol
  :model - Model identifier
  :profile - Profile symbol
  :meta - Additional metadata plist"
  (let* ((now (current-time))
         (session-id (or id (benedict-session--generate-id)))
         (session (benedict-session--create
                   :id session-id
                   :created-at now
                   :updated-at now
                   :title title
                   :root root
                   :provider provider
                   :model model
                   :profile profile
                   :meta meta)))
    (puthash session-id session benedict-session--registry)
    session))

(defun benedict-session-get (id)
  "Get session by ID from registry."
  (gethash id benedict-session--registry))

(defun benedict-session-list (&optional predicate)
  "List all sessions, optionally filtered by PREDICATE.
Returns sessions sorted by updated-at (most recent first)."
  (let (result)
    (maphash (lambda (_id s)
               (when (or (null predicate) (funcall predicate s))
                 (push s result)))
             benedict-session--registry)
    (sort result (lambda (a b)
                   (time-less-p (benedict-session-updated-at b)
                                (benedict-session-updated-at a))))))

(defun benedict-session-delete (id)
  "Delete session with ID from registry.
Returns t if deleted, nil if not found."
  (when (gethash id benedict-session--registry)
    (remhash id benedict-session--registry)
    t))

(defun benedict-session-touch (session)
  "Update SESSION's updated-at timestamp to now."
  (setf (benedict-session-updated-at session) (current-time)))

;;; Events

(defvar benedict-session-event-hook nil
  "Hook run when session events occur.
Each function receives (SESSION EVENT-TYPE PAYLOAD).")

(defvar benedict-session-ask-user-hook nil
  "Hook run when a question is raised.
Each function receives (SESSION QUESTION-PLIST).")

(defun benedict-session--emit (session event-type &rest payload)
  "Emit EVENT-TYPE for SESSION with PAYLOAD."
  (benedict-session-touch session)
  (run-hook-with-args 'benedict-session-event-hook session event-type payload)
  (when (eq event-type 'question-raised)
    (run-hook-with-args 'benedict-session-ask-user-hook session (car payload))))

(defun benedict-session-set-state (session new-state)
  "Set SESSION state to NEW-STATE, emitting event if changed."
  (let ((old (benedict-session-state session)))
    (unless (eq old new-state)
      (setf (benedict-session-state session) new-state)
      (benedict-session--emit session 'state-changed :old old :new new-state))))

;;; Messages

(defun benedict-session-add-message (session message)
  "Add MESSAGE to SESSION, assigning ID and timestamp.
MESSAGE is a plist with :role, :content, etc.
Returns the message with :id and :timestamp added."
  (let ((id (format "msg-%03d" (cl-incf (benedict-session-message-seq session)))))
    (setq message (plist-put (copy-sequence message) :id id))
    (setq message (plist-put message :timestamp (current-time)))
    (push message (benedict-session-messages session))
    (benedict-session--emit session 'message-added :message message)
    message))

(defun benedict-session-get-message (session id)
  "Get message with ID from SESSION, or nil if not found."
  (cl-find id (benedict-session-messages session)
           :key (lambda (m) (plist-get m :id)) :test #'equal))

(defun benedict-session-update-message (session id updates)
  "Update message with ID in SESSION, merging UPDATES plist.
Returns the updated message or nil if not found."
  (when-let ((msg (benedict-session-get-message session id)))
    (cl-loop for (k v) on updates by #'cddr do (plist-put msg k v))
    (benedict-session--emit session 'message-updated :id id :updates updates)
    msg))

(defun benedict-session-messages-chronological (session)
  "Return SESSION messages in chronological order (oldest first)."
  (reverse (copy-sequence (benedict-session-messages session))))

;;; Draft (streaming accumulator)

(defun benedict-session-start-draft (session &optional content)
  "Start a new draft for SESSION with optional initial CONTENT.
Sets state to streaming."
  (setf (benedict-session-draft session)
        (list :content (or content "")
              :tool-calls nil
              :thinking nil
              :started-at (current-time)))
  (benedict-session-set-state session 'streaming)
  (benedict-session--emit session 'draft-started))

(defun benedict-session-append-draft (session delta)
  "Append DELTA text to SESSION's current draft."
  (when-let ((draft (benedict-session-draft session)))
    (setf (benedict-session-draft session)
          (plist-put draft :content (concat (plist-get draft :content) delta)))
    (benedict-session--emit session 'draft-updated :delta delta)))

(defun benedict-session-add-draft-tool-call (session tool-call)
  "Add TOOL-CALL plist to SESSION's current draft."
  (when-let ((draft (benedict-session-draft session)))
    (setf (benedict-session-draft session)
          (plist-put draft :tool-calls
                     (append (plist-get draft :tool-calls) (list tool-call))))
    (benedict-session--emit session 'draft-updated :tool-call tool-call)))

(defun benedict-session-finalize-draft (session &optional metadata)
  "Finalize SESSION's draft into an assistant message.
METADATA is an optional plist merged into the message.
Returns the created message."
  (when-let ((draft (benedict-session-draft session)))
    (let ((msg (list :role 'assistant
                     :content (plist-get draft :content)
                     :tool-calls (plist-get draft :tool-calls)
                     :metadata metadata)))
      (setf (benedict-session-draft session) nil)
      (benedict-session-set-state session 'idle)
      (benedict-session--emit session 'draft-finalized)
      (benedict-session-add-message session msg))))

(defun benedict-session-discard-draft (session)
  "Discard SESSION's current draft without creating a message."
  (setf (benedict-session-draft session) nil)
  (benedict-session--emit session 'draft-finalized :discarded t))

;;; Inflight Request Tracking

(defun benedict-session-start-request (session handle &optional loop-state)
  "Record that SESSION has an active request with HANDLE.
LOOP-STATE is optional agent loop state.
Returns a unique request ID."
  (let ((id (cl-incf benedict-session--request-seq)))
    (setf (benedict-session-inflight session)
          (list :request handle
                :request-id id
                :started-at (current-time)
                :loop-state loop-state))
    id))

(defun benedict-session-clear-request (session)
  "Clear SESSION's inflight request state."
  (setf (benedict-session-inflight session) nil))

(defun benedict-session-cancel (session)
  "Cancel SESSION's active request, discard draft, set cancelled state.
Returns t if there was something to cancel."
  (when (benedict-session-inflight session)
    (when-let ((started (plist-get (benedict-session-inflight session) :started-at)))
      (setf (benedict-session-last-phase session) 'canceled)
      (setf (benedict-session-last-elapsed session)
            (float-time (time-subtract (current-time) started)))
      (setf (benedict-session-last-usage session) nil))
    (benedict-session-clear-request session)
    (benedict-session-discard-draft session)
    (benedict-session-set-state session 'cancelled)
    t))

(defun benedict-session-request-active-p (session)
  "Return non-nil if SESSION has an active inflight request."
  (not (null (benedict-session-inflight session))))

;;; Telemetry Accumulation

(defun benedict-session--usage-value (usage key)
  "Return value for KEY in USAGE plist or alist."
  (when usage
    (let* ((key-str (if (symbolp key) (symbol-name key) key))
           (sym (intern key-str))
           (kw (intern (concat ":" key-str))))
      (cond
       ((and (listp usage)
             (consp (car usage))
             (not (keywordp (caar usage))))
        (or (cdr (assoc-string key-str usage))
            (cdr (assq sym usage))
            (cdr (assq kw usage))))
       ((and (listp usage) (keywordp (car usage)))
        (plist-get usage kw))
       (t nil)))))

(defun benedict-session--usage-number (usage key)
  "Return numeric value for KEY in USAGE."
  (when-let ((val (benedict-session--usage-value usage key)))
    (if (stringp val) (string-to-number val) val)))

(defun benedict-session--usage-cost-number (usage)
  "Return numeric cost value from USAGE."
  (or (benedict-session--usage-number usage "cost")
      (benedict-session--usage-number usage "total_cost")
      (benedict-session--usage-number usage "total-cost")))

(defun benedict-session-accumulate-usage (session usage elapsed)
  "Accumulate USAGE plist and ELAPSED seconds into SESSION totals.
USAGE should have :prompt-tokens, :completion-tokens, :total-tokens, :cost.
ELAPSED is seconds as a float."
  (when usage
    (let ((current (or (benedict-session-accumulated-usage session)
                       '(:prompt 0 :completion 0 :total 0 :cost 0.0))))
      (setf (benedict-session-accumulated-usage session)
            (list :prompt (+ (or (plist-get current :prompt) 0)
                             (or (benedict-session--usage-number usage "prompt_tokens")
                                 (benedict-session--usage-number usage "prompt-tokens")
                                 (benedict-session--usage-number usage "prompt")
                                 0))
                  :completion (+ (or (plist-get current :completion) 0)
                                 (or (benedict-session--usage-number usage "completion_tokens")
                                     (benedict-session--usage-number usage "completion-tokens")
                                     (benedict-session--usage-number usage "completion")
                                     0))
                  :total (+ (or (plist-get current :total) 0)
                            (or (benedict-session--usage-number usage "total_tokens")
                                (benedict-session--usage-number usage "total-tokens")
                                (benedict-session--usage-number usage "tokens")
                                (benedict-session--usage-number usage "total")
                                0))
                  :cost (+ (or (plist-get current :cost) 0.0)
                           (or (benedict-session--usage-cost-number usage) 0.0))))))
  (when elapsed
    (cl-incf (benedict-session-accumulated-seconds session) elapsed)))

;;; Frontend (buffer) Management

(defun benedict-session--add-frontend (session buffer)
  "Attach BUFFER as a frontend to SESSION."
  (let ((fronts (cl-remove-if-not #'buffer-live-p
                                  (benedict-session-attached-frontends session))))
    (unless (memq buffer fronts)
      (push buffer fronts))
    (setf (benedict-session-attached-frontends session) fronts)))

(defun benedict-session--remove-frontend (session buffer)
  "Detach BUFFER from SESSION."
  (setf (benedict-session-attached-frontends session)
        (delq buffer (benedict-session-attached-frontends session))))

(defun benedict-session-frontends (session)
  "Return list of live frontend buffers for SESSION.
Also cleans up dead buffer references."
  (let ((fronts (cl-remove-if-not #'buffer-live-p
                                  (benedict-session-attached-frontends session))))
    (setf (benedict-session-attached-frontends session) fronts)
    fronts))

(defun benedict-session-has-frontend-p (session)
  "Return non-nil if SESSION has any live frontend buffers."
  (not (null (benedict-session-frontends session))))

;;; Lifecycle

(defun benedict-session-destroy (session)
  "Destroy SESSION, cleaning up resources.
Cancels any active request, tears down flywire, removes from registry."
  (when (benedict-session-request-active-p session)
    (benedict-session-cancel session))
  (when-let ((fw (benedict-session-flywire-session session)))
    (when (fboundp 'benedict-flywire-session-teardown)
      (benedict-flywire-session-teardown fw)))
  (benedict-session--emit session 'destroyed)
  (benedict-session-delete (benedict-session-id session)))

(provide 'benedict-session)
;;; benedict-session.el ends here
