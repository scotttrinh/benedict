;;; benedict-provider-openrouter.el --- OpenRouter provider backend -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Implements a non-streaming chat backend against the OpenRouter API using
;; url-retrieve with retry/backoff and auth-source/env based credential lookup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'json)
(require 'benedict-provider)

(defgroup benedict-provider-openrouter nil
  "Settings for the Benedict OpenRouter provider."
  :group 'benedict
  :prefix "benedict-provider-openrouter-")

(defcustom benedict-provider-openrouter-endpoint
  "https://openrouter.ai/api/v1/chat/completions"
  "Endpoint used for OpenRouter chat completions."
  :type 'string
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-default-model "openrouter/auto"
  "Default model identifier sent to OpenRouter when none is specified."
  :type 'string
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-default-temperature 0.2
  "Default sampling temperature for OpenRouter requests."
  :type '(choice (const :tag "Provider default" nil) number)
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-default-reasoning
  '((effort . "medium") (enabled . t))
  "Default reasoning options sent with every request when non-nil.
Set to nil to keep provider defaults. This alist/plist accepts keys
EFFORT (string), MAX_TOKENS (number), EXCLUDE (boolean), and ENABLED
(boolean)."
  :type '(choice (const :tag "Provider default" nil)
                 (plist :tag "Custom reasoning plist"))
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-default-usage '((include . t))
  "Default usage options sent with every request when non-nil.
Set to nil to keep provider defaults. Keys include INCLUDE (boolean)."
  :type '(choice (const :tag "Provider default" nil)
                 (plist :tag "Custom usage plist"))
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-max-retries 2
  "Number of retry attempts after the first try for transient failures."
  :type 'integer
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-retry-backoff-seconds 0.5
  "Base delay in seconds for retry backoff (exponential per attempt)."
  :type 'number
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-env-var "OPENROUTER_API_KEY"
  "Environment variable name used to locate the OpenRouter API key."
  :type 'string
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-auth-source-user "openrouter"
  "Default auth-source username searched for OpenRouter credentials.
Set to nil to skip matching on :user."
  :type '(choice (const :tag "Any user" nil) string)
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-referer "https://github.com/scotttrinh/benedict"
  "Referer header value required by OpenRouter's policy."
  :type 'string
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-app-name "Benedict"
  "Human readable application name sent via the X-Title header."
  :type 'string
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-enable-streaming t
  "When non-nil, enable streaming via curl for OpenRouter requests.
Streaming requires a working curl executable and is used only when the
request handler provides an :on-delta callback (unless :stream nil is
explicitly set on the request)."
  :type 'boolean
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-curl-program "curl"
  "Executable used to issue streaming requests.
Must support --no-buffer/--fail-with-body (curl 7.60+)."
  :type 'file
  :group 'benedict-provider-openrouter)

