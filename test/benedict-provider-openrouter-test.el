;;; benedict-provider-openrouter-test.el --- Tests for OpenRouter provider -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-provider)
(require 'benedict-tools)
(require 'benedict-provider-openrouter)
(require 'benedict-provider-vercel)
(require 'benedict-provider-ollama)

(defun benedict-provider-test--json-get (alist key)
  "Return string KEY from JSON-like ALIST."
  (alist-get key alist nil nil #'string=))

(defconst benedict-provider-test--sample-schema
  '(:type object
    :properties
    (:path (:type string :description "Filesystem path.")
     :start (:type integer :description "Optional start line.")
     :end   (:type integer :description "Optional end line."))
    :required (:path))
  "Canonical JSON-Schema snippet used by provider serialization tests.")

(defmacro benedict-provider-openrouter-test--with-clean-state (&rest body)
  "Run BODY with a cleared OpenRouter state table before/after."
  `(unwind-protect
       (progn
         (clrhash benedict-provider-openrouter--state-table)
         ,@body)
     (clrhash benedict-provider-openrouter--state-table)))

(ert-deftest benedict-provider-openrouter-stream-finalizes-from-state ()
  "Streamed usage/reasoning stored in the registry survives to final result."
  (benedict-provider-openrouter-test--with-clean-state
    (let* ((start (current-time))
           (request-id "openrouter-test-req")
           (result nil)
           (context (list :request-id request-id
                          :start-time start
                          :stream-complete nil
                          :on-delta (lambda (&rest _payload))
                          :on-complete (lambda (payload) (setq result payload)))))
      (benedict-provider-openrouter--state-create
       :id request-id
       :provider 'openrouter
       :model "openrouter/test-model"
       :start-time start)
      (should (benedict-provider-openrouter--state-get request-id))
      ;; Content delta
      (benedict-provider-openrouter--stream-handle-json
       context
       (list :id "remote-xyz"
             :model "openrouter/test-model"
             :choices (list (list :index 0
                                  :delta (list :role "assistant" :content "Hello")))))
      (let ((state (benedict-provider-openrouter--state-get request-id)))
        (should (equal (plist-get state :message-chunks) '("Hello"))))
      ;; Reasoning-only delta
      (benedict-provider-openrouter--stream-handle-json
       context
       (list :choices (list (list :index 0
                                  :delta (list :reasoning_details
                                               (list (list :text "think")))))))
      ;; Usage-only final block
      (benedict-provider-openrouter--stream-handle-json
       context (list :usage '((prompt_tokens . 1) (completion_tokens . 2) (total_tokens . 3))))
      (benedict-provider-openrouter--finalize-stream context)
      (should result)
      (should (equal (plist-get result :usage)
                     '((prompt_tokens . 1) (completion_tokens . 2) (total_tokens . 3))))
      (should (equal (plist-get (plist-get result :message) :content) "Hello"))
      (should (plist-get result :thinking))
      (should (numberp (plist-get result :latency)))
      (should (null (benedict-provider-openrouter--state-get request-id))))))

(ert-deftest benedict-provider-openrouter-request-id-shape ()
  "Generated request ids are log-friendly and unique-ish."
  (let ((id (benedict-provider-openrouter--make-request-id)))
    (should (string-match "^openrouter-[0-9]\\{8\\}T[0-9]\\{6\\}Z-[0-9a-f]+$" id))
    (should (not (equal id (benedict-provider-openrouter--make-request-id))))))

(ert-deftest benedict-provider-openrouter-stream-accumulates-tool-calls ()
  "Streamed tool calls split across chunks are reassembled correctly."
  (benedict-provider-openrouter-test--with-clean-state
    (let* ((start (current-time))
           (request-id "openrouter-tool-test")
           (result nil)
           (context (list :request-id request-id
                          :start-time start
                          :stream-complete nil
                          :on-delta (lambda (&rest _payload))
                          :on-complete (lambda (payload) (setq result payload)))))
      (benedict-provider-openrouter--state-create
       :id request-id
       :provider 'openrouter
       :model "openrouter/test-model"
       :start-time start)

      ;; Chunk 1: Tool call start with ID and partial function name
      (benedict-provider-openrouter--stream-handle-json
       context
       (list :choices (list (list :index 0
                                  :delta (list :tool_calls
                                               (list (list :index 0
                                                           :id "call_123"
                                                           :type "function"
                                                           :function (list :name "project-"))))))))

      ;; Chunk 2: Rest of function name and partial arguments
      (benedict-provider-openrouter--stream-handle-json
       context
       (list :choices (list (list :index 0
                                  :delta (list :tool_calls
                                               (list (list :index 0
                                                           :function (list :name "search"
                                                                           :arguments "{\"query\":"))))))))

      ;; Chunk 3: Rest of arguments
      (benedict-provider-openrouter--stream-handle-json
       context
       (list :choices (list (list :index 0
                                  :delta (list :tool_calls
                                               (list (list :index 0
                                                           :function (list :arguments "\"test\"}"))))))))

      ;; Finish stream
      (benedict-provider-openrouter--finalize-stream context)

      (should result)
      (let* ((message (plist-get result :message))
             (tool-calls (plist-get message :tool-calls))
             (call (car tool-calls)))
        (should (equal (plist-get message :content) ""))
        (should (= (length tool-calls) 1))
        (should (equal (plist-get call :id) "call_123"))
        (should (eq (plist-get call :name) 'project-search))
        (should (equal (plist-get call :arguments) (list :query "test")))))))

(ert-deftest benedict-provider-openrouter-shared-schema-and-args-encoders ()
  "OpenRouter tool serialization reuses shared schema + arg encoders."
  (let* ((schema benedict-provider-test--sample-schema)
         (tool (list :id 'openrouter-test :doc "doc" :schema schema))
         (expected (benedict-tool-schema->json-parameters schema))
         (serialized (benedict-provider-openrouter--serialize-tool tool))
         (function (benedict-provider-test--json-get serialized "function")))
    (should function)
    (should (equal (benedict-provider-test--json-get function "parameters")
                   expected)))
  (let* ((args '(:path "foo.txt" :start 1 :end 10))
         (expected-json (benedict-tool-encode-args-json args))
         (call (list :id "call-openrouter" :name 'openrouter-test :arguments args))
         (serialized (benedict-provider-openrouter--serialize-tool-call call))
         (function (benedict-provider-test--json-get serialized "function"))
         (arguments (benedict-provider-test--json-get function "arguments")))
    (should (stringp arguments))
    (should (equal arguments expected-json))))

(ert-deftest benedict-provider-vercel-shared-schema-and-args-encoders ()
  "Vercel tool serialization reuses shared schema + arg encoders."
  (let* ((schema benedict-provider-test--sample-schema)
         (tool (list :id 'vercel-test :doc "doc" :schema schema))
         (expected (benedict-tool-schema->json-parameters schema))
         (serialized (benedict-provider-vercel--serialize-tool tool))
         (function (benedict-provider-test--json-get serialized "function")))
    (should function)
    (should (equal (benedict-provider-test--json-get function "parameters")
                   expected)))
  (let* ((args '(:path "bar.txt" :start 5))
         (expected-json (benedict-tool-encode-args-json args))
         (call (list :id "call-vercel" :name 'vercel-test :arguments args))
         (serialized (benedict-provider-vercel--serialize-tool-call call))
         (function (benedict-provider-test--json-get serialized "function"))
         (arguments (benedict-provider-test--json-get function "arguments")))
    (should (stringp arguments))
    (should (equal arguments expected-json))))

(ert-deftest benedict-provider-ollama-shared-schema-and-args-encoders ()
  "Ollama tool serialization reuses shared schema + arg encoders."
  (let* ((schema benedict-provider-test--sample-schema)
         (tool (list :id 'ollama-test :doc "doc" :schema schema))
         (expected (benedict-tool-schema->json-parameters schema))
         (serialized (benedict-provider-ollama--serialize-tool tool))
         (function (benedict-provider-test--json-get serialized "function")))
    (should function)
    (should (equal (benedict-provider-test--json-get function "parameters")
                   expected)))
  (let* ((args '(:path "baz.txt" :end 99))
         (expected-json (benedict-tool-encode-args-json args))
         (call (list :id "call-ollama" :name 'ollama-test :arguments args))
         (serialized (benedict-provider-ollama--serialize-tool-call call))
         (function (benedict-provider-test--json-get serialized "function"))
         (arguments (benedict-provider-test--json-get function "arguments")))
    (should (stringp arguments))
    (should (equal arguments expected-json))))


(ert-deftest benedict-provider-openrouter-resolve-from-file ()
  "OpenRouter resolves credentials from the filesystem store."
  (let ((temp-dir (make-temp-file "benedict-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'xdg-config-home) (lambda () temp-dir))
                  ((symbol-function 'getenv) (lambda (_) nil))
                  ((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
          (benedict-credentials-set 'openrouter 'api '(:token "file-token-123"))
          (let ((cred (benedict-provider-openrouter--resolve-credential)))
            (should (equal (plist-get cred :token) "file-token-123"))
            (should (eq (plist-get cred :source) 'file))))
      (delete-directory temp-dir t))))

(provide 'benedict-provider-openrouter-test)
;;; benedict-provider-openrouter-test.el ends here
