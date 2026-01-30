;;; benedict-provider-gemini-test.el --- Tests for Gemini provider -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'ert-async)
(require 'propcheck)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-provider-gemini)

(defun benedict-provider-gemini-test--json-get (alist key)
  "Return KEY from JSON-like ALIST using string comparison."
  (alist-get key alist nil nil #'string=))

(propcheck-deftest benedict-provider-gemini-pkce-flow-prop ()
  "PKCE flow (verifier -> challenge) works for any 32 random bytes."
  (let ((bytes (cl-loop repeat 32 collect (propcheck-generate-integer "byte" :min 0 :max 255))))
    (let* ((verifier (benedict-provider-gemini--make-verifier bytes))
           (challenge (benedict-provider-gemini--derive-challenge verifier)))
      (propcheck-should (string-match-p "\\`[-_A-Za-z0-9]+\\'" verifier))
      (propcheck-should (string-match-p "\\`[-_A-Za-z0-9]+\\'" challenge))
      (propcheck-should (not (multibyte-string-p verifier)))
      (propcheck-should (not (multibyte-string-p challenge))))))

(ert-deftest benedict-provider-gemini-generate-verifier-uses-make-verifier ()
  "Verifier generation calls the deterministic helper."
  (cl-letf (((symbol-function 'benedict-provider-gemini--make-verifier)
             (lambda (bytes) (format "mock-%d" (length bytes)))))
    (should (equal (benedict-provider-gemini--generate-verifier) "mock-32"))))

(ert-deftest benedict-provider-gemini-derive-challenge-base64url ()
  "PKCE challenge derivation wraps SHA256 with base64url encoding."
  (let* ((verifier "plain-verifier")
         (expected (base64url-encode-string (secure-hash 'sha256 verifier nil nil t) t)))
    (should (equal (benedict-provider-gemini--derive-challenge verifier) expected))))

(ert-deftest benedict-provider-gemini-state-roundtrip ()
  "State payload encoding round-trips through base64url helpers."
  (let* ((payload (list :verifier "abc" :nonce "xyz"))
         (encoded (benedict-provider-gemini--encode-state payload))
         (decoded (benedict-provider-gemini--decode-state encoded)))
    (should decoded)
    (should (equal (plist-get decoded :verifier) "abc"))
    (should (equal (plist-get decoded :nonce) "xyz"))))

(ert-deftest benedict-provider-gemini-pkce-session-roundtrip ()
  "PKCE state survives auth URL construction and callback parsing."
  (let* ((verifier "test-verifier")
         (state (benedict-provider-gemini--encode-state (list :verifier verifier :nonce "n1")))
         (challenge (benedict-provider-gemini--derive-challenge verifier))
         (auth-url (benedict-provider-gemini--authorization-url challenge state))
         (query (cadr (split-string auth-url "?" t)))
         (params (url-parse-query-string query)))
    (should (equal (cadr (assoc-string "code_challenge" params t)) challenge))
    (should (equal (cadr (assoc-string "code_challenge_method" params t)) "S256"))
    (should (equal (cadr (assoc-string "state" params t)) state))
    (should (equal (cadr (assoc-string "redirect_uri" params t)) benedict-provider-gemini-redirect-uri))
    (let* ((callback (format "%s?code=auth-code&state=%s" benedict-provider-gemini-redirect-uri state))
           (parsed (benedict-provider-gemini--parse-callback callback))
           (decoded (benedict-provider-gemini--decode-state (plist-get parsed :state))))
      (should (equal (plist-get parsed :code) "auth-code"))
      (should decoded)
      (should (equal (plist-get decoded :verifier) verifier))
      (should (equal (plist-get decoded :nonce) "n1")))))

(ert-deftest benedict-provider-gemini-resolve-uses-cache ()
  "Cached credentials skip refresh calls."
  (let ((benedict-provider-gemini--token-cache (make-hash-table :test 'equal)))
    (puthash "refresh-1"
             (list :access "cached-access" :expires (+ (float-time) 999))
             benedict-provider-gemini--token-cache)
    (cl-letf (((symbol-function 'benedict-credentials-get)
               (lambda (_provider _type) (list :refresh "refresh-1|proj-123")))
               ((symbol-function 'benedict-provider-gemini--refresh-access-token)
                (lambda (&rest _)
                  (error "Refresh should not be called"))))
      (let ((credential (benedict-provider-gemini--resolve-credential)))
        (should (equal (plist-get credential :access) "cached-access"))
        (should (equal (plist-get credential :refresh) "refresh-1"))
        (should (equal (plist-get credential :project-id) "proj-123"))))))

(ert-deftest benedict-provider-gemini-resolve-refreshes-when-expired ()
  "Expired cache entries trigger token refresh."
  (let ((benedict-provider-gemini--token-cache (make-hash-table :test 'equal))
        (refresh-count 0)
        (persist-count 0))
    (puthash "refresh-old" (list :access "stale" :expires (float-time))
             benedict-provider-gemini--token-cache)
    (cl-letf (((symbol-function 'benedict-credentials-get)
               (lambda (_provider _type) (list :refresh "refresh-old")))
              ((symbol-function 'benedict-provider-gemini--persist-refresh-token)
               (lambda (&rest _) (setq persist-count (1+ persist-count))))
              ((symbol-function 'benedict-provider-gemini--refresh-access-token)
               (lambda (_refresh)
                 (setq refresh-count (1+ refresh-count))
                 (list :access "new-access" :expires (+ (float-time) 3600)
                       :refresh "refresh-old"))))
      (let ((credential (benedict-provider-gemini--resolve-credential)))
        (should (= refresh-count 1))
        (should (= persist-count 1))
        (should (equal (plist-get credential :access) "new-access"))
        (should (equal (plist-get credential :refresh) "refresh-old"))))))

(ert-deftest benedict-provider-gemini-refresh-rotates-token ()
  "Refresh flow updates storage when Google rotates tokens."
  (cl-letf (((symbol-function 'benedict-provider-gemini--token-request)
             (lambda (_payload)
               (list :status 200
                     :body "{\"access_token\":\"ya29-token\",\"refresh_token\":\"1//new\",\"expires_in\":3600}"))))
    (let* ((result (benedict-provider-gemini--refresh-access-token "1//old")))
      (should (equal (plist-get result :refresh) "1//new"))
      (should (equal (plist-get result :access) "ya29-token"))
      (should (> (plist-get result :expires) (float-time))))))

(ert-deftest benedict-provider-gemini-refresh-invalid-grant ()
  "Refresh failures with invalid_grant clear the credentials store."
  (let ((removed-provider nil)
        (removed-type nil))
    (cl-letf (((symbol-function 'benedict-provider-gemini--token-request)
               (lambda (_payload)
                 (list :status 400 :body "{\"error\":\"invalid_grant\"}")))
              ((symbol-function 'benedict-credentials-remove)
               (lambda (p t)
                 (setq removed-provider p)
                 (setq removed-type t))))
      (should-error (benedict-provider-gemini--refresh-access-token "bad")
                    :type 'error)
      (should (eq removed-provider 'gemini))
      (should (eq removed-type 'oauth)))))


(ert-deftest benedict-provider-gemini-payload-shape ()
  "Payload encoding follows Gemini content schema."
  (let* ((request (list :model "gemini-test"
                        :messages (list (list :role 'system :content "system prompt")
                                        (list :role 'user :content "hi")
                                        (list :role 'assistant :content "hello"))
                        :temperature 0.3
                        :max-tokens 256))
         ;; OAuth mode triggers wrapping
         (benedict-provider-gemini-auth-method 'oauth)
         (encoded (benedict-provider-gemini--encode-payload request "proj-123" t))
         (decoded (json-parse-string encoded :object-type 'alist :array-type 'list))
         (inner (benedict-provider-gemini-test--json-get decoded "request")))
    (should (equal (benedict-provider-gemini-test--json-get decoded "model") "gemini-test"))
    (should (equal (benedict-provider-gemini-test--json-get decoded "project") "proj-123"))
    (let ((system (benedict-provider-gemini-test--json-get inner "systemInstruction")))
      (should system)
      (should (equal (benedict-provider-gemini-test--json-get system "role") "system")))
    (let ((contents (benedict-provider-gemini-test--json-get inner "contents")))
      (should (= (length contents) 2))
      (should (equal (benedict-provider-gemini-test--json-get (car contents) "role") "user"))
      (should (equal (benedict-provider-gemini-test--json-get (cadr contents) "role") "model")))
    (let* ((config (benedict-provider-gemini-test--json-get inner "generationConfig"))
           (temperature (benedict-provider-gemini-test--json-get config "temperature"))
           (max-output (benedict-provider-gemini-test--json-get config "maxOutputTokens")))
      (should (= temperature 0.3))
      (should (= max-output 256)))))

(ert-deftest benedict-provider-gemini-payload-shape-unwrapped ()
  "Payload encoding in api-key mode is not wrapped."
  (let* ((request (list :model "gemini-test"
                        :messages (list (list :role 'user :content "hi"))))
         (benedict-provider-gemini-auth-method 'api-key)
         (encoded (benedict-provider-gemini--encode-payload request))
         (decoded (json-parse-string encoded :object-type 'alist :array-type 'list)))
    (should (equal (benedict-provider-gemini-test--json-get decoded "model") "gemini-test"))
    (should-not (benedict-provider-gemini-test--json-get decoded "project"))
    (should-not (benedict-provider-gemini-test--json-get decoded "request"))
    (should (benedict-provider-gemini-test--json-get decoded "contents"))))

(ert-deftest benedict-provider-gemini-header-redaction ()
  "Header redaction masks bearer tokens."
  (let* ((headers (benedict-provider-gemini--build-headers "secret-token"))
         (redacted (benedict-provider-gemini--redact-headers headers))
         (auth-original (cdr (assoc "Authorization" headers)))
         (auth-redacted (cdr (assoc "Authorization" redacted))))
    (should (string-match-p "Bearer" auth-redacted))
    (should (not (equal auth-original auth-redacted)))))

(ert-deftest benedict-provider-gemini-redact-secret-edge-cases ()
  "Redact secret handles short or non-string values safely."
  (should (equal (benedict-provider-gemini--redact-secret "123") "***"))
  (should (equal (benedict-provider-gemini--redact-secret "") "***"))
  (should (equal (benedict-provider-gemini--redact-secret nil) "***"))
  (should (equal (benedict-provider-gemini--redact-secret 'symbol) "***"))
  (should (equal (benedict-provider-gemini--redact-secret "123456789") "1234…89")))

(ert-deftest benedict-provider-gemini-redact-authorization-variations ()
  "Redact authorization value handles various prefix formats."
  ;; Well-formed
  (should (string-match-p "Bearer 1234…89"
                          (benedict-provider-gemini--redact-authorization-value "Bearer 123456789")))
  ;; Mixed case prefix
  (should (string-match-p "Bearer 1234…89"
                          (benedict-provider-gemini--redact-authorization-value "bearer 123456789")))
  (should (string-match-p "Bearer 1234…89"
                          (benedict-provider-gemini--redact-authorization-value "BEARER 123456789")))
  ;; Missing token
  (let ((redacted (benedict-provider-gemini--redact-authorization-value "Bearer ")))
    (should (string-prefix-p "Bearer " redacted))
    (should (equal (substring redacted 7) "***")))
  (let ((redacted (benedict-provider-gemini--redact-authorization-value "Bearer")))
    (should (string-prefix-p "Bearer " redacted))
    (should (equal (substring redacted 7) "***")))
  ;; Non-bearer
  (should (equal (benedict-provider-gemini--redact-authorization-value "Basic abc") "***"))
  ;; Non-string
  (should (equal (benedict-provider-gemini--redact-authorization-value nil) "***")))

(ert-deftest benedict-provider-gemini-redact-headers-robustness ()
  "Redact headers is case-insensitive and preserves other headers."
  (let* ((headers '(("Authorization" . "Bearer secret")
                    ("X-Custom" . "keep-me")
                    ("authorization" . "Bearer also-secret")
                    (AUTHORIZATION . "Bearer symbol-secret")
                    ("Content-Type" . "application/json")))
         (redacted (benedict-provider-gemini--redact-headers headers)))
    (should (equal (cdr (assoc "X-Custom" redacted)) "keep-me"))
    (should (equal (cdr (assoc "Content-Type" redacted)) "application/json"))
    (should (string-prefix-p "Bearer " (cdr (assoc "Authorization" redacted))))
    (should (string-prefix-p "Bearer " (cdr (assoc "authorization" redacted))))
    (should (string-prefix-p "Bearer " (cdr (assoc 'AUTHORIZATION redacted))))
    (should-not (string-match-p "secret" (format "%s" redacted)))))

(ert-deftest benedict-provider-gemini-body-preview ()
  "Body preview truncates long strings and handles short ones."
  (should (equal (benedict-provider-gemini--body-preview "short") "short"))
  (let* ((long (make-string 2100 ?a))
         (preview (benedict-provider-gemini--body-preview long)))
    (should (string-match-p "… (truncated 100 chars)" preview))
    (should (= (length (substring preview 0 2000)) 2000)))
  ;; Custom limit
  (should (string-match-p "… (truncated 5 chars)"
                          (benedict-provider-gemini--body-preview "1234567890" 5))))

(ert-deftest benedict-provider-gemini-send-logs-http-diagnostics ()
  "Send flow emits structured debug logs with redacted headers."
  (let ((logged nil))
    (cl-letf (((symbol-function 'lgr-get-threshold) (lambda (&rest _) 600))
              ((symbol-function 'lgr-log)
               (lambda (_lgr level msg &rest args)
                 (when (= level 500) ; debug
                   (push (cons msg args) logged))))
              ((symbol-function 'benedict-http-request)
               (lambda (&rest _) nil))
              ((symbol-function 'benedict-provider-gemini--resolve-credential)
               (lambda () (list :access "secret-token" :project-id "proj-123"))))
      (benedict-provider-gemini--send nil (list :messages (list (list :role 'user :content "hi"))))
      (let ((request-log (assoc "Gemini HTTP request" logged)))
        (should request-log)
        (let ((args (cdr request-log)))
          (should (equal (plist-get args :project-id) "proj-123"))
          (should (equal (plist-get args :auth-method) "oauth"))
          (should (plist-get args :url))
          (let ((headers (plist-get args :headers)))
            (should (string-prefix-p "Bearer " (plist-get headers :Authorization)))
            (should-not (string-match-p "secret-token" (plist-get headers :Authorization)))))))))

(ert-deftest benedict-provider-gemini-handle-success-logs-response ()
  "Success handler emits debug log with body preview."
  (let ((logged nil))
    (cl-letf (((symbol-function 'lgr-get-threshold) (lambda (&rest _) 600))
              ((symbol-function 'lgr-log)
               (lambda (_lgr level msg &rest args)
                 (when (= level 500) ; debug
                   (push (cons msg args) logged))))
              ((symbol-function 'benedict-provider-gemini--on-complete) (lambda (_) nil)))
      (benedict-provider-gemini--handle-success
       "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello\"}]}}]}"
       (list :request-id "req-1" :model "m1"))
      (let ((response-log (assoc "Gemini HTTP response" logged)))
        (should response-log)
        (let ((args (cdr response-log)))
          (should (equal (plist-get args :request-id) "req-1"))
          (should (plist-get args :body-preview)))))))

(ert-deftest-async benedict-provider-gemini-login-persists-refresh-token (done)
  "Simulated OAuth login persists refresh token and seeds cache."
  (let* ((verifier "unit-test-verifier")
         (access-token "ya29.unit-access")
         (refresh-token "1//unit-refresh")
         (state-value nil)
         (opened-url nil)
         (copied-url nil)
         (read-prompt nil)
         (credential-set-call nil)
         (token-request-count 0)
         (temp-dir (make-temp-file "benedict-test-xdg-" t))
         (orig-encode (symbol-function 'benedict-provider-gemini--encode-state)))
    (let ((benedict-provider-gemini--token-cache (make-hash-table :test 'equal)))
      (cl-letf* (((symbol-function 'xdg-config-home) (lambda () temp-dir))
                 ((symbol-function 'benedict-provider-gemini--generate-verifier)
                  (lambda () verifier))
                 ((symbol-function 'benedict-provider-gemini--encode-state)
                  (lambda (plist)
                    (setq state-value (funcall orig-encode plist))
                    state-value))
                 ((symbol-function 'benedict-credentials-set)
                  (lambda (provider type entry)
                    (setq credential-set-call (list provider type entry))))
                 ((symbol-function 'browse-url)
                  (lambda (url)
                    (setq opened-url url)))
                 ((symbol-function 'kill-new)
                  (lambda (value)
                    (setq copied-url value)))
                 ((symbol-function 'read-string)
                  (lambda (prompt)
                    (setq read-prompt prompt)
                    (should state-value)
                    (format "%s?code=test-code&state=%s"
                            benedict-provider-gemini-redirect-uri state-value)))
                  ((symbol-function 'benedict-provider-gemini--load-managed-project)
                   (lambda (_access-token) nil))
                  ((symbol-function 'benedict-provider-gemini--token-request)
                   (lambda (_payload)
                     (setq token-request-count (1+ token-request-count))
                     (list :status 200
                           :body (json-encode
                                  `(("access_token" . ,access-token)
                                    ("refresh_token" . ,refresh-token)
                                    ("expires_in" . 120)))))))
        (condition-case err
            (progn
              (benedict-provider-gemini-login)
              (should (equal read-prompt "Paste Gemini redirect URL: "))
              (should opened-url)
              (should (equal opened-url copied-url))
              (should (string-match-p (regexp-quote state-value) opened-url))
              (should (= token-request-count 1))
              (should credential-set-call)
              (should (eq (car credential-set-call) 'gemini))
              (should (eq (cadr credential-set-call) 'oauth))
              (let ((entry (nth 2 credential-set-call)))
                (should (equal (plist-get entry :refresh) refresh-token))
                (should (equal (plist-get entry :access) access-token))
                (should (> (plist-get entry :expires) (float-time))))
              (let ((cached (gethash refresh-token benedict-provider-gemini--token-cache)))
                (should cached)
                (should (equal (plist-get cached :access) access-token))
                (should (> (plist-get cached :expires) (float-time))))
              (delete-directory temp-dir t)
              (funcall done))
          (error
           (delete-directory temp-dir t)
           (funcall done err)))))))

(ert-deftest benedict-provider-gemini-resolve-api-key-mode ()
  "Gemini in api-key mode uses standard resolution."
  (let ((benedict-provider-gemini-auth-method 'api-key))
    (cl-letf (((symbol-function 'benedict-credentials-resolve-api-key)
               (lambda (provider &rest args)
                 (should (eq provider 'gemini))
                 (should (equal (plist-get args :env-var) "GEMINI_API_KEY"))
                 (list :token "api-token-123" :source 'file))))
      (let ((credential (benedict-provider-gemini--resolve-credential)))
        (should (equal (plist-get credential :token) "api-token-123"))
        (should (eq (plist-get credential :source) 'file))))))

(ert-deftest benedict-provider-gemini-refresh-packed-token ()
  "Refresh flow preserves packed project IDs."
  (let ((benedict-provider-gemini--token-cache (make-hash-table :test 'equal))
        (persist-call nil))
    (cl-letf (((symbol-function 'benedict-credentials-get)
               (lambda (_p _t) (list :refresh "old-ref|proj-123|managed-456")))
              ((symbol-function 'benedict-provider-gemini--refresh-access-token)
               (lambda (_ref)
                 (list :access "new-acc" :expires (+ (float-time) 3600) :refresh "new-ref")))
              ((symbol-function 'benedict-credentials-set)
               (lambda (p t entry) (setq persist-call (list p t entry)))))
      (let ((res (benedict-provider-gemini--resolve-credential)))
        (should (equal (plist-get res :access) "new-acc"))
        (should (equal (plist-get (nth 2 persist-call) :refresh) "new-ref|proj-123|managed-456"))))))

(ert-deftest benedict-provider-gemini-fallback-to-managed-id ()
  "When project-id is missing, fallback to managed project-id."
  (let ((benedict-provider-gemini--token-cache (make-hash-table :test 'equal))
        (persist-call nil))
    (cl-letf (((symbol-function 'benedict-credentials-get)
              (lambda (_p _t) (list :refresh "old-ref||managed-456"
                                    :access "old-acc"
                                    :expires (+ (float-time) 1000))))
             ((symbol-function 'benedict-credentials-set)
              (lambda (p t entry) (setq persist-call (list p t entry)))))
      (let ((res (benedict-provider-gemini--resolve-credential)))
        (should (equal (plist-get res :access) "old-acc"))
        (should (equal (plist-get res :project-id) "managed-456"))))))

(ert-deftest benedict-provider-gemini-both-project-ids-present ()
  "When both project-id and managed-project-id are present, prefer project-id."
  (let ((benedict-provider-gemini--token-cache (make-hash-table :test 'equal))
        (persist-call nil))
    (cl-letf (((symbol-function 'benedict-credentials-get)
              (lambda (_p _t) (list :refresh "old-ref|proj-123|managed-456"
                                    :access "old-acc"
                                    :expires (+ (float-time) 1000))))
             ((symbol-function 'benedict-credentials-set)
              (lambda (p t entry) (setq persist-call (list p t entry)))))
      (let ((res (benedict-provider-gemini--resolve-credential)))
        (should (equal (plist-get res :access) "old-acc"))
        (should (equal (plist-get res :project-id) "proj-123"))))))

(ert-deftest benedict-provider-gemini-load-managed-project-when-missing ()
  "When no project IDs are present, load managed project and persist it."
  (let ((benedict-provider-gemini--token-cache (make-hash-table :test 'equal))
        (persist-call nil)
        (load-call nil))
    (cl-letf (((symbol-function 'benedict-credentials-get)
               (lambda (_p _t) (list :refresh "old-ref"
                                     :access "old-acc"
                                     :expires (+ (float-time) 1000))))
              ((symbol-function 'benedict-provider-gemini--load-managed-project)
               (lambda (_access)
                 (setq load-call t)
                 (list :project-id "loaded-123" :current-tier "standard" :allowed-tiers nil)))
              ((symbol-function 'benedict-credentials-set)
               (lambda (p t entry) (setq persist-call (list p t entry)))))
      (let ((res (benedict-provider-gemini--resolve-credential)))
        (should load-call)
        (should (equal (plist-get res :project-id) "loaded-123"))
        (should (equal (plist-get res :access) "old-acc"))
        (should (equal (plist-get (nth 2 persist-call) :refresh) "old-ref||loaded-123"))))))

(ert-deftest benedict-provider-gemini-endpoint-construction ()
  "Endpoint construction matches standard and Cloud Code Assist (v1internal) patterns."
  (let ((model "gemini-test"))
    ;; Non-wrapped (standard)
    (should (equal (benedict-provider-gemini--endpoint-for model nil nil)
                   "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent"))
    ;; Non-wrapped streaming
    (should (equal (benedict-provider-gemini--endpoint-for model t nil)
                   "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:streamGenerateContent"))
    ;; Wrapped (OAuth / Cloud Code Assist)
    (should (equal (benedict-provider-gemini--endpoint-for model nil t)
                   "https://cloudcode-pa.googleapis.com/v1internal:generateContent"))
    ;; Wrapped streaming
    (should (equal (benedict-provider-gemini--endpoint-for model t t)
                   "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent"))))

(provide 'benedict-provider-gemini-test)
;;; benedict-provider-gemini-test.el ends here
