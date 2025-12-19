;;; benedict-provider-gemini.el --- Google Gemini provider backend -*- lexical-binding: t; -*-
;; Author: Benedict maintainers
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Implements a Google Gemini provider with OAuth-based credential resolution,
;; PKCE helpers, and a basic non-streaming chat flow using benedict-http.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url)
(require 'url-util)
(require 'url-parse)
(require 'auth-source)
(require 'browse-url)
(require 'lgr)
(require 'benedict-provider)
(require 'benedict-http)

(defgroup benedict-provider-gemini nil
  "Settings for the Benedict Google Gemini provider."
  :group 'benedict
  :prefix "benedict-provider-gemini-")

(defcustom benedict-provider-gemini-endpoint
  "https://generativelanguage.googleapis.com/v1beta/models"
  "Base endpoint for Gemini text chat APIs.
The provider appends `:generateContent` or `:streamGenerateContent` when
issuing chat requests."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-default-model "gemini-2.0-flash"
  "Default Gemini model used when a request omits :model."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-auth-source-host "gemini"
  "`auth-source' machine/host entry searched for refresh tokens."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-auth-source-user "oauth"
  "`auth-source' login/user value searched for refresh tokens."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-auth-source-port 443
  "`auth-source' port searched for Gemini refresh tokens."
  :type 'integer
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-client-id
  "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
  "Google OAuth client id shared with the gemini-cli plugin."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-client-secret
  "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"
  "Google OAuth client secret shared with the gemini-cli plugin."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-redirect-uri
  "http://localhost:8085/oauth2callback"
  "Redirect URI used by the Emacs-driven OAuth login flow."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-scopes
  '("https://www.googleapis.com/auth/cloud-platform"
    "https://www.googleapis.com/auth/userinfo.email"
    "https://www.googleapis.com/auth/userinfo.profile")
  "OAuth scopes requested when authenticating with Google."
  :type '(repeat (string :tag "Scope"))
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-authorization-endpoint
  "https://accounts.google.com/o/oauth2/v2/auth"
  "OAuth authorization endpoint opened by `benedict-provider-gemini-login'."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-token-endpoint
  "https://oauth2.googleapis.com/token"
  "Google token endpoint used for refresh/login exchanges."
  :type 'string
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-token-timeout 30
  "Timeout (seconds) used for token endpoint requests."
  :type 'number
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-user-agent "Benedict/0.1"
  "User-Agent header sent with Gemini requests."
  :type 'string
  :group 'benedict-provider-gemini)

(defvar benedict-provider-gemini--token-cache (make-hash-table :test 'equal)
  "In-memory cache of access tokens keyed by refresh token.")

(defconst benedict-provider-gemini--logger-name "benedict.gemini"
  "Logger name used for Gemini provider events.")

(defconst benedict-provider-gemini--token-debug-buffer-name
  "*Benedict Gemini Token Response*"
  "Name of the buffer used to surface raw token endpoint responses.")

(defun benedict-provider-gemini--logger ()
  "Return the logger used for Gemini provider logs."
  (lgr-get-logger benedict-provider-gemini--logger-name))

(defun benedict-provider-gemini--redact-secret (value)
  "Return VALUE masked for logging."
  (if (and (stringp value) (> (length value) 8))
      (format "%s…%s" (substring value 0 4) (substring value (- (length value) 2)))
    "***"))

(defun benedict-provider-gemini--redact-authorization-value (value)
  "Return VALUE redacted while preserving Bearer metadata."
  (let ((string (benedict-provider-gemini--stringify value)))
    (if (string-prefix-p "Bearer " string)
        (format "Bearer %s"
                (benedict-provider-gemini--redact-secret
                 (string-trim (substring string 7))))
      (benedict-provider-gemini--redact-secret string))))

(defun benedict-provider-gemini--redact-headers (headers)
  "Redact sensitive HEADERS before logging."
  (mapcar
   (lambda (pair)
     (let ((name (car pair))
           (value (cdr pair)))
       (if (string-match-p "^authorization$" (downcase (format "%s" name)))
           (cons name (benedict-provider-gemini--redact-authorization-value value))
         pair)))
   (copy-sequence headers)))

(defun benedict-provider-gemini--make-request-id ()
  "Return a log-friendly request identifier."
  (format "gemini-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%SZ" (current-time) t)
          (random #x1000000)))

(defun benedict-provider-gemini--auth-source-entry ()
  "Return the auth-source entry storing the Gemini refresh token."
  (car (auth-source-search :host benedict-provider-gemini-auth-source-host
                           :user benedict-provider-gemini-auth-source-user
                           :port benedict-provider-gemini-auth-source-port
                           :max 1 :require '(:secret))))

(defun benedict-provider-gemini--secret-as-string (secret)
  "Return SECRET resolved to a string."
  (cond
   ((functionp secret) (funcall secret))
   ((and (stringp secret) (not (string-empty-p secret))) secret)
   (t nil)))

(defun benedict-provider-gemini--cache-get (refresh)
  "Return cached entry for REFRESH token."
  (and refresh (gethash refresh benedict-provider-gemini--token-cache)))

(defun benedict-provider-gemini--cache-store (refresh data &optional old-refresh)
  "Store DATA for REFRESH token, removing OLD-REFRESH when provided."
  (when old-refresh
    (remhash old-refresh benedict-provider-gemini--token-cache))
  (when (and refresh data)
    (puthash refresh (list :access (plist-get data :access)
                           :expires (plist-get data :expires))
             benedict-provider-gemini--token-cache))
  data)

(defun benedict-provider-gemini--credential-error ()
  "Signal a standardized credential error message."
  (error (concat "Gemini refresh token missing. Add an auth-source entry for host %s "
                 "and user %s, or run M-x benedict-provider-gemini-login.")
         benedict-provider-gemini-auth-source-host
         benedict-provider-gemini-auth-source-user))

(defun benedict-provider-gemini--resolve-credential ()
  "Return plist describing the resolved credential."
  (unless (featurep 'auth-source)
    (require 'auth-source))
  (let* ((entry (benedict-provider-gemini--auth-source-entry))
         (refresh (and entry
                       (benedict-provider-gemini--secret-as-string
                        (plist-get entry :secret)))))
    (unless (and refresh (not (string-empty-p refresh)))
      (benedict-provider-gemini--credential-error))
    (let* ((cached (benedict-provider-gemini--cache-get refresh))
           (expires (plist-get cached :expires))
           (access (plist-get cached :access))
           (now (float-time)))
      (if (and cached access expires (> expires now))
          (list :access access :expires expires :refresh refresh)
        (let* ((fresh (benedict-provider-gemini--refresh-access-token refresh entry))
               (next-refresh (or (plist-get fresh :refresh) refresh)))
          (benedict-provider-gemini--cache-store next-refresh fresh refresh)
          (list :access (plist-get fresh :access)
                :expires (plist-get fresh :expires)
                :refresh next-refresh))))))

(defun benedict-provider-gemini--ensure-number (value default)
  "Coerce VALUE into a number, falling back to DEFAULT when needed."
  (cond
   ((numberp value) value)
   ((and (stringp value) (string-match-p "^[0-9.]+$" value))
    (string-to-number value))
   (t default)))

(defun benedict-provider-gemini--update-auth-entry (entry refresh-token)
  "Update ENTRY's secret to REFRESH-TOKEN, logging failures."
  (when (and entry refresh-token)
    (condition-case err
        (when (fboundp 'auth-source-update)
          (auth-source-update entry :secret refresh-token)
          (plist-put entry :secret refresh-token))
      (error
       (let ((lgr (benedict-provider-gemini--logger)))
         (lgr-warn lgr "Failed to update auth-source" :error err)))))
  entry)

(defun benedict-provider-gemini--debug-buffer-hint (buffer-name)
  "Return user-facing hint referencing BUFFER-NAME.
Returns an empty string when BUFFER-NAME is nil."
  (if (and buffer-name (not (string-empty-p buffer-name)))
      (format "Inspect buffer %s for the raw response." buffer-name)
    ""))

(defun benedict-provider-gemini--expose-token-response-buffer (source-buffer)
  "Display SOURCE-BUFFER contents in a dedicated debug buffer.
Returns the displayed buffer's name."
  (when (buffer-live-p source-buffer)
    (let* ((target (get-buffer-create benedict-provider-gemini--token-debug-buffer-name))
           (name (buffer-name target))
           (lgr (benedict-provider-gemini--logger)))
      (with-current-buffer target
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert-buffer-substring source-buffer)
          (goto-char (point-min))))
      (display-buffer target)
      (message "Gemini OAuth response missing HTTP status; showing %s" name)
      (lgr-warn lgr "Gemini token response missing HTTP status" :buffer name)
      name)))

(defun benedict-provider-gemini--token-request (body)
  "Execute token endpoint POST using BODY (form-encoded string)."
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/x-www-form-urlencoded")))
         (url-request-data body)
         (buffer (url-retrieve-synchronously benedict-provider-gemini-token-endpoint
                                             t t benedict-provider-gemini-token-timeout)))
    (unless buffer
      (error "Gemini token endpoint unavailable"))
    (with-current-buffer buffer
      (unwind-protect
          (progn
            (goto-char (point-min))
            (let ((status 0)
                  debug-buffer
                  body-text)
              (if (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                  (setq status (string-to-number (match-string 1)))
                (setq debug-buffer (benedict-provider-gemini--expose-token-response-buffer buffer)))
              (setq body-text
                    (save-excursion
                      (goto-char (point-min))
                      (if (re-search-forward "\n\n" nil t)
                          (buffer-substring-no-properties (point) (point-max))
                        (buffer-substring-no-properties (point-min) (point-max)))))
              (list :status status :body body-text :debug-buffer debug-buffer)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun benedict-provider-gemini--parse-json (body)
  "Parse BODY into a plist, returning nil for empty strings."
  (when (and body (not (string-empty-p body)))
    (json-parse-string body :object-type 'plist :array-type 'list
                       :null-object nil :false-object :json-false)))

(defun benedict-provider-gemini--refresh-access-token (refresh-token &optional entry)
  "Return plist (:access :expires :refresh) after refreshing REFRESH-TOKEN.
ENTRY, when non-nil, is the auth-source entry used for storage."
  (unless (and (stringp refresh-token) (not (string-empty-p refresh-token)))
    (benedict-provider-gemini--credential-error))
  (let* ((payload (benedict-provider-gemini--build-query-string
                   `(("client_id" . ,benedict-provider-gemini-client-id)
                     ("client_secret" . ,benedict-provider-gemini-client-secret)
                     ("grant_type" . "refresh_token")
                     ("refresh_token" . ,refresh-token))))
         (response (benedict-provider-gemini--token-request payload))
         (status (plist-get response :status))
         (body (plist-get response :body))
         (debug-buffer (plist-get response :debug-buffer))
         (hint (benedict-provider-gemini--debug-buffer-hint debug-buffer))
         (parsed (benedict-provider-gemini--parse-json body))
         (lgr (benedict-provider-gemini--logger)))
    (when (= status 0)
      (if (string-empty-p hint)
          (error "Gemini token refresh failed before receiving an HTTP status.")
        (error "Gemini token refresh failed before receiving an HTTP status. %s" hint)))
    (if (= status 200)
        (let* ((access (plist-get parsed :access_token))
               (expires-in (benedict-provider-gemini--ensure-number
                            (plist-get parsed :expires_in) 3600))
               (new-refresh (or (plist-get parsed :refresh_token) refresh-token))
               (expires (+ (float-time) (max 30 (- expires-in 30)))))
          (unless access
            (error "Gemini token response missing access token"))
          (when (and entry (not (string= new-refresh refresh-token)))
            (benedict-provider-gemini--update-auth-entry entry new-refresh))
          (lgr-info lgr "Refreshed Gemini access token"
                    :rotated (not (string= new-refresh refresh-token))
                    :expires expires)
          (list :access access :expires expires :refresh new-refresh))
      (let* ((error-block (and parsed (plist-get parsed :error)))
             (code (or (and (plistp error-block) (plist-get error-block :code))
                       (plist-get parsed :error)
                       status))
             (message (or (and (plistp error-block) (plist-get error-block :message))
                          (plist-get parsed :error_description)
                          body
                          "Gemini token refresh failed")))
        (when (and (stringp code) (string= code "invalid_grant"))
          (error (concat "Gemini refresh token was rejected (invalid_grant). "
                         "Run M-x benedict-provider-gemini-login to reauthenticate.")))
        (error "Gemini token refresh failed (HTTP %s): %s" status message)))))

(defun benedict-provider-gemini--build-query-string (params)
  "Return URL-encoded query string built from PARAMS."
  (mapconcat
   (lambda (pair)
     (format "%s=%s"
             (url-hexify-string (format "%s" (car pair)))
             (url-hexify-string (format "%s" (or (cdr pair) "")))))
   params "&"))

(defun benedict-provider-gemini--normalize-role (role)
  "Return normalized symbol ROLE for Gemini payloads."
  (cond
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t 'user)))

(defun benedict-provider-gemini--role->gemini (role)
  "Map Benedict ROLE to Gemini role strings."
  (pcase (benedict-provider-gemini--normalize-role role)
    ('assistant "model")
    ('tool "model")
    (_ (downcase (symbol-name (benedict-provider-gemini--normalize-role role))))))

(defun benedict-provider-gemini--stringify (value)
  "Return VALUE coerced to a UTF-8 string."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (format "%s" value))))

(defun benedict-provider-gemini--parts-from-text (text)
  "Return Gemini parts vector from TEXT."
  (vector (list (cons "text" text))))

(defun benedict-provider-gemini--serialize-message (message)
  "Serialize MESSAGE plist into Gemini content entry."
  (let* ((role (plist-get message :role))
         (content (benedict-provider-gemini--stringify (plist-get message :content)))
         (normalized (benedict-provider-gemini--normalize-role role)))
    (unless (and (stringp content) (>= (length content) 0))
      (setq content ""))
    (cond
     ((eq normalized 'system)
      (list (cons "role" "system")
            (cons "parts" (benedict-provider-gemini--parts-from-text content))))
     (t
      (list (cons "role" (benedict-provider-gemini--role->gemini role))
            (cons "parts" (benedict-provider-gemini--parts-from-text content)))))))

(defun benedict-provider-gemini--extract-system-prompt (messages)
  "Return cons of (SYSTEM . REMAINDER) for MESSAGES."
  (let (system remainder)
    (dolist (message messages)
      (let ((role (benedict-provider-gemini--normalize-role (plist-get message :role))))
        (if (and (eq role 'system) (not system))
            (setq system message)
          (push message remainder))))
    (list system (nreverse remainder))))

(defun benedict-provider-gemini--build-body (request)
  "Return JSON-ready alist for REQUEST."
  (let ((messages (plist-get request :messages)))
    (unless (and (listp messages) messages)
      (error "Gemini request requires a non-empty :messages list"))
    (pcase-let* ((`(,system ,content-messages)
                  (benedict-provider-gemini--extract-system-prompt messages))
                 (model (or (plist-get request :model)
                            benedict-provider-gemini-default-model))
                 (contents (mapcar #'benedict-provider-gemini--serialize-message
                                   content-messages))
                 (body `(("contents" . ,contents))))
      (push (cons "model" model) body)
      (when system
        (push (cons "systemInstruction"
                    (list (cons "role" "system")
                          (cons "parts"
                                (benedict-provider-gemini--parts-from-text
                                 (benedict-provider-gemini--stringify
                                  (plist-get system :content))))))
              body))
      (let (generation)
        (when (plist-member request :temperature)
          (let ((value (plist-get request :temperature)))
            (when value (push (cons "temperature" value) generation))))
        (when (plist-member request :top-p)
          (let ((value (plist-get request :top-p)))
            (when value (push (cons "topP" value) generation))))
        (when (plist-member request :max-tokens)
          (let ((value (plist-get request :max-tokens)))
            (when value (push (cons "maxOutputTokens" value) generation))))
        (when generation
          (push (cons "generationConfig" (nreverse generation)) body)))
      (nreverse body))))

(defun benedict-provider-gemini--encode-payload (request)
  "Return encoded JSON payload for REQUEST."
  (encode-coding-string
   (json-encode (benedict-provider-gemini--build-body request))
   'utf-8))

(defun benedict-provider-gemini--build-headers (access-token)
  "Return HTTP headers using ACCESS-TOKEN."
  (let ((headers (list (cons "Content-Type" "application/json")
                       (cons "Authorization" (format "Bearer %s" access-token)))))
    (when (and benedict-provider-gemini-user-agent
               (not (string-empty-p benedict-provider-gemini-user-agent)))
      (push (cons "User-Agent" benedict-provider-gemini-user-agent) headers))
    (nreverse headers)))

(defun benedict-provider-gemini--endpoint-for (model &optional stream)
  "Return endpoint URL for MODEL, optionally STREAM."
  (let* ((base (string-remove-suffix "/" benedict-provider-gemini-endpoint))
         (suffix (if stream ":streamGenerateContent" ":generateContent")))
    (format "%s/%s%s" base model suffix)))

(defun benedict-provider-gemini--parts->text (parts)
  "Concatenate Gemini PARTS into a single string."
  (mapconcat
   (lambda (part)
     (cond
      ((plist-get part :text) (plist-get part :text))
      ((alist-get "text" part nil nil #'string=))
      (t "")))
   (or parts '()) ""))

(defun benedict-provider-gemini--usage-from-metadata (metadata)
  "Return normalized usage plist from METADATA."
  (when metadata
    (let (result)
      (when-let ((prompt (or (plist-get metadata :promptTokenCount
                              (alist-get "promptTokenCount" metadata nil nil #'string=)))))
        (setq result (plist-put result :prompt prompt)))
      (when-let ((completion (or (plist-get metadata :candidatesTokenCount)
                                 (alist-get "candidatesTokenCount" metadata nil nil #'string=))))
        (setq result (plist-put result :completion completion)))
      (when-let ((total (or (plist-get metadata :totalTokenCount)
                            (alist-get "totalTokenCount" metadata nil nil #'string=))))
        (setq result (plist-put result :total total)))
      result)))

(defun benedict-provider-gemini--handle-success (body context)
  "Handle successful BODY for CONTEXT."
  (condition-case err
      (let* ((parsed (benedict-provider-gemini--parse-json body))
             (candidates (plist-get parsed :candidates))
             (first (car candidates))
             (content (and first (plist-get first :content)))
             (parts (or (and content (plist-get content :parts))
                        (plist-get first :parts)))
             (text (benedict-provider-gemini--parts->text parts))
             (usage (benedict-provider-gemini--usage-from-metadata
                     (plist-get parsed :usageMetadata)))
             (message (list :role 'assistant :content text))
             (request-id (plist-get context :request-id))
             (start (plist-get context :start-time))
             (latency (and start (float-time (time-subtract (current-time) start))))
             (result (list :message message
                           :model (plist-get context :model)
                           :provider 'gemini
                           :usage usage
                           :latency latency
                           :raw parsed)))
        (let ((lgr (benedict-provider-gemini--logger)))
          (lgr-info lgr "Gemini completion"
                    :request-id request-id
                    :latency latency
                    :empty-response (string-empty-p text)))
        (if (functionp (plist-get context :on-complete))
            (funcall (plist-get context :on-complete) result)
          (when (functionp (plist-get context :on-success))
            (funcall (plist-get context :on-success) result)))
        result)
    (json-parse-error
     (benedict-provider-gemini--emit-error
      context (list :type 'decode :provider 'gemini :message "Failed to parse Gemini response"
                    :error err :body body)))))

(defun benedict-provider-gemini--extract-error-message (body)
  "Return human-friendly error message derived from BODY."
  (let* ((parsed (ignore-errors (benedict-provider-gemini--parse-json body)))
         (error-block (and parsed (plist-get parsed :error)))
         (status (and error-block (plist-get error-block :code)))
         (message (or (and error-block (plist-get error-block :message))
                      (plist-get parsed :error_description)
                      body)))
    (list :message message :status status)))

(defun benedict-provider-gemini--emit-error (context payload)
  "Invoke the CONTEXT on-error handler with PAYLOAD."
  (let ((handler (plist-get context :on-error)))
    (when (functionp handler)
      (funcall handler payload))))

(defun benedict-provider-gemini--handle-error (err context)
  "Handle ERR for CONTEXT."
  (let* ((type (plist-get err :type))
         (body (plist-get err :body))
         (stderr (plist-get err :stderr))
         (request-id (plist-get context :request-id))
         (lgr (benedict-provider-gemini--logger))
         (message-details (and body (benedict-provider-gemini--extract-error-message body)))
         (payload (list :type (or type 'network)
                        :provider 'gemini
                        :message (or (plist-get message-details :message)
                                     (plist-get err :message)
                                     stderr
                                     "Gemini request failed")
                        :status (plist-get message-details :status)
                        :retryable nil
                        :body body)))
    (lgr-error lgr "Gemini request failed"
               :request-id request-id
               :type type
               :message (plist-get payload :message))
    (benedict-provider-gemini--emit-error context payload)))

(cl-defun benedict-provider-gemini--send
    (_provider request &key on-success on-error _on-delta on-complete &allow-other-keys)
  "Dispatch REQUEST to Gemini.
ON-SUCCESS/ON-ERROR/ON-COMPLETE mirror `benedict-provider-dispatch'."
  (let* ((credential (benedict-provider-gemini--resolve-credential))
         (model (or (plist-get request :model) benedict-provider-gemini-default-model))
         (payload (benedict-provider-gemini--encode-payload (plist-put (copy-sequence request)
                                                                       :model model)))
         (request-id (or (plist-get request :request-id)
                         (benedict-provider-gemini--make-request-id)))
         (start-time (current-time))
         (url (benedict-provider-gemini--endpoint-for model nil))
         (headers (benedict-provider-gemini--build-headers (plist-get credential :access)))
         (context (list :request-id request-id
                        :model model
                        :start-time start-time
                        :on-success on-success
                        :on-error on-error
                        :on-complete on-complete)))
    (let ((lgr (benedict-provider-gemini--logger)))
      (lgr-debug lgr "Gemini request"
                 :request-id request-id
                 :model model
                 :headers (benedict-provider-gemini--redact-headers headers)))
    (benedict-http-request
     url
     :method "POST"
     :headers headers
     :body payload
     :stream nil
     :request-id request-id
     :provider 'gemini
     :on-success (lambda (_status _headers body)
                   (benedict-provider-gemini--handle-success body context))
     :on-error (lambda (err)
                 (benedict-provider-gemini--handle-error err context)))))

;;;###autoload
(defun benedict-provider-gemini-login ()
  "Run the interactive OAuth login flow for the Gemini provider."
  (interactive)
  (let* ((verifier (benedict-provider-gemini--generate-verifier))
         (challenge (benedict-provider-gemini--derive-challenge verifier))
         (state (benedict-provider-gemini--encode-state (list :verifier verifier)))
         (auth-url (benedict-provider-gemini--authorization-url challenge state)))
    (kill-new auth-url)
    (message "Gemini OAuth URL copied to kill-ring; opening browser…")
    (condition-case _
        (browse-url auth-url)
      (error
       (message "Open this URL manually: %s" auth-url)))
    (let* ((callback (string-trim (read-string "Paste Gemini redirect URL: ")))
           (params (benedict-provider-gemini--parse-callback callback))
           (code (plist-get params :code))
           (state-param (plist-get params :state)))
      (unless (and code state-param)
        (error "Gemini callback URL missing code/state"))
      (let ((decoded (benedict-provider-gemini--decode-state state-param)))
        (unless (and decoded (equal (plist-get decoded :verifier) verifier))
          (error "OAuth state mismatch; aborting.")))
      (let* ((tokens (benedict-provider-gemini--exchange-authorization-code code verifier))
             (refresh (plist-get tokens :refresh))
             (access (plist-get tokens :access))
             (expires (plist-get tokens :expires)))
        (benedict-provider-gemini--persist-refresh-token refresh)
        (benedict-provider-gemini--cache-store refresh (list :access access :expires expires))
        (message "Gemini refresh token stored for %s/%s"
                 benedict-provider-gemini-auth-source-host
                 benedict-provider-gemini-auth-source-user)))))

(defun benedict-provider-gemini--generate-verifier ()
  "Return a freshly generated PKCE verifier string."
  (benedict-provider-gemini--make-verifier
   (cl-loop repeat 32 collect (random 256))))

(defun benedict-provider-gemini--make-verifier (bytes)
  "Return a PKCE verifier string from a list of BYTES."
  (base64url-encode-string (apply #'unibyte-string bytes) t))

(defun benedict-provider-gemini--derive-challenge (verifier)
  "Return PKCE challenge derived from VERIFIER."
  (let* ((hash (secure-hash 'sha256 verifier nil nil t)))
    (base64url-encode-string hash t)))

(defun benedict-provider-gemini--encode-state (plist)
  "Encode PLIST into base64url state payload."
  (base64url-encode-string (json-encode plist) t))

(defun benedict-provider-gemini--decode-state (state)
  "Decode STATE payload back into a plist."
  (condition-case _
      (json-parse-string (decode-coding-string (base64-decode-string state t) 'utf-8)
                         :object-type 'plist :array-type 'list)
    (error nil)))

(defun benedict-provider-gemini--authorization-url (challenge state)
  "Build authorization URL using CHALLENGE and STATE."
  (format "%s?%s"
          benedict-provider-gemini-authorization-endpoint
          (benedict-provider-gemini--build-query-string
           `(("client_id" . ,benedict-provider-gemini-client-id)
             ("redirect_uri" . ,benedict-provider-gemini-redirect-uri)
             ("response_type" . "code")
             ("scope" . ,(string-join benedict-provider-gemini-scopes " "))
             ("access_type" . "offline")
             ("prompt" . "consent")
             ("code_challenge" . ,challenge)
             ("code_challenge_method" . "S256")
             ("state" . ,state)))))

(defun benedict-provider-gemini--extract-query (url)
  "Return query component from URL string."
  (let ((start (string-match-p "\\?" url)))
    (if start
        (let ((frag (string-match-p "#" url (1+ start))))
          (substring url (1+ start) (or frag (length url))))
      "")))

(defun benedict-provider-gemini--parse-callback (callback-url)
  "Return plist with :code and :state extracted from CALLBACK-URL."
  (let* ((query (benedict-provider-gemini--extract-query callback-url))
         (pairs (url-parse-query-string query))
         (code (cadr (assoc-string "code" pairs t)))
         (state (cadr (assoc-string "state" pairs t))))
    (list :code code :state state)))

(defun benedict-provider-gemini--exchange-authorization-code (code verifier)
  "Exchange authorization CODE and PKCE VERIFIER for tokens."
  (let* ((payload (benedict-provider-gemini--build-query-string
                   `(("client_id" . ,benedict-provider-gemini-client-id)
                     ("client_secret" . ,benedict-provider-gemini-client-secret)
                     ("code" . ,code)
                     ("code_verifier" . ,verifier)
                     ("grant_type" . "authorization_code")
                     ("redirect_uri" . ,benedict-provider-gemini-redirect-uri))))
         (response (benedict-provider-gemini--token-request payload))
         (status (plist-get response :status))
         (body (plist-get response :body))
         (debug-buffer (plist-get response :debug-buffer))
         (hint (benedict-provider-gemini--debug-buffer-hint debug-buffer))
         (parsed (benedict-provider-gemini--parse-json body)))
    (when (= status 0)
      (if (string-empty-p hint)
          (error "Gemini login failed before receiving an HTTP status.")
        (error "Gemini login failed before receiving an HTTP status. %s" hint)))
    (unless (= status 200)
      (let* ((message (or (plist-get parsed :error_description)
                          body
                          "Gemini login failed"))
             (details (if (string-empty-p hint)
                          message
                        (format "%s %s" message hint))))
        (error "Gemini login failed (HTTP %s): %s" status details)))
    (let ((refresh (plist-get parsed :refresh_token))
          (access (plist-get parsed :access_token))
          (expires-in (benedict-provider-gemini--ensure-number (plist-get parsed :expires_in) 3600)))
      (unless (and refresh access)
        (error "Gemini login response missing refresh or access token"))
      (list :refresh refresh
            :access access
            :expires (+ (float-time) (max 30 (- expires-in 30)))))))


(defun benedict-provider-gemini--persist-refresh-token (refresh-token)
  "Persist REFRESH-TOKEN into auth-source."
  (let ((entry (benedict-provider-gemini--auth-source-entry)))
    (if entry
        (benedict-provider-gemini--update-auth-entry entry refresh-token)
      (if (fboundp 'auth-source-add)
          (auth-source-add :host benedict-provider-gemini-auth-source-host
                           :user benedict-provider-gemini-auth-source-user
                           :port benedict-provider-gemini-auth-source-port
                           :secret refresh-token
                           :create t)
        (error (concat "Cannot store Gemini refresh token automatically. "
                       "Please add it to auth-source manually."))))))

(benedict-provider-register
 (benedict-provider--create
  :id 'gemini
  :name "Google Gemini"
  :send #'benedict-provider-gemini--send
  :capabilities '(:streaming nil :tools t)
  :cancel #'ignore))

(provide 'benedict-provider-gemini)
;;; benedict-provider-gemini.el ends here
