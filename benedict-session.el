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

;;; Session Struct

(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state and runtime."
  id created-at updated-at title
  entries
  (message-seq 0)
  (state 'idle) draft pending-question inflight last-error last-request
  root provider model profile meta
  tools system-prompt autonomy verbosity
  harness tool-invoke-fn
  flywire-session attached-frontends
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
                                        tool-invoke-fn)
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
  :tool-invoke-fn - Runtime tool invocation function"
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
                   :tool-invoke-fn tool-invoke-fn)))
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

(defvar benedict-session-ask-user-hook nil
  "Hook run when a question is raised.
Each function receives (SESSION QUESTION-PLIST).")

(defun benedict-session--emit (session event-type &rest payload)
  "Emit EVENT-TYPE for SESSION with PAYLOAD."
  (let ((event (benedict-event-create
                :type event-type
                :session-id (benedict-session-id session)
                :timestamp (current-time)
                :payload payload)))
    (benedict-session-touch session)
    (run-hook-with-args 'benedict-session-event-hook
                        session event-type (plist-put payload :event event)))
  (when (eq event-type 'question-raised)
    (run-hook-with-args 'benedict-session-ask-user-hook
                        session
                        (plist-get payload :question))))

(defun benedict-session-set-state (session new-state)
  "Set SESSION state to NEW-STATE, emitting event if changed."
  (let ((old (benedict-session-state session)))
    (unless (eq old new-state)
      (setf (benedict-session-state session) new-state)
      (benedict-session--emit session 'state-changed :old old :new new-state))))

(defun benedict-session-approval-pending-p (session)
  "Return non-nil when SESSION is waiting on a tool approval."
  (and (eq (benedict-session-state session) 'approval-pending)
       (benedict-session-pending-question session)))

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
Return the created message."
  (when-let ((draft (benedict-session-draft session)))
    (let ((msg (list :role 'assistant
                     :content (plist-get draft :content)
                     :tool-calls (plist-get draft :tool-calls)
                     :thinking (plist-get draft :thinking)
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
  "Cancel SESSION's active request, discard draft, set cancelled state.
Return t if there was something to cancel."
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

;;; Internal Dispatch Callbacks

(defun benedict-session--on-delta (session data)
  "Handle streaming delta DATA for SESSION.
Update draft content.  This is an internal callback for dispatch."
  (when session
    (let ((kind (plist-get data :kind))
          (text (plist-get data :text)))
      (pcase kind
        ('content-delta
         (when text
           (benedict-session-append-draft session text)))
        ('thinking-delta
         (benedict-session--emit session 'draft-updated :payload data))))))

(defun benedict-session--on-success (session result)
  "Handle successful response RESULT for SESSION.
Finalize draft and accumulate telemetry.  This is an internal callback for dispatch."
  (when session
    (let* ((inflight (benedict-session-inflight session))
           (request-id (and inflight (plist-get inflight :request-id)))
           (message (plist-get result :message))
           (content (or (plist-get message :content) ""))
           (tool-calls (plist-get message :tool-calls))
           (usage (plist-get result :usage))
           (metadata (list :provider (plist-get result :provider)
                           :model (plist-get result :model)
                           :latency (plist-get result :latency)
                           :usage usage)))
      ;; Update session provider/model from response
      (when-let ((provider (plist-get result :provider)))
        (setf (benedict-session-provider session) provider))
      (when-let ((model (plist-get result :model)))
        (setf (benedict-session-model session) model))
      ;; Accumulate telemetry before clearing request
      (when-let ((started (and inflight (plist-get inflight :started-at))))
        (let* ((elapsed (float-time (time-subtract (current-time) started)))
               (duration (or (plist-get result :latency) elapsed)))
          (setf (benedict-session-last-phase session) 'complete)
          (setf (benedict-session-last-elapsed session) elapsed)
          (setf (benedict-session-last-usage session) usage)
          (benedict-session-accumulate-usage session usage duration)))
      ;; Finalize or create message
      (when-let ((thinking (plist-get result :thinking)))
        (when-let ((draft (benedict-session-draft session)))
          (setf (benedict-session-draft session)
                (plist-put draft :thinking thinking))))
      (when tool-calls
        (when-let ((draft (benedict-session-draft session)))
          (setf (benedict-session-draft session)
                (plist-put draft :tool-calls
                           (append (plist-get draft :tool-calls)
                                   tool-calls)))))
      (if (and (benedict-session-draft session)
               (> (length (plist-get (benedict-session-draft session) :content)) 0))
          (benedict-session-finalize-draft session metadata)
        (when (benedict-session-draft session)
          (benedict-session-discard-draft session)
          (benedict-session-set-state session 'idle))
        (benedict-session-add-message
         session
         (list :role 'assistant
               :content content
               :tool-calls tool-calls
               :thinking (plist-get result :thinking)
               :metadata metadata)))
      ;; Emit completion event
      (benedict-session--emit session 'request-completed
                              :success t
                              :result result
                              :request-id request-id)
      (when tool-calls
        (benedict-session--process-tool-calls session tool-calls))
      ;; Clear request state after notifying observers.
      (benedict-session-clear-request session))))

(defun benedict-session--on-error (session payload)
  "Handle error PAYLOAD for SESSION.
Clear request and discard draft.  This is an internal callback for dispatch."
  (when session
    (let* ((inflight (benedict-session-inflight session))
           (request-id (and inflight (plist-get inflight :request-id))))
      (when-let ((provider (plist-get payload :provider)))
        (setf (benedict-session-provider session) provider))
      (when-let ((started (and inflight (plist-get inflight :started-at))))
        (setf (benedict-session-last-phase session) 'error)
        (setf (benedict-session-last-elapsed session)
              (float-time (time-subtract (current-time) started)))
        (setf (benedict-session-last-usage session) nil))
      (benedict-session-discard-draft session)
      (setf (benedict-session-last-error session) payload)
      (benedict-session-set-state session 'error)
      (benedict-session--emit session 'request-completed
                              :success nil
                              :error payload
                              :request-id request-id)
      (benedict-session-clear-request session))))

;;; Dispatch API

(defun benedict-session-busy-p (session)
  "Return non-nil if SESSION has an active request or is waiting on approval."
  (or (benedict-session-request-active-p session)
      (memq (benedict-session-state session) '(streaming approval-pending))))

(cl-defun benedict-session-dispatch (session request &key dispatch-fn)
  "Send REQUEST through the provider for SESSION.
Update session state and emit events throughout the lifecycle.

REQUEST is a plist with at minimum :provider, :model, :messages.
DISPATCH-FN is the provider dispatch function (default:
`benedict-provider-dispatch').

Return the request ID on success.  Signal error if session is busy.

Events emitted:
- `request-started` with (:request-id N) after dispatch begins
- `draft-started` when streaming begins
- `draft-updated` for each content delta
- `request-completed` with (:success BOOL) after success/error
- `message-added` when response is finalized"
  (when (benedict-session-busy-p session)
    (error "Session is busy with an active request"))
  (let* ((dispatch (or dispatch-fn
                       (and (fboundp 'benedict-provider-dispatch)
                            #'benedict-provider-dispatch)))
         (handle (funcall dispatch
                          request
                          :on-success (lambda (result)
                                        (benedict-session--on-success session result))
                          :on-error (lambda (payload)
                                      (benedict-session--on-error session payload))
                          :on-delta (lambda (&rest payload)
                                      (let ((data (if (and (listp payload)
                                                           (not (keywordp (car payload)))
                                                           (listp (car payload)))
                                                      (car payload)
                                                    payload)))
                                        (benedict-session--on-delta session data)))))
         (request-id (benedict-session-start-request session handle)))
    (benedict-session-start-draft session)
    (when-let ((provider (plist-get request :provider)))
      (setf (benedict-session-provider session) provider))
    (when-let ((model (plist-get request :model)))
      (setf (benedict-session-model session) model))
    (when-let ((profile (plist-get request :profile)))
      (setf (benedict-session-profile session) profile))
    (benedict-session--emit session 'request-started :request-id request-id)
    request-id))

;;; Tool Execution

(defun benedict-session--tool-invoke-supports-options-p (fn)
  "Return non-nil when FN can accept optional keyword arguments."
  (when fn
    (let ((arity (func-arity fn)))
      (or (eq (cdr arity) 'many)
          (and (integerp (cdr arity))
               (>= (cdr arity) 3))))))

(defun benedict-session--resolve-tool-invoke-fn (session)
  "Return the configured tool invoke function for SESSION."
  (or (benedict-session-tool-invoke-fn session)
      (and (fboundp 'benedict-tool-invoke)
           #'benedict-tool-invoke)))

(defun benedict-session--invoke-tool (session tool-call &optional skip-approval)
  "Execute TOOL-CALL plist for SESSION.
Return plist (:status :output :error).  Emit tool-started and tool-completed events."
  (let* ((tool-id (or (plist-get tool-call :name)
                      (plist-get tool-call :tool)))
         (call-id (plist-get tool-call :id))
         (arguments (plist-get tool-call :arguments))
         (tool-invoke-fn (benedict-session--resolve-tool-invoke-fn session))
         (status 'success)
         (output nil)
         (error-info nil))
    (benedict-session--emit session 'tool-started
                            :tool-call tool-call
                            :tool-id tool-id)
    (lgr-log benedict-session--logger lgr-level-debug "Invoking tool %s" tool-id)
    (condition-case err
        (if tool-invoke-fn
            (let ((raw-result
                   (if (benedict-session--tool-invoke-supports-options-p tool-invoke-fn)
                       (funcall tool-invoke-fn
                                tool-id arguments
                                :session session
                                :harness (benedict-session-harness session)
                                :skip-approval skip-approval)
                     (funcall tool-invoke-fn tool-id arguments))))
              (if (and (listp raw-result) (plist-member raw-result :status))
                  (progn
                    (setq status (plist-get raw-result :status))
                    (setq output (plist-get raw-result :output))
                    (setq error-info (plist-get raw-result :error))
                    (when (plist-member raw-result :approval)
                      (setq output (plist-put output :approval
                                              (plist-get raw-result :approval)))))
                (setq output raw-result)))
          (error "No tool invoke function configured"))
      (benedict-tool-denied
       (setq status 'denied)
       (setq error-info (list :message (error-message-string err)
                              :type (car err)
                              :data (cdr err)
                              :code 'permission-denied))
       (lgr-log benedict-session--logger lgr-level-warn
                "Tool %s denied: %s" tool-id (error-message-string err)))
      (error
       (setq status 'failure)
       (setq error-info (list :message (error-message-string err)
                              :type (car err)
                              :data (cdr err)))
       (lgr-log benedict-session--logger lgr-level-error
                "Tool %s failed: %s" tool-id (error-message-string err))))
    (benedict-session--emit session 'tool-completed
                            :tool-call tool-call
                            :tool-id tool-id
                            :status status
                            :output output
                            :error error-info)
    (list :status status
          :output output
          :error error-info
          :call-id call-id
          :tool-id tool-id)))

(defun benedict-session--pending-approval (session)
  "Return the pending approval plist for SESSION, or nil."
  (let ((pending (benedict-session-pending-question session)))
    (when (and (listp pending)
               (eq (plist-get pending :type) 'tool-approval))
      pending)))

(defun benedict-session--record-tool-result (session result)
  "Record tool RESULT in SESSION as a transcript entry."
  (let* ((call-id (plist-get result :call-id))
         (tool-id (plist-get result :tool-id))
         (status (plist-get result :status))
         (output (plist-get result :output))
         (error-info (plist-get result :error))
         (message (benedict-session--format-tool-result
                   tool-id call-id status output error-info)))
    (benedict-session-add-message session message)
    result))

(defun benedict-session--tool-result-plist-without-keys (plist keys)
  "Return PLIST copied without KEYS."
  (let (result)
    (cl-loop for (key value) on plist by #'cddr
             unless (memq key keys)
             do (setq result (plist-put result key value)))
    result))

(defun benedict-session--tool-result-content (output error-info)
  "Return display content derived from OUTPUT and ERROR-INFO."
  (if error-info
      (if (eq (plist-get error-info :code) 'permission-denied)
          (format "Tool denied: %s" (plist-get error-info :message))
        (if (eq (plist-get error-info :code) 'scope-expansion-required)
            (format "Tool requires scope expansion: %s" (plist-get error-info :message))
          (format "Tool error: %s" (plist-get error-info :message))))
    (cond
     ((stringp output) output)
     ((plist-get output :text) (plist-get output :text))
     ((plist-get output :content) (plist-get output :content))
     (t (format "%S" output)))))

(defun benedict-session--tool-result-metadata (status output error-info)
  "Return canonical tool result metadata for STATUS, OUTPUT, and ERROR-INFO."
  (let* ((structured-output (and (listp output) (copy-tree output)))
         (ui (and structured-output (plist-get structured-output :ui)))
         (effects (and structured-output (plist-get structured-output :effects)))
         (details (if error-info
                      (copy-tree error-info)
                    (and structured-output
                         (benedict-session--tool-result-plist-without-keys
                          structured-output
                          '(:content :text :message :ui :effects))))))
    (let ((metadata (list :status status)))
      (when details
        (setq metadata (plist-put metadata :details details)))
      (when ui
        (setq metadata (plist-put metadata :ui ui)))
      (when effects
        (setq metadata (plist-put metadata :effects effects)))
      (when error-info
        (setq metadata (plist-put metadata :error (copy-tree error-info))))
      metadata)))

(defun benedict-session--format-tool-result (tool-id call-id status output error-info)
  "Format tool result for TOOL-ID and CALL-ID using STATUS, OUTPUT, and ERROR-INFO.
Return a plist suitable for adding to message history."
  (let* ((normalized-status (or status (if error-info 'failure 'success)))
         (content (benedict-session--tool-result-content output error-info))
         (metadata (benedict-session--tool-result-metadata
                    normalized-status output error-info)))
    (list :role 'tool
          :tool-call-id call-id
          :name tool-id
          :content content
          :metadata metadata)))

(defun benedict-session--build-pending-approval (session tool-call tool-result tool-calls index)
  "Build pending approval state for SESSION from TOOL-CALL, TOOL-RESULT, TOOL-CALLS, and INDEX."
  (let* ((approval (plist-get (plist-get tool-result :output) :approval))
         (assistant-message (cl-find-if
                             (lambda (entry)
                               (eq (benedict-message-role entry) 'assistant))
                             (benedict-session-entries session)))
         (message-id (and assistant-message (benedict-message-id assistant-message))))
    (append
     (list :type 'tool-approval
           :tool-call tool-call
           :tool-id (plist-get tool-result :tool-id)
           :call-id (plist-get tool-result :call-id)
           :assistant-message-id message-id
           :tool-call-index index
           :remaining-tool-calls tool-calls)
     approval)))

(defun benedict-session--set-pending-approval (session pending)
  "Store PENDING approval on SESSION and emit approval request events."
  (setf (benedict-session-pending-question session) pending)
  (when-let ((message-id (plist-get pending :assistant-message-id)))
    (benedict-session--update-tool-call-status
     session message-id (plist-get pending :call-id) 'awaiting-approval))
  (benedict-session-set-state session 'approval-pending)
  (benedict-session--emit session 'approval-requested :approval pending)
  (benedict-session--emit session 'question-raised :question pending))

(defun benedict-session--clear-pending-approval (session)
  "Clear any pending approval from SESSION."
  (setf (benedict-session-pending-question session) nil))

(defun benedict-session--process-tool-calls (session tool-calls &optional start-index)
  "Execute TOOL-CALLS for SESSION and record results.
Return a list of result plists."
  (let ((results nil)
        (index 0)
        (pending nil))
    (ignore start-index)
    (catch 'benedict-stop-tool-processing
      (dolist (call tool-calls)
        (let ((result (benedict-session--invoke-tool session call)))
          (pcase (plist-get result :status)
            ('pending
             (setq pending (benedict-session--build-pending-approval
                            session call result tool-calls index))
             (benedict-session--set-pending-approval session pending)
             (throw 'benedict-stop-tool-processing t))
            (_
             (benedict-session--record-tool-result session result)
             (push result results)
             (setq index (1+ index)))))))
    (if pending
        (list :status 'pending
              :results (nreverse results)
              :pending pending)
      (list :status 'complete
            :results (nreverse results)))))

(defun benedict-session--resume-after-approval (session pending)
  "Resume SESSION after resolving PENDING approval."
  (let* ((tool-calls (plist-get pending :remaining-tool-calls))
         (index (or (plist-get pending :tool-call-index) 0))
         (remaining (nthcdr (1+ index) tool-calls))
         (assistant-message-id (plist-get pending :assistant-message-id))
         (assistant-message (and assistant-message-id
                                 (benedict-session-get-entry session assistant-message-id))))
    (benedict-session--clear-pending-approval session)
    (if remaining
        (let ((process-result (benedict-session--process-tool-calls
                               session remaining (1+ index))))
          (when (eq (plist-get process-result :status) 'complete)
            (let ((decision (and assistant-message
                                 (benedict-session--should-continue session assistant-message))))
              (pcase decision
                ('continue
                 (benedict-session-set-state session 'running)
                 (cl-incf (benedict-session-loop-turn-count session))
                 (benedict-session--dispatch-next session))
                ('checkpoint
                 (benedict-session-set-state session 'checkpoint))
                ('stop
                 (benedict-session-set-state session 'idle))))))
      (let ((decision (and assistant-message
                           (benedict-session--should-continue session assistant-message))))
        (pcase decision
          ('continue
           (benedict-session-set-state session 'running)
           (cl-incf (benedict-session-loop-turn-count session))
           (benedict-session--dispatch-next session))
          ('checkpoint
           (benedict-session-set-state session 'checkpoint))
          (_
           (benedict-session-set-state session 'idle)))))))

(defun benedict-session-approve-pending-tool (session)
  "Approve and execute the pending tool request for SESSION."
  (let ((pending (or (benedict-session--pending-approval session)
                     (user-error "Session is not waiting on a tool approval"))))
    (let* ((tool-call (plist-get pending :tool-call))
           (call-id (plist-get pending :call-id))
           (assistant-message-id (plist-get pending :assistant-message-id))
           (result (benedict-session--invoke-tool session tool-call t)))
      (when assistant-message-id
        (benedict-session--update-tool-call-status session assistant-message-id call-id 'success))
      (unless (eq (plist-get result :status) 'success)
        (error "Approved tool did not complete successfully"))
      (benedict-session--record-tool-result session result)
      (benedict-session--emit session 'approval-resolved
                              :approval pending
                              :resolution 'approved
                              :result result)
      (benedict-session--resume-after-approval session pending)
      result)))

(defun benedict-session-deny-pending-tool (session)
  "Deny the pending tool request for SESSION."
  (let ((pending (or (benedict-session--pending-approval session)
                     (user-error "Session is not waiting on a tool approval"))))
    (let* ((call-id (plist-get pending :call-id))
           (tool-id (plist-get pending :tool-id))
           (assistant-message-id (plist-get pending :assistant-message-id))
           (result (list :status 'denied
                         :call-id call-id
                         :tool-id tool-id
                         :error (list :message "Tool denied by user"
                                      :code 'permission-denied
                                      :decision 'approval-denied
                                      :policy 'deny))))
      (when assistant-message-id
        (benedict-session--update-tool-call-status session assistant-message-id call-id 'denied))
      (benedict-session--record-tool-result session result)
      (benedict-session--emit session 'approval-resolved
                              :approval pending
                              :resolution 'denied
                              :result result)
      (benedict-session--resume-after-approval session pending)
      result)))

;;; Loop Management

(defvar benedict-session-checkpoint-handler nil
  "Function called when checkpoint is requested.
Called as (funcall fn SESSION REASON).
Should return non-nil to continue, nil to stop.
If nil, loop waits for `benedict-session-continue' call.")

(defun benedict-session--check-repetition (session tool-calls)
  "Return non-nil if TOOL-CALLS match previous assistant message in SESSION."
  (cl-labels ((normalize (calls)
                (mapcar (lambda (call)
                          (let (normalized)
                            (when-let ((id (plist-get call :id)))
                              (setq normalized (plist-put normalized :id id)))
                            (when-let ((name (or (plist-get call :name)
                                                 (plist-get call :tool))))
                              (setq normalized (plist-put normalized :name name)))
                            (when-let ((arguments (plist-get call :arguments)))
                              (setq normalized (plist-put normalized :arguments arguments)))
                            normalized))
                        (if (vectorp calls) (append calls nil) calls))))
    (let* ((tool-calls (normalize tool-calls))
         (messages (benedict-session-entries session))
         (assistants (cl-remove-if-not
                      (lambda (m) (eq (benedict-message-role m) 'assistant))
                      messages))
         (previous (cadr assistants)))
      (when previous
        (equal tool-calls (normalize (benedict-message-tool-calls previous)))))))

(defun benedict-session--check-turn-limit (session)
  "Return non-nil if SESSION turn limit reached.  Emits checkpoint-requested if so."
  (let* ((config (benedict-session-loop-config session))
         (limit (plist-get config :max-turns))
         (count (benedict-session-loop-turn-count session)))
    (when (and limit (> count 0) (= 0 (mod count limit)))
      (benedict-session--emit session 'checkpoint-requested
                              :reason 'turn-limit
                              :turn-count count
                              :limit limit)
      t)))

(defun benedict-session--check-time-limit (session)
  "Return non-nil if SESSION time limit reached.  Emits checkpoint-requested if so."
  (let* ((config (benedict-session-loop-config session))
         (limit (plist-get config :max-time))
         (start (benedict-session-loop-start-time session)))
    (when (and limit start)
      (let ((elapsed (float-time (time-subtract (current-time) start))))
        (when (> elapsed limit)
          (benedict-session--emit session 'checkpoint-requested
                                  :reason 'time-limit
                                  :elapsed elapsed
                                  :limit limit)
          t)))))

(defun benedict-session--check-token-limit (session)
  "Return non-nil if SESSION token limit reached.  Emits checkpoint-requested if so."
  (let* ((config (benedict-session-loop-config session))
         (limit (plist-get config :max-tokens))
         (usage (benedict-session-accumulated-usage session))
         (total (or (plist-get usage :total) 0)))
    (when (and limit (> total limit))
      (benedict-session--emit session 'checkpoint-requested
                              :reason 'token-limit
                              :total-tokens total
                              :limit limit)
      t)))

(defun benedict-session--check-constraints (session)
  "Check all loop constraints for SESSION.  Return non-nil if any limit reached."
  (or (benedict-session--check-turn-limit session)
      (benedict-session--check-time-limit session)
      (benedict-session--check-token-limit session)))

(defun benedict-session--should-continue (session assistant-message)
  "Decide whether SESSION loop should continue after ASSISTANT-MESSAGE.
Return 'continue, 'stop, or 'checkpoint."
  (let ((tool-calls (benedict-message-tool-calls assistant-message)))
    (cond
     ((not tool-calls) 'stop)
     ((benedict-session--check-repetition session tool-calls)
      (benedict-session--emit session 'loop-stopped :reason 'repetition)
      'stop)
     ((benedict-session--check-constraints session) 'checkpoint)
     (t 'continue))))

(defun benedict-session--loop-step (session)
  "Execute one step of the agent loop for SESSION.
Process tool calls from the last message, then dispatch if it should continue."
  (let* ((messages (benedict-session-entries session))
         (last-msg (car messages))
         (tool-calls (and last-msg (benedict-message-tool-calls last-msg))))
    (lgr-log benedict-session--logger lgr-level-debug
             "Loop step for session %s: %d tool calls"
             (benedict-session-id session) (length tool-calls))
    (when tool-calls
      (let ((process-result (benedict-session--process-tool-calls session tool-calls)))
        (when (eq (plist-get process-result :status) 'complete)
          (let ((decision (benedict-session--should-continue session last-msg)))
            (lgr-log benedict-session--logger lgr-level-debug
                     "Loop decision for session %s: %s"
                     (benedict-session-id session) decision)
            (pcase decision
              ('continue
               (cl-incf (benedict-session-loop-turn-count session))
               (benedict-session--dispatch-next session))
              ('checkpoint
               (benedict-session-set-state session 'checkpoint))
              ('stop
               (benedict-session-set-state session 'idle)))))))))

(defun benedict-session--dispatch-next (session)
  "Dispatch next request in the loop for SESSION.
Build the request from session state and dispatch it."
  (let ((request (benedict-session--build-request session)))
    (if (and (plist-get request :provider)
             (plist-get request :model))
        (progn
          (lgr-log benedict-session--logger lgr-level-debug
                   "Dispatching next request for %s (turn %d)"
                   (benedict-session-id session)
                   (benedict-session-loop-turn-count session))
          (benedict-session-dispatch session request))
      ;; Cannot dispatch without provider/model - reset to idle
        (lgr-log benedict-session--logger lgr-level-warn
                "Cannot dispatch next request for %s: missing provider/model. Req: %S"
                (benedict-session-id session) request)
      (benedict-session-set-state session 'idle)
      (benedict-session--emit session 'dispatch-needed))))

(defun benedict-session-continue (session)
  "Continue SESSION after a checkpoint.
Reset the time limit and continue the loop."
  (when (eq (benedict-session-state session) 'checkpoint)
    (setf (benedict-session-loop-start-time session) (current-time))
    (benedict-session-set-state session 'running)
    (benedict-session--dispatch-next session)))

(defun benedict-session-stop (session)
  "Stop SESSION's agent loop."
  (when (benedict-session-approval-pending-p session)
    (setf (benedict-session-pending-question session) nil))
  (benedict-session-set-state session 'idle)
  (benedict-session--emit session 'loop-stopped :reason 'user-stopped))

(cl-defun benedict-session-run (session &key request config)
  "Start the agent loop for SESSION.
REQUEST is the initial request plist.
CONFIG is loop config plist (:max-turns :max-time :max-tokens)."
  (when (benedict-session-busy-p session)
    (error "Session is busy"))
  (setf (benedict-session-loop-turn-count session) 0)
  (setf (benedict-session-loop-start-time session) (current-time))
  (when config
    (setf (benedict-session-loop-config session) config))
  (benedict-session--sync-harness-budgets session)
  (benedict-session-set-state session 'running)
  (if request
      (benedict-session-dispatch session request)
    (benedict-session--dispatch-next session)))

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