(defcustom benedict-provider-openrouter-streaming-extra-args nil
  "Additional arguments appended to the streaming curl command."
  :type '(repeat string)
  :group 'benedict-provider-openrouter)

(defconst benedict-provider-openrouter--stream-log-limit 32768
  "Maximum number of bytes to retain from streaming stdout for diagnostics.")

(defconst benedict-provider-openrouter--retryable-status-codes
  '(408 409 425 429 500 502 503 504)
  "HTTP status codes considered retryable for OpenRouter requests.")

(defvar benedict-provider-openrouter--state-table
  (make-hash-table :test 'equal)
  "In-memory registry of per-request state keyed by request id.")

(defun benedict-provider-openrouter--make-request-id ()
  "Return a log-friendly unique request identifier for OpenRouter."
  (format "openrouter-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%SZ" (current-time) t)
          (random #x1000000)))

(defun benedict-provider-openrouter--state-create (&rest kvs)
  "Create and store a new state entry seeded with KVS, returning its id."
  (let* ((id (or (plist-get kvs :id)
                 (benedict-provider-openrouter--make-request-id)))
         (state (list :id id)))
    (while kvs
      (let ((k (pop kvs))
            (v (pop kvs)))
        (setq state (plist-put state k v))))
    (puthash id state benedict-provider-openrouter--state-table)
    id))

(defun benedict-provider-openrouter--state-get (id)
  "Return state for request ID, or nil when absent."
  (and id (gethash id benedict-provider-openrouter--state-table)))

(defun benedict-provider-openrouter--state-update (id &rest kvs)
  "Update state for ID with KVS and return the updated state."
  (when id
    (let ((state (or (benedict-provider-openrouter--state-get id)
                     (list :id id))))
      (while kvs
        (let ((k (pop kvs))
              (v (pop kvs)))
          (setq state (plist-put state k v))))
      (puthash id state benedict-provider-openrouter--state-table)
      state)))

(defun benedict-provider-openrouter--state-push (id key value)
  "Push VALUE onto plist KEY for state ID (as a stack)."
  (when id
    (let* ((state (or (benedict-provider-openrouter--state-get id)
                      (list :id id)))
           (current (plist-get state key)))
      (setq state (plist-put state key (cons value current)))
      (puthash id state benedict-provider-openrouter--state-table)
      state)))

(defun benedict-provider-openrouter--state-clear (id)
  "Remove request state bound to ID."
  (when id
    (remhash id benedict-provider-openrouter--state-table)))

(defun benedict-provider-openrouter--state-get* (context key)
  "Helper: fetch KEY from state associated with CONTEXT."
  (plist-get (benedict-provider-openrouter--state-get
              (plist-get context :request-id))
             key))

(defun benedict-provider-openrouter--state-update* (context &rest kvs)
  "Helper: update state associated with CONTEXT using KVS."
  (apply #'benedict-provider-openrouter--state-update
         (plist-get context :request-id)
         kvs))

(defun benedict-provider-openrouter--state-push* (context key value)
  "Helper: push VALUE onto KEY in state associated with CONTEXT."
  (benedict-provider-openrouter--state-push
   (plist-get context :request-id) key value))

(cl-defun benedict-provider-openrouter--send
    (_provider request &key on-success on-error on-delta on-complete)
  "Dispatch REQUEST to OpenRouter.
ON-SUCCESS/ON-ERROR/ON-DELTA/ON-COMPLETE mirror `benedict-provider-dispatch'.
When streaming is enabled, callbacks receive incremental deltas via curl."
  (let* ((credential (benedict-provider-openrouter--resolve-credential))
         (streaming (benedict-provider-openrouter--streaming-request-p request on-delta))
         (payload (benedict-provider-openrouter--encode-payload request streaming))
         (request-id (or (plist-get request :request-id)
                         (benedict-provider-openrouter--make-request-id)))
         (start-time (current-time)))
    (benedict-provider-openrouter--state-create
     :id request-id
     :provider 'openrouter
     :model (or (plist-get request :model)
                benedict-provider-openrouter-default-model)
     :start-time start-time
     :status (if streaming :streaming :http))
    (let ((context (list :request request
                         :payload payload
                         :credential credential
                         :request-id request-id
                         :on-success on-success
                         :on-error on-error
                         :on-delta on-delta
                         :on-complete on-complete
                         :streaming streaming
                         :mode (if streaming 'stream 'http)
                         :attempt 1
                         :max-attempts (max 1 (+ 1 (max 0 benedict-provider-openrouter-max-retries)))
                         :start-time start-time
                         :provider 'openrouter)))
    (if streaming
        (benedict-provider-openrouter--start-stream context)
      (benedict-provider-openrouter--perform-request context))
    context)))

(defun benedict-provider-openrouter--perform-request (context)
  "Execute the HTTP request described by CONTEXT."
  (let* ((token (plist-get (plist-get context :credential) :token))
         (headers (benedict-provider-openrouter--build-headers token))
         (payload (plist-get context :payload)))
    (benedict-provider-log-debug
     'openrouter :request
     :request-id (plist-get context :request-id)
     :attempt (plist-get context :attempt)
     :endpoint benedict-provider-openrouter-endpoint
     :headers (benedict-provider-openrouter--redact-headers headers)
     :body payload
     :body-bytes (and payload (string-bytes payload))
     :credential-source (plist-get (plist-get context :credential) :source))
    (let ((url-request-method "POST")
          (url-request-extra-headers headers)
          (url-request-data payload))
      (url-retrieve benedict-provider-openrouter-endpoint
                    #'benedict-provider-openrouter--handle-response
                    (list context)
                    t t))))

(defun benedict-provider-openrouter--handle-response (status context)
  "Process STATUS from url-retrieve with CONTEXT."
  (let ((buffer (current-buffer)))
    (unwind-protect
        (progn
          (if (plist-get status :error)
              (benedict-provider-openrouter--handle-network-error status context)
            (goto-char (point-min))
            (let ((http-status (if (boundp 'url-http-response-status)
                                   url-http-response-status
                                 0)))
              (if (re-search-forward "\n\n" nil t)
                  (let* ((header-end (match-end 0))
                         (headers (buffer-substring-no-properties (point-min) header-end))
                         (body (buffer-substring-no-properties header-end (point-max))))
                    (benedict-provider-openrouter--log-http-response
                     context http-status headers body)
                    (benedict-provider-openrouter--process-http-response
                     context http-status body))
                (let ((headers (buffer-substring-no-properties (point-min) (point-max))))
                  (benedict-provider-openrouter--log-http-response
                   context http-status headers "")
                  (benedict-provider-openrouter--process-http-response
                   context http-status ""))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun benedict-provider-openrouter--streaming-available-p ()
  "Return non-nil when streaming prerequisites are satisfied."
  (and benedict-provider-openrouter-enable-streaming
       (executable-find benedict-provider-openrouter-curl-program)))

(defun benedict-provider-openrouter--streaming-request-p (request on-delta)
  "Return non-nil when REQUEST should use streaming with ON-DELTA callback."
  (let ((explicit (plist-member request :stream)))
    (cond
     (explicit
      (and (plist-get request :stream)
           (benedict-provider-openrouter--streaming-available-p)))
     (t
      (and on-delta
           (benedict-provider-openrouter--streaming-available-p))))))

(defun benedict-provider-openrouter--start-stream (context)
  "Launch the streaming curl process for CONTEXT."
  (if (not (benedict-provider-openrouter--streaming-available-p))
      (progn
        (setf (plist-get context :streaming) nil)
        (setf (plist-get context :mode) 'http)
        (benedict-provider-openrouter--perform-request context)
        context)
    (let ((token (plist-get (plist-get context :credential) :token))
          (payload (plist-get context :payload)))
      (benedict-provider-openrouter--state-update
       (plist-get context :request-id)
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
       :remote-id nil)
      (setf (plist-get context :partial) ""
            (plist-get context :stdout-log) ""
            (plist-get context :stream-complete) nil
            (plist-get context :mode) 'stream)
      (let* ((command (benedict-provider-openrouter--make-curl-command
                       token payload))
             (stderr-buffer (generate-new-buffer
                             (format " *benedict-openrouter-%s-stderr*"
                                     (plist-get context :request-id)))))
        (benedict-provider-log-debug
         'openrouter :stream-start
         :request-id (plist-get context :request-id)
         :endpoint benedict-provider-openrouter-endpoint)
        (condition-case err
            (let ((process
                   (make-process
                    :name (format "benedict-openrouter-%s"
                                  (plist-get context :request-id))
                    :buffer nil
                    :command command
                    :stderr stderr-buffer
                    :coding 'utf-8
                    :noquery t
                    :connection-type 'pipe
                    :filter #'benedict-provider-openrouter--curl-filter
                    :sentinel #'benedict-provider-openrouter--curl-sentinel)))
              (process-put process 'benedict-provider-openrouter-context context)
              (setf (plist-get context :process) process
                    (plist-get context :stderr-buffer) stderr-buffer)
              context)
          (error
           (benedict-provider-log
            'openrouter 'error :stream-start-failed
            :request-id (plist-get context :request-id)
            :message (error-message-string err))
           (when (buffer-live-p stderr-buffer)
             (kill-buffer stderr-buffer))
           (setf (plist-get context :streaming) nil)
           (setf (plist-get context :mode) 'http)
           (benedict-provider-openrouter--perform-request context)
           context))))))

(defun benedict-provider-openrouter--make-curl-command (token payload)
  "Return a curl command list using TOKEN and PAYLOAD."
  (let ((headers (copy-sequence (benedict-provider-openrouter--build-headers token))))
    (push (cons "Accept" "text/event-stream") headers)
    (append
     (list benedict-provider-openrouter-curl-program
           "--silent" "--show-error" "--no-buffer" "--fail-with-body"
           "-X" "POST")
     (cl-mapcan (lambda (header)
                  (list "-H"
                        (format "%s: %s" (car header) (cdr header))))
                headers)
     benedict-provider-openrouter-streaming-extra-args
     (list "--data-binary" payload benedict-provider-openrouter-endpoint))))

(defun benedict-provider-openrouter--curl-filter (process chunk)
  "Process streaming CHUNK for PROCESS."
  (let ((context (process-get process 'benedict-provider-openrouter-context)))
    (when context
      (benedict-provider-openrouter--append-stream-log context chunk)
      (benedict-provider-log-trace
       'openrouter :stream-chunk
       :request-id (plist-get context :request-id)
       :bytes (length chunk)
       :chunk (if (> (length chunk) 512)
                  (concat (substring chunk 0 512) "…")
                chunk))
      (benedict-provider-openrouter--stream-handle-data
       context (string-replace "\r" "" chunk)))))

(defun benedict-provider-openrouter--curl-sentinel (process event)
  "Handle PROCESS sentinel EVENT."
  (let ((context (process-get process 'benedict-provider-openrouter-context)))
    (when context
      (benedict-provider-openrouter--stream-handle-sentinel context event))))

(defun benedict-provider-openrouter--append-stream-log (context chunk)
  "Append CHUNK to CONTEXT stdout log capped at
`benedict-provider-openrouter--stream-log-limit'."
  (let* ((log (or (plist-get context :stdout-log) ""))
         (combined (concat log chunk))
         (limit benedict-provider-openrouter--stream-log-limit))
    (setf (plist-get context :stdout-log)
          (if (> (length combined) limit)
              (substring combined (- (length combined) limit))
            combined))))

(defun benedict-provider-openrouter--stream-handle-data (context chunk)
  "Process streaming data CHUNK for CONTEXT."
  (let ((buffer (concat (or (plist-get context :partial) "") chunk))
        (continue t))
    (while continue
      (let ((pos (string-match "\n\n" buffer)))
        (if (null pos)
            (setq continue nil)
          (let ((event (substring buffer 0 pos)))
            (setq buffer (substring buffer (+ pos 2)))
            (unless (string-empty-p event)
              (benedict-provider-openrouter--process-sse-block context event))))))
    (setf (plist-get context :partial) buffer)))

(defun benedict-provider-openrouter--process-sse-block (context block)
  "Parse SSE BLOCK and dispatch for CONTEXT."
  (let ((lines (split-string block "\n"))
        (data-lines nil)
        (event-type nil))
    (dolist (line lines)
      (cond
       ((string-prefix-p "data:" line)
        (push (string-trim-left (substring line 5)) data-lines))
       ((string-prefix-p "event:" line)
        (setq event-type (string-trim (substring line 6))))
       ((string-prefix-p ":" line)
        ;; Comment - ignore
        nil)
       ((string-empty-p line)
        nil)
       (t
        (push (string-trim line) data-lines))))
    (let ((payload (string-join (nreverse (delq nil data-lines)) "\n")))
      (when (> (length payload) 0)
        (benedict-provider-log-trace
         'openrouter :stream-sse-block
         :request-id (plist-get context :request-id)
         :event event-type
         :bytes (length payload)
         :payload (if (> (length payload) 512)
                      (concat (substring payload 0 512) "…")
                    payload))
        (benedict-provider-openrouter--handle-sse-payload context payload event-type)))))

(defun benedict-provider-openrouter--handle-sse-payload (context payload _event)
  "Handle SSE PAYLOAD for CONTEXT."
  (if (string= payload "[DONE]")
      (benedict-provider-openrouter--stream-handle-done context)
    (condition-case err
        (let ((json (json-parse-string payload :object-type 'plist :array-type 'list
                                       :null-object nil :false-object :json-false)))
          (benedict-provider-openrouter--stream-handle-json context json))
      (json-parse-error
       (benedict-provider-log
        'openrouter 'warn :stream-parse-error
        :request-id (plist-get context :request-id)
        :payload payload
        :error err)))))

(defun benedict-provider-openrouter--stream-handle-json (context event)
  "Handle parsed streaming EVENT for CONTEXT."
  (unless (plist-get context :stream-complete)
    (let* ((request-id (plist-get context :request-id))
           (remote-id (plist-get event :id)))
      (benedict-provider-openrouter--state-update
       request-id :raw-last event)
      (if-let ((error-block (plist-get event :error)))
          (benedict-provider-openrouter--stream-handle-error context error-block nil)
        (progn
          (when-let ((model (plist-get event :model)))
            (benedict-provider-openrouter--state-update request-id :model model))
          (when remote-id
            (benedict-provider-openrouter--state-update request-id :remote-id remote-id))
          (when-let ((usage (plist-get event :usage)))
            (benedict-provider-openrouter--state-update request-id :usage usage))
          (let ((choices (benedict-provider-openrouter--normalize-seq
                          (plist-get event :choices))))
            (cond
             (choices
              (let* ((normalized (benedict-provider-openrouter--normalize-delta-choices
                                  context choices))
                     (reasoning-count (apply #'+ (mapcar
                                                  (lambda (choice)
                                                    (length (benedict-provider-openrouter--normalize-seq
                                                             (plist-get (plist-get choice :delta)
                                                                        :reasoning_details))))
                                                  normalized))))
                (benedict-provider-log-trace
                 'openrouter :stream-delta
                 :request-id request-id
                 :remote-id remote-id
                 :choices (length normalized)
                 :reasoning reasoning-count)
                (when (functionp (plist-get context :on-delta))
                  (let ((payload (benedict-provider-openrouter--stream-build-delta-payload
                                  context event normalized)))
                    (funcall (plist-get context :on-delta) payload)))))
             ((benedict-provider-openrouter--stream-handle-reasoning-event
               context event)
              nil))))))))

(defun benedict-provider-openrouter--stream-handle-reasoning-event (context event)
  "Handle reasoning-only EVENT by emitting a synthetic delta.
Returns non-nil when a delta was dispatched."
  (let ((details (benedict-provider-openrouter--normalize-reasoning-delta
                  context event)))
    (when details
      (let* ((delta (list :reasoning_details (apply #'vector details)))
             (choice (list :index 0 :delta delta))
             (payload (benedict-provider-openrouter--stream-build-delta-payload
                       context event (list choice))))
        (benedict-provider-log-trace
         'openrouter :stream-reasoning-event
         :request-id (plist-get context :request-id)
         :details (length details))
        (when (functionp (plist-get context :on-delta))
          (funcall (plist-get context :on-delta) payload))
        t))))

(defun benedict-provider-openrouter--normalize-delta-choices (context choices)
  "Return normalized CHOICES for CONTEXT."
  (let (result)
    (cl-loop for choice in choices
             for idx from 0
             do (push (benedict-provider-openrouter--normalize-delta-choice
                       context choice idx)
                      result))
    (nreverse result)))

(defun benedict-provider-openrouter--normalize-delta-choice (context choice index)
  "Normalize a single CHOICE for CONTEXT with INDEX."
  (let* ((normalized (copy-tree choice t))
         (delta (plist-get normalized :delta)))
    (plist-put normalized :index (or (plist-get normalized :index) index))
    (when delta
      (when-let ((chunk (benedict-provider-openrouter--accumulate-message-from-delta
                         context delta)))
        (plist-put normalized :text chunk)
        (plist-put delta :text chunk))
      (let ((details (benedict-provider-openrouter--normalize-reasoning-delta
                      context delta)))
        (when details
          (plist-put delta :reasoning_details (apply #'vector details)))))
    (when-let ((message (plist-get normalized :message)))
      (benedict-provider-openrouter--store-final-message context message))
    normalized))

(defun benedict-provider-openrouter--normalize-reasoning-delta (context delta)
  "Extract reasoning details from DELTA for CONTEXT."
  (let (details)
    (dolist (entry (benedict-provider-openrouter--extract-reasoning-details delta))
      (when-let ((detail (benedict-provider-openrouter--prepare-reasoning-detail
                          context entry)))
        (push detail details)))
    (nreverse details)))

(defun benedict-provider-openrouter--extract-reasoning-details (delta)
  "Return raw reasoning entries extracted from DELTA."
  (let (result)
    (dolist (key '(:reasoning_details :reasoning :reasoning_content :thinking :thoughts))
      (setq result (nconc result
                          (benedict-provider-openrouter--normalize-seq
                           (plist-get delta key)))))
    (when-let ((content (plist-get delta :content)))
      (dolist (entry (benedict-provider-openrouter--normalize-seq content))
        (when (benedict-provider-openrouter--reasoning-content-entry-p entry)
          (push entry result))))
    (nreverse result)))

(defun benedict-provider-openrouter--reasoning-content-entry-p (entry)
  "Return non-nil when ENTRY looks like a reasoning content block."
  (when (and entry (listp entry))
    (when-let ((type (plist-get entry :type)))
      (let ((normalized (downcase (format "%s" type))))
        (or (string-prefix-p "thinking" normalized)
            (string-prefix-p "reasoning" normalized))))))

(defun benedict-provider-openrouter--prepare-reasoning-detail (context entry)
  "Normalize reasoning ENTRY for CONTEXT, returning a detail plist."
  (cond
   ((null entry) nil)
   ((stringp entry)
    (benedict-provider-openrouter--prepare-reasoning-detail
     context (list :type "reasoning.text" :text entry)))
  ((listp entry)
    (let* ((detail (copy-tree entry t))
           (type (or (plist-get detail :type) "reasoning.text")))
      (plist-put detail :type type)
      (unless (plist-get detail :format)
        (plist-put detail :format "openrouter-reasoning"))
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
                     (benedict-provider-openrouter--normalize-seq content) ""))))))
        (when text
        (plist-put detail :text text)))
      (if (or (plist-get detail :text)
              (plist-get detail :summary)
              (plist-get detail :data))
          (let ((id (or (plist-get detail :id)
                        (benedict-provider-openrouter--next-reasoning-id context))))
            (plist-put detail :id id)
            (plist-put detail :index
                       (or (plist-get detail :index)
                           (benedict-provider-openrouter--register-reasoning-id
                            context id)))
            (benedict-provider-openrouter--accumulate-reasoning-entry context detail)
            detail)
        nil)))
   (t nil)))

(defun benedict-provider-openrouter--register-reasoning-id (context id)
  "Register reasoning ID for CONTEXT and return its index."
  (let* ((state (benedict-provider-openrouter--state-get
                 (plist-get context :request-id)))
         (order (plist-get state :reasoning-order)))
    (unless (cl-member id order :test #'equal)
      (setq order (append order (list id)))
      (benedict-provider-openrouter--state-update
       (plist-get context :request-id) :reasoning-order order))
    (cl-position id order :test #'equal)))

(defun benedict-provider-openrouter--next-reasoning-id (context)
  "Return a new reasoning identifier for CONTEXT."
  (let* ((state (benedict-provider-openrouter--state-get
                 (plist-get context :request-id)))
         (counter (or (plist-get state :reasoning-counter) 0)))
    (benedict-provider-openrouter--state-update
     (plist-get context :request-id) :reasoning-counter (1+ counter))
    (format "%s-thinking-%d" (plist-get context :request-id) counter)))

(defun benedict-provider-openrouter--accumulate-reasoning-entry (context detail)
  "Accumulate DETAIL chunks into CONTEXT final reasoning state."
  (let* ((state (benedict-provider-openrouter--state-get
                 (plist-get context :request-id)))
         (entries (plist-get state :reasoning-entries))
         (id (plist-get detail :id))
         (existing (cl-assoc id entries :test #'equal)))
    (unless existing
      (setq existing (cons id (copy-tree detail t)))
      (push existing entries)
      (benedict-provider-openrouter--state-update
       (plist-get context :request-id) :reasoning-entries entries))
    (dolist (key '(:text :summary :data))
      (when-let ((chunk (plist-get detail key)))
        (let ((current (plist-get (cdr existing) key)))
          (plist-put (cdr existing) key
                     (if current (concat current chunk) chunk)))))
    (cdr existing)))

(defun benedict-provider-openrouter--accumulate-message-from-delta (context delta)
  "Append assistant message text from DELTA for CONTEXT."
  (when-let ((role (plist-get delta :role)))
    (benedict-provider-openrouter--state-update
     (plist-get context :request-id)
     :role (intern (downcase (format "%s" role)))))
  (let ((text (benedict-provider-openrouter--delta-text delta)))
    (when (and text (not (string-empty-p text)))
      (benedict-provider-openrouter--state-push* context :message-chunks text)
      text)))

(defun benedict-provider-openrouter--delta-text (delta)
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
         (benedict-provider-openrouter--normalize-seq content) "")))))
   ((plist-member delta :text)
    (plist-get delta :text))
   (t nil)))

(defun benedict-provider-openrouter--store-final-message (context message)
  "Remember final MESSAGE for CONTEXT if present."
  (benedict-provider-openrouter--state-update
   (plist-get context :request-id) :final-message message)
  (when-let ((content (plist-get message :content)))
    (cond
     ((stringp content)
      (benedict-provider-openrouter--state-update
       (plist-get context :request-id) :final-message-text content))
     (content
      (let ((text (mapconcat
                   (lambda (entry)
                     (cond
                      ((stringp entry) entry)
                      ((listp entry) (or (plist-get entry :text) ""))
                      (t "")))
                   (benedict-provider-openrouter--normalize-seq content) "")))
        (benedict-provider-openrouter--state-update
         (plist-get context :request-id) :final-message-text text))))))

(defun benedict-provider-openrouter--stream-build-delta-payload (context event choices)
  "Build delta payload for CONTEXT using EVENT and normalized CHOICES."
  (let ((payload (copy-tree event t)))
    (plist-put payload :provider 'openrouter)
    (plist-put payload :model (or (plist-get payload :model)
                                  (benedict-provider-openrouter--state-get*
                                   context :model)
                                  benedict-provider-openrouter-default-model))
    (when-let ((usage (or (plist-get event :usage)
                          (benedict-provider-openrouter--state-get*
                           context :usage))))
      (plist-put payload :usage usage))
    (plist-put payload :choices (apply #'vector choices))
    payload))

(defun benedict-provider-openrouter--stream-handle-done (context)
  "Handle end-of-stream for CONTEXT."
  (unless (plist-get context :stream-complete)
    (setf (plist-get context :stream-complete) t)
    (benedict-provider-openrouter--finalize-stream context)))

(defun benedict-provider-openrouter--stream-handle-sentinel (context event)
  "Process process sentinel EVENT for CONTEXT."
  (cond
   ((plist-get context :stream-complete)
    (benedict-provider-openrouter--stream-cleanup context))
   ((and (stringp event)
         (string-match-p "finished" event))
    (benedict-provider-openrouter--stream-handle-done context))
   (t
    (let ((stderr (benedict-provider-openrouter--stream-read-stderr context)))
      (benedict-provider-openrouter--stream-handle-error
       context nil (or stderr (string-trim event)))))))

(defun benedict-provider-openrouter--stream-read-stderr (context)
  "Return stderr contents for CONTEXT."
  (let ((buffer (plist-get context :stderr-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (prog1 (string-trim (buffer-string))
          (erase-buffer))))))

(defun benedict-provider-openrouter--stream-handle-error (context error-block message)
  "Emit an error for CONTEXT.
ERROR-BLOCK is the parsed JSON block when available.  MESSAGE is a fallback string."
  (setf (plist-get context :stream-complete) t)
  (let* ((request-id (plist-get context :request-id))
         (state (benedict-provider-openrouter--state-get request-id))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (and start-time
                       (float-time (time-subtract end-time start-time))))
         (payload (list :type 'stream
                        :provider 'openrouter
                        :message (or message
                                     (plist-get error-block :message)
                                     "Streaming request failed")
                        :code (plist-get error-block :code)
                        :status (plist-get error-block :status)
                        :retryable nil
                        :body (plist-get context :stdout-log))))
    (benedict-provider-openrouter--state-update
     request-id
     :status :error
     :error payload
     :end-time end-time
     :latency latency)
    (benedict-provider-log
     'openrouter 'error :stream-error
     :request-id request-id
     :remote-id (plist-get state :remote-id)
     :message (plist-get payload :message)
     :code (plist-get payload :code))
    (benedict-provider-openrouter--stream-cleanup context)
    (benedict-provider-openrouter--state-clear request-id)
    (when (functionp (plist-get context :on-error))
      (funcall (plist-get context :on-error) payload))))

(defun benedict-provider-openrouter--finalize-stream (context)
  "Finalize streaming CONTEXT and deliver completion callback."
  (let* ((request-id (plist-get context :request-id))
         (state (benedict-provider-openrouter--state-get request-id))
         (chunks (plist-get state :message-chunks))
         (content (or (plist-get state :final-message-text)
                      (mapconcat #'identity (nreverse chunks) "")))
         (role (or (plist-get state :role) 'assistant))
         (message (or (plist-get state :final-message)
                      (list :role role :content content)))
         (thinking (benedict-provider-openrouter--finalize-reasoning context))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (if start-time
                      (float-time (time-subtract end-time start-time))
                    0.0))
         (result (list :message message
                       :model (or (plist-get state :model)
                                  benedict-provider-openrouter-default-model)
                       :provider 'openrouter
                       :usage (plist-get state :usage)
                       :thinking thinking
                       :latency latency
                       :raw (plist-get state :raw-last)
                       :empty-response (string-empty-p (or content "")))))
    (benedict-provider-openrouter--state-update request-id
                                                :status :completed
                                                :end-time end-time
                                                :latency latency)
    (benedict-provider-log
     'openrouter 'info :stream-complete
     :request-id request-id
     :remote-id (plist-get state :remote-id)
     :latency latency
     :model (plist-get result :model)
     :content-bytes (length (or content "")))
    (benedict-provider-openrouter--stream-cleanup context)
    (benedict-provider-openrouter--state-clear request-id)
    (let ((on-complete (plist-get context :on-complete))
          (on-success (plist-get context :on-success)))
      (cond
       ((functionp on-complete) (funcall on-complete result))
       ((functionp on-success) (funcall on-success result))))))

(defun benedict-provider-openrouter--finalize-reasoning (context)
  "Return accumulated reasoning payload for CONTEXT."
  (let* ((state (benedict-provider-openrouter--state-get
                 (plist-get context :request-id)))
         (order (plist-get state :reasoning-order))
         (entries (plist-get state :reasoning-entries)))
    (when (and order entries)
      (let (result)
        (dolist (id order (nreverse result))
          (when-let ((entry (cdr (cl-assoc id entries :test #'equal))))
            (push (copy-tree entry t) result)))))))

(defun benedict-provider-openrouter--stream-cleanup (context)
  "Tear down streaming resources for CONTEXT."
  (when-let ((process (plist-get context :process)))
    (when (process-live-p process)
      (set-process-sentinel process nil)
      (delete-process process)))
  (when-let ((stderr (plist-get context :stderr-buffer)))
    (when (buffer-live-p stderr)
      (kill-buffer stderr))))

(defun benedict-provider-openrouter--cancel (_provider handle)
  "Cancel HANDLE (best-effort)."
  (when (and handle (plist-get handle :process))
    (setf (plist-get handle :stream-complete) t)
    (benedict-provider-openrouter--stream-cleanup handle)))

(defun benedict-provider-openrouter--log-http-response (context status headers body)
  "Emit a structured log for STATUS/HEADERS/BODY tied to CONTEXT."
  (benedict-provider-log-debug
   'openrouter :response
   :request-id (plist-get context :request-id)
   :attempt (plist-get context :attempt)
   :status status
   :elapsed (float-time (time-subtract (current-time)
                                       (plist-get context :start-time)))
   :headers headers
   :body body
   :body-bytes (and body (string-bytes body))))

(defun benedict-provider-openrouter--handle-network-error (status context)
  "Handle network STATUS (pre-HTTP) using CONTEXT."
  (let* ((error-data (plist-get status :error))
         (message (if error-data (format "%s" error-data) "Network error"))
         (request-id (plist-get context :request-id))
         (attempt (plist-get context :attempt)))
    (if (benedict-provider-openrouter--maybe-retry context nil message)
        (benedict-provider-log
         'openrouter 'warn :network-error
         :request-id request-id
         :attempt attempt
         :message message
         :error error-data
         :retry t)
      (benedict-provider-log
       'openrouter 'error :network-error
       :request-id request-id
       :attempt attempt
       :message message
       :error error-data
       :retry nil)
      (benedict-provider-openrouter--emit-error
       context (list :type 'network :message message :retryable nil)))))

(defun benedict-provider-openrouter--process-http-response (context status-code body)
  "Parse BODY returned with STATUS-CODE using CONTEXT."
  (condition-case err
      (let* ((parsed (and (not (string-empty-p body))
                          (json-parse-string body :object-type 'alist :array-type 'list
                                             :null-object nil :false-object :json-false)))
             (error-block (and parsed (benedict-provider-openrouter--aget "error" parsed))))
        (if error-block
            (benedict-provider-openrouter--handle-api-error context status-code error-block body)
          (benedict-provider-openrouter--handle-success context status-code parsed body)))
    (json-parse-error
     (let ((request-id (plist-get context :request-id)))
       (if (benedict-provider-openrouter--maybe-retry context status-code "JSON parse error")
           (benedict-provider-log
            'openrouter 'warn :decode-error
            :request-id request-id
            :status status-code
            :body body
            :error err
            :retry t)
         (benedict-provider-log
          'openrouter 'error :decode-error
          :request-id request-id
          :status status-code
          :body body
          :error err
          :retry nil)
         (benedict-provider-openrouter--emit-error
          context (list :type 'decode :status status-code :message "Failed to parse response"
                        :body body :retryable nil :error err)))))))

(defun benedict-provider-openrouter--handle-success (context status-code parsed body)
  "Handle PARSED success payload (STATUS-CODE, BODY) using CONTEXT."
  (let* ((request-id (plist-get context :request-id))
         (state (benedict-provider-openrouter--state-get request-id))
         (choices (or (benedict-provider-openrouter--aget "choices" parsed) '()))
         (first (car choices))
         (message (and first (benedict-provider-openrouter--aget "message" first)))
         (decoded-message (if message
                              (benedict-provider-openrouter--decode-message message)
                            (list :role 'assistant :content "" :raw nil)))
         (usage (benedict-provider-openrouter--aget "usage" parsed))
         (model (or (benedict-provider-openrouter--aget "model" parsed)
                    benedict-provider-openrouter-default-model))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (if start-time
                      (float-time (time-subtract end-time start-time))
                    0.0))
         (empty-response (string-empty-p (or (plist-get decoded-message :content) "")))
         (result (list :message decoded-message
                       :usage usage
                       :model model
                       :provider 'openrouter
                       :status status-code
                       :latency latency
                       :raw parsed
                       :empty-response empty-response))
         (log-level (if empty-response 'warn 'info)))
    (benedict-provider-openrouter--state-update
     request-id :usage usage :model model :latency latency
     :status :completed :end-time end-time)
    (benedict-provider-log
     'openrouter log-level :completion
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
    (benedict-provider-openrouter--state-clear request-id)))

(defun benedict-provider-openrouter--handle-api-error (context status-code error-block body)
  "Handle API ERROR-BLOCK with STATUS-CODE/BODY."
  (let* ((message (or (benedict-provider-openrouter--aget "message" error-block)
                      (format "HTTP %s" status-code)))
         (code (or (benedict-provider-openrouter--aget "code" error-block)
                   status-code))
         (retryable (benedict-provider-openrouter--retryable-status-p status-code))
         (retry (and retryable
                     (benedict-provider-openrouter--maybe-retry context status-code message))))
    (if retry
        (benedict-provider-log
         'openrouter 'warn :http-error
         :request-id (plist-get context :request-id)
         :attempt (plist-get context :attempt)
         :status status-code
         :code code
         :message message
         :retry t)
      (benedict-provider-log
       'openrouter 'error :http-error
       :request-id (plist-get context :request-id)
       :attempt (plist-get context :attempt)
       :status status-code
       :code code
       :message message
       :retry nil)
      (benedict-provider-openrouter--emit-error
       context (list :type 'http :status status-code :code code :message message
                     :retryable retryable :body body)))))

(defun benedict-provider-openrouter--maybe-retry (context status message)
  "Retry request described by CONTEXT when STATUS/MESSAGE is retryable."
  (let ((attempt (plist-get context :attempt))
        (max (plist-get context :max-attempts)))
    (when (and (< attempt max)
               (benedict-provider-openrouter--retryable-p status message))
      (let* ((delay (benedict-provider-openrouter--retry-delay attempt))
             (next (copy-sequence context)))
        (setq next (plist-put next :attempt (1+ attempt)))
        (setq next (plist-put next :start-time (current-time)))
        (benedict-provider-openrouter--state-update
         (plist-get context :request-id)
         :status :retrying
         :start-time (plist-get next :start-time))
        (benedict-provider-log-debug
         'openrouter :retry
         :request-id (plist-get context :request-id)
         :current-attempt attempt
         :next-attempt (plist-get next :attempt)
         :delay delay
         :status status
         :message message)
        (run-at-time delay #'benedict-provider-openrouter--perform-request next)
        t))))

(defun benedict-provider-openrouter--retry-delay (attempt)
  "Compute retry delay for ATTEMPT."
  (* benedict-provider-openrouter-retry-backoff-seconds
     (expt 2 (max 0 (1- attempt)))))

(defun benedict-provider-openrouter--retryable-p (status message)
  "Return non-nil when STATUS/MESSAGE indicates a retryable error."
  (or (null status)
      (zerop status)
      (memq status benedict-provider-openrouter--retryable-status-codes)
      (and (stringp message)
           (string-match-p "\\(timeout\\|temporarily unavailable\\)" (downcase message)))))

(defun benedict-provider-openrouter--retryable-status-p (status)
  "Return non-nil if STATUS is in the retryable set."
  (memq status benedict-provider-openrouter--retryable-status-codes))

(defun benedict-provider-openrouter--emit-error (context payload)
  "Invoke the CONTEXT on-error handler with PAYLOAD."
  (let* ((handler (plist-get context :on-error))
         (request-id (plist-get context :request-id))
         (state (benedict-provider-openrouter--state-get request-id))
         (end-time (current-time))
         (start-time (or (plist-get state :start-time)
                         (plist-get context :start-time)))
         (latency (and start-time
                       (float-time (time-subtract end-time start-time)))))
    (when request-id
      (benedict-provider-openrouter--state-update
       request-id :status :error :error payload :end-time end-time :latency latency)
      (benedict-provider-openrouter--state-clear request-id))
    (when (functionp handler)
      (funcall handler payload))))

(defun benedict-provider-openrouter--build-headers (token)
  "Construct headers using TOKEN."
  (let ((headers (list (cons "Content-Type" "application/json")
                       (cons "Authorization" (format "Bearer %s" token)))))
    (when (and benedict-provider-openrouter-referer
               (not (string-empty-p benedict-provider-openrouter-referer)))
      (push (cons "HTTP-Referer" benedict-provider-openrouter-referer) headers))
    (when (and benedict-provider-openrouter-app-name
               (not (string-empty-p benedict-provider-openrouter-app-name)))
      (push (cons "X-Title" benedict-provider-openrouter-app-name) headers))
    (nreverse headers)))

(defun benedict-provider-openrouter--redact-secret (value)
  "Return VALUE masked for logging."
  (if (and (stringp value) (> (length value) 8))
      (format "%s…%s" (substring value 0 4) (substring value (- (length value) 2)))
    "***"))

(defun benedict-provider-openrouter--redact-headers (headers)
  "Redact sensitive HEADERS for logging."
  (mapcar
   (lambda (header)
     (let* ((name (car header))
            (value (cdr header))
            (normalized (downcase (format "%s" name))))
       (if (member normalized '("authorization" "proxy-authorization"))
           (cons name (benedict-provider-openrouter--redact-secret value))
         header)))
   (copy-sequence headers)))

(defun benedict-provider-openrouter--encode-payload (request &optional stream)
  "Return JSON payload string for REQUEST.
When STREAM is non-nil, include the \"stream\": true flag in the payload."
  (encode-coding-string
   (json-encode (benedict-provider-openrouter--build-body request stream))
   'utf-8))

(defun benedict-provider-openrouter--build-body (request &optional stream)
  "Build an alist for REQUEST."
  (let ((messages (plist-get request :messages)))
    (unless (and (listp messages) messages)
      (error "OpenRouter request requires a non-empty :messages list"))
    (let ((body `(("model" . ,(or (plist-get request :model)
                                  benedict-provider-openrouter-default-model))
                  ("messages" . ,(mapcar #'benedict-provider-openrouter--serialize-message
                                         messages)))))
      (when stream
        (push '("stream" . t) body))
      (let ((temperature (if (plist-member request :temperature)
                             (plist-get request :temperature)
                           benedict-provider-openrouter-default-temperature)))
        (when temperature
          (push (cons "temperature" temperature) body)))
      (let ((reasoning (or (plist-get request :reasoning)
                           benedict-provider-openrouter-default-reasoning)))
        (when reasoning
          (when-let ((normalized (benedict-provider-openrouter--normalize-reasoning reasoning)))
            (push (cons "reasoning" normalized) body))))
      (let ((usage (or (plist-get request :usage-options)
                       benedict-provider-openrouter-default-usage)))
        (when usage
          (when-let ((normalized (benedict-provider-openrouter--normalize-usage usage)))
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
                   do (let ((k (benedict-provider-openrouter--option-key key)))
                        (push (cons k value) body)))))
      (nreverse body))))

(defun benedict-provider-openrouter--serialize-message (message)
  "Serialize MESSAGE plist to an alist for JSON encoding."
  (let* ((role (or (plist-get message :role) (plist-get message :type)))
         (content (or (plist-get message :content) (plist-get message :text)))
         (name (plist-get message :name)))
    (unless (and role (stringp content))
      (error "Message requires :role and string :content"))
    (let ((payload `(("role" . ,(benedict-provider-openrouter--role-string role))
                     ("content" . ,content))))
      (when (and name (stringp name))
        (push (cons "name" name) payload))
      (nreverse payload))))

(defun benedict-provider-openrouter--role-string (role)
  "Convert ROLE (symbol/string) to API string."
  (cond
   ((stringp role) (downcase role))
   ((symbolp role) (downcase (symbol-name role)))
   (t (downcase (format "%s" role)))))

(defun benedict-provider-openrouter--option-key (key)
  "Normalize option KEY (keyword/symbol/string) into JSON field."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-openrouter--normalize-usage (value)
  "Normalize VALUE into an alist suitable for the \"usage\" field."
  (let* ((alist (cond
                 ((null value) nil)
                 ((and (listp value)
                       (keywordp (car value)))
                  (let (result)
                    (while value
                      (let ((k (pop value))
                            (v (pop value)))
                        (push (cons (benedict-provider-openrouter--usage-key k) v) result)))
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

(defun benedict-provider-openrouter--usage-key (key)
  "Normalize usage KEY into a string identifier."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-openrouter--normalize-reasoning (value)
  "Normalize VALUE into an alist suitable for the \"reasoning\" field."
  (let* ((alist (cond
                 ((null value) nil)
                 ((and (listp value)
                       (keywordp (car value)))
                  (let (result)
                    (while value
                      (let ((k (pop value))
                            (v (pop value)))
                        (push (cons (benedict-provider-openrouter--reasoning-key k) v) result)))
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

(defun benedict-provider-openrouter--reasoning-key (key)
  "Normalize reasoning KEY into a string identifier."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun benedict-provider-openrouter--normalize-seq (value)
  "Return VALUE coerced into a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((vectorp value) (append value nil))
   (t (list value))))

(defun benedict-provider-openrouter--decode-message (message)
  "Convert MESSAGE alist to Benedict's internal plist."
  (let ((role (or (benedict-provider-openrouter--aget "role" message)
                  "assistant"))
        (content (or (benedict-provider-openrouter--aget "content" message)
                     "")))
    (list :role (intern (downcase role))
          :content content
          :raw message)))

(defun benedict-provider-openrouter--aget (key alist)
  "Return value for KEY within ALIST (keys are strings)."
  (alist-get key alist nil nil #'string=))

(defun benedict-provider-openrouter--resolve-credential ()
  "Return plist describing the resolved credential."
  (or (benedict-provider-openrouter--auth-source-credential)
      (benedict-provider-openrouter--env-credential)
      (error (concat "OpenRouter API key missing. "
                     "Configure auth-source for host %s or set %s.")
             (benedict-provider-openrouter--host)
             benedict-provider-openrouter-env-var)))

(defun benedict-provider-openrouter--auth-source-credential ()
  "Return auth-source credential plist when available."
  (when (require 'auth-source nil t)
    (let* ((host (benedict-provider-openrouter--host))
           (search-args (list :host host :max 1 :require '(:secret)))
           (search-args (if benedict-provider-openrouter-auth-source-user
                            (append search-args (list :user benedict-provider-openrouter-auth-source-user))
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

(defun benedict-provider-openrouter--env-credential ()
  "Return env-based credential plist when present."
  (let ((token (getenv benedict-provider-openrouter-env-var)))
    (when (and (stringp token) (not (string-empty-p token)))
      (list :token token :source 'env))))

(defun benedict-provider-openrouter--host ()
  "Extract host from the configured endpoint."
  (let ((url (url-generic-parse-url benedict-provider-openrouter-endpoint)))
    (url-host url)))

(benedict-provider-register
 (benedict-provider--create
  :id 'openrouter
  :name "OpenRouter"
  :send #'benedict-provider-openrouter--send
  :capabilities '(:streaming t :tools nil)
  :cancel #'benedict-provider-openrouter--cancel))

(provide 'benedict-provider-openrouter)
;;; benedict-provider-openrouter.el ends here
