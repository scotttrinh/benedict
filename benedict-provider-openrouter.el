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

(defconst benedict-provider-openrouter--retryable-status-codes
  '(408 409 425 429 500 502 503 504)
  "HTTP status codes considered retryable for OpenRouter requests.")

(defvar benedict-provider-openrouter--request-counter 0
  "Internal counter to correlate OpenRouter log events.")

(defun benedict-provider-openrouter--next-request-id ()
  "Return a unique request identifier for OpenRouter logs."
  (format "openrouter-%06d"
          (cl-incf benedict-provider-openrouter--request-counter)))

(cl-defun benedict-provider-openrouter--send
    (_provider request &key on-success on-error on-delta on-complete)
  "Dispatch REQUEST to OpenRouter.
ON-SUCCESS/ON-ERROR/ON-DELTA/ON-COMPLETE mirror `benedict-provider-dispatch'.
Currently non-streaming; ON-DELTA is unused and ON-COMPLETE takes precedence."
  (let* ((credential (benedict-provider-openrouter--resolve-credential))
         (payload (benedict-provider-openrouter--encode-payload request))
         (request-id (or (plist-get request :request-id)
                         (benedict-provider-openrouter--next-request-id)))
         (context (list :request request
                        :payload payload
                        :credential credential
                        :request-id request-id
                        :on-success on-success
                        :on-error on-error
                        :on-delta on-delta
                        :on-complete on-complete
                        :attempt 1
                        :max-attempts (max 1 (+ 1 (max 0 benedict-provider-openrouter-max-retries)))
                        :start-time (current-time)
                        :provider 'openrouter)))
    (benedict-provider-openrouter--perform-request context)
    context))

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
  (let* ((choices (or (benedict-provider-openrouter--aget "choices" parsed) '()))
         (first (car choices))
         (message (and first (benedict-provider-openrouter--aget "message" first)))
         (decoded-message (if message
                              (benedict-provider-openrouter--decode-message message)
                            (list :role 'assistant :content "" :raw nil)))
         (usage (benedict-provider-openrouter--aget "usage" parsed))
         (model (or (benedict-provider-openrouter--aget "model" parsed)
                    benedict-provider-openrouter-default-model))
         (latency (float-time (time-subtract (current-time)
                                             (plist-get context :start-time))))
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
    (benedict-provider-log
     'openrouter log-level :completion
     :request-id (plist-get context :request-id)
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
        (funcall (plist-get context :on-success) result)))))

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
  (let ((handler (plist-get context :on-error)))
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

(defun benedict-provider-openrouter--encode-payload (request)
  "Return JSON payload string for REQUEST."
  (encode-coding-string
   (json-encode (benedict-provider-openrouter--build-body request))
   'utf-8))

(defun benedict-provider-openrouter--build-body (request)
  "Build an alist for REQUEST."
  (let ((messages (plist-get request :messages)))
    (unless (and (listp messages) messages)
      (error "OpenRouter request requires a non-empty :messages list"))
    (let ((body `(("model" . ,(or (plist-get request :model)
                                  benedict-provider-openrouter-default-model))
                  ("messages" . ,(mapcar #'benedict-provider-openrouter--serialize-message
                                         messages)))))
      (let ((temperature (if (plist-member request :temperature)
                             (plist-get request :temperature)
                           benedict-provider-openrouter-default-temperature)))
        (when temperature
          (push (cons "temperature" temperature) body)))
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
  :capabilities '(:streaming nil :tools nil)
  :cancel #'ignore))

(provide 'benedict-provider-openrouter)
;;; benedict-provider-openrouter.el ends here
