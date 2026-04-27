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
(require 'benedict-credentials)

(defgroup benedict-provider-gemini nil
  "Settings for the Benedict Google Gemini provider."
  :group 'benedict
  :prefix "benedict-provider-gemini-")

(defcustom benedict-provider-gemini-auth-method 'oauth
  "Method used to authenticate with Gemini.
Can be `oauth` (default) or `api-key`.
In `oauth` mode, Benedict uses OAuth refresh tokens stored in the
filesystem store (~/.config/benedict/auth.json).
In `api-key` mode, Benedict uses an API key from environment variables,
filesystem store, or auth-source."
  :type '(choice (const oauth) (const api-key))
  :group 'benedict-provider-gemini)

(defcustom benedict-provider-gemini-env-var "GEMINI_API_KEY"
  "Environment variable name used to locate the Gemini API key."
  :type 'string
  :group 'benedict-provider-gemini)

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

(defconst benedict-provider-gemini-cloud-code-endpoint
  "https://cloudcode-pa.googleapis.com"
  "Endpoint for Gemini Code Assist API.")

(defconst benedict-provider-gemini-cloud-code-headers
  '(("User-Agent" . "google-api-nodejs-client/9.15.1")
    ("X-Goog-Api-Client" . "gl-node/22.17.0")
    ("Client-Metadata" . "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI"))
  "Headers required by the Gemini Code Assist API.")

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

(defun benedict-provider-gemini--authorization-token-part (string)
  "Return the token portion of a Bearer Authorization STRING.
Returns nil if STRING does not start with Bearer (case-insensitive)
or contains no token."
  (when (and (stringp string)
             (string-match "^[Bb][Ee][Aa][Rr][Ee][Rr]\\s-*" string))
    (let ((token (string-trim (substring string (match-end 0)))))
      (if (string-empty-p token) nil token))))

(defun benedict-provider-gemini--redact-authorization-value (value)
  "Return VALUE redacted while preserving Bearer metadata."
  (let* ((string (benedict-provider-gemini--stringify value))
         (token (benedict-provider-gemini--authorization-token-part string)))
    (if token
        (format "Bearer %s" (benedict-provider-gemini--redact-secret token))
      ;; If it matched Bearer prefix but has no token, return "Bearer ***"
      ;; Otherwise, for unknown Authorization formats, return fixed mask for safety
      (if (and (stringp string) (string-match "^[Bb][Ee][Aa][Rr][Ee][Rr]\\s-*" string))
          "Bearer ***"
        "***"))))

(defun benedict-provider-gemini--redact-headers (headers)
  "Redact sensitive HEADERS before logging."
  (mapcar
   (lambda (pair)
      (let* ((name (car pair))
             (value (cdr pair))
             ;; Ensure we have a string for the check
             (name-str (cond ((symbolp name) (symbol-name name))
                             ((stringp name) name)
                             (t (format "%s" name)))))
        (if (string-equal "authorization" (downcase name-str))
            (cons name (benedict-provider-gemini--redact-authorization-value value))
          pair)))
   (if (listp headers) (copy-sequence headers) nil)))

(defun benedict-provider-gemini--make-request-id ()
  "Return a log-friendly request identifier."
  (format "gemini-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%SZ" (current-time) t)
          (random #x1000000)))

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

(defun benedict-provider-gemini--load-managed-project (access-token)
  "Load managed project information from Google using ACCESS-TOKEN.
Returns plist with :project-id (string or nil), :current-tier (string or nil),
:allowed-tiers (list or nil)."
  (let* ((lgr (benedict-provider-gemini--logger))
         (url (format "%s/v1internal:loadCodeAssist"
                      (string-remove-suffix "/" benedict-provider-gemini-cloud-code-endpoint)))
         (headers (append benedict-provider-gemini-cloud-code-headers
                          (list (cons "Content-Type" "application/json")
                                (cons "Authorization" (format "Bearer %s" access-token)))))
         (body (json-encode `(("metadata" . ,(list (cons "ideType" "IDE_UNSPECIFIED")
                                                   (cons "platform" "PLATFORM_UNSPECIFIED")
                                                   (cons "pluginType" "GEMINI"))))))
         (url-request-method "POST")
         (url-request-extra-headers headers)
         (url-request-data (encode-coding-string body 'utf-8))
         (buffer (url-retrieve-synchronously url t t benedict-provider-gemini-token-timeout)))
    (when buffer
      (with-current-buffer buffer
        (unwind-protect
            (progn
              (goto-char (point-min))
              (if (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                  (let ((status (string-to-number (match-string 1))))
                    (goto-char (point-min))
                    (when (re-search-forward "\n\n" nil t)
                      (let* ((parsed (benedict-provider-gemini--parse-json
                                      (buffer-substring-no-properties (point) (point-max))))
                             (project-id (plist-get parsed :cloudaicompanionProject))
                             (current-tier (plist-get (plist-get parsed :currentTier) :id))
                             (allowed-tiers (plist-get parsed :allowedTiers))
                             (result (list :project-id project-id
                                           :current-tier current-tier
                                           :allowed-tiers allowed-tiers)))
                        (if (= status 200)
                            (progn
                              (lgr-info lgr "Loaded Gemini managed project" :project-id project-id)
                              result)
                          (lgr-error lgr "Failed to load Gemini managed project"
                                      :status status
                                      :current-tier current-tier
                                      :allowed-tiers allowed-tiers
                                      :url url)
                          result))))
                (lgr-error lgr "Failed to load Gemini managed project: no HTTP status"
                            :url url)
                nil))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(defun benedict-provider-gemini--credential-error ()
  "Signal a standardized credential error message."
  (if (eq benedict-provider-gemini-auth-method 'oauth)
      (error (concat "Gemini OAuth refresh token missing. "
                     "Run M-x benedict-provider-gemini-login to authenticate."))
    (error (benedict-credentials-error-message
            'gemini
            benedict-provider-gemini-env-var
            benedict-provider-gemini-auth-source-host))))

(defun benedict-provider-gemini--resolve-credential ()
  "Return plist describing the resolved credential."
  (if (eq benedict-provider-gemini-auth-method 'api-key)
      (or (benedict-credentials-resolve-api-key
           'gemini
           :env-var benedict-provider-gemini-env-var
           :auth-source-params (list :host benedict-provider-gemini-auth-source-host
                                     :user benedict-provider-gemini-auth-source-user
                                     :port benedict-provider-gemini-auth-source-port))
          (benedict-provider-gemini--credential-error))
    ;; OAuth mode
    (let* ((creds (benedict-credentials-get 'gemini 'oauth))
           (packed-refresh (plist-get creds :refresh))
           (access (plist-get creds :access))
           (expires (plist-get creds :expires))
           (refresh-parts (benedict-provider-gemini--parse-refresh packed-refresh))
           (refresh (car refresh-parts))
           (project-id (nth 1 refresh-parts))
           (managed-project-id (nth 2 refresh-parts)))
      (unless (and refresh (not (string-empty-p refresh)))
        (benedict-provider-gemini--credential-error))
      (let* ((cached (benedict-provider-gemini--cache-get refresh))
             (cached-expires (plist-get cached :expires))
             (cached-access (plist-get cached :access))
             (now (float-time)))
        ;; Use cached access token if still valid and we have a project
        (if (and cached-access cached-expires (> cached-expires now)
                 (or project-id managed-project-id))
            (list :access cached-access :expires cached-expires :refresh refresh
                  :project-id (or project-id managed-project-id))
          ;; Check if stored access token is still valid and we have a project
          (if (and access expires (> expires now)
                   (or project-id managed-project-id))
              (progn
                (benedict-provider-gemini--cache-store refresh creds)
                (list :access access :expires expires :refresh refresh
                      :project-id (or project-id managed-project-id)))
            ;; Refresh token or load project
            (let* ((fresh (if (and access expires (> expires now))
                              (list :access access :expires expires :refresh refresh)
                            (benedict-provider-gemini--refresh-access-token refresh)))
                   (next-refresh (or (plist-get fresh :refresh) refresh))
                   (next-access (plist-get fresh :access))
                   (next-expires (plist-get fresh :expires)))
               ;; If we don't have a project ID, try to load one
               (unless (or project-id managed-project-id)
                 (let ((managed-project-result (benedict-provider-gemini--load-managed-project next-access)))
                   (setq managed-project-id (plist-get managed-project-result :project-id))))
               (benedict-provider-gemini--persist-refresh-token
                next-refresh next-access next-expires project-id managed-project-id)
               (benedict-provider-gemini--cache-store next-refresh fresh refresh)
               (list :access next-access
                     :expires next-expires
                     :refresh next-refresh
                     :project-id (or project-id managed-project-id)))))))))

(defun benedict-provider-gemini--ensure-number (value default)
  "Coerce VALUE into a number, falling back to DEFAULT when needed."
  (cond
   ((numberp value) value)
   ((and (stringp value) (string-match-p "^[0-9.]+$" value))
    (string-to-number value))
   (t default)))

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

(defun benedict-provider-gemini--refresh-access-token (refresh-token)
  "Return plist (:access :expires :refresh) after refreshing REFRESH-TOKEN."
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
          (error "Gemini token refresh failed before receiving an HTTP status")
        (error "Gemini token refresh failed before receiving an HTTP status: %s" hint)))
    (if (= status 200)
        (let* ((access (plist-get parsed :access_token))
               (expires-in (benedict-provider-gemini--ensure-number
                            (plist-get parsed :expires_in) 3600))
               (new-refresh (or (plist-get parsed :refresh_token) refresh-token))
               (expires (+ (float-time) (max 30 (- expires-in 30)))))
          (unless access
            (error "Gemini token response missing access token"))
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
          (benedict-credentials-remove 'gemini 'oauth)
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

(defun benedict-provider-gemini--body-preview (body &optional limit)
  "Return a truncated preview string for BODY with LIMIT."
  (let* ((text (benedict-provider-gemini--stringify body))
         (max (or limit 2000)))
    (if (> (length text) max)
        (format "%s… (truncated %d chars)"
                (substring text 0 max)
                (- (length text) max))
      text)))

(defun benedict-provider-gemini--parts-from-text (text)
  "Return Gemini parts vector from TEXT."
  (vector (list (cons "text" text))))

(defun benedict-provider-gemini--serialize-message (message)
  "Serialize canonical MESSAGE into Gemini content entry."
  (let* ((role (benedict-provider-message-role message))
         (content (benedict-provider-gemini--stringify
                   (benedict-provider-message-content message)))
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
      (let ((role (benedict-provider-gemini--normalize-role
                   (benedict-provider-message-role message))))
        (if (and (eq role 'system) (not system))
            (setq system message)
          (push message remainder))))
    (list system (nreverse remainder))))

(defun benedict-provider-gemini--serialize-tool (tool)
  "Serialize a benedict TOOL spec to Gemini functionDeclaration."
  (let ((name (plist-get tool :name))
        (doc (plist-get tool :description))
        (schema (plist-get tool :parameters)))
    (list (cons "name" name)
          (cons "description" (or doc ""))
          (cons "parameters" schema))))

(defun benedict-provider-gemini--build-body (request &optional project-id wrap)
  "Return JSON-ready alist for REQUEST.
When WRAP is non-nil, wrap the request in a Code Assist-compatible structure
using PROJECT-ID."
  (let ((messages (plist-get request :messages))
        (tools (plist-get request :tools)))
    (setq messages (benedict-provider-request-messages request "Gemini"))
    (pcase-let* ((`(,system ,content-messages)
                   (benedict-provider-gemini--extract-system-prompt messages))
                 (model (or (plist-get request :model)
                            benedict-provider-gemini-default-model))
                 (contents (mapcar #'benedict-provider-gemini--serialize-message
                                   content-messages))
                 (body `(("contents" . ,contents))))
      (unless wrap
        (push (cons "model" model) body))
      (when system
        (push (cons "systemInstruction"
                    (list (cons "role" "system")
                          (cons "parts"
                                (benedict-provider-gemini--parts-from-text
                                (benedict-provider-gemini--stringify
                                  (benedict-provider-message-content system))))))
              body))
      (when tools
        (let ((declarations (mapcar #'benedict-provider-gemini--serialize-tool tools)))
          (push (cons "tools"
                      (vector (list (cons "functionDeclarations" (vconcat declarations)))))
                body)))
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
      (let ((result (nreverse body)))
        (if wrap
            `(("project" . ,(or project-id ""))
              ("model" . ,model)
              ("request" . ,result))
          result)))))

(defun benedict-provider-gemini--encode-payload (request &optional project-id wrap)
  "Return encoded JSON payload for REQUEST, PROJECT-ID, and WRAP."
  (encode-coding-string
   (json-encode (benedict-provider-gemini--build-body request project-id wrap))
   'utf-8))

(defun benedict-provider-gemini--build-headers (access-token &optional wrap)
  "Return HTTP headers using ACCESS-TOKEN.
When WRAP is non-nil, include headers required by the Cloud Code Assist API."
  (let ((headers (list (cons "Content-Type" "application/json")
                       (cons "Authorization" (format "Bearer %s" access-token)))))
    (if wrap
        (setq headers (append benedict-provider-gemini-cloud-code-headers headers))
      (when (and benedict-provider-gemini-user-agent
                 (not (string-empty-p benedict-provider-gemini-user-agent)))
        (push (cons "User-Agent" benedict-provider-gemini-user-agent) headers)))
    (nreverse headers)))

(defun benedict-provider-gemini--endpoint-for (model &optional stream wrap)
  "Return endpoint URL for MODEL, optionally STREAM.
When WRAP is non-nil, use the Cloud Code Assist endpoint and /v1internal prefix."
  (if wrap
      (let* ((base (string-remove-suffix "/" benedict-provider-gemini-cloud-code-endpoint))
             (suffix (if stream ":streamGenerateContent" ":generateContent")))
        (format "%s/v1internal%s" base suffix))
    (let* ((base (string-remove-suffix "/" benedict-provider-gemini-endpoint))
           (suffix (if stream ":streamGenerateContent" ":generateContent")))
      (format "%s/%s%s" base model suffix))))

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
      (when-let ((prompt (plist-get metadata :promptTokenCount)))
        (setq result (plist-put result :prompt prompt)))
      (when-let ((completion (plist-get metadata :candidatesTokenCount)))
        (setq result (plist-put result :completion completion)))
      (when-let ((total (plist-get metadata :totalTokenCount)))
        (setq result (plist-put result :total total)))
      result)))

(defun benedict-provider-gemini--object-get (object key)
  "Return KEY from Gemini JSON OBJECT regardless of parsed container type."
  (let* ((name (substring (symbol-name key) 1))
         (string-key name)
         (symbol-key (intern name)))
    (cond
     ((hash-table-p object)
      (or (gethash key object)
          (gethash string-key object)
          (gethash symbol-key object)))
     ((and (consp object) (consp (car object)))
      (or (alist-get key object)
          (alist-get string-key object nil nil #'string=)
          (alist-get symbol-key object)))
     ((listp object)
      (plist-get object key))
     (t nil))))

(defun benedict-provider-gemini--tool-args-json (args)
  "Return canonical JSON argument string for Gemini ARGS."
  (if args
      (json-encode args)
    "{}"))

(defun benedict-provider-gemini--extract-tool-calls (parts)
  "Return extracted Gemini tool-call plists from PARTS."
  (let (calls)
    (cl-loop for part in (cond
                          ((vectorp parts) (append parts nil))
                          ((listp parts) parts)
                          (t nil))
             for call = (benedict-provider-gemini--object-get part :functionCall)
             when call
             do (let* ((name (benedict-provider-gemini--object-get call :name))
                       (args (benedict-provider-gemini--object-get call :args))
                       (args-json (benedict-provider-gemini--tool-args-json args)))
                  (push (list :id (format "call_%s" (md5 (format "%s%s" name (random))))
                              :name name
                              :arguments args-json)
                        calls)))
    (nreverse calls)))

(defun benedict-provider-gemini--handle-success (body context)
  "Handle successful BODY for CONTEXT."
  (condition-case err
      (let* ((parsed (benedict-provider-gemini--parse-json body))
             ;; If the response is wrapped (Cloud Code Assist), the actual Gemini
             ;; response is under the "response" key.
             (effective (or (plist-get parsed :response) parsed))
             (candidates (plist-get effective :candidates))
             (first (car candidates))
             (content (and first (plist-get first :content)))
             (parts (or (and content (plist-get content :parts))
                        (plist-get first :parts)))
             (text (benedict-provider-gemini--parts->text parts))
             (tool-calls (benedict-provider-gemini--extract-tool-calls parts))
             (usage (benedict-provider-gemini--usage-from-metadata
                     (plist-get effective :usageMetadata)))
             (request-id (plist-get context :request-id))
             (start (plist-get context :start-time))
             (latency (and start (float-time (time-subtract (current-time) start))))
             (result (benedict-provider-result-create
                      :text text
                      :tool-calls tool-calls
                      :model (plist-get context :model)
                      :provider 'gemini
                      :usage usage
                      :latency latency
                      :raw effective)))
         (let ((lgr (benedict-provider-gemini--logger)))
           (lgr-info lgr "Gemini completion"
                     :request-id request-id
                     :latency latency
                     :empty-response (if (string-empty-p text) "yes" "no"))
           (lgr-debug lgr "Gemini HTTP response"
                      :request-id request-id
                      :latency latency
                      :model (plist-get context :model)
                      :empty-response (if (string-empty-p text) "yes" "no")
                      :body-preview (benedict-provider-gemini--body-preview body)))
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
                         :status (or (plist-get message-details :status) :json-false)
                         :retryable :json-false
                         :body body)))
    (lgr-error lgr "Gemini request failed"
               :request-id request-id
               :type (if type (symbol-name type) "unknown")
               :message (plist-get payload :message)
               :status (plist-get payload :status))
    (lgr-debug lgr "Gemini request failure detail"
               :request-id request-id
               :body-preview (benedict-provider-gemini--body-preview body))
    (benedict-provider-gemini--emit-error context payload)))

(cl-defun benedict-provider-gemini--send
    (_provider request &key on-success on-error _on-delta on-complete &allow-other-keys)
  "Dispatch REQUEST to Gemini.
ON-SUCCESS/ON-ERROR/ON-COMPLETE mirror `benedict-provider-dispatch'."
  (let* ((credential (benedict-provider-gemini--resolve-credential))
         (model (or (plist-get request :model) benedict-provider-gemini-default-model))
         (wrap (eq benedict-provider-gemini-auth-method 'oauth))
         (project-id (plist-get credential :project-id))
         (payload (benedict-provider-gemini--encode-payload
                   (plist-put (copy-sequence request) :model model)
                   project-id wrap))
         (request-id (or (plist-get request :request-id)
                         (benedict-provider-gemini--make-request-id)))
         (start-time (current-time))
         (url (benedict-provider-gemini--endpoint-for model nil wrap))
         (headers (benedict-provider-gemini--build-headers (plist-get credential :access) wrap))
         (context (list :request-id request-id
                        :model model
                        :start-time start-time
                        :on-success on-success
                        :on-error on-error
                        :on-complete on-complete)))
    (let ((lgr (benedict-provider-gemini--logger))
          (redacted-headers (benedict-provider-gemini--redact-headers headers)))
      (lgr-debug lgr "Gemini HTTP request"
                 :request-id request-id
                 :url url
                 :model model
                 :auth-method (symbol-name benedict-provider-gemini-auth-method)
                 :wrap (if wrap "yes" "no")
                 :project-id project-id
                 :headers (let (result)
                            (dolist (h redacted-headers)
                              (let* ((name (car h))
                                     (sym (if (symbolp name) name (intern (format ":%s" name)))))
                                (setq result (plist-put result sym (cdr h)))))
                            result)
                 :body-preview (benedict-provider-gemini--body-preview payload)))
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
          (error "OAuth state mismatch; aborting"))
       (let* ((tokens (benedict-provider-gemini--exchange-authorization-code code verifier))
              (refresh (plist-get tokens :refresh))
              (access (plist-get tokens :access))
              (expires (plist-get tokens :expires))
              (managed-project-result (benedict-provider-gemini--load-managed-project access))
              (managed-project-id (plist-get managed-project-result :project-id)))
         (benedict-provider-gemini--persist-refresh-token refresh access expires nil managed-project-id)
         (benedict-provider-gemini--cache-store refresh (list :access access :expires expires))
         (message "Gemini refresh token stored in %s" (benedict-credentials--file)))))))

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
          (error "Gemini login failed before receiving an HTTP status")
        (error "Gemini login failed before receiving an HTTP status: %s" hint)))
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


(defun benedict-provider-gemini--parse-refresh (refresh)
  "Split REFRESH string into (REFRESH-TOKEN PROJECT-ID MANAGED-PROJECT-ID)."
  (let ((parts (mapcar (lambda (x) (if (string= x "") nil x))
                       (split-string (or refresh "") "|"))))
    (list (nth 0 parts)
          (nth 1 parts)
          (nth 2 parts))))

(defun benedict-provider-gemini--format-refresh (refresh-token &optional project-id managed-project-id)
  "Serialize REFRESH-TOKEN, PROJECT-ID, and MANAGED-PROJECT-ID into a packed string."
  (if (or project-id managed-project-id)
      (format "%s|%s|%s"
              (or refresh-token "")
              (or project-id "")
              (or managed-project-id ""))
    (or refresh-token "")))

(defun benedict-provider-gemini--persist-refresh-token (refresh access expires &optional project-id managed-project-id)
  "Persist REFRESH token and related ACCESS and EXPIRES metadata.
Optional PROJECT-ID and MANAGED-PROJECT-ID are packed into the refresh string."
  (let* ((entry (list :refresh (benedict-provider-gemini--format-refresh refresh project-id managed-project-id)
                      :access access
                      :expires expires)))
    (benedict-credentials-set 'gemini 'oauth entry)))

(benedict-provider-register
 (benedict-provider--create
  :id 'gemini
  :name "Google Gemini"
  :send #'benedict-provider-gemini--send
  :capabilities '(:streaming nil :tools t)
  :cancel #'ignore))

(provide 'benedict-provider-gemini)
;;; benedict-provider-gemini.el ends here
