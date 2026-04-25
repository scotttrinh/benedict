;;; benedict-core.el --- Headless runtime kernel for Benedict -*- lexical-binding: t; -*-

;;; Commentary:
;; Public control-plane runtime for Benedict sessions.  The core owns run
;; state, turn state, durable runtime events, provider dispatch, tool execution,
;; and user-facing yields without depending on chat buffers or VUI rendering.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict-message)
(require 'benedict-provider)
(require 'benedict-session)

(defvar benedict-core--yield-seq 0
  "Sequence number for core yield identifiers.")

(defun benedict-core--next-yield-id ()
  "Return a fresh yield identifier."
  (format "yield-%03d" (cl-incf benedict-core--yield-seq)))

(defun benedict-core--emit (session type &rest payload)
  "Emit durable event TYPE with PAYLOAD for SESSION."
  (apply #'benedict-session--emit session type payload))

(defun benedict-core--set-run-state (session state)
  "Set SESSION core run STATE and emit a state transition event."
  (let ((old (benedict-session-run-state session)))
    (unless (eq old state)
      (setf (benedict-session-run-state session) state)
      (benedict-core--emit session 'state-changed
                           :axis 'run
                           :old old
                           :new state))))

(defun benedict-core--set-turn-state (session state)
  "Set SESSION core turn STATE and emit a state transition event."
  (let ((old (benedict-session-turn-state session)))
    (unless (eq old state)
      (setf (benedict-session-turn-state session) state)
      (benedict-core--emit session 'state-changed
                           :axis 'turn
                           :old old
                           :new state))))

(defun benedict-core--tool-name= (a b)
  "Return non-nil when tool names A and B identify the same tool."
  (string= (format "%s" a) (format "%s" b)))

(defun benedict-core--tool-spec (session tool-call)
  "Return the tool spec for TOOL-CALL in SESSION, or nil."
  (let ((name (or (plist-get tool-call :name)
                  (plist-get tool-call :tool))))
    (cl-find-if (lambda (spec)
                  (benedict-core--tool-name= name (plist-get spec :id)))
                (benedict-session-tools session))))

(defun benedict-core--required-capabilities (tool-spec)
  "Return capability list required by TOOL-SPEC."
  (let ((capabilities (plist-get tool-spec :capabilities)))
    (cond
     ((null capabilities) nil)
     ((listp capabilities) capabilities)
     (t (list capabilities)))))

(defun benedict-core--capabilities-approved-p (required approved)
  "Return non-nil when REQUIRED capabilities are included in APPROVED."
  (cl-every (lambda (capability) (member capability approved)) required))

(defun benedict-core-invocation-p (object)
  "Return non-nil when OBJECT is a core tool invocation."
  (and (listp object)
       (eq (plist-get object :type) 'tool-invocation)
       (plist-get object :tool-call)
       (plist-get object :tool-spec)))

(defconst benedict-core--terminal-tool-actions
  '(execute-tool request-yield append-tool-result stop-run fail-stage)
  "Terminal actions returned by the tool action pipeline.")

(defun benedict-core-action-p (object)
  "Return non-nil when OBJECT is a core tool action."
  (and (listp object)
       (memq (plist-get object :action)
             (cons 'update-invocation benedict-core--terminal-tool-actions))))

(defun benedict-core-invocation-update (invocation &rest plist)
  "Return INVOCATION copied with PLIST applied."
  (unless (benedict-core-invocation-p invocation)
    (error "Invalid tool invocation: %S" invocation))
  (let ((updated (copy-tree invocation)))
    (cl-loop for (key value) on plist by #'cddr
             do (setq updated (plist-put updated key value)))
    updated))

(defun benedict-core-action-update-invocation (invocation &rest metadata)
  "Return an action to replace the current tool INVOCATION.
METADATA is appended to the action plist."
  (unless (benedict-core-invocation-p invocation)
    (error "Invalid update invocation: %S" invocation))
  (append (list :action 'update-invocation :invocation invocation) metadata))

(defun benedict-core-action-execute-tool (invocation &rest metadata)
  "Return a terminal action to execute tool INVOCATION.
METADATA is appended to the action plist."
  (unless (benedict-core-invocation-p invocation)
    (error "Invalid execute invocation: %S" invocation))
  (append (list :action 'execute-tool :invocation invocation) metadata))

(defun benedict-core-action-request-yield
    (invocation yield-type reason &rest metadata)
  "Return a terminal action that yields INVOCATION to the user.
YIELD-TYPE identifies the yield kind.  REASON explains why the yield is
required.  METADATA is appended to the action plist."
  (unless (benedict-core-invocation-p invocation)
    (error "Invalid yield invocation: %S" invocation))
  (unless yield-type
    (error "Invalid yield type: %S" yield-type))
  (append (list :action 'request-yield
                :yield-type yield-type
                :reason reason
                :invocation invocation)
          metadata))

(defun benedict-core-action-append-tool-result
    (invocation reason &rest metadata)
  "Return a terminal action to append a paired tool result.
INVOCATION identifies the original tool call.  REASON describes why the
tool was not executed.  METADATA is appended to the action plist."
  (unless (benedict-core-invocation-p invocation)
    (error "Invalid tool-result invocation: %S" invocation))
  (append (list :action 'append-tool-result
                :invocation invocation)
          (when reason (list :reason reason))
          metadata))

(defun benedict-core-action-stop-run (invocation reason &rest metadata)
  "Return a terminal action to append a tool result and stop the run.
INVOCATION identifies the original tool call.  REASON explains why the run
must stop.  METADATA is appended to the action plist."
  (unless (benedict-core-invocation-p invocation)
    (error "Invalid stop invocation: %S" invocation))
  (append (list :action 'stop-run
                :invocation invocation
                :reason reason)
          metadata))

(defun benedict-core-action-fail-stage (invocation error &rest metadata)
  "Return a terminal action that records a failed stage result.
INVOCATION identifies the original tool call.  ERROR is the failure data.
METADATA is appended to the action plist."
  (unless (benedict-core-invocation-p invocation)
    (error "Invalid fail-stage invocation: %S" invocation))
  (append (list :action 'fail-stage
                :invocation invocation
                :error error)
          metadata))

(defun benedict-core--default-policy-action (context invocation)
  "Apply the default capability policy from CONTEXT to INVOCATION."
  (let* ((tool-spec (plist-get invocation :tool-spec))
         (required (benedict-core--required-capabilities tool-spec))
         (approved (plist-get context :approved-capabilities)))
    (if (benedict-core--capabilities-approved-p required approved)
        (benedict-core-action-execute-tool invocation)
      (benedict-core-action-request-yield
       (benedict-core-invocation-update invocation
                                        :required-capabilities required)
       'approval-request
       'capability-approval-required
       :required-capabilities required))))

(defun benedict-core--initial-invocation (session tool-call tool-spec)
  "Return the initial rich invocation for SESSION TOOL-CALL and TOOL-SPEC."
  (list :type 'tool-invocation
        :session-id (benedict-session-id session)
        :original-tool-call (copy-tree tool-call)
        :tool-call (copy-tree tool-call)
        :tool-spec tool-spec
        :required-capabilities (benedict-core--required-capabilities tool-spec)))

(defun benedict-core--action-pipeline-context (session)
  "Return immutable context passed to tool action pipeline stages for SESSION."
  (list :session-id (benedict-session-id session)
        :root (benedict-session-root session)
        :run-state (benedict-session-run-state session)
        :turn-state (benedict-session-turn-state session)
        :approved-capabilities
        (copy-tree (benedict-session-approved-capabilities session))
        :harness (benedict-session-harness session)))

(defun benedict-core--action-validation-error (object)
  "Return validation error plist for OBJECT, or nil when it is valid."
  (cond
   ((null object) nil)
   ((not (listp object))
    (list :path nil :expected "tool action plist or nil" :actual object))
   ((not (memq (plist-get object :action)
               (cons 'update-invocation benedict-core--terminal-tool-actions)))
    (list :path '(:action)
          :expected '(update-invocation execute-tool request-yield
                      append-tool-result stop-run fail-stage)
          :actual (plist-get object :action)))
   ((not (benedict-core-invocation-p (plist-get object :invocation)))
    (list :path '(:invocation)
          :expected "plist with :type tool-invocation, :tool-call, and :tool-spec"
          :actual (plist-get object :invocation)))
   ((and (eq (plist-get object :action) 'request-yield)
         (not (plist-get object :yield-type)))
    (list :path '(:yield-type) :expected "non-nil yield type" :actual nil))
   ((and (memq (plist-get object :action)
               '(append-tool-result stop-run fail-stage))
         (not (or (plist-get object :reason)
                  (plist-get object :error)
                  (plist-get object :message))))
    (list :path nil
          :expected "reason, message, or error data"
          :actual object))
   (t nil)))

(defun benedict-core--emit-contract-violation (session stage validation)
  "Emit a contract violation event on SESSION for STAGE using VALIDATION data."
  (benedict-core--emit session 'contract-violation
                       :boundary 'tool-action-pipeline
                       :stage stage
                       :path (plist-get validation :path)
                       :expected (plist-get validation :expected)
                       :actual (plist-get validation :actual)))

(defun benedict-core--validate-action-stage-result
    (session stage result original-invocation)
  "Validate SESSION STAGE RESULT or fail ORIGINAL-INVOCATION."
  (let ((validation (benedict-core--action-validation-error result)))
    (if validation
        (progn
          (benedict-core--emit-contract-violation session stage validation)
          (benedict-core-action-fail-stage
           original-invocation
           (list :message "Tool action pipeline stage returned invalid result"
                 :type 'contract-violation
                 :stage stage
                 :path (plist-get validation :path)
                 :expected (plist-get validation :expected)
                 :actual (plist-get validation :actual))))
      result)))

(defun benedict-core--action-pipeline-functions (session)
  "Return action pipeline functions configured for SESSION."
  (append (benedict-session-action-pipeline-functions session)
          (list #'benedict-core--default-policy-action)))

(defun benedict-core--run-action-pipeline (session tool-call tool-spec)
  "Run SESSION's tool action pipeline for TOOL-CALL and TOOL-SPEC."
  (let* ((original-invocation (benedict-core--initial-invocation
                               session tool-call tool-spec))
         (invocation original-invocation)
         (context (benedict-core--action-pipeline-context session))
         (functions (benedict-core--action-pipeline-functions session))
         action)
    (while (and functions (not action))
      (let* ((fn (pop functions))
             (stage-result (benedict-core--validate-action-stage-result
                            session
                            fn
                            (funcall fn context invocation)
                            original-invocation)))
        (cond
         ((null stage-result))
         ((eq (plist-get stage-result :action) 'update-invocation)
          (setq invocation (plist-get stage-result :invocation)))
         ((memq (plist-get stage-result :action)
                benedict-core--terminal-tool-actions)
          (setq action stage-result)))))
    (or action (benedict-core-action-execute-tool invocation))))

(defun benedict-core--add-yield (session yield)
  "Add YIELD to SESSION and emit a yield-created event."
  (let ((final-yield (copy-tree yield)))
    (unless (plist-get final-yield :id)
      (setq final-yield (plist-put final-yield :id (benedict-core--next-yield-id))))
    (setf (benedict-session-outstanding-yields session)
          (append (benedict-session-outstanding-yields session) (list final-yield)))
    (benedict-core--emit session 'yield-created :yield final-yield)
    final-yield))

(defun benedict-core--remove-yield (session yield-id)
  "Remove YIELD-ID from SESSION and return the removed yield."
  (let ((removed nil)
        (kept nil))
    (dolist (yield (benedict-session-outstanding-yields session))
      (if (and (not removed) (equal (plist-get yield :id) yield-id))
          (setq removed yield)
        (push yield kept)))
    (setf (benedict-session-outstanding-yields session) (nreverse kept))
    removed))

(defun benedict-core--message-content (message)
  "Return display content for provider MESSAGE."
  (benedict-provider-result-text (benedict-provider-require-result message)))

(defun benedict-core--normalize-tool-result (tool-call raw-result)
  "Normalize RAW-RESULT for TOOL-CALL into a canonical result plist."
  (let* ((tool-id (or (plist-get tool-call :name)
                      (plist-get tool-call :tool)))
         (call-id (plist-get tool-call :id))
         (status (if (and (listp raw-result) (plist-member raw-result :status))
                     (plist-get raw-result :status)
                   'success))
         (output (if (and (listp raw-result) (plist-member raw-result :output))
                     (plist-get raw-result :output)
                   raw-result))
         (error (and (listp raw-result) (plist-get raw-result :error))))
    (list :status status
          :tool-id tool-id
          :call-id call-id
          :output output
          :error error)))

(defun benedict-core--tool-result-content (result)
  "Return transcript content for normalized tool RESULT."
  (let ((output (plist-get result :output))
        (error (plist-get result :error)))
    (cond
     (error (or (plist-get error :message) (format "%S" error)))
     ((stringp output) output)
     ((and (listp output) (plist-get output :content)) (plist-get output :content))
     ((and (listp output) (plist-get output :text)) (plist-get output :text))
     (t (format "%S" output)))))

(defun benedict-core--function-accepts-options-p (fn)
  "Return non-nil when FN can accept runtime keyword options."
  (when fn
    (let ((arity (func-arity fn)))
      (or (eq (cdr arity) 'many)
          (and (integerp (cdr arity))
               (>= (cdr arity) 3))))))

(defun benedict-core--record-tool-result (session result)
  "Record normalized tool RESULT in SESSION transcript."
  (let* ((status (or (plist-get result :status) 'success))
         (error (plist-get result :error))
         (message (benedict-message-tool-result
                   (plist-get result :call-id)
                   (plist-get result :tool-id)
                   status
                   (benedict-core--tool-result-content result)
                   error)))
    (benedict-session-add-message session message)
    result))

(defun benedict-core--invoke-tool (session invocation)
  "Invoke the enriched tool INVOCATION for SESSION."
  (let* ((tool-call (plist-get invocation :tool-call))
         (tool-spec (plist-get invocation :tool-spec))
         (tool-id (or (plist-get tool-call :name)
                      (plist-get tool-call :tool)))
         (args (plist-get tool-call :arguments))
         (invoke-fn (benedict-session-tool-invoke-fn session))
         (spec-fn (plist-get tool-spec :fn))
         raw-result)
    (benedict-core--emit session 'tool-started
                         :tool-call tool-call
                         :tool-id tool-id)
    (condition-case err
        (setq raw-result
              (cond
               (invoke-fn
                (if (benedict-core--function-accepts-options-p invoke-fn)
                    (funcall invoke-fn
                             tool-id args
                             :session session
                             :harness (benedict-session-harness session))
                  (funcall invoke-fn tool-id args)))
               (spec-fn (apply spec-fn args))
               (benedict-session-tool-invoke-fn
                (let ((fn benedict-session-tool-invoke-fn))
                  (if (benedict-core--function-accepts-options-p fn)
                      (funcall fn
                               tool-id args
                               :session session
                               :harness (benedict-session-harness session))
                    (funcall fn tool-id args))))
               (t (error "No tool invoke function configured for %S" tool-id))))
      (error
       (setq raw-result
             (list :status 'failure
                   :error (list :message (error-message-string err)
                                :type (car err)
                                :data (cdr err))))))
    (let ((result (benedict-core--normalize-tool-result tool-call raw-result)))
      (benedict-core--emit session 'tool-completed
                           :tool-call tool-call
                           :tool-id tool-id
                           :status (plist-get result :status)
                           :result result)
      result)))

(defun benedict-core--action-tool-result (action &optional status)
  "Return a non-executed tool result for ACTION.
STATUS defaults to `denied'."
  (let* ((invocation (plist-get action :invocation))
         (tool-call (plist-get invocation :tool-call))
         (reason (or (plist-get action :reason)
                     (plist-get action :message))))
    (let ((tool-id (or (plist-get tool-call :name)
                       (plist-get tool-call :tool))))
      (list :status (or status 'denied)
            :tool-id tool-id
            :call-id (plist-get tool-call :id)
            :error (list :message (or reason
                                      (format "Tool %S was not executed" tool-id))
                         :action (plist-get action :action))))))

(defun benedict-core--failed-action-tool-result (action)
  "Return a failed tool result for ACTION."
  (let* ((invocation (plist-get action :invocation))
         (tool-call (plist-get invocation :tool-call))
         (tool-id (or (plist-get tool-call :name)
                      (plist-get tool-call :tool)))
         (error (or (plist-get action :error)
                    (plist-get action :reason)
                    (plist-get action :message))))
    (list :status 'failure
          :tool-id tool-id
          :call-id (plist-get tool-call :id)
          :error (if (listp error)
                     error
                   (list :message (format "%S" error)
                         :action (plist-get action :action))))))

(defun benedict-core--tool-approval-yield
    (session action remaining-tool-calls)
  "Create an approval yield for SESSION ACTION.
REMAINING-TOOL-CALLS are queued behind the approval request."
  (let ((invocation (plist-get action :invocation)))
    (benedict-core--add-yield
     session
     (let* ((tool-call (plist-get invocation :tool-call))
            (tool-id (or (plist-get tool-call :name)
                         (plist-get tool-call :tool))))
       (list :type 'approval-request
             :from 'harness
             :to 'user
             :action action
             :approval 'confirm
             :tool-id tool-id
             :args (plist-get tool-call :arguments)
             :invocation invocation
             :tool-call tool-call
             :tool-spec (plist-get invocation :tool-spec)
             :required-capabilities (plist-get invocation :required-capabilities)
             :remaining-tool-calls remaining-tool-calls)))))

(defun benedict-core--execute-tool-calls (session tool-calls)
  "Evaluate and execute TOOL-CALLS for SESSION.
Return 'complete when all calls are handled, or 'waiting when a yield blocks."
  (benedict-core--set-turn-state session 'model-yielded-tool-calls)
  (benedict-core--emit
   session 'yield-created
   :yield (list :type 'tool-call
                :from 'model
                :to 'harness
                :tool-calls tool-calls))
  (benedict-core--set-turn-state session 'harness-evaluating)
  (catch 'blocked
    (while tool-calls
      (let* ((tool-call (pop tool-calls))
             (tool-spec (or (benedict-core--tool-spec session tool-call)
                            (list :id (or (plist-get tool-call :name)
                                          (plist-get tool-call :tool)))))
             (action (benedict-core--run-action-pipeline session tool-call tool-spec))
             (invocation (plist-get action :invocation)))
        (pcase (plist-get action :action)
          ('execute-tool
           (benedict-core--set-turn-state session 'harness-executing)
           (benedict-core--record-tool-result
            session
            (benedict-core--invoke-tool session invocation)))
          ('request-yield
           (benedict-core--set-run-state session 'waiting)
           (benedict-core--set-turn-state session 'harness-yielded-approval)
           (let ((yield (benedict-core--tool-approval-yield
                         session action tool-calls)))
             (benedict-core--emit session 'approval-requested
                                  :tool-call tool-call
                                  :action action
                                  :yield yield))
           (throw 'blocked 'waiting))
          ('append-tool-result
           (benedict-core--record-tool-result
            session
            (benedict-core--action-tool-result
             action
             (plist-get action :status))))
          ('stop-run
           (benedict-core--record-tool-result
            session
            (benedict-core--action-tool-result
             action
             (plist-get action :status)))
           (benedict-core--set-run-state session 'idle)
           (benedict-core--set-turn-state session 'turn-complete)
           (benedict-core--emit session 'run-stopped :reason (plist-get action :reason))
           (throw 'blocked 'waiting))
          ('fail-stage
           (benedict-core--record-tool-result
            session
            (benedict-core--failed-action-tool-result action)))
          (_
           (benedict-core--record-tool-result
            session
            (benedict-core--action-tool-result
             (benedict-core-action-append-tool-result
              (benedict-core--initial-invocation session tool-call tool-spec)
              "Unknown action pipeline status")))))))
    (benedict-core--set-turn-state session 'tool-results-ready)
    (benedict-core--emit session 'yield-created
                         :yield (list :type 'tool-result
                                      :from 'harness
                                      :to 'model))
    'complete))

(defun benedict-core--provider-request (session)
  "Build a canonical provider request from SESSION state."
  (let* ((provider (benedict-session-provider session))
         (history (benedict-session-entries-chronological session))
         (system (benedict-session-system-prompt session))
         (messages (append system history)))
    (unless (cl-every #'benedict-message-p messages)
      (error "Provider request messages must be canonical benedict-message values"))
    (list :provider provider
          :model (benedict-session-model session)
          :profile (benedict-session-profile session)
          :tools (benedict-session-tools session)
          :autonomy (benedict-session-autonomy session)
          :verbosity (benedict-session-verbosity session)
          :messages messages)))

(defun benedict-core--handle-provider-delta (session data)
  "Handle streaming delta DATA for SESSION."
  (when session
    (let ((kind (plist-get data :kind))
          (text (plist-get data :text)))
      (pcase kind
        ('content-delta
         (when text
           (benedict-session-append-draft session text)))
        ('thinking-delta
         (benedict-core--emit session 'draft-updated :payload data))))))

(defun benedict-core--handle-provider-result (session result)
  "Apply provider RESULT to SESSION and continue the turn if needed."
  (setq result (benedict-provider-require-result result))
  (let* ((inflight (benedict-session-inflight session))
         (started (and inflight (plist-get inflight :started-at)))
         (usage (benedict-provider-result-usage result)))
    (when-let ((provider (benedict-provider-result-provider result)))
      (setf (benedict-session-provider session) provider))
    (when-let ((model (benedict-provider-result-model result)))
      (setf (benedict-session-model session) model))
    (when started
      (let* ((elapsed (float-time (time-subtract (current-time) started)))
             (duration (or (benedict-provider-result-latency result) elapsed)))
        (setf (benedict-session-last-phase session) 'complete)
        (setf (benedict-session-last-elapsed session) elapsed)
        (setf (benedict-session-last-usage session) usage)
        (benedict-session-accumulate-usage session usage duration))))
  (benedict-session-clear-request session)
  (let* ((thinking (benedict-provider-result-thinking result))
         (tool-calls (benedict-provider-result-tool-calls result))
         (metadata (list :provider (benedict-provider-result-provider result)
                         :model (benedict-provider-result-model result)
                         :usage (benedict-provider-result-usage result)
                         :provider-metadata
                         (benedict-provider-result-metadata result)))
         (assistant
          (if (and (benedict-session-draft session)
                   (not (string-empty-p (plist-get (benedict-session-draft session) :content))))
              (let ((draft (benedict-session-draft session))
                    (final-content (benedict-provider-result-text result)))
                (when thinking
                  (setf (benedict-session-draft session)
                        (plist-put draft :thinking thinking)))
                (when tool-calls
                  (setf (benedict-session-draft session)
                        (plist-put draft :tool-calls
                                   (append (plist-get draft :tool-calls)
                                           tool-calls))))
                (when (not (string-empty-p final-content))
                   (setf (benedict-session-draft session)
                         (plist-put draft :content final-content)))
                (benedict-session-finalize-draft session metadata))
            (progn
              (benedict-session-discard-draft session)
              (benedict-session-add-message
               session
               (benedict-message-assistant-response
                :text (benedict-provider-result-text result)
                :tool-calls tool-calls
                :thinking thinking
                :metadata metadata)))))
         (assistant-tool-calls (benedict-message-tool-calls assistant)))
    (benedict-core--emit session 'request-completed
                         :success t
                         :result result)
    (if assistant-tool-calls
        (when (eq (benedict-core--execute-tool-calls session assistant-tool-calls) 'complete)
          (benedict-core-step session))
      (benedict-core--set-turn-state session 'turn-complete)
      (benedict-core--set-run-state session 'idle)
      (benedict-core--emit session 'run-completed
                           :turn-state (benedict-session-turn-state session)))))

(defun benedict-core--handle-provider-error (session error)
  "Apply provider ERROR to SESSION."
  (benedict-session-clear-request session)
  (benedict-session-discard-draft session)
  (setf (benedict-session-last-error session) error)
  (benedict-core--set-run-state session 'error)
  (benedict-core--emit session 'request-completed
                       :success nil
                       :error error)
  (benedict-core--emit session 'run-failed :error error))

;;; Public API

(cl-defun benedict-core-create-session
    (&key id title root provider model profile meta tools system-prompt autonomy
     verbosity harness tool-invoke-fn provider-dispatch-fn
     action-pipeline-functions approved-capabilities &allow-other-keys)
  "Create a Benedict session configured for core execution.
ID, TITLE, ROOT, PROVIDER, MODEL, PROFILE, META, TOOLS, SYSTEM-PROMPT,
AUTONOMY, VERBOSITY, HARNESS, and TOOL-INVOKE-FN mirror
`benedict-session-create'.  PROVIDER-DISPATCH-FN, ACTION-PIPELINE-FUNCTIONS, and
APPROVED-CAPABILITIES configure runtime behavior."
  (let ((session (benedict-session-create
                  :id id
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
                  :harness harness
                  :tool-invoke-fn tool-invoke-fn
                  :provider-dispatch-fn provider-dispatch-fn
                  :action-pipeline-functions action-pipeline-functions
                  :approved-capabilities approved-capabilities)))
    (benedict-core--set-run-state session 'idle)
    (benedict-core--emit session 'session-created)
    session))

(defun benedict-core-add-user-input (session text &optional metadata)
  "Append user TEXT with METADATA to SESSION."
  (benedict-session-add-message
   session
   (benedict-message-user-text text metadata)))

(cl-defun benedict-core-run (session &rest _options)
  "Run SESSION until it becomes idle, waits on a yield, errors, or is cancelled."
  (when (memq (benedict-session-run-state session) '(running waiting))
    (error "Session is already active"))
  (benedict-core--set-run-state session 'running)
  (benedict-core--set-turn-state session 'model-dispatch)
  (benedict-core--emit session 'run-started)
  (benedict-core--emit session 'turn-started)
  (benedict-core-step session)
  session)

(defun benedict-core-step (session)
  "Execute one core runtime step for SESSION."
  (unless (eq (benedict-session-run-state session) 'running)
    (benedict-core--set-run-state session 'running))
  (benedict-core--set-turn-state session 'model-dispatch)
  (let ((request (benedict-core--provider-request session))
        (dispatch (or (benedict-session-provider-dispatch-fn session)
                      benedict-session-provider-dispatch-fn
                      #'benedict-provider-dispatch)))
    (if (and (plist-get request :provider)
             (plist-get request :model))
        (let* ((request-id (benedict-session-start-request session nil))
               (_ (benedict-core--emit session 'request-started
                                       :request request
                                       :request-id request-id))
               (handle
                (progn
                  (benedict-session-start-draft session)
                  (funcall dispatch
                           request
                           :on-success (lambda (result)
                                         (benedict-core--handle-provider-result
                                          session result))
                           :on-error (lambda (error)
                                       (benedict-core--handle-provider-error
                                        session error))
                           :on-delta (lambda (&rest payload)
                                       (let ((data (if (and (listp payload)
                                                            (not (keywordp (car payload)))
                                                            (listp (car payload)))
                                                       (car payload)
                                                     payload)))
                                         (benedict-core--handle-provider-delta
                                          session data)))))))
          (when-let ((inflight (benedict-session-inflight session)))
            (when (equal request-id (plist-get inflight :request-id))
              (setf (benedict-session-inflight session)
                    (plist-put inflight :request handle)))))
      (benedict-core--set-run-state session 'idle)
      (benedict-core--set-turn-state session 'turn-complete)
      (benedict-core--emit session 'dispatch-needed))))

(defun benedict-core-continue (session)
  "Continue SESSION when it is waiting and no external decision is required."
  (when (benedict-session-outstanding-yields session)
    (error "Session has outstanding yields that must be resolved"))
  (benedict-core--set-run-state session 'running)
  (benedict-core-step session))

(defun benedict-core-resume (session yield-id decision)
  "Resolve YIELD-ID on SESSION using DECISION and continue when possible."
  (let ((yield (or (benedict-core--remove-yield session yield-id)
                   (error "No outstanding yield %S" yield-id))))
    (benedict-core--emit session 'yield-resolved
                         :yield yield
                         :decision decision)
    (pcase (plist-get yield :type)
      ('approval-request
       (if (eq (plist-get decision :decision) 'approve)
           (let* ((invocation (plist-get yield :invocation))
                  (capabilities (plist-get yield :required-capabilities))
                  (existing (benedict-session-approved-capabilities session)))
             (setf (benedict-session-approved-capabilities session)
                   (append existing
                           (cl-remove-if (lambda (cap) (member cap existing))
                                         capabilities)))
             (benedict-core--emit session 'approval-resolved
                                  :yield yield
                                  :decision decision)
             (benedict-core--set-run-state session 'running)
             (benedict-core--set-turn-state session 'harness-executing)
             (benedict-core--record-tool-result
              session
              (benedict-core--invoke-tool session invocation))
             (let ((remaining (plist-get yield :remaining-tool-calls)))
               (if (and remaining
                        (eq (benedict-core--execute-tool-calls session remaining) 'waiting))
                   session
                 (benedict-core--set-turn-state session 'tool-results-ready)
                 (benedict-core-step session))))
         (let* ((invocation (plist-get yield :invocation))
                (tool-call (plist-get yield :tool-call)))
           (ignore tool-call)
           (benedict-core--emit session 'approval-resolved
                                :yield yield
                                :decision decision)
           (benedict-core--set-run-state session 'running)
           (benedict-core--record-tool-result
            session
            (benedict-core--action-tool-result
             (benedict-core-action-append-tool-result
              invocation
              "Tool denied by user")))
           (if (and (plist-get yield :remaining-tool-calls)
                    (eq (benedict-core--execute-tool-calls
                         session
                         (plist-get yield :remaining-tool-calls))
                        'waiting))
               session
             (benedict-core-step session)))))
      (_ (benedict-core-continue session))))
  session)

(defun benedict-core-stop (session)
  "Stop SESSION and clear outstanding core yields."
  (when-let ((inflight (benedict-session-inflight session)))
    (let ((handle (plist-get inflight :request)))
      (when handle
        (benedict-provider-abort handle)))
    (benedict-session-clear-request session))
  (benedict-session-discard-draft session)
  (setf (benedict-session-outstanding-yields session) nil)
  (benedict-core--set-turn-state session 'turn-complete)
  (benedict-core--set-run-state session 'cancelled)
  (benedict-core--emit session 'run-stopped :reason 'user-stopped)
  session)

(provide 'benedict-core)
;;; benedict-core.el ends here
