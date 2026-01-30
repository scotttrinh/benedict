;;; benedict-provider-openrouter.el --- OpenRouter provider backend -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Implements a chat backend against a local Ollama API

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'json)
(require 'lgr)
(require 'benedict-provider)
(require 'benedict-tools)
(require 'benedict-http)

(defgroup benedict-provider-ollama nil
  "Settings for the Benedict Ollama provider."
  :group 'benedict
  :prefix "benedict-provider-ollama-")

(defcustom benedict-provider-ollama-endpoint
  "http://localhost:11434/v1/chat/completions"
  "Endpoint used for Ollama chat completions."
  :type 'string
  :group 'benedict-provider-ollama)

(defcustom benedict-provider-ollama-default-model "gpt-oss:20b"
  "Default model identifier sent to Ollama when none is specified."
  :type 'string
  :group 'benedict-provider-ollama)

(defcustom benedict-provider-ollama-default-temperature 0.2
  "Default sampling temperature for Ollama requests."
  :type '(choice (const :tag "Provider default" nil) number)
  :group 'benedict-provider-ollama)

(defcustom benedict-provider-ollama-default-reasoning
  '((effort . "medium") (enabled . t))
  "Default reasoning options sent with every request when non-nil.
Set to nil to keep provider defaults.  This alist/plist accepts keys
EFFORT (string), MAX_TOKENS (number), EXCLUDE (boolean),
and ENABLED (boolean)."
  :type '(choice
          (const :tag "Provider default" nil)
          (plist :tag "Custom reasoning plist"))
  :group 'benedict-provider-ollama)

(defcustom benedict-provider-ollama-default-usage '((include . t))
  "Default usage options sent with every request when non-nil.
Set to nil to keep provider defaults.
Keys include INCLUDE (boolean)."
  :type '(choice
          (const :tag "Provider default" nil)
          (plist :tag "Custom usage plist"))
  :group 'benedict-provider-ollama)

(defcustom benedict-provider-ollama-max-retries 2
  "Number of retry attempts after the first try for transient failures."
  :type 'integer
  :group 'benedict-provider-ollama)

(defcustom benedict-provider-ollama-retry-backoff-seconds 0.5
  "Base delay in seconds for retry backoff (exponential per attempt)."
  :type 'number
  :group 'benedict-provider-ollama)

(defcustom benedict-provider-ollama-enable-streaming t
  "When non-nil, enable streaming via curl for Ollama requests."
  :type 'boolean
  :group 'benedict-provider-ollama)

(defconst benedict-provider-ollama--retryable-status-codes
  '(408 409 425 429 500 502 503 504)
  "HTTP status codes considered retryable for Ollama requests.")

(defvar benedict-provider-ollama--state-table
  (make-hash-table :test 'equal)
  "In-memory registry of per-request state keyed by request id.")

(defun benedict-provider-ollama--make-request-id ()
  "Return a log-friendly unique request identifier for Ollama."
  (format "ollama-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%SZ" (current-time) t)
          (random #x1000000)))

(defun benedict-provider-ollama--state-create (&rest kvs)
  "Create and store a new state entry seeded with KVS, returning its id."
  (let* ((id (or (plist-get kvs :id)
                 (benedict-provider-ollama--make-request-id)))
         (state (list :id id)))
    (while kvs
      (let ((k (pop kvs))
            (v (pop kvs)))
        (setq state (plist-put state k v))))
    (puthash id state benedict-provider-ollama--state-table)
    id))

(defun benedict-provider-ollama--state-get (id)
  "Return state for request ID, or nil when absent."
  (and id (gethash id benedict-provider-ollama--state-table)))

(defun benedict-provider-ollama--state-update (id &rest kvs)
  "Update state for ID with KVS and return the updated state."
  (when id
    (let ((state (or (benedict-provider-ollama--state-get id)
                     (list :id id))))
      (while kvs
        (let ((k (pop kvs))
              (v (pop kvs)))
          (setq state (plist-put state k v))))
      (puthash id state benedict-provider-ollama--state-table)
      state)))

(defun benedict-provider-ollama--state-push (id key value)
  "Push VALUE onto plist KEY for state ID (as a stack)."
  (when id
    (let* ((state (or (benedict-provider-ollama--state-get id)
                      (list :id id)))
           (current (plist-get state key)))
      (setq state (plist-put state key (cons value current)))
      (puthash id state benedict-provider-ollama--state-table)
      state)))

(defun benedict-provider-ollama--state-clear (id)
  "Remove request state bound to ID."
  (when id
    (remhash id benedict-provider-ollama--state-table)))

(defun benedict-provider-ollama--state-get* (context key)
  "Helper: fetch KEY from state associated with CONTEXT."
  (plist-get (benedict-provider-ollama--state-get
              (plist-get context :request-id))
             key))

(defun benedict-provider-ollama--state-update* (context &rest kvs)
  "Helper: update state associated with CONTEXT using KVS."
  (apply #'benedict-provider-ollama--state-update
         (plist-get context :request-id)
         kvs))

(defun benedict-provider-ollama--state-push* (context key value)
  "Helper: push VALUE onto KEY in state associated with CONTEXT."
  (benedict-provider-ollama--state-push
   (plist-get context :request-id) key value))

(cl-defun benedict-provider-ollama--send
    (_provider request &key on-success on-error on-delta on-complete)
  "Dispatch REQUEST to Ollama.
ON-SUCCESS/ON-ERROR/ON-DELTA/ON-COMPLETE mirror `benedict-provider-dispatch'.
When streaming is enabled, callbacks receive incremental deltas via curl."
  (let* ((streaming (and benedict-provider-ollama-enable-streaming
                         (or (plist-get request :stream)
                             (not (null on-delta)))))
         (payload (benedict-provider-ollama--encode-payload request streaming))
         (request-id (or (plist-get request :request-id)
                         (benedict-provider-ollama--make-request-id)))
         (start-time (current-time)))
    (benedict-provider-ollama--state-create
     :id request-id
     :provider 'ollama
     :model (or (plist-get request :model)
                benedict-provider-ollama-default-model)
     :start-time start-time
     :status (if streaming :streaming :http))
    (when streaming
      (benedict-provider-ollama--state-update
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
                         :request-id request-id
                         :on-success on-success
                         :on-error on-error
                         :on-delta on-delta
                         :streaming streaming
                         :mode (if streaming 'stream 'http)
                         :attempt 1
                         :max-attempts (max 1 (+ 1 (max 0 benedict-provider-ollama-max-retries)))
                         :start-time start-time
                         :provider 'ollama)))
      (benedict-provider-ollama--perform-request context)
      context)))

(defun benedict-provider-ollama--perform-request (context)
  "Execute the HTTP request described by CONTEXT."
  (let* ((headers (benedict-provider-ollama--build-headers))
         (payload (plist-get context :payload))
         (streaming (plist-get context :streaming))
         (lgr (lgr-get-logger "benedict.ollama")))
    (lgr-debug lgr "Request"
               :attempt (plist-get context :attempt)
               :request-id (plist-get context :request-id)
               :streaming streaming)
    
    (let ((process
           (benedict-http-request
            benedict-provider-ollama-endpoint
            :method "POST"
            :headers headers
            :body payload
            :stream streaming
            :request-id (plist-get context :request-id)
            :provider 'ollama
            :on-success (lambda (_status _headers body)
                          (benedict-provider-ollama--handle-response body context))
            :on-error (lambda (err)
                        (benedict-provider-ollama--handle-error err context))
            :on-delta (lambda (_type data)
                        (benedict-provider-ollama--handle-sse-payload context data nil)))))
      (setf (plist-get context :process) process)
      context)))


(defun benedict-provider-ollama--handle-sse-payload (context payload _event)
  "Handle SSE PAYLOAD for CONTEXT.
Handles standard JSON payloads as well as newline-delimited JSON (NDJSON)
which some providers (like xAI/Grok) seem to emit within a single SSE block."
  (if (string= payload "[DONE]")
      (benedict-provider-ollama--stream-handle-done context)
    (let* ((lines (split-string payload "\n" t))
           (parsed-objects nil)
           (parse-error nil)
           (lgr (lgr-get-logger "benedict.ollama")))
      ;; Attempt to parse each line as a separate JSON object
      (dolist (line lines)
        (unless parse-error
          (condition-case _err
              (push (json-parse-string line :object-type 'plist :array-type 'list
                                       :null-object nil :false-object :json-false)
                    parsed-objects)
            (json-parse-error
             (setq parse-error t)))))
      (cond
       ((and parsed-objects (not parse-error))
        (dolist (json (nreverse parsed-objects))
          (benedict-provider-ollama--stream-handle-json context json)))
       (t
        (condition-case err
            (let ((json (json-parse-string payload :object-type 'plist :array-type 'list
                                           :null-object nil :false-object :json-false)))
              (benedict-provider-ollama--stream-handle-json context json))
          (json-parse-error
           (lgr-warn lgr "Stream parse error"
                     :request-id (plist-get context :request-id)
                     :error err))))))))

(defun benedict-provider-ollama--stream-handle-error (context error-block _ignored)
  "Handle streaming ERROR-BLOCK for CONTEXT."
  (let ((message (or (plist-get error-block :message) "Unknown streaming error"))
        (code (plist-get error-block :code))
        (type (plist-get error-block :type)))
    (let ((lgr (lgr-get-logger "benedict.ollama")))
      (lgr-error lgr "Stream error"
                 :request-id (plist-get context :request-id)
                 :code code
                 :type type
                 :error message))
    (benedict-provider-ollama--emit-error
     context (list :type 'api :code code :message message :body error-block :retryable nil))))

(defun benedict-provider-ollama--stream-handle-json (context event)
  "Handle parsed streaming EVENT for CONTEXT."
  (unless (plist-get context :stream-complete)
    (let* ((request-id (plist-get context :request-id))
           (remote-id (plist-get event :id))
           (on-delta (plist-get context :on-delta)))
      (benedict-provider-ollama--state-update
       request-id :raw-last event)
      (if-let ((error-block (plist-get event :error)))
          (benedict-provider-ollama--stream-handle-error context error-block nil)
        (progn
          (when-let ((model (plist-get event :model)))
            (benedict-provider-ollama--state-update request-id :model model))
          (when remote-id
            (benedict-provider-ollama--state-update request-id :remote-id remote-id))
          (when-let ((usage (plist-get event :usage)))
            (benedict-provider-ollama--state-update request-id :usage usage))
          (let ((choices (benedict-provider-ollama--normalize-seq
                          (plist-get event :choices))))
            (cond
             (choices)
             (let* ((normalized (benedict-provider-ollama--normalize-delta-choices
                                  context choices)))
                (let ((lgr (lgr-get-logger "benedict.ollama")))
                  (lgr-trace lgr "Stream delta"
                             :request-id request-id
                             :choice-count (length normalized)))
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
                              reasoning))))))
             ((benedict-provider-ollama--stream-handle-reasoning-event
               context event)
              nil))))))))

(defun benedict-provider-ollama--stream-handle-reasoning-event (context event)
  "Handle reasoning-only EVENT for CONTEXT by emitting a synthetic delta.
Returns non-nil when a delta was dispatched."
  (let ((details (benedict-provider-ollama--normalize-reasoning-delta
                  context event))
        (on-delta (plist-get context :on-delta))
        (request-id (plist-get context :request-id)))
    (when details
      (let ((lgr (lgr-get-logger "benedict.ollama")))
        (lgr-trace lgr "Stream reasoning event"
                   :request-id request-id
                   :detail-count (length details)))
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

(defun benedict-provider-ollama--normalize-delta-choices (context choices)
  "Return normalized CHOICES for CONTEXT."
  (let (result)
    (cl-loop for choice in choices
             for idx from 0
             do (push (benedict-provider-ollama--normalize-delta-choice
                       context choice idx)
                      result))
    (nreverse result)))

(defun benedict-provider-ollama--normalize-delta-choice (context choice index)
  "Normalize a single CHOICE for CONTEXT with INDEX."
  (let* ((normalized (copy-tree choice t))
         (delta (plist-get normalized :delta)))
    (plist-put normalized :index (or (plist-get normalized :index) index))
    (when delta
      (benedict-provider-ollama--accumulate-tool-calls-from-delta context delta)
      (when-let ((chunk (benedict-provider-ollama--accumulate-message-from-delta
                         context delta)))
        (plist-put normalized :text chunk)
        (plist-put delta :text chunk))
      (let ((details (benedict-provider-ollama--normalize-reasoning-delta
                      context delta)))
        (when details
          (plist-put delta :reasoning_details (apply #'vector details)))))
    (when-let ((message (plist-get normalized :message)))
      (benedict-provider-ollama--store-final-message context message))
    normalized))

(defun benedict-provider-ollama--normalize-reasoning-delta (context delta)
  "Extract reasoning details from DELTA for CONTEXT."
  (let (details)
    (dolist (entry (benedict-provider-ollama--extract-reasoning-details delta))
      (when-let ((detail (benedict-provider-ollama--prepare-reasoning-detail
                          context entry)))
        (push detail details)))
    (nreverse details)))

(defun benedict-provider-ollama--extract-reasoning-details (delta)
  "Return raw reasoning entries extracted from DELTA."
  (let (result)
    (dolist (key '(:reasoning_details :reasoning :reasoning_content :thinking :thoughts))
      (setq result (nconc result
                          (benedict-provider-ollama--normalize-seq
                           (plist-get delta key)))))
    (when-let ((content (plist-get delta :content)))
      (dolist (entry (benedict-provider-ollama--normalize-seq content))
        (when (benedict-provider-ollama--reasoning-content-entry-p entry)
          (push entry result))))
    (nreverse result)))

(defun benedict-provider-ollama--reasoning-content-entry-p (entry)
  "Return non-nil when ENTRY resembles a reasoning content block."
  (when (and entry (listp entry))
    (when-let ((type (plist-get entry :type)))
      (let ((normalized (downcase (format "%s" type))))
        (or (string-prefix-p "thinking" normalized)
            (string-prefix-p "reasoning" normalized))))))

(defun benedict-provider-ollama--prepare-reasoning-detail (context entry)
  "Normalize reasoning ENTRY for CONTEXT, returning a detail plist."
  (cond
   ((null entry) nil)
   ((stringp entry)
    (benedict-provider-ollama--prepare-reasoning-detail
     context (list :type "reasoning.text" :text entry)))
   ((listp entry)
    (let* ((detail (copy-tree entry t))
           (type (or (plist-get detail :type) "reasoning.text")))
      (plist-put detail :type type)
      (unless (plist-get detail :format)
        (plist-put detail :format "ollama-reasoning"))
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
                     (benedict-provider-ollama--normalize-seq content) ""))))))
        (when text
          (plist-put detail :text text)))
      (if (or (plist-get detail :text)
              (plist-get detail :summary)
              (plist-get detail :data))
          (let ((id (or (plist-get detail :id)
                        (benedict-provider-ollama--next-reasoning-id context))))
            (plist-put detail :id id)
            (plist-put detail :index
                       (or (plist-get detail :index)
                           (benedict-provider-ollama--register-reasoning-id
                            context id)))
            (benedict-provider-ollama--accumulate-reasoning-entry context detail)
            detail)
        nil)))
   (t nil)))

(defun benedict-provider-ollama--register-reasoning-id (context id)
  "Register reasoning ID for CONTEXT and return its index."
  (let* ((state (benedict-provider-ollama--state-get
                 (plist-get context :request-id)))
         (order (plist-get state :reasoning-order)))
    (unless (cl-member id order :test #'equal)
      (setq order (append order (list id)))
      (benedict-provider-ollama--state-update
       (plist-get context :request-id) :reasoning-order order))
    (cl-position id order :test #'equal)))

(defun benedict-provider-ollama--next-reasoning-id (context)
  "Return a new reasoning identifier for CONTEXT."
  (let* ((state (benedict-provider-ollama--state-get
                 (plist-get context :request-id)))
         (counter (or (plist-get state :reasoning-counter) 0)))
    (benedict-provider-ollama--state-update
     (plist-get context :request-id) :reasoning-counter (1+ counter))
    (format "%s-thinking-%d" (plist-get context :request-id) counter)))

(defun benedict-provider-ollama--accumulate-reasoning-entry (context detail)
  "Accumulate DETAIL chunks into CONTEXT final reasoning state."
  (let* ((state (benedict-provider-ollama--state-get
                 (plist-get context :request-id)))
         (entries (plist-get state :reasoning-entries))
         (id (plist-get detail :id))
         (existing (cl-assoc id entries :test #'equal)))
    (unless existing
      (setq existing (cons id (copy-tree detail t)))
      (push existing entries)
      (benedict-provider-ollama--state-update
       (plist-get context :request-id) :reasoning-entries entries))
    (dolist (key '(:text :summary :data))
      (when-let ((chunk (plist-get detail key)))
        (let ((current (plist-get (cdr existing) key)))
          (plist-put (cdr existing) key
                     (if current (concat current chunk) chunk)))))
    (cdr existing)))

(defun benedict-provider-ollama--accumulate-message-from-delta (context delta)
  "Append assistant message text from DELTA for CONTEXT."
  (when-let ((role (plist-get delta :role)))
    (benedict-provider-ollama--state-update
     (plist-get context :request-id)
     :role (intern (downcase (format "%s" role)))))
  (let ((text (benedict-provider-ollama--delta-text delta)))
    (when (and text (not (string-empty-p text)))
      (benedict-provider-ollama--state-push* context :message-chunks text)
      text)))

(defun benedict-provider-ollama--accumulate-tool-calls-from-delta (context delta)
  "Accumulate tool-call entries from DELTA for CONTEXT."
  (when-let ((calls (plist-get delta :tool_calls)))
    (let* ((state (benedict-provider-ollama--state-get
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
      (benedict-provider-ollama--state-update
       (plist-get context :request-id) :tool-call-partials partials))))

(defun benedict-provider-ollama--finalize-tool-calls (context)
  "Finalize accumulated tool-call entries for CONTEXT."
  (let* ((state (benedict-provider-ollama--state-get
                 (plist-get context :request-id)))
         (partials (plist-get state :tool-call-partials)))
    (when partials
      (let (result)
        (dolist (pair (sort partials (lambda (a b) (< (car a) (car b)))))
          (let* ((entry (cdr pair))
                 (name (plist-get entry :name))
                 (args-str (plist-get entry :arguments))
                 (decoded-args (benedict-provider-ollama--decode-tool-arguments args-str)))
            (push (list :id (plist-get entry :id)
                        :type (or (plist-get entry :type) "function")
                        :name (benedict-provider-ollama--normalize-tool-name name)
                        :arguments decoded-args
                        :raw entry)
                  result)))
        (nreverse result)))))

(defun benedict-provider-ollama--delta-text (delta)
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
         (benedict-provider-ollama--normalize-seq content) "")))))
   ((plist-member delta :text)
    (plist-get delta :text))
   (t nil)))

(defun benedict-provider-ollama--store-final-message (context message)
  "Remember final MESSAGE for CONTEXT if present."
  (benedict-provider-ollama--state-update
   (plist-get context :request-id) :final-message message)
  (when-let ((content (plist-get message :content)))
    (cond
     ((stringp content)
      (benedict-provider-ollama--state-update
       (plist-get context :request-id) :final-message-text content))
     (content
      (let ((text (mapconcat
                   (lambda (entry)
                     (cond
                      ((stringp entry) entry)
                      ((listp entry) (or (plist-get entry :text) ""))
                      (t "")))
                   (benedict-provider-ollama--normalize-seq content) "")))
        (benedict-provider-ollama--state-update
         (plist-get context :request-id) :final-message-text text))))))

(defun benedict-provider-ollama--stream-build-delta-payload (context event choices)
  "Build delta payload for CONTEXT using EVENT and normalized CHOICES."
  (let ((payload (copy-tree event t)))
    (plist-put payload :provider 'ollama)
    (plist-put payload :model (or (plist-get payload :model)
                                  (benedict-provider-ollama--state-get*
                                   context :model)
                                  benedict-provider-ollama-default-model))
    (when-let ((usage (or (plist-get event :usage)
                          (benedict-provider-ollama--state-get*
                           context :usage))))
      (plist-put payload :usage usage))
    (plist-put payload :choices (apply #'vector choices))
    payload))

(defun benedict-provider-ollama--stream-handle-done (context)
  "Handle end-of-stream for CONTEXT."
  (unless (plist-get context :stream-complete)
    (setf (plist-get context :stream-complete) t)
    (benedict-provider-ollama--finalize-stream context)))


(defun benedict-provider-ollama--finalize-stream (context)
  "Finalize streaming CONTEXT and deliver completion callback."
  (let* ((request-id (plist-get context :request-id))
         (state (benedict-provider-ollama--state-get request-id))
         (chunks (plist-get state :message-chunks))
         (content (or (plist-get state :final-message-text)
                      (mapconcat #'identity (nreverse chunks) "")))
         (role (or (plist-get state :role) 'assistant))
         (tool-calls (benedict-provider-ollama--finalize-tool-calls context))
         (message (or (plist-get state :final-message)
                      (list :role role :content content :tool-calls tool-calls)))
         (thinking (benedict-provider-ollama--finalize-reasoning context))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (if start-time
                      (float-time (time-subtract end-time start-time))
                    0.0))
         (result (list :message message
                       :model (or (plist-get state :model)
                                  benedict-provider-ollama-default-model)
                       :provider 'ollama
                       :usage (plist-get state :usage)
                       :thinking thinking
                       :latency latency
                       :raw (plist-get state :raw-last)
                       :empty-response (and (string-empty-p (or content ""))
                                            (null tool-calls)))))
    (benedict-provider-ollama--state-update request-id
                                                :status :completed
                                                :end-time end-time
                                                :latency latency)
    (let ((lgr (lgr-get-logger "benedict.ollama")))
      (lgr-info lgr "Stream complete"
                :request-id request-id
                :latency latency
                :model (plist-get result :model)
                :empty-response (plist-get result :empty-response)))
    (benedict-provider-ollama--stream-cleanup context)
    (benedict-provider-ollama--state-clear request-id)
    (let ((on-complete (plist-get context :on-complete))
          (on-success (plist-get context :on-success)))
      (cond
       ((functionp on-complete) (funcall on-complete result))
       ((functionp on-success) (funcall on-success result))))))

(defun benedict-provider-ollama--finalize-reasoning (context)
  "Return accumulated reasoning payload for CONTEXT."
  (let* ((state (benedict-provider-ollama--state-get
                 (plist-get context :request-id)))
         (order (plist-get state :reasoning-order))
         (entries (plist-get state :reasoning-entries)))
    (when (and order entries)
      (let (result)
        (dolist (id order (nreverse result))
          (when-let ((entry (cdr (cl-assoc id entries :test #'equal))))
            (push (copy-tree entry t) result)))))))

(defun benedict-provider-ollama--stream-cleanup (context)
  "Tear down streaming resources for CONTEXT."
  (when-let ((process (plist-get context :process)))
    (when (process-live-p process)
      (let ((stderr (process-get process 'benedict-http-stderr)))
        (when (buffer-live-p stderr)
          (kill-buffer stderr)))
      (set-process-sentinel process nil)
      (delete-process process)))
  (when-let ((stderr (plist-get context :stderr-buffer)))
    (when (buffer-live-p stderr)
      (kill-buffer stderr))))

(defun benedict-provider-ollama--cancel (_provider handle)
  "Cancel HANDLE (best-effort)."
  (when (and handle (plist-get handle :process))
    (setf (plist-get handle :stream-complete) t)
    (benedict-provider-ollama--stream-cleanup handle)))

(defun benedict-provider-ollama--handle-response (body context)
  "Handle successful HTTP response BODY for CONTEXT."
  (benedict-provider-ollama--process-http-response context 200 body))

(defun benedict-provider-ollama--handle-error (error context)
  "Handle HTTP/Process ERROR for CONTEXT."
  (let ((type (plist-get error :type))
        (code (plist-get error :code))
        (body (plist-get error :body))
        (stderr (plist-get error :stderr))
        (message (plist-get error :message)))
    (setf (plist-get context :stream-complete) t)
    (if (and (eq type 'http) (eq code 22))
        (benedict-provider-ollama--process-http-response context 0 body)
      (let* ((request-id (plist-get context :request-id))
             (attempt (plist-get context :attempt))
             (err-msg (or message stderr "Unknown error"))
             (lgr (lgr-get-logger "benedict.ollama")))
        (if (benedict-provider-ollama--maybe-retry context nil err-msg)
            (lgr-warn lgr "Network error"
                      :request-id request-id
                      :attempt attempt
                      :error err-msg
                      :retrying t)
          (lgr-error lgr "Network error"
                     :request-id request-id
                     :attempt attempt
                     :error err-msg
                     :retrying nil)
          (benedict-provider-ollama--emit-error
           context (list :type 'network :message err-msg :retryable nil)))))))

(defun benedict-provider-ollama--process-http-response (context status-code body)
  "Parse BODY returned with STATUS-CODE using CONTEXT."
  (condition-case err
      (let* ((parsed (and (not (string-empty-p body))
                          (json-parse-string body :object-type 'alist :array-type 'list
                                             :null-object nil :false-object :json-false)))
             (error-block (and parsed (benedict-provider-ollama--aget "error" parsed))))
        (if error-block
            (benedict-provider-ollama--handle-api-error context status-code error-block body)
          (benedict-provider-ollama--handle-success context status-code parsed body)))
    (json-parse-error
     (let ((request-id (plist-get context :request-id))
           (lgr (lgr-get-logger "benedict.ollama")))
       (if (benedict-provider-ollama--maybe-retry context status-code "JSON parse error")
           (lgr-warn lgr "Decode error"
                     :status status-code
                     :request-id request-id
                     :retrying t)
         (lgr-error lgr "Decode error"
                    :status status-code
                    :request-id request-id
                    :retrying nil)
         (benedict-provider-ollama--emit-error
          context (list :type 'decode :status status-code :message "Failed to parse response"
                        :body body :retryable nil :error err)))))))

(defun benedict-provider-ollama--handle-success (context status-code parsed _body)
  "Handle PARSED success payload (STATUS-CODE, BODY) using CONTEXT."
  (let* ((request-id (plist-get context :request-id))
         (state (benedict-provider-ollama--state-get request-id))
         (choices (or (benedict-provider-ollama--aget "choices" parsed) '()))
         (first (car choices))
         (message (and first (benedict-provider-ollama--aget "message" first)))
         (decoded-message (if message
                              (benedict-provider-ollama--decode-message message)
                            (list :role 'assistant :content "" :raw nil)))
         (usage (benedict-provider-ollama--aget "usage" parsed))
         (model (or (benedict-provider-ollama--aget "model" parsed)
                    benedict-provider-ollama-default-model))
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
                       :provider 'ollama
                       :status status-code
                       :latency latency
                       :raw parsed
                       :empty-response empty-response)))
        (log-level (if empty-response 'warn 'info))
    (benedict-provider-ollama--state-update
     request-id :usage usage :model model :latency latency
     :status :completed :end-time end-time)
    (let ((lgr (lgr-get-logger "benedict.ollama")))
      (lgr-info lgr "Completion"
                :model model
                :status status-code
                :request-id request-id
                :latency latency
                :empty-response empty-response))
    ;; Prefer :on-complete over :on-success for consistency with streaming protocol
    (if (functionp (plist-get context :on-complete))
        (funcall (plist-get context :on-complete) result)
      (when (functionp (plist-get context :on-success))
        (funcall (plist-get context :on-success) result)))
    (benedict-provider-ollama--state-clear request-id)))

(defun benedict-provider-ollama--handle-api-error (context status-code error-block body)
  "Handle API ERROR-BLOCK with STATUS-CODE/BODY for CONTEXT."
  (let* ((message (or (benedict-provider-ollama--aget "message" error-block)
                      (format "HTTP %s" status-code)))
         (code (or (benedict-provider-ollama--aget "code" error-block)
                   status-code))
         (retryable (benedict-provider-ollama--retryable-status-p status-code))
         (retry (and retryable
                     (benedict-provider-ollama--maybe-retry context status-code message)))
         (lgr (lgr-get-logger "benedict.ollama")))
    (if retry
        (lgr-warn lgr "HTTP error"
                  :status status-code
                  :request-id (plist-get context :request-id)
                  :code code
                  :message message
                  :retrying t)
      (lgr-error lgr "HTTP error"
                 :status status-code
                 :request-id (plist-get context :request-id)
                 :code code
                 :message message
                 :retrying nil)
      (benedict-provider-ollama--emit-error
       context (list :type 'http :status status-code :code code :message message
                     :retryable retryable :body body)))))

(defun benedict-provider-ollama--maybe-retry (context status message)
  "Retry request described by CONTEXT when STATUS/MESSAGE is retryable."
  (let ((attempt (plist-get context :attempt))
        (max (plist-get context :max-attempts)))
    (when (and (< attempt max)
               (benedict-provider-ollama--retryable-p status message))
      (let* ((delay (benedict-provider-ollama--retry-delay attempt))
             (next (copy-sequence context)))
        (setq next (plist-put next :attempt (1+ attempt)))
        (setq next (plist-put next :start-time (current-time)))
        (benedict-provider-ollama--state-update
         (plist-get context :request-id)
         :status :retrying
         :start-time (plist-get next :start-time))
        (let ((lgr (lgr-get-logger "benedict.ollama")))
          (lgr-debug lgr "Retry"
                     :attempt attempt
                     :next-attempt (plist-get next :attempt)
                     :delay delay
                     :request-id (plist-get context :request-id)))
        (run-at-time delay #'benedict-provider-ollama--perform-request next)
        t))))

(defun benedict-provider-ollama--retry-delay (attempt)
  "Compute retry delay for ATTEMPT."
  (* benedict-provider-ollama-retry-backoff-seconds
     (expt 2 (max 0 (1- attempt)))))

(defun benedict-provider-ollama--retryable-p (status message)
  "Return non-nil when STATUS/MESSAGE indicates a retryable error."
  (or (null status)
      (zerop status)
      (memq status benedict-provider-ollama--retryable-status-codes)
      (and (stringp message)
           (string-match-p "\\(timeout\\|temporarily unavailable\\)" (downcase message)))))

(defun benedict-provider-ollama--retryable-status-p (status)
  "Return non-nil if STATUS is in the retryable set."
  (memq status benedict-provider-ollama--retryable-status-codes))

(defun benedict-provider-ollama--emit-error (context payload)
  "Invoke the CONTEXT on-error handler with PAYLOAD."
  (let* ((handler (plist-get context :on-error))
         (request-id (plist-get context :request-id))
         (state (benedict-provider-ollama--state-get request-id))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (and start-time
                       (float-time (time-subtract end-time start-time)))))
    (when request-id
      (benedict-provider-ollama--state-update
       request-id :status :error :error payload :end-time end-time :latency latency)
      (benedict-provider-ollama--state-clear request-id))
    (when (functionp handler)
      (funcall handler payload))))

(defun benedict-provider-ollama--build-headers ()
  "Construct headers using TOKEN."
  (list (cons "Content-Type" "application/json")))

(defun benedict-provider-ollama--redact-secret (value)
  "Return VALUE masked for logging."
  (if (and (stringp value) (> (length value) 8))
      (format "%s…%s" (substring value 0 4) (substring value (- (length value) 2)))
    "***"))

(defun benedict-provider-ollama--redact-headers (headers)
  "Redact sensitive HEADERS for logging."
  (mapcar
   (lambda (header)
     (let* ((name (car header))
            (value (cdr header))
            (normalized (downcase (format "%s" name))))
       (if (member normalized '("authorization" "proxy-authorization"))
           (cons name (benedict-provider-ollama--redact-secret value))
         header)))
   (copy-sequence headers)))

(defun benedict-provider-ollama--encode-payload (request &optional stream)
  "Return JSON payload string for REQUEST.
When STREAM is non-nil, include the \"stream\": true flag in the payload."
  (encode-coding-string
   (json-encode (benedict-provider-ollama--build-body request stream))
   'utf-8))

(defun benedict-provider-ollama--build-body (request &optional stream)
  "Build an alist for REQUEST, optionally STREAM."
  (let ((messages (plist-get request :messages)))
    (unless (and (listp messages) messages)
      (error "Ollama request requires a non-empty :messages list"))
    (let ((body `(("model" . ,(or (plist-get request :model)
                                  benedict-provider-ollama-default-model))
                  ("messages" . ,(mapcar #'benedict-provider-ollama--serialize-message
                                         messages)))))
      (when stream
        (push '("stream" . t) body))
      (when-let ((tools (plist-get request :tools)))
        (when-let ((serialized (benedict-provider-ollama--serialize-tools tools)))
          (push (cons "tools" serialized) body)))
      (let ((temperature (if (plist-member request :temperature)
                             (plist-get request :temperature)
                           benedict-provider-ollama-default-temperature)))
        (when temperature
          (push (cons "temperature" temperature) body)))
      (let ((reasoning (or (plist-get request :reasoning)
                           benedict-provider-ollama-default-reasoning)))
        (when reasoning
          (when-let ((normalized (benedict-provider-ollama--normalize-reasoning reasoning)))
            (push (cons "reasoning" normalized) body))))
      (let ((usage (or (plist-get request :usage-options)
                       benedict-provider-ollama-default-usage)))
        (when usage
          (when-let ((normalized (benedict-provider-ollama--normalize-usage usage)))
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
                   do (let ((k (benedict-provider-ollama--option-key key)))
                        (push (cons k value) body)))))
      (nreverse body))))

(defun benedict-provider-ollama--serialize-message (message)
  "Serialize MESSAGE plist to an alist for JSON encoding."
  (let* ((role (or (plist-get message :role) (plist-get message :type)))
         (content (plist-get message :content))
         (name (plist-get message :name))
         (tool-calls (plist-get message :tool-calls))
         (tool-call-id (plist-get message :tool-call-id)))
    (unless role
      (error "Message requires :role"))
    (let ((payload `(("role" . ,(benedict-provider-ollama--role-string role)))))
      (cond
       (tool-calls
        (push (cons "tool_calls"
                    (benedict-provider-ollama--serialize-tool-calls tool-calls))
              payload)
        (push (cons "content" (if (stringp content) content "")) payload))
       (t
        (push (cons "content" (if (stringp content) content "")) payload)))
      (when (and name (stringp name))
        (push (cons "name" name) payload))
      (when (and tool-call-id (stringp tool-call-id))
        (push (cons "tool_call_id" tool-call-id) payload))
      (nreverse payload))))

(defun benedict-provider-ollama--serialize-tools (tools)
  "Serialize TOOLS (registry specs) into Ollama format."
  (mapcar #'benedict-provider-ollama--serialize-tool tools))

(defun benedict-provider-ollama--serialize-tool (tool)
  "Serialize TOOL spec plist into a tool definition."
  (let* ((id (plist-get tool :id))
         (doc (or (plist-get tool :doc) ""))
         (schema (plist-get tool :schema))
         (parameters (if schema
                         (benedict-tool-schema->json-parameters schema)
                       (benedict-tool-schema->json-parameters '(:type object)))))
    (list
     (cons "type" "function")
     (cons "function"
           (delq nil
                 (list (cons "name" (benedict-provider-ollama--tool-name id))
                       (cons "description" doc)
                       (cons "parameters" parameters)))))))

(defun benedict-provider-ollama--tool-name (id)
  "Return a provider-safe string for tool ID."
  (cond
   ((symbolp id) (symbol-name id))
   ((stringp id) id)
   (t (format "%s" id))))



(defun benedict-provider-ollama--serialize-tool-calls (calls)
  "Serialize tool-call entries for JSON encoding.
The CALLS argument is a list of tool-call plists."
  (mapcar #'benedict-provider-ollama--serialize-tool-call calls))

(defun benedict-provider-ollama--serialize-tool-call (call)
  "Serialize a single CALL plist into Ollama format."
  (let* ((id (or (plist-get call :id)
                 (format "call-%s" (cl-gensym))))
         (type (or (plist-get call :type) "function"))
         (name (benedict-provider-ollama--tool-name
                (or (plist-get call :name) (plist-get call :tool))))
         (raw-arguments (plist-get call :arguments))
         (arguments (if (stringp raw-arguments)
                        raw-arguments
                      (benedict-tool-encode-args-json raw-arguments))))
    (list (cons "id" id)
          (cons "type" (if (stringp type) type "function"))
          (cons "function"
                (delq nil
                      (list (cons "name" name)
                            (cons "arguments" arguments)))))))

(defun benedict-provider-ollama--role-string (role)
  "Convert ROLE (symbol/string) to API string."
  (cond
   ((stringp role) (downcase role))
   ((symbolp role) (downcase (symbol-name role)))
   (t (downcase (format "%s" role)))))

(defun benedict-provider-ollama--option-key (key)
  "Normalize option KEY (keyword/symbol/string) into JSON field."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-ollama--normalize-usage (value)
  "Normalize VALUE into an alist suitable for the \"usage\" field."
  (let* ((alist (cond
                 ((null value) nil)
                 ((and (listp value)
                       (keywordp (car value)))
                  (let (result)
                    (while value
                      (let ((k (pop value))
                            (v (pop value)))
                        (push (cons (benedict-provider-ollama--usage-key k) v) result)))
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

(defun benedict-provider-ollama--usage-key (key)
  "Normalize usage KEY into a string identifier."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-ollama--normalize-reasoning (value)
  "Normalize VALUE into an alist suitable for the \"reasoning\" field."
  (let* ((alist (cond
                 ((null value) nil)
                 ((and (listp value)
                       (keywordp (car value)))
                  (let (result)
                    (while value
                      (let ((k (pop value))
                            (v (pop value)))
                        (push (cons (benedict-provider-ollama--reasoning-key k) v) result)))
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

(defun benedict-provider-ollama--reasoning-key (key)
  "Normalize reasoning KEY into a string identifier."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-ollama--normalize-seq (value)
  "Return VALUE coerced into a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((vectorp value) (append value nil))
   (t (list value))))

(defun benedict-provider-ollama--decode-message (message)
  "Convert MESSAGE alist to Benedict's internal plist."
  (let* ((role (or (benedict-provider-ollama--aget "role" message)
                  "assistant")))
        (content (or (benedict-provider-ollama--aget "content" message)
                     ""))
        (tool-calls (benedict-provider-ollama--aget "tool_calls" message))
        (result (list :role (intern (downcase role))
                      :content content
                      :raw message))
    (when tool-calls
      (when-let ((decoded (benedict-provider-ollama--decode-tool-calls tool-calls)))
        (setq result (plist-put result :tool-calls decoded))))
    result))

(defun benedict-provider-ollama--decode-tool-calls (calls)
  "Return tool-call plists decoded from tool-call input.
The CALLS argument supplies the tool-call payloads."
  (let (result)
    (dolist (call calls (nreverse result))
      (when-let ((decoded (benedict-provider-ollama--decode-tool-call call)))
        (push decoded result)))))

(defun benedict-provider-ollama--decode-tool-call (call)
  "Convert CALL alist into a normalized plist."
  (let* ((id (benedict-provider-ollama--aget "id" call))
         (type (or (benedict-provider-ollama--aget "type" call) "function"))
         (function (benedict-provider-ollama--aget "function" call))
         (name (and function (benedict-provider-ollama--aget "name" function)))
         (arguments (and function (benedict-provider-ollama--aget "arguments" function)))
         (decoded-args (benedict-provider-ollama--decode-tool-arguments arguments)))
    (list :id id
          :type type
          :name (benedict-provider-ollama--normalize-tool-name name)
          :arguments decoded-args
          :raw call)))

(defun benedict-provider-ollama--normalize-tool-name (name)
  "Return NAME coerced into a symbol for registry lookups."
  (cond
   ((symbolp name) name)
   ((stringp name)
    (let ((normalized (replace-regexp-in-string "_" "-" (downcase name))))
      (intern normalized)))
   (t (intern (format "%s" name)))))

(defun benedict-provider-ollama--decode-tool-arguments (arguments)
  "Decode tool ARGUMENTS JSON string into a plist."
  (cond
   ((stringp arguments)
    (if (string-empty-p arguments)
        nil
      (condition-case err
          (json-parse-string arguments :object-type 'plist :array-type 'list
                             :null-object nil :false-object :json-false)
        (json-parse-error
         (let ((lgr (lgr-get-logger "benedict.ollama")))
           (lgr-warn lgr "Failed to decode tool arguments"
                     :arguments arguments
                     :error err))
         nil))))
   ((plistp arguments) arguments)
   (t nil)))

(defun benedict-provider-ollama--aget (key alist)
  "Return value for KEY within ALIST (keys are strings)."
  (alist-get key alist nil nil #'string=))

(defun benedict-provider-ollama--host ()
  "Extract host from the configured endpoint."
  (let ((url (url-generic-parse-url benedict-provider-ollama-endpoint)))
    (url-host url)))

(benedict-provider-register
 (benedict-provider--create
  :id 'ollama
  :name "Ollama"
  :send #'benedict-provider-ollama--send
  :capabilities '(:streaming t :tools t)
  :cancel #'benedict-provider-ollama--cancel))

(provide 'benedict-provider-ollama)
;;; benedict-provider-ollama.el ends here
