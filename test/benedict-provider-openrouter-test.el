;;; benedict-provider-openrouter-test.el --- Tests for OpenRouter provider -*- lexical-binding: t; -*-

(require 'ert)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-provider)
(require 'benedict-provider-openrouter)

(ert-deftest benedict-provider-openrouter-stream-finalizes-from-state ()
  "Streamed usage/reasoning stored in the registry survives to final result."
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
    (should (null (benedict-provider-openrouter--state-get request-id)))))

(ert-deftest benedict-provider-openrouter-request-id-shape ()
  "Generated request ids are log-friendly and unique-ish."
  (let ((id (benedict-provider-openrouter--make-request-id)))
    (should (string-match "^openrouter-[0-9]\\{8\\}T[0-9]\\{6\\}Z-[0-9a-f]+$" id))
    (should (not (equal id (benedict-provider-openrouter--make-request-id))))))

(ert-deftest benedict-provider-openrouter-stream-accumulates-tool-calls ()
  "Streamed tool calls split across chunks are reassembled correctly."
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
      (should (equal (plist-get call :arguments) (list :query "test"))))))


(provide 'benedict-provider-openrouter-test)
;;; benedict-provider-openrouter-test.el ends here
