;;; benedict-provider-vercel.el --- Vercel provider backend -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Implements a non-streaming chat backend against the Vercel API using
;; url-retrieve with retry/backoff and auth-source/env based credential lookup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'json)
(require 'lgr)
(require 'benedict-provider)
(require 'benedict-http)

;; Temporary compatibility layer for old logging calls
;; TODO: Replace all call sites with direct lgr calls
(cl-defun benedict-provider-log (_provider _level _event &rest _data)
  "Stub for old logging infrastructure - replaced by lgr."
  nil)

(cl-defun benedict-provider-log-debug (_provider _event &rest _data)
  "Stub for old logging infrastructure - replaced by lgr."
  nil)

(cl-defun benedict-provider-log-trace (_provider _event &rest _data)
  "Stub for old logging infrastructure - replaced by lgr."
  nil)

(defgroup benedict-provider-vercel nil
  "Settings for the Benedict Vercel provider."
  :group 'benedict
  :prefix "benedict-provider-vercel-")

(defcustom benedict-provider-vercel-endpoint
  "https://ai-gateway.vercel.sh/v1/chat/completions"
  "Endpoint used for Vercel chat completions."
  :type 'string
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-default-model "xai/grok-4.1-fast-reasoning"
  "Default model identifier sent to Vercel when none is specified."
  :type 'string
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-default-temperature 0.2
  "Default sampling temperature for Vercel requests."
  :type '(choice (const :tag "Provider default" nil) number)
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-default-reasoning
  '((effort . "medium") (enabled . t))
  "Default reasoning options sent with every request when non-nil.
Set to nil to keep provider defaults. This alist/plist accepts keys
EFFORT (string), MAX_TOKENS (number), EXCLUDE (boolean), and ENABLED
(boolean)."
  :type '(choice
          (const :tag "Provider default" nil)
          (plist :tag "Custom reasoning plist"))
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-default-usage '((include . t))
  "Default usage options sent with every request when non-nil.
Set to nil to keep provider defaults. Keys include INCLUDE (boolean)."
  :type '(choice
          (const :tag "Provider default" nil)
          (plist :tag "Custom usage plist"))
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-max-retries 2
  "Number of retry attempts after the first try for transient failures."
  :type 'integer
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-retry-backoff-seconds 0.5
  "Base delay in seconds for retry backoff (exponential per attempt)."
  :type 'number
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-env-var "AI_GATEWAY_API_KEY"
  "Environment variable name used to locate the Vercel API key."
  :type 'string
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-auth-source-user "vercel"
  "Default auth-source username searched for Vercel credentials.
Set to nil to skip matching on :user."
  :type '(choice (const :tag "Any user" nil) string)
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-referer "https://github.com/scotttrinh/benedict"
  "Referer header value required by Vercel's policy."
  :type 'string
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-app-name "Benedict"
  "Human readable application name sent via the X-Title header."
  :type 'string
  :group 'benedict-provider-vercel)

(defcustom benedict-provider-vercel-enable-streaming t
  "When non-nil, enable streaming via curl for Vercel requests."
  :type 'boolean
  :group 'benedict-provider-vercel)

(make-obsolete-variable 'benedict-provider-vercel-curl-program
                        'benedict-http-curl-program "0.1")
(make-obsolete-variable 'benedict-provider-vercel-streaming-extra-args
                        'benedict-http-proxy-args "0.1")

(defconst benedict-provider-vercel--retryable-status-codes
  '(408 409 425 429 500 502 503 504)
  "HTTP status codes considered retryable for Vercel requests.")

(defvar benedict-provider-vercel--state-table
  (make-hash-table :test 'equal)
  "In-memory registry of per-request state keyed by request id.")

(defun benedict-provider-vercel--make-request-id ()
  "Return a log-friendly unique request identifier for Vercel."
  (format "vercel-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%SZ" (current-time) t)
          (random #x1000000)))

(defun benedict-provider-vercel--state-create (&rest kvs)
  "Create and store a new state entry seeded with KVS, returning its id."
  (let* ((id (or (plist-get kvs :id)
                 (benedict-provider-vercel--make-request-id)))
         (state (list :id id)))
    (while kvs
      (let ((k (pop kvs))
            (v (pop kvs)))
        (setq state (plist-put state k v))))
    (puthash id state benedict-provider-vercel--state-table)
    id))

(defun benedict-provider-vercel--state-get (id)
  "Return state for request ID, or nil when absent."
  (and id (gethash id benedict-provider-vercel--state-table)))

(defun benedict-provider-vercel--state-update (id &rest kvs)
  "Update state for ID with KVS and return the updated state."
  (when id
    (let ((state (or (benedict-provider-vercel--state-get id)
                     (list :id id))))
      (while kvs
        (let ((k (pop kvs))
              (v (pop kvs)))
          (setq state (plist-put state k v))))
      (puthash id state benedict-provider-vercel--state-table)
      state)))

(defun benedict-provider-vercel--state-push (id key value)
  "Push VALUE onto plist KEY for state ID (as a stack)."
  (when id
    (let* ((state (or (benedict-provider-vercel--state-get id)
                      (list :id id)))
           (current (plist-get state key)))
      (setq state (plist-put state key (cons value current)))
      (puthash id state benedict-provider-vercel--state-table)
      state)))

(defun benedict-provider-vercel--state-clear (id)
  "Remove request state bound to ID."
  (when id
    (remhash id benedict-provider-vercel--state-table)))

(defun benedict-provider-vercel--state-get* (context key)
  "Helper: fetch KEY from state associated with CONTEXT."
  (plist-get (benedict-provider-vercel--state-get
              (plist-get context :request-id))
             key))

(defun benedict-provider-vercel--state-update* (context &rest kvs)
  "Helper: update state associated with CONTEXT using KVS."
  (apply #'benedict-provider-vercel--state-update
         (plist-get context :request-id)
         kvs))

(defun benedict-provider-vercel--state-push* (context key value)
  "Helper: push VALUE onto KEY in state associated with CONTEXT."
  (benedict-provider-vercel--state-push
   (plist-get context :request-id) key value))

(cl-defun benedict-provider-vercel--send
    (_provider request &key on-success on-error on-delta on-complete)
  "Dispatch REQUEST to Vercel.
ON-SUCCESS/ON-ERROR/ON-DELTA/ON-COMPLETE mirror `benedict-provider-dispatch'.
When streaming is enabled, callbacks receive incremental deltas via curl."
  (let* ((credential (benedict-provider-vercel--resolve-credential))
         (streaming (and benedict-provider-vercel-enable-streaming
                         (or (plist-get request :stream)
                             on-delta)))
         (payload (benedict-provider-vercel--encode-payload request streaming))
         (request-id (or (plist-get request :request-id)
                         (benedict-provider-vercel--make-request-id)))
         (start-time (current-time)))
    (benedict-provider-vercel--state-create
     :id request-id
     :provider 'vercel
     :model (or (plist-get request :model)
                benedict-provider-vercel-default-model)
     :start-time start-time
     :status (if streaming :streaming :http))
    (when streaming
      (benedict-provider-vercel--state-update
       request-id
       :status :streaming
       :message-chunks nil
       :reasoning-counter 0
       :reasoning-entries nil
       :reasoning-order nil
       :role 'assistant
       :final-message nil
       :final-message-text nil
       :usage nil
       :raw-last nil
       :remote-id nil
       :tool-call-partials nil))
    (let ((context (list :request request
                         :payload payload
                         :credential credential
                         :request-id request-id
                         :on-success on-success
                         :on-error on-error
                         :on-delta on-delta
                         :streaming streaming
                         :mode (if streaming 'stream 'http)
                         :attempt 1
                         :max-attempts (max 1 (+ 1 (max 0 benedict-provider-vercel-max-retries)))
                         :start-time start-time
                         :provider 'vercel)))
      (benedict-provider-vercel--perform-request context)
      context)))

(defun benedict-provider-vercel--perform-request (context)
  "Execute the HTTP request described by CONTEXT."
  (let* ((token (plist-get (plist-get context :credential) :token))
         (headers (benedict-provider-vercel--build-headers token))
         (payload (plist-get context :payload))
         (streaming (plist-get context :streaming)))
    (benedict-provider-log-debug
     'vercel :request
     :request-id (plist-get context :request-id)
     :attempt (plist-get context :attempt)
     :endpoint benedict-provider-vercel-endpoint
     :headers (benedict-provider-vercel--redact-headers headers)
     :body payload
     :body-bytes (and payload (string-bytes payload))
     :credential-source (plist-get (plist-get context :credential) :source))
    
    (let ((process 
           (benedict-http-request
            benedict-provider-vercel-endpoint
            :method "POST"
            :headers headers
            :body payload
            :stream streaming
            :request-id (plist-get context :request-id)
            :provider 'vercel
            :on-success (lambda (_status _headers body)
                          (benedict-provider-vercel--handle-response body context))
            :on-error (lambda (err)
                        (benedict-provider-vercel--handle-error err context))
            :on-delta (lambda (_type data)
                        (benedict-provider-vercel--handle-sse-payload context data nil)))))
      (setf (plist-get context :process) process)
      context)))





(defun benedict-provider-vercel--handle-sse-payload (context payload _event)
  "Handle SSE PAYLOAD for CONTEXT.
Handles standard JSON payloads as well as newline-delimited JSON (NDJSON)
which some providers (like xAI/Grok) seem to emit within a single SSE block."
  (if (string= payload "[DONE]")
      (benedict-provider-vercel--stream-handle-done context)
    (let ((lines (split-string payload "\n" t))
          (parsed-objects nil)
          (parse-error nil))
      ;; Attempt to parse each line as a separate JSON object
      (dolist (line lines)
        (unless parse-error
          (condition-case _err
              (push (json-parse-string line :object-type 'plist :array-type 'list
                                       :null-object nil :false-object :json-false)
                    parsed-objects)
            (json-parse-error
             (setq parse-error t)))))
      
      (if (and parsed-objects (not parse-error))
          ;; Successfully parsed as NDJSON
          (dolist (json (nreverse parsed-objects))
            (benedict-provider-vercel--stream-handle-json context json))
        ;; Fallback: Parse the entire payload as a single JSON object
        (condition-case err
            (let ((json (json-parse-string payload :object-type 'plist :array-type 'list
                                           :null-object nil :false-object :json-false)))
              (benedict-provider-vercel--stream-handle-json context json))
          (json-parse-error
           (benedict-provider-log
            'vercel 'warn :stream-parse-error
            :request-id (plist-get context :request-id)
            :payload payload
            :error err)))))))

(defun benedict-provider-vercel--stream-handle-error (context error-block _ignored)
  "Handle streaming ERROR-BLOCK for CONTEXT."
  (let ((message (or (plist-get error-block :message) "Unknown streaming error"))
        (code (plist-get error-block :code))
        (type (plist-get error-block :type)))
    (benedict-provider-log
     'vercel 'error :stream-error
     :request-id (plist-get context :request-id)
     :code code
     :type type
     :message message)
    (benedict-provider-vercel--emit-error
     context (list :type 'api :code code :message message :body error-block :retryable nil))))

(defun benedict-provider-vercel--stream-handle-json (context event)
  "Handle parsed streaming EVENT for CONTEXT."
  (unless (plist-get context :stream-complete)
    (let* ((request-id (plist-get context :request-id))
           (remote-id (plist-get event :id))
           (on-delta (plist-get context :on-delta)))
      (benedict-provider-vercel--state-update
       request-id :raw-last event)
      (if-let ((error-block (plist-get event :error)))
          (benedict-provider-vercel--stream-handle-error context error-block nil)
        (progn
          (when-let ((model (plist-get event :model)))
            (benedict-provider-vercel--state-update request-id :model model))
          (when remote-id
            (benedict-provider-vercel--state-update request-id :remote-id remote-id))
          (when-let ((usage (plist-get event :usage)))
            (benedict-provider-vercel--state-update request-id :usage usage))
          (let ((choices (benedict-provider-vercel--normalize-seq
                          (plist-get event :choices))))
            (cond
             (choices
              (let* ((normalized (benedict-provider-vercel--normalize-delta-choices
                                  context choices)))
                (benedict-provider-log-trace
                 'vercel :stream-delta
                 :request-id request-id
                 :remote-id remote-id
                 :choices (length normalized))
                (when (functionp on-delta)
                  (dolist (choice normalized)
                    (let ((delta (plist-get choice :delta)))
                      (when-let ((text (plist-get delta :text)))
                        (funcall on-delta
                                 :message-id request-id
                                 :kind 'content-delta
                                 :text text))
                      (when-let ((reasoning (plist-get delta :reasoning_details)))
                        (mapc (lambda (detail)
                                (let ((chunk (or (plist-get detail :text)
                                                 (plist-get detail :summary)
                                                 (plist-get detail :data))))
                                  (when (and chunk (> (length chunk) 0))
                                    (funcall on-delta
                                             :message-id request-id
                                             :kind 'thinking-delta
                                             :text chunk))))
                              reasoning)))))))
             ((benedict-provider-vercel--stream-handle-reasoning-event
               context event)
              nil))))))))

(defun benedict-provider-vercel--stream-handle-reasoning-event (context event)
  "Handle reasoning-only EVENT by emitting a synthetic delta.
Returns non-nil when a delta was dispatched."
  (let ((details (benedict-provider-vercel--normalize-reasoning-delta
                  context event))
        (on-delta (plist-get context :on-delta))
        (request-id (plist-get context :request-id)))
    (when details
      (benedict-provider-log-trace
       'vercel :stream-reasoning-event
       :request-id request-id
       :details (length details))
      (when on-delta
        (mapc (lambda (detail)
                (let ((chunk (or (plist-get detail :text)
                                 (plist-get detail :summary)
                                 (plist-get detail :data))))
                  (when (and chunk (> (length chunk) 0))
                    (funcall on-delta :message-id request-id
                             :kind 'thinking-delta
                             :text chunk))))
              details))
      t)))

(defun benedict-provider-vercel--normalize-delta-choices (context choices)
  "Return normalized CHOICES for CONTEXT."
  (let (result)
    (cl-loop for choice in choices
             for idx from 0
             do (push (benedict-provider-vercel--normalize-delta-choice
                       context choice idx)
                      result))
    (nreverse result)))

(defun benedict-provider-vercel--normalize-delta-choice (context choice index)
  "Normalize a single CHOICE for CONTEXT with INDEX."
  (let* ((normalized (copy-tree choice t))
         (delta (plist-get normalized :delta)))
    (plist-put normalized :index (or (plist-get normalized :index) index))
    (when delta
      (benedict-provider-vercel--accumulate-tool-calls-from-delta context delta)
      (when-let ((chunk (benedict-provider-vercel--accumulate-message-from-delta
                         context delta)))
        (plist-put normalized :text chunk)
        (plist-put delta :text chunk))
      (let ((details (benedict-provider-vercel--normalize-reasoning-delta
                      context delta)))
        (when details
          (plist-put delta :reasoning_details (apply #'vector details)))))
    (when-let ((message (plist-get normalized :message)))
      (benedict-provider-vercel--store-final-message context message))
    normalized))

(defun benedict-provider-vercel--normalize-reasoning-delta (context delta)
  "Extract reasoning details from DELTA for CONTEXT."
  (let (details)
    (dolist (entry (benedict-provider-vercel--extract-reasoning-details delta))
      (when-let ((detail (benedict-provider-vercel--prepare-reasoning-detail
                          context entry)))
        (push detail details)))
    (nreverse details)))

(defun benedict-provider-vercel--extract-reasoning-details (delta)
  "Return raw reasoning entries extracted from DELTA."
  (let (result)
    (dolist (key '(:reasoning_details :reasoning :reasoning_content :thinking :thoughts))
      (setq result (nconc result
                          (benedict-provider-vercel--normalize-seq
                           (plist-get delta key)))))
    (when-let ((content (plist-get delta :content)))
      (dolist (entry (benedict-provider-vercel--normalize-seq content))
        (when (benedict-provider-vercel--reasoning-content-entry-p entry)
          (push entry result))))
    (nreverse result)))

(defun benedict-provider-vercel--reasoning-content-entry-p (entry)
  "Return non-nil when ENTRY looks like a reasoning content block."
  (when (and entry (listp entry))
    (when-let ((type (plist-get entry :type)))
      (let ((normalized (downcase (format "%s" type))))
        (or (string-prefix-p "thinking" normalized)
            (string-prefix-p "reasoning" normalized))))))

(defun benedict-provider-vercel--prepare-reasoning-detail (context entry)
  "Normalize reasoning ENTRY for CONTEXT, returning a detail plist."
  (cond
   ((null entry) nil)
   ((stringp entry)
    (benedict-provider-vercel--prepare-reasoning-detail
     context (list :type "reasoning.text" :text entry)))
   ((listp entry)
    (let* ((detail (copy-tree entry t))
           (type (or (plist-get detail :type) "reasoning.text")))
      (plist-put detail :type type)
      (unless (plist-get detail :format)
        (plist-put detail :format "vercel-reasoning"))
      (let ((text (plist-get detail :text))
            (summary (plist-get detail :summary))
            (data (plist-get detail :data)))
        (unless (or text summary data)
          (let ((content (plist-get detail :content)))
            (cond
             ((stringp content)
              (setq text content))
             (content
              (setq text
                    (mapconcat
                     (lambda (piece)
                       (cond
                        ((stringp piece) piece)
                        ((listp piece)
                         (or (plist-get piece :text)
                             (plist-get piece :content)
                             ""))
                        (t "")))
                     (benedict-provider-vercel--normalize-seq content) ""))))))
        (when text
          (plist-put detail :text text)))
      (if (or (plist-get detail :text)
              (plist-get detail :summary)
              (plist-get detail :data))
          (let ((id (or (plist-get detail :id)
                        (benedict-provider-vercel--next-reasoning-id context))))
            (plist-put detail :id id)
            (plist-put detail :index
                       (or (plist-get detail :index)
                           (benedict-provider-vercel--register-reasoning-id
                            context id)))
            (benedict-provider-vercel--accumulate-reasoning-entry context detail)
            detail)
        nil)))
   (t nil)))

(defun benedict-provider-vercel--register-reasoning-id (context id)
  "Register reasoning ID for CONTEXT and return its index."
  (let* ((state (benedict-provider-vercel--state-get
                 (plist-get context :request-id)))
         (order (plist-get state :reasoning-order)))
    (unless (cl-member id order :test #'equal)
      (setq order (append order (list id)))
      (benedict-provider-vercel--state-update
       (plist-get context :request-id) :reasoning-order order))
    (cl-position id order :test #'equal)))

(defun benedict-provider-vercel--next-reasoning-id (context)
  "Return a new reasoning identifier for CONTEXT."
  (let* ((state (benedict-provider-vercel--state-get
                 (plist-get context :request-id)))
         (counter (or (plist-get state :reasoning-counter) 0)))
    (benedict-provider-vercel--state-update
     (plist-get context :request-id) :reasoning-counter (1+ counter))
    (format "%s-thinking-%d" (plist-get context :request-id) counter)))

(defun benedict-provider-vercel--accumulate-reasoning-entry (context detail)
  "Accumulate DETAIL chunks into CONTEXT final reasoning state."
  (let* ((state (benedict-provider-vercel--state-get
                 (plist-get context :request-id)))
         (entries (plist-get state :reasoning-entries))
         (id (plist-get detail :id))
         (existing (cl-assoc id entries :test #'equal)))
    (unless existing
      (setq existing (cons id (copy-tree detail t)))
      (push existing entries)
      (benedict-provider-vercel--state-update
       (plist-get context :request-id) :reasoning-entries entries))
    (dolist (key '(:text :summary :data))
      (when-let ((chunk (plist-get detail key)))
        (let ((current (plist-get (cdr existing) key)))
          (plist-put (cdr existing) key
                     (if current (concat current chunk) chunk)))))
    (cdr existing)))

(defun benedict-provider-vercel--accumulate-message-from-delta (context delta)
  "Append assistant message text from DELTA for CONTEXT."
  (when-let ((role (plist-get delta :role)))
    (benedict-provider-vercel--state-update
     (plist-get context :request-id)
     :role (intern (downcase (format "%s" role)))))
  (let ((text (benedict-provider-vercel--delta-text delta)))
    (when (and text (not (string-empty-p text)))
      (benedict-provider-vercel--state-push* context :message-chunks text)
      text)))

(defun benedict-provider-vercel--accumulate-tool-calls-from-delta (context delta)
  "Accumulate tool calls from DELTA for CONTEXT."
  (when-let ((calls (plist-get delta :tool_calls)))
    (let* ((state (benedict-provider-vercel--state-get
                   (plist-get context :request-id)))
           (partials (plist-get state :tool-call-partials)))
      (dolist (call calls)
        (let* ((index (plist-get call :index))
               (entry (or (alist-get index partials)
                          (list :index index :id "" :type "" :name "" :arguments ""))))
          (when-let ((id (plist-get call :id)))
            (plist-put entry :id (concat (plist-get entry :id) id)))
          (when-let ((type (plist-get call :type)))
            (plist-put entry :type (concat (plist-get entry :type) type)))
          (when-let ((function (plist-get call :function)))
            (when-let ((name (plist-get function :name)))
              (plist-put entry :name (concat (plist-get entry :name) name)))
            (when-let ((args (plist-get function :arguments)))
              (plist-put entry :arguments (concat (plist-get entry :arguments) args))))
          (setf (alist-get index partials) entry)))
      (benedict-provider-vercel--state-update
       (plist-get context :request-id) :tool-call-partials partials))))

(defun benedict-provider-vercel--finalize-tool-calls (context)
  "Finalize accumulated tool calls for CONTEXT."
  (let* ((state (benedict-provider-vercel--state-get
                 (plist-get context :request-id)))
         (partials (plist-get state :tool-call-partials)))
    (when partials
      (let (result)
        (dolist (pair (sort partials (lambda (a b) (< (car a) (car b)))))
          (let* ((entry (cdr pair))
                 (name (plist-get entry :name))
                 (args-str (plist-get entry :arguments))
                 (decoded-args (benedict-provider-vercel--decode-tool-arguments args-str)))
            (push (list :id (plist-get entry :id)
                        :type (or (plist-get entry :type) "function")
                        :name (benedict-provider-vercel--normalize-tool-name name)
                        :arguments decoded-args
                        :raw entry)
                  result)))
        (nreverse result)))))

(defun benedict-provider-vercel--delta-text (delta)
  "Extract user-visible text from DELTA."
  (cond
   ((plist-member delta :content)
    (let ((content (plist-get delta :content)))
      (cond
       ((stringp content) content)
       (content
        (mapconcat
         (lambda (entry)
           (cond
            ((stringp entry) entry)
            ((listp entry)
             (or (plist-get entry :text)
                 (plist-get entry :content)
                 ""))
            (t "")))
         (benedict-provider-vercel--normalize-seq content) "")))))
   ((plist-member delta :text)
    (plist-get delta :text))
   (t nil)))

(defun benedict-provider-vercel--store-final-message (context message)
  "Remember final MESSAGE for CONTEXT if present."
  (benedict-provider-vercel--state-update
   (plist-get context :request-id) :final-message message)
  (when-let ((content (plist-get message :content)))
    (cond
     ((stringp content)
      (benedict-provider-vercel--state-update
       (plist-get context :request-id) :final-message-text content))
     (content
      (let ((text (mapconcat
                   (lambda (entry)
                     (cond
                      ((stringp entry) entry)
                      ((listp entry) (or (plist-get entry :text) ""))
                      (t "")))
                   (benedict-provider-vercel--normalize-seq content) "")))
        (benedict-provider-vercel--state-update
         (plist-get context :request-id) :final-message-text text))))))

(defun benedict-provider-vercel--stream-build-delta-payload (context event choices)
  "Build delta payload for CONTEXT using EVENT and normalized CHOICES."
  (let ((payload (copy-tree event t)))
    (plist-put payload :provider 'vercel)
    (plist-put payload :model (or (plist-get payload :model)
                                  (benedict-provider-vercel--state-get*
                                   context :model)
                                  benedict-provider-vercel-default-model))
    (when-let ((usage (or (plist-get event :usage)
                          (benedict-provider-vercel--state-get*
                           context :usage))))
      (plist-put payload :usage usage))
    (plist-put payload :choices (apply #'vector choices))
    payload))

(defun benedict-provider-vercel--stream-handle-done (context)
  "Handle end-of-stream for CONTEXT."
  (unless (plist-get context :stream-complete)
    (setf (plist-get context :stream-complete) t)
    (benedict-provider-vercel--finalize-stream context)))


(defun benedict-provider-vercel--finalize-stream (context)
  "Finalize streaming CONTEXT and deliver completion callback."
  (let* ((request-id (plist-get context :request-id))
         (state (benedict-provider-vercel--state-get request-id))
         (chunks (plist-get state :message-chunks))
         (content (or (plist-get state :final-message-text)
                      (mapconcat #'identity (nreverse chunks) "")))
         (role (or (plist-get state :role) 'assistant))
         (tool-calls (benedict-provider-vercel--finalize-tool-calls context))
         (message (or (plist-get state :final-message)
                      (list :role role :content content :tool-calls tool-calls)))
         (thinking (benedict-provider-vercel--finalize-reasoning context))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (if start-time
                      (float-time (time-subtract end-time start-time))
                    0.0))
         (result (list :message message
                       :model (or (plist-get state :model)
                                  benedict-provider-vercel-default-model)
                       :provider 'vercel
                       :usage (plist-get state :usage)
                       :thinking thinking
                       :latency latency
                       :raw (plist-get state :raw-last)
                       :empty-response (and (string-empty-p (or content ""))
                                            (null tool-calls)))))
    (benedict-provider-vercel--state-update request-id
                                                :status :completed
                                                :end-time end-time
                                                :latency latency)
    (benedict-provider-log
     'vercel 'info :stream-complete
     :request-id request-id
     :remote-id (plist-get state :remote-id)
     :latency latency
     :model (plist-get result :model)
     :content-bytes (length (or content "")))
    (benedict-provider-vercel--stream-cleanup context)
    (benedict-provider-vercel--state-clear request-id)
    (let ((on-complete (plist-get context :on-complete))
          (on-success (plist-get context :on-success)))
      (cond
       ((functionp on-complete) (funcall on-complete result))
       ((functionp on-success) (funcall on-success result))))))

(defun benedict-provider-vercel--finalize-reasoning (context)
  "Return accumulated reasoning payload for CONTEXT."
  (let* ((state (benedict-provider-vercel--state-get
                 (plist-get context :request-id)))
         (order (plist-get state :reasoning-order))
         (entries (plist-get state :reasoning-entries)))
    (when (and order entries)
      (let (result)
        (dolist (id order (nreverse result))
          (when-let ((entry (cdr (cl-assoc id entries :test #'equal))))
            (push (copy-tree entry t) result)))))))

(defun benedict-provider-vercel--stream-cleanup (context)
  "Tear down streaming resources for CONTEXT."
  (when-let ((process (plist-get context :process)))
    (when (process-live-p process)
      (set-process-sentinel process nil)
      (delete-process process))))

(defun benedict-provider-vercel--cancel (_provider handle)
  "Cancel HANDLE (best-effort)."
  (when (and handle (plist-get handle :process))
    (setf (plist-get handle :stream-complete) t)
    (benedict-provider-vercel--stream-cleanup handle)))

(defun benedict-provider-vercel--handle-response (body context)
  "Handle successful HTTP response BODY for CONTEXT."
  (benedict-provider-vercel--process-http-response context 200 body))

(defun benedict-provider-vercel--handle-error (error context)
  "Handle HTTP/Process ERROR for CONTEXT."
  (let ((type (plist-get error :type))
        (code (plist-get error :code))
        (body (plist-get error :body))
        (stderr (plist-get error :stderr))
        (message (plist-get error :message)))
    (setf (plist-get context :stream-complete) t)
    (if (and (eq type 'http) (eq code 22))
        (benedict-provider-vercel--process-http-response context 0 body)
      (let* ((request-id (plist-get context :request-id))
             (attempt (plist-get context :attempt))
             (err-msg (or message stderr "Unknown error")))
        (if (benedict-provider-vercel--maybe-retry context nil err-msg)
            (benedict-provider-log
             'vercel 'warn :network-error
             :request-id request-id
             :attempt attempt
             :message err-msg
             :retry t)
          (benedict-provider-log
           'vercel 'error :network-error
           :request-id request-id
           :attempt attempt
           :message err-msg
           :retry nil)
          (benedict-provider-vercel--emit-error
           context (list :type 'network :message err-msg :retryable nil)))))))

(defun benedict-provider-vercel--process-http-response (context status-code body)
  "Parse BODY returned with STATUS-CODE using CONTEXT."
  (condition-case err
      (let* ((parsed (and (not (string-empty-p body))
                          (json-parse-string body :object-type 'alist :array-type 'list
                                             :null-object nil :false-object :json-false)))
             (error-block (and parsed (benedict-provider-vercel--aget "error" parsed))))
        (if error-block
            (benedict-provider-vercel--handle-api-error context status-code error-block body)
          (benedict-provider-vercel--handle-success context status-code parsed body)))
    (json-parse-error
     (let ((request-id (plist-get context :request-id)))
       (if (benedict-provider-vercel--maybe-retry context status-code "JSON parse error")
           (benedict-provider-log
            'vercel 'warn :decode-error
            :request-id request-id
            :status status-code
            :body body
            :error err
            :retry t)
         (benedict-provider-log
          'vercel 'error :decode-error
          :request-id request-id
          :status status-code
          :body body
          :error err
          :retry nil)
         (benedict-provider-vercel--emit-error
          context (list :type 'decode :status status-code :message "Failed to parse response"
                        :body body :retryable nil :error err)))))))

(defun benedict-provider-vercel--handle-success (context status-code parsed _body)
  "Handle PARSED success payload (STATUS-CODE, _BODY) using CONTEXT."
  (let* ((request-id (plist-get context :request-id))
         (state (benedict-provider-vercel--state-get request-id))
         (choices (or (benedict-provider-vercel--aget "choices" parsed) '()))
         (first (car choices))
         (message (and first (benedict-provider-vercel--aget "message" first)))
         (decoded-message (if message
                              (benedict-provider-vercel--decode-message message)
                            (list :role 'assistant :content "" :raw nil)))
         (usage (benedict-provider-vercel--aget "usage" parsed))
         (model (or (benedict-provider-vercel--aget "model" parsed)
                    benedict-provider-vercel-default-model))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (if start-time
                      (float-time (time-subtract end-time start-time))
                    0.0))
         (empty-response (and (string-empty-p (or (plist-get decoded-message :content) ""))
                              (not (plist-get decoded-message :tool-calls))))
         (result (list :message decoded-message
                       :usage usage
                       :model model
                       :provider 'vercel
                       :status status-code
                       :latency latency
                       :raw parsed
                       :empty-response empty-response))
         (log-level (if empty-response 'warn 'info)))
    (benedict-provider-vercel--state-update
     request-id :usage usage :model model :latency latency
     :status :completed :end-time end-time)
    (benedict-provider-log
     'vercel log-level :completion
     :request-id request-id
     :attempt (plist-get context :attempt)
     :status status-code
     :model model
     :latency latency
     :usage usage
     :empty-response empty-response)
    ;; Prefer :on-complete over :on-success for consistency with streaming protocol
    (if (functionp (plist-get context :on-complete))
        (funcall (plist-get context :on-complete) result)
      (when (functionp (plist-get context :on-success))
        (funcall (plist-get context :on-success) result)))
    (benedict-provider-vercel--state-clear request-id)))

(defun benedict-provider-vercel--handle-api-error (context status-code error-block body)
  "Handle API ERROR-BLOCK with STATUS-CODE/BODY."
  (let* ((message (or (benedict-provider-vercel--aget "message" error-block)
                      (format "HTTP %s" status-code)))
         (code (or (benedict-provider-vercel--aget "code" error-block)
                   status-code))
         (retryable (benedict-provider-vercel--retryable-status-p status-code))
         (retry (and retryable
                     (benedict-provider-vercel--maybe-retry context status-code message))))
    (if retry
        (benedict-provider-log
         'vercel 'warn :http-error
         :request-id (plist-get context :request-id)
         :attempt (plist-get context :attempt)
         :status status-code
         :code code
         :message message
         :retry t)
      (benedict-provider-log
       'vercel 'error :http-error
       :request-id (plist-get context :request-id)
       :attempt (plist-get context :attempt)
       :status status-code
       :code code
       :message message
       :retry nil)
      (benedict-provider-vercel--emit-error
       context (list :type 'http :status status-code :code code :message message
                     :retryable retryable :body body)))))

(defun benedict-provider-vercel--maybe-retry (context status message)
  "Retry request described by CONTEXT when STATUS/MESSAGE is retryable."
  (let ((attempt (plist-get context :attempt))
        (max (plist-get context :max-attempts)))
    (when (and (< attempt max)
               (benedict-provider-vercel--retryable-p status message))
      (let* ((delay (benedict-provider-vercel--retry-delay attempt))
             (next (copy-sequence context)))
        (setq next (plist-put next :attempt (1+ attempt)))
        (setq next (plist-put next :start-time (current-time)))
        (benedict-provider-vercel--state-update
         (plist-get context :request-id)
         :status :retrying
         :start-time (plist-get next :start-time))
        (benedict-provider-log-debug
         'vercel :retry
         :request-id (plist-get context :request-id)
         :current-attempt attempt
         :next-attempt (plist-get next :attempt)
         :delay delay
         :status status
         :message message)
        (run-at-time delay #'benedict-provider-vercel--perform-request next)
        t))))

(defun benedict-provider-vercel--retry-delay (attempt)
  "Compute retry delay for ATTEMPT."
  (* benedict-provider-vercel-retry-backoff-seconds
     (expt 2 (max 0 (1- attempt)))))

(defun benedict-provider-vercel--retryable-p (status message)
  "Return non-nil when STATUS/MESSAGE indicates a retryable error."
  (or (null status)
      (zerop status)
      (memq status benedict-provider-vercel--retryable-status-codes)
      (and (stringp message)
           (string-match-p "\\(timeout\\|temporarily unavailable\\)" (downcase message)))))

(defun benedict-provider-vercel--retryable-status-p (status)
  "Return non-nil if STATUS is in the retryable set."
  (memq status benedict-provider-vercel--retryable-status-codes))

(defun benedict-provider-vercel--emit-error (context payload)
  "Invoke the CONTEXT on-error handler with PAYLOAD."
  (let* ((handler (plist-get context :on-error))
         (request-id (plist-get context :request-id))
         (state (benedict-provider-vercel--state-get request-id))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (and start-time
                       (float-time (time-subtract end-time start-time)))))
    (when request-id
      (benedict-provider-vercel--state-update
       request-id :status :error :error payload :end-time end-time :latency latency)
      (benedict-provider-vercel--state-clear request-id))
    (when (functionp handler)
      (funcall handler payload))))

(defun benedict-provider-vercel--build-headers (token)
  "Construct headers using TOKEN."
  (let ((headers (list (cons "Content-Type" "application/json")
                       (cons "Authorization" (format "Bearer %s" token)))))
    (when (and benedict-provider-vercel-referer
               (not (string-empty-p benedict-provider-vercel-referer)))
      (push (cons "HTTP-Referer" benedict-provider-vercel-referer) headers))
    (when (and benedict-provider-vercel-app-name
               (not (string-empty-p benedict-provider-vercel-app-name)))
      (push (cons "X-Title" benedict-provider-vercel-app-name) headers))
    (nreverse headers)))

(defun benedict-provider-vercel--redact-secret (value)
  "Return VALUE masked for logging."
  (if (and (stringp value) (> (length value) 8))
      (format "%s…%s" (substring value 0 4) (substring value (- (length value) 2)))
    "***"))

(defun benedict-provider-vercel--redact-headers (headers)
  "Redact sensitive HEADERS for logging."
  (mapcar
   (lambda (header)
     (let* ((name (car header))
            (value (cdr header))
            (normalized (downcase (format "%s" name))))
       (if (member normalized '("authorization" "proxy-authorization"))
           (cons name (benedict-provider-vercel--redact-secret value))
         header)))
   (copy-sequence headers)))

(defun benedict-provider-vercel--encode-payload (request &optional stream)
  "Return JSON payload string for REQUEST.
When STREAM is non-nil, include the \"stream\": true flag in the payload."
  (encode-coding-string
   (json-encode (benedict-provider-vercel--build-body request stream))
   'utf-8))

(defun benedict-provider-vercel--build-body (request &optional stream)
  "Build an alist for REQUEST."
  (let ((messages (plist-get request :messages)))
    (unless (and (listp messages) messages)
      (error "Vercel request requires a non-empty :messages list"))
    (let ((body `(("model" . ,(or (plist-get request :model)
                                  benedict-provider-vercel-default-model))
                  ("messages" . ,(mapcar #'benedict-provider-vercel--serialize-message
                                         messages)))))
      (when stream
        (push '("stream" . t) body))
      (when-let ((tools (plist-get request :tools)))
        (when-let ((serialized (benedict-provider-vercel--serialize-tools tools)))
          (push (cons "tools" serialized) body)))
      (let ((temperature (if (plist-member request :temperature)
                             (plist-get request :temperature)
                           benedict-provider-vercel-default-temperature)))
        (when temperature
          (push (cons "temperature" temperature) body)))
      (let ((reasoning (or (plist-get request :reasoning)
                           benedict-provider-vercel-default-reasoning)))
        (when reasoning
          (when-let ((normalized (benedict-provider-vercel--normalize-reasoning reasoning)))
            (push (cons "reasoning" normalized) body))))
      (let ((usage (or (plist-get request :usage-options)
                       benedict-provider-vercel-default-usage)))
        (when usage
          (when-let ((normalized (benedict-provider-vercel--normalize-usage usage)))
            (push (cons "usage" normalized) body))))
      (dolist (pair '((:max-tokens . "max_tokens")
                      (:top-p . "top_p")
                      (:presence-penalty . "presence_penalty")
                      (:frequency-penalty . "frequency_penalty")))
        (when (plist-member request (car pair))
          (push (cons (cdr pair) (plist-get request (car pair))) body)))
      (let ((options (plist-get request :options)))
        (when (and options (listp options))
          (cl-loop for (key value) on options by #'cddr
                   do (let ((k (benedict-provider-vercel--option-key key)))
                        (push (cons k value) body)))))
      (nreverse body))))

(defun benedict-provider-vercel--serialize-message (message)
  "Serialize MESSAGE plist to an alist for JSON encoding."
  (let* ((role (or (plist-get message :role) (plist-get message :type)))
         (content (plist-get message :content))
         (name (plist-get message :name))
         (tool-calls (plist-get message :tool-calls))
         (tool-call-id (plist-get message :tool-call-id)))
    (unless role
      (error "Message requires :role"))
    (let ((payload `(("role" . ,(benedict-provider-vercel--role-string role)))))
      (cond
       (tool-calls
        (push (cons "tool_calls"
                    (benedict-provider-vercel--serialize-tool-calls tool-calls))
              payload)
        (push (cons "content" (if (stringp content) content "")) payload))
       (t
        (push (cons "content" (if (stringp content) content "")) payload)))
      (when (and name (stringp name))
        (push (cons "name" name) payload))
      (when (and tool-call-id (stringp tool-call-id))
        (push (cons "tool_call_id" tool-call-id) payload))
      (nreverse payload))))

(defun benedict-provider-vercel--serialize-tools (tools)
  "Serialize TOOLS (registry specs) into Vercel format."
  (mapcar #'benedict-provider-vercel--serialize-tool tools))

(defun benedict-provider-vercel--serialize-tool (tool)
  "Serialize TOOL spec plist into a tool definition."
  (let* ((id (plist-get tool :id))
         (doc (or (plist-get tool :doc) ""))
         (schema (plist-get tool :schema)))
    (list
     (cons "type" "function")
     (cons "function"
           (delq nil
                 (list (cons "name" (benedict-provider-vercel--tool-name id))
                       (cons "description" doc)
                       (cons "parameters"
                             (benedict-provider-vercel--encode-tool-schema schema))))))))

(defun benedict-provider-vercel--tool-name (id)
  "Return a provider-safe string for tool ID."
  (cond
   ((symbolp id) (symbol-name id))
   ((stringp id) id)
   (t (format "%s" id))))

(defun benedict-provider-vercel--encode-tool-schema (schema)
  "Convert SCHEMA plist into a JSON schema alist."
  (let ((properties nil)
        (required nil))
    (when (and schema (listp schema))
      (let ((plist (copy-sequence schema)))
        (while plist
          (let* ((key (pop plist))
                 (type (pop plist))
                 (name (benedict-provider-vercel--tool-argument-name key)))
            (cond
             ;; Nested object schema, e.g. :target (:kind string :path string ...)
             ((and (listp type) (not (keywordp (car type))))
              (let ((subschema (benedict-provider-vercel--encode-tool-schema type)))
                (push (cons name subschema) properties)))
             ;; Simple leaf type
             (t
              (push (cons name
                          (list (cons "type"
                                      (benedict-provider-vercel--tool-type-string type))))
                    properties)))
            (push name required)))))
    (let ((payload (list (cons "type" "object")
                         (cons "properties" (nreverse properties)))))
      (when required
        (push (cons "required" (vconcat (nreverse required))) payload))
      payload)))

(defun benedict-provider-vercel--tool-type-string (type)
  "Map TYPE indicator to a JSON schema \"type\" string."
  (pcase type
    ((or 'string :string "string") "string")
    ((or 'integer :integer "integer" 'int :int) "integer")
    ((or 'number :number "number" 'float :float) "number")
    ((or 'boolean :boolean "boolean" 'bool :bool) "boolean")
    (_ "string")))

(defun benedict-provider-vercel--serialize-tool-calls (calls)
  "Serialize CALLS (a list of tool call plists) for JSON encoding."
  (mapcar #'benedict-provider-vercel--serialize-tool-call calls))

(defun benedict-provider-vercel--serialize-tool-call (call)
  "Serialize a single CALL plist into Vercel format."
  (let* ((id (or (plist-get call :id)
                 (format "call-%s" (cl-gensym))))
         (type (or (plist-get call :type) "function"))
         (name (benedict-provider-vercel--tool-name
                (or (plist-get call :name) (plist-get call :tool))))
         (arguments (benedict-provider-vercel--encode-tool-arguments
                     (plist-get call :arguments))))
    (list (cons "id" id)
          (cons "type" (if (stringp type) type "function"))
          (cons "function"
                (delq nil
                      (list (cons "name" name)
                            (cons "arguments" arguments)))))))

(defun benedict-provider-vercel--encode-tool-arguments (arguments)
  "Encode tool ARGUMENTS plist/alist into a JSON string."
  (cond
   ((stringp arguments) arguments)
   ((null arguments) "{}")
   (t (let ((alist (benedict-provider-vercel--tool-arguments->alist arguments)))
        (encode-coding-string (json-encode alist) 'utf-8)))))

(defun benedict-provider-vercel--tool-arguments->alist (arguments)
  "Convert ARGUMENTS (plist/alist) into an alist with string keys."
  (cond
   ((null arguments) nil)
   ((and (listp arguments) (keywordp (car arguments)))
    (let ((plist (copy-sequence arguments))
          result)
      (while plist
        (let ((key (pop plist))
              (value (pop plist)))
          (push (cons (benedict-provider-vercel--tool-argument-name key) value)
                result)))
      (nreverse result)))
   ((listp arguments)
    (mapcar (lambda (entry)
              (cons (benedict-provider-vercel--tool-argument-name (car entry))
                    (cdr entry)))
            arguments))
   (t nil)))

(defun benedict-provider-vercel--tool-argument-name (key)
  "Normalize KEY into a string for tool argument encoding."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-vercel--role-string (role)
  "Convert ROLE (symbol/string) to API string."
  (cond
   ((stringp role) (downcase role))
   ((symbolp role) (downcase (symbol-name role)))
   (t (downcase (format "%s" role)))))

(defun benedict-provider-vercel--option-key (key)
  "Normalize option KEY (keyword/symbol/string) into JSON field."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-vercel--normalize-usage (value)
  "Normalize VALUE into an alist suitable for the \"usage\" field."
  (let* ((alist (cond
                 ((null value) nil)
                 ((and (listp value)
                       (keywordp (car value)))
                  (let (result)
                    (while value
                      (let ((k (pop value))
                            (v (pop value)))
                        (push (cons (benedict-provider-vercel--usage-key k) v) result)))
                    (nreverse result)))
                 ((listp value) value)
                 (t nil))))
    (when alist
      (let (result)
        (dolist (entry alist (nreverse result))
          (let ((key (car entry))
                (val (cdr entry)))
            (pcase key
              ("include" (push (cons "include" val) result))
              (_ nil))))))))

(defun benedict-provider-vercel--usage-key (key)
  "Normalize usage KEY into a string identifier."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-vercel--normalize-reasoning (value)
  "Normalize VALUE into an alist suitable for the \"reasoning\" field."
  (let* ((alist (cond
                 ((null value) nil)
                 ((and (listp value)
                       (keywordp (car value)))
                  (let (result)
                    (while value
                      (let ((k (pop value))
                            (v (pop value)))
                        (push (cons (benedict-provider-vercel--reasoning-key k) v) result)))
                    (nreverse result)))
                 ((listp value) value)
                 (t nil))))
    (when alist
      (let (result)
        (dolist (entry alist (nreverse result))
          (let ((key (car entry))
                (val (cdr entry)))
            (pcase key
              ("effort" (push (cons "effort" val) result))
              ("max_tokens" (push (cons "max_tokens" val) result))
              ("exclude" (push (cons "exclude" val) result))
              ("enabled" (push (cons "enabled" val) result))
              (_ nil))))))))

(defun benedict-provider-vercel--reasoning-key (key)
  "Normalize reasoning KEY into a string identifier."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-vercel--normalize-seq (value)
  "Return VALUE coerced into a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((vectorp value) (append value nil))
   (t (list value))))

(defun benedict-provider-vercel--decode-message (message)
  "Convert MESSAGE alist to Benedict's internal plist."
  (let* ((role (or (benedict-provider-vercel--aget "role" message)
                   "assistant"))
         (content (or (benedict-provider-vercel--aget "content" message)
                      ""))
         (tool-calls (benedict-provider-vercel--aget "tool_calls" message))
         (result (list :role (intern (downcase role))
                       :content content
                       :raw message)))
    (when tool-calls
      (when-let ((decoded (benedict-provider-vercel--decode-tool-calls tool-calls)))
        (setq result (plist-put result :tool-calls decoded))))
    result))

(defun benedict-provider-vercel--decode-tool-calls (calls)
  "Return CALLS converted into normalized tool call plists."
  (let (result)
    (dolist (call calls (nreverse result))
      (when-let ((decoded (benedict-provider-vercel--decode-tool-call call)))
        (push decoded result)))))

(defun benedict-provider-vercel--decode-tool-call (call)
  "Convert CALL alist into a normalized plist."
  (let* ((id (benedict-provider-vercel--aget "id" call))
         (type (or (benedict-provider-vercel--aget "type" call) "function"))
         (function (benedict-provider-vercel--aget "function" call))
         (name (and function (benedict-provider-vercel--aget "name" function)))
         (arguments (and function (benedict-provider-vercel--aget "arguments" function)))
         (decoded-args (benedict-provider-vercel--decode-tool-arguments arguments)))
    (list :id id
          :type type
          :name (benedict-provider-vercel--normalize-tool-name name)
          :arguments decoded-args
          :raw call)))

(defun benedict-provider-vercel--normalize-tool-name (name)
  "Return NAME coerced into a symbol for registry lookups."
  (cond
   ((symbolp name) name)
   ((stringp name)
    (let ((normalized (replace-regexp-in-string "_" "-" (downcase name))))
      (intern normalized)))
   (t (intern (format "%s" name)))))

(defun benedict-provider-vercel--decode-tool-arguments (arguments)
  "Decode tool ARGUMENTS JSON string into a plist."
  (cond
   ((stringp arguments)
    (if (string-empty-p arguments)
        nil
      (condition-case err
          (json-parse-string arguments :object-type 'plist :array-type 'list
                             :null-object nil :false-object :json-false)
        (json-parse-error
         (benedict-provider-log
          'vercel 'warn :tool-args-decode
          :message "Failed to decode tool arguments"
          :error err
          :input arguments)
         nil))))
   ((plistp arguments) arguments)
   (t nil)))

(defun benedict-provider-vercel--aget (key alist)
  "Return value for KEY within ALIST (keys are strings)."
  (alist-get key alist nil nil #'string=))

(defun benedict-provider-vercel--resolve-credential ()
  "Return plist describing the resolved credential."
  (or (benedict-provider-vercel--auth-source-credential)
      (benedict-provider-vercel--env-credential)
      (error (concat "Vercel API key missing. "
                     "Configure auth-source for host %s or set %s.")
             (benedict-provider-vercel--host)
             benedict-provider-vercel-env-var)))

(defun benedict-provider-vercel--auth-source-credential ()
  "Return auth-source credential plist when available."
  (when (require 'auth-source nil t)
    (let* ((host (benedict-provider-vercel--host))
           (search-args (list :host host :max 1 :require '(:secret)))
           (search-args (if benedict-provider-vercel-auth-source-user
                            (append search-args (list :user benedict-provider-vercel-auth-source-user))
                          search-args))
           (entry (car (apply #'auth-source-search search-args))))
      (when entry
        (let* ((secret (plist-get entry :secret))
               (token (cond
                       ((functionp secret) (funcall secret))
                       ((stringp secret) secret)
                       (t nil))))
          (when (and (stringp token) (not (string-empty-p token)))
            (list :token token :source 'auth-source :entry entry)))))))

(defun benedict-provider-vercel--env-credential ()
  "Return env-based credential plist when present."
  (let ((token (getenv benedict-provider-vercel-env-var)))
    (when (and (stringp token) (not (string-empty-p token)))
      (list :token token :source 'env))))

(defun benedict-provider-vercel--host ()
  "Extract host from the configured endpoint."
  (let ((url (url-generic-parse-url benedict-provider-vercel-endpoint)))
    (url-host url)))

(benedict-provider-register
 (benedict-provider--create
  :id 'vercel
  :name "Vercel"
  :send #'benedict-provider-vercel--send
  :capabilities '(:streaming t :tools t)
  :cancel #'benedict-provider-vercel--cancel))

(provide 'benedict-provider-vercel)
;;; benedict-provider-vercel.el ends here
