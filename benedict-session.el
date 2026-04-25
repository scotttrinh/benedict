;;; benedict-session.el --- Session management for Benedict -*- lexical-binding: t -*-

;;; Commentary:
;; In-memory session data structure that owns conversation state and runtime.
;; Sessions are independent of chat buffers (frontends) and can run headlessly.

;;; Code:

(require 'cl-lib)
(require 'lgr)
(require 'benedict-event)
(require 'benedict-harness)
(require 'benedict-message)

(autoload 'benedict-store-save-session "benedict-store" nil nil)
(autoload 'benedict-store-load-session "benedict-store" nil nil)
(autoload 'benedict-store-session-path "benedict-store" nil nil)

(defvar benedict-session--logger (lgr-get-logger "benedict.session")
  "Logger for session events.")

(defvar benedict-session-tool-invoke-fn nil
  "Global default tool invocation function.")

(defvar benedict-session-provider-dispatch-fn nil
  "Global default provider dispatch function.")

;;; Session Struct

(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state and runtime."
  id created-at updated-at title
  entries
  (message-seq 0)
  draft inflight last-error last-request
  root provider model profile meta
  tools system-prompt autonomy verbosity
  harness tool-invoke-fn
  flywire-session attached-frontends
  ;; Runtime state
  (run-state 'idle)
  turn-state
  outstanding-yields
  events
  provider-dispatch-fn
  action-pipeline-functions
  approved-capabilities
  ;; Telemetry fields
  (accumulated-usage nil)    ; plist: :prompt :completion :total :cost
  (accumulated-seconds 0.0)  ; float: total elapsed time
  last-phase                 ; symbol: complete/error/canceled/idle
  last-usage                 ; raw usage payload from last request
  last-elapsed               ; float: last request elapsed seconds
  ;; Loop state
  (loop-turn-count 0)
  loop-start-time
  loop-config)               ; plist: :max-turns :max-time :max-tokens

;;; Registry

(defvar benedict-session--registry (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session structs.")

(defvar benedict-session--request-seq 0
  "Sequence number for generating unique request IDs.")

(defun benedict-session--generate-id ()
  "Generate a unique session ID."
  (format "ses-%s-%s" (format-time-string "%Y%m%d%H%M%S")
          (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))

(cl-defun benedict-session-create (&key id title root provider model profile meta
                                        tools system-prompt autonomy verbosity harness
                                        tool-invoke-fn provider-dispatch-fn
                                        action-pipeline-functions approved-capabilities)
  "Create and register a new session with TITLE.

Optional keyword arguments:
  :id - Explicit ID (generated if nil)
  :title - Human-readable session title
  :root - Project root directory
  :provider - Provider symbol
  :model - Model identifier
  :profile - Profile symbol
  :meta - Additional metadata plist
  :tools - Tool definitions
  :system-prompt - List of system messages
  :autonomy - Autonomy level symbol
  :verbosity - Verbosity level symbol
  :harness - Attached tool harness
  :tool-invoke-fn - Runtime tool invocation function
  :provider-dispatch-fn - Core provider dispatch function
  :action-pipeline-functions - Core action pipeline stages
  :approved-capabilities - Initially approved capabilities"
  (let* ((now (current-time))
         (session-id (or id (benedict-session--generate-id)))
         (initial-harness
          (or harness
              (benedict-harness-create
               :scope (when root (list :paths (list root)))
               :budgets nil)))
         (session (benedict-session--create
                   :id session-id
                   :created-at now
                   :updated-at now
                   :title title
                   :root root
                   :provider provider
                   :model model
                   :profile profile
                   :meta meta
                   :tools tools
                   :system-prompt system-prompt
                   :autonomy autonomy
                   :verbosity verbosity
                   :harness initial-harness
                   :tool-invoke-fn tool-invoke-fn
                   :provider-dispatch-fn provider-dispatch-fn
                   :action-pipeline-functions action-pipeline-functions
                   :approved-capabilities approved-capabilities)))
    (puthash session-id session benedict-session--registry)
    session))

(defun benedict-session-configure (session &rest config)
  "Update SESSION configuration.
CONFIG is a plist with keys: :provider :model :profile :tools
:system-prompt :autonomy :verbosity :loop-config."
  (cl-loop for (key value) on config by #'cddr
           do (pcase key
                (:provider (setf (benedict-session-provider session) value))
                (:model (setf (benedict-session-model session) value))
                (:profile (setf (benedict-session-profile session) value))
                (:tools (setf (benedict-session-tools session) value))
                (:system-prompt (setf (benedict-session-system-prompt session) value))
                (:autonomy (setf (benedict-session-autonomy session) value))
                (:verbosity (setf (benedict-session-verbosity session) value))
                (:loop-config (setf (benedict-session-loop-config session) value))))
  (benedict-session--sync-harness-budgets session)
  (benedict-session-touch session)
  session)

;;; Request Building

(defun benedict-session--build-request (session)
  "Build a provider request plist from SESSION state."
  (let* ((provider (benedict-session-provider session))
         (model (benedict-session-model session))
         (profile (benedict-session-profile session))
         (tools (benedict-session-tools session))
         (system (benedict-session-system-prompt session))
         (autonomy (benedict-session-autonomy session))
         (verbosity (benedict-session-verbosity session))
         (history (mapcar (lambda (entry)
                            (benedict-message->provider-message entry provider))
                          (benedict-session-entries-chronological session)))
         (messages (if system (append system history) history)))
    (list :provider provider
          :model model
          :profile profile
          :tools tools
          :autonomy autonomy
          :verbosity verbosity
          :messages messages)))

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

(defun benedict-session-attach-harness (session harness)
  "Attach HARNESS to SESSION and return SESSION."
  (setf (benedict-session-harness session) harness)
  (benedict-session-touch session)
  session)

(cl-defun benedict-session-save (session &key root)
  "Persist SESSION to disk under ROOT and return the session directory path."
  (let* ((saved-at (current-time))
         (path (benedict-store-session-path (benedict-session-id session) root))
         (meta (copy-tree (benedict-session-meta session))))
    (setq meta (plist-put meta :store-path path))
    (setq meta (plist-put meta :last-saved-at saved-at))
    (setf (benedict-session-meta session) meta)
    (benedict-session-touch session)
    (benedict-store-save-session session :root root)
    (benedict-session--emit session 'session-saved :path path :saved-at saved-at)
    path))

(cl-defun benedict-session-load (path &key root)
  "Load a persisted session from PATH or session id under ROOT."
  (let* ((resolved-path (if (file-directory-p path)
                            path
                          (benedict-store-session-path path root)))
         (session (benedict-store-load-session path :root root))
         (meta (copy-tree (benedict-session-meta session))))
    (setq meta (plist-put meta :store-path resolved-path))
    (setf (benedict-session-meta session) meta)
    (puthash (benedict-session-id session) session benedict-session--registry)
    session))

(defun benedict-session--sync-harness-budgets (session)
  "Copy SESSION loop-config limits into the attached harness budgets."
  (when-let ((harness (benedict-session-harness session)))
    (setf (benedict-harness-budgets harness)
          (copy-tree (benedict-session-loop-config session)))))

;;; Events

(defvar benedict-session-event-hook nil
  "Hook run when session events occur.
Each function receives (SESSION EVENT-TYPE PAYLOAD).")

(defun benedict-session--emit (session event-type &rest payload)
  "Emit EVENT-TYPE for SESSION with PAYLOAD."
  (let* ((durable-payload (copy-tree payload))
         (event (benedict-event-create
                 :type event-type
                 :session-id (benedict-session-id session)
                 :timestamp (current-time)
                 :payload durable-payload))
         (hook-payload (plist-put (copy-tree payload) :event event)))
    (setf (benedict-session-events session)
          (append (benedict-session-events session) (list event)))
    (benedict-session-touch session)
    (run-hook-with-args 'benedict-session-event-hook
                        session event-type hook-payload)))

(defun benedict-session-approval-pending-p (session)
  "Return non-nil when SESSION is waiting on a tool approval."
  (cl-some (lambda (yield)
             (eq (plist-get yield :type) 'approval-request))
           (benedict-session-outstanding-yields session)))

;;; Messages

(defun benedict-session-add-entry (session entry)
  "Add canonical ENTRY to SESSION, assigning ID and timestamp when missing."
  (let ((normalized (benedict-message-from-data entry)))
    (unless (benedict-message-id normalized)
      (setf (benedict-message-id normalized)
            (format "msg-%03d" (cl-incf (benedict-session-message-seq session)))))
    (unless (benedict-message-timestamp normalized)
      (setf (benedict-message-timestamp normalized) (current-time)))
    (push normalized (benedict-session-entries session))
    (benedict-session--emit session 'message-added
                            :entry normalized)
    normalized))

(defun benedict-session-add-message (session message)
  "Add MESSAGE to SESSION and return the canonical entry."
  (benedict-session-add-entry session message))

(defun benedict-session-get-entry (session id)
  "Get canonical entry with ID from SESSION, or nil if not found."
  (cl-find id (benedict-session-entries session)
           :key #'benedict-message-id :test #'equal))

(defun benedict-session-get-message (session id)
  "Get canonical message with ID from SESSION, or nil if not found."
  (benedict-session-get-entry session id))

(defun benedict-session-update-message (session id updates)
  "Update message with ID in SESSION, merging the change plist.
Return the updated message or nil if not found."
  (when-let ((entry (benedict-session-get-entry session id)))
    (let ((updated
           (benedict-message-from-data
            (list :id (benedict-message-id entry)
                  :kind (benedict-message-kind entry)
                  :role (or (plist-get updates :role)
                            (benedict-message-role entry))
                  :content (or (plist-get updates :content)
                               (benedict-message-text entry))
                  :thinking (or (plist-get updates :thinking)
                                (benedict-message-thinking entry))
                  :tool-calls (or (plist-get updates :tool-calls)
                                  (benedict-message-tool-calls entry))
                  :timestamp (or (plist-get updates :timestamp)
                                 (benedict-message-timestamp entry))
                  :metadata (or (plist-get updates :metadata)
                                (benedict-message-metadata entry))))))
      (setf (benedict-session-entries session)
            (cl-loop for candidate in (benedict-session-entries session)
                     collect (if (equal (benedict-message-id candidate) id)
                                 updated
                               candidate)))
      (benedict-session--emit session 'message-updated
                              :id id
                              :updates updates
                              :entry updated)
      updated)))

(defun benedict-session--tool-call-statuses (message)
  "Return MESSAGE tool call statuses from metadata, or nil."
  (plist-get (benedict-message-metadata message) :tool-call-statuses))

(defun benedict-session--update-tool-call-status (session message-id call-id status)
  "Update tool CALL-ID in MESSAGE-ID to STATUS for SESSION."
  (when-let ((entry (benedict-session-get-entry session message-id)))
    (let* ((metadata (copy-tree (or (benedict-message-metadata entry) nil)))
           (statuses (copy-tree (or (benedict-session--tool-call-statuses entry) nil)))
           (existing (assoc call-id statuses)))
      (if existing
          (setcdr existing status)
        (push (cons call-id status) statuses))
      (benedict-session-update-message
       session message-id
       (list :metadata (plist-put metadata :tool-call-statuses statuses))))))

(defun benedict-session-entries-chronological (session)
  "Return SESSION entries in chronological order (oldest first)."
  (reverse (copy-sequence (benedict-session-entries session))))

(defun benedict-session-messages-chronological (session)
  "Return SESSION entries in chronological order (oldest first)."
  (benedict-session-entries-chronological session))

;;; Draft (streaming accumulator)

(defun benedict-session-start-draft (session &optional content)
  "Start a new draft for SESSION with optional initial CONTENT."
  (setf (benedict-session-draft session)
        (list :content (or content "")
              :tool-calls nil
              :thinking nil
              :started-at (current-time)))
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
Return the created message."
  (when-let ((draft (benedict-session-draft session)))
    (let ((msg (list :role 'assistant
                     :content (plist-get draft :content)
                     :tool-calls (plist-get draft :tool-calls)
                     :thinking (plist-get draft :thinking)
                     :metadata metadata)))
      (setf (benedict-session-draft session) nil)
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
Return a unique request ID."
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
  "Cancel SESSION's active request, discard draft.
Return t if there was something to cancel."
  (when (benedict-session-inflight session)
    (when-let ((started (plist-get (benedict-session-inflight session) :started-at)))
      (setf (benedict-session-last-phase session) 'canceled)
      (setf (benedict-session-last-elapsed session)
            (float-time (time-subtract (current-time) started)))
      (setf (benedict-session-last-usage session) nil))
    (benedict-session-clear-request session)
    (benedict-session-discard-draft session)
    t))

(defun benedict-session-request-active-p (session)
  "Return non-nil if SESSION has an active inflight request."
  (not (null (benedict-session-inflight session))))

;;; Dispatch API

(defun benedict-session-busy-p (session)
  "Return non-nil if SESSION has an active request or is waiting on approval."
  (or (benedict-session-request-active-p session)
      (memq (benedict-session-run-state session) '(running waiting))))

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
