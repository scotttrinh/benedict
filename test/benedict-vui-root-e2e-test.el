;;; benedict-vui-root-e2e-test.el --- End-to-end tests for VUI root -*- lexical-binding: t; -*-

;;; Commentary:
;; Full mounted-root flows using fake provider scripts.

;;; Code:

(require 'ert)
(require 'ert-async)
(require 'vui)
(require 'benedict-message)
(require 'benedict-provider)
(require 'benedict-provider-fake)
(require 'benedict-session)
(require 'benedict-core)
(require 'benedict-vui-root)
(require 'benedict-test-helpers)
(require 'test/benedict-vui-test-utils)

(defun benedict-vui-root-e2e-test--dispatch (session prompt)
  "Submit PROMPT through SESSION for mounted root test flows."
  (benedict-session-add-message
   session
   (benedict-message-user-text prompt))
  (benedict-core-run session))

(defun benedict-vui-root-e2e-test--buffer-text ()
  "Return the mounted buffer text."
  (buffer-string))

(defun benedict-vui-root-e2e-test--messages (session)
  "Return SESSION messages in chronological order."
  (benedict-session-messages-chronological session))

(ert-deftest-async benedict-vui-root-e2e-simple-success-lifecycle (done)
  "Simple success shows user + assistant lifecycle and settles session state."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success :content "Hello there"))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "Ping")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text))
            (messages (benedict-vui-root-e2e-test--messages session)))
        (should (string-match-p "Ping" text))
        (should (string-match-p "Hello there" text))
        (should-not (string-match-p "ACTIVE" text))
        (should (eq (benedict-session-run-state session) 'idle))
        (should (= 2 (length messages))))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-streaming-chunks-incremental-draft (done)
  "Streaming chunks appear incrementally before final assistant message settles."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.08)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Hello" " there")
                    :content "Hello there"))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "Stream please")
      (should
       (benedict-vui-test--wait-until
        (lambda ()
          (let ((text (benedict-vui-root-e2e-test--buffer-text)))
            (and (string-match-p "Hello" text)
                 (not (string-match-p "Hello there" text))
                 (string-match-p "ACTIVE" text))))
        :timeout 2.0))
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "Hello there" text))
        (should-not (string-match-p "ACTIVE" text))
        (should (eq (benedict-session-run-state session) 'idle)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-streaming-tool-calls-show-use-and-result-status (done)
  "Streaming + tool calls render tool use/result blocks with statuses."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.02)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Tooling")
                    :content "Tooling done"
                    :tool-calls (list (list :id "call-1"
                                            :name 'read_file
                                            :arguments '(:path "README.md"))))
              (list :type 'success
                    :content "all finished"))))
    (with-mounted-vui-root
      (setf (benedict-session-tool-invoke-fn session)
            (lambda (_tool-id _arguments)
              "mock tool output"))
      (benedict-vui-root-e2e-test--dispatch session "run tool")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "all finished" text))
        (should (string-match-p "Execution" text))
        (should (string-match-p "read_file" text))
        (should (string-match-p "Show details" text)))
      (benedict-vui-test--click-button-labeled "Show details")
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "Tool: read_file" text))
        (should (string-match-p "Result: read_file" text))
        (should (string-match-p "SUCCESS" text))
        (should (string-match-p "mock tool output" text)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-turn-progression-promotes-answer-and-collapses-execution (done)
  "A streaming turn settles into answer-first history with expandable execution detail."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.08)
       (benedict-provider-fake-script
       (list (list :type 'success
                    :chunks '("Draft")
                    :content "Draft"
                    :thinking "Reasoning details"
                    :tool-calls (list (list :id "call-1"
                                            :name 'read_file
                                            :arguments '(:path "README.md"))))
             (list :type 'success
                   :content "turn complete"))))
    (with-mounted-vui-root
      (setf (benedict-session-tool-invoke-fn session)
            (lambda (_tool-id _arguments)
              "mock tool output"))
      (benedict-vui-root-e2e-test--dispatch session "Inspect README")
      (let ((prompt-id (benedict-message-id
                        (car (benedict-vui-root-e2e-test--messages session)))))
        (should
         (benedict-vui-test--wait-until
          (lambda ()
            (let ((text (benedict-vui-root-e2e-test--buffer-text)))
              (and (string-match-p "Prompt" text)
                   (string-match-p "Inspect README" text)
                   (string-match-p "Activity" text)
                   (string-match-p "Draft answer" text)
                   (string-match-p "Draft" text)
                   (string-match-p "ACTIVE" text))))
          :timeout 2.0))
        (benedict-vui-test--assert-turn-properties-for
         "Prompt"
         :turn-id prompt-id
         :turn-target 'prompt
         :message-key prompt-id)
        (benedict-vui-test--assert-turn-properties-for
         "Activity"
         :turn-id prompt-id
         :turn-target 'activity)
        (should (benedict-vui-test--wait-for-request-finished session 2.0))
        (vui-flush-sync)
        (let* ((text (benedict-vui-root-e2e-test--buffer-text))
               (messages (benedict-vui-root-e2e-test--messages session))
               (assistant-id (benedict-message-id (car (last messages)))))
          (should (string-match-p "Prompt" text))
          (should (string-match-p "Inspect README" text))
          (should (string-match-p "Answer" text))
          (should (string-match-p "turn complete" text))
          (should (string-match-p "Execution" text))
          (should (string-match-p "1 tool | read_file | thinking" text))
          (should (string-match-p "Show details" text))
          (should-not (string-match-p "Activity" text))
          (should-not (string-match-p "Draft answer" text))
          (should-not (string-match-p "Execution details" text))
          (should-not (string-match-p "Result: read_file" text))
          (should-not (string-match-p "ACTIVE" text))
          (benedict-vui-test--assert-turn-properties-for
           "Prompt"
           :turn-id prompt-id
           :turn-target 'prompt
           :message-key prompt-id)
          (benedict-vui-test--assert-turn-properties-for
           "Answer"
           :turn-id prompt-id
           :turn-target 'outcome
           :message-key assistant-id)
          (benedict-vui-test--assert-turn-properties-for
           "Execution"
           :turn-id prompt-id
           :turn-target 'execution-summary))
        (benedict-vui-test--click-button-labeled "Show details")
        (vui-flush-sync)
        (let ((text (benedict-vui-root-e2e-test--buffer-text)))
          (should (string-match-p "Execution details" text))
          (should (string-match-p "Tool: read_file" text))
          (should (string-match-p "Result: read_file" text))
          (should (string-match-p "SUCCESS" text))
          (should (string-match-p "mock tool output" text))
          (benedict-vui-test--assert-turn-properties-for
           "Execution details"
           :turn-id prompt-id
           :turn-target 'execution-details))
        (funcall done)))))

(ert-deftest-async benedict-vui-root-e2e-streaming-thinking-payload-visible (done)
  "Streaming + thinking payload renders the thinking block label."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Answer")
                    :content "Answer"
                    :thinking "Reasoning details"))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "show thinking")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "THINKING" text))
        (should-not (string-match-p "ACTIVE" text)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-provider-model-update-reflects-in-header (done)
  "Provider/model changes from completion render in header badge."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content "ok"
                    :model "anthropic/claude-fake"))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "provider please")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "ANT" text))
        (should (string-match-p "claude-fake" text))
        (should (equal (benedict-session-model session) "anthropic/claude-fake")))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-usage-renders-in-status-bar (done)
  "Usage payload renders tokens and cost in the status bar."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content "usage"
                    :usage '(:total 77 :cost 0.321)))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "usage please")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "77 tokens" text))
        (should (string-match-p "\\$0.3210" text))
        (should (equal (benedict-session-last-usage session)
                       '(:total 77 :cost 0.321))))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-provider-error-stops-streaming-and-renders-error (done)
  "Provider errors surface in UI and clear active streaming indicators."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.02)
       (benedict-provider-fake-script
        (list (list :type 'error :message "Rate limited"))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "fail please")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "Rate limited" text))
        (should-not (string-match-p "ACTIVE" text))
        (should (eq (benedict-session-run-state session) 'error)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-cancel-mid-stream-clears-draft-without-corruption (done)
  "Cancelling mid-stream clears draft/indicator and preserves transcript integrity."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.4)
       (benedict-provider-fake-streaming-chunk-delay 0.1)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Partial" " response")
                    :content "Partial response"))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "cancel me")
      (should
       (benedict-vui-test--wait-until
        (lambda ()
          (string-match-p "ACTIVE" (benedict-vui-root-e2e-test--buffer-text)))
        :timeout 2.0))
      (should (benedict-core-stop session))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text))
            (messages (benedict-vui-root-e2e-test--messages session)))
        (should-not (string-match-p "ACTIVE" text))
        (should (eq (benedict-session-run-state session) 'cancelled))
        (should (= 1 (length messages)))
        (should (equal (benedict-message-text (car messages)) "cancel me")))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-empty-assistant-response-does-not-crash (done)
  "Empty assistant responses keep UI/session stable without streaming residue."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success :content ""))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "empty response")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text))
            (messages (benedict-vui-root-e2e-test--messages session)))
        (should (string-match-p "empty response" text))
        (should-not (string-match-p "ACTIVE" text))
        (should (= 2 (length messages)))
        (should (equal (benedict-message-text (nth 1 messages)) ""))
        (should (eq (benedict-session-run-state session) 'idle)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-multi-turn-continuity-keeps-navigation-stable (done)
  "Multi-turn scripted runs preserve transcript continuity and navigation properties."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success :content "First answer")
              (list :type 'success :content "Second answer")
              (list :type 'success :content "Third answer"))))
    (with-mounted-vui-root
      (let ((first-user-id nil)
            (first-assistant-id nil)
            (second-user-id nil)
            (second-assistant-id nil)
            (third-user-id nil)
            (third-assistant-id nil))
        (benedict-vui-root-e2e-test--dispatch session "First question")
        (should (benedict-vui-test--wait-for-request-finished session 2.0))
        (vui-flush-sync)
        (let ((messages (benedict-vui-root-e2e-test--messages session))
              (text (benedict-vui-root-e2e-test--buffer-text)))
          (should (= 2 (length messages)))
          (setq first-user-id (benedict-message-id (nth 0 messages)))
          (setq first-assistant-id (benedict-message-id (nth 1 messages)))
          (should (string-match-p "First question" text))
          (should (string-match-p "First answer" text))
          (benedict-vui-test--assert-text-properties-for
           "First question"
           :message-key first-user-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "First answer"
           :message-key first-assistant-id
           :region-kind 'body))

        (benedict-vui-root-e2e-test--dispatch session "Second question")
        (should (benedict-vui-test--wait-for-request-finished session 2.0))
        (vui-flush-sync)
        (let ((messages (benedict-vui-root-e2e-test--messages session))
              (text (benedict-vui-root-e2e-test--buffer-text)))
          (should (= 4 (length messages)))
          (setq second-user-id (benedict-message-id (nth 2 messages)))
          (setq second-assistant-id (benedict-message-id (nth 3 messages)))
          (should (equal (benedict-message-id (nth 0 messages)) first-user-id))
          (should (equal (benedict-message-id (nth 1 messages)) first-assistant-id))
          (should (string-match-p "First question" text))
          (should (string-match-p "First answer" text))
          (should (string-match-p "Second question" text))
          (should (string-match-p "Second answer" text))
          (benedict-vui-test--assert-text-properties-for
           "First question"
           :message-key first-user-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "First answer"
           :message-key first-assistant-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "Second question"
           :message-key second-user-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "Second answer"
           :message-key second-assistant-id
           :region-kind 'body))

        (benedict-vui-root-e2e-test--dispatch session "Third question")
        (should (benedict-vui-test--wait-for-request-finished session 2.0))
        (vui-flush-sync)
        (let ((messages (benedict-vui-root-e2e-test--messages session))
              (text (benedict-vui-root-e2e-test--buffer-text)))
          (should (= 6 (length messages)))
          (setq third-user-id (benedict-message-id (nth 4 messages)))
          (setq third-assistant-id (benedict-message-id (nth 5 messages)))
          (should (equal (benedict-message-id (nth 0 messages)) first-user-id))
          (should (equal (benedict-message-id (nth 1 messages)) first-assistant-id))
          (should (equal (benedict-message-id (nth 2 messages)) second-user-id))
          (should (equal (benedict-message-id (nth 3 messages)) second-assistant-id))
          (should (string-match-p "First question" text))
          (should (string-match-p "First answer" text))
          (should (string-match-p "Second question" text))
          (should (string-match-p "Second answer" text))
          (should (string-match-p "Third question" text))
          (should (string-match-p "Third answer" text))
          (benedict-vui-test--assert-text-properties-for
           "First question"
           :message-key first-user-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "First answer"
           :message-key first-assistant-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "Second question"
           :message-key second-user-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "Second answer"
           :message-key second-assistant-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "Third question"
           :message-key third-user-id
           :region-kind 'body)
          (benedict-vui-test--assert-text-properties-for
           "Third answer"
           :message-key third-assistant-id
           :region-kind 'body)
          (should (eq (benedict-session-run-state session) 'idle)))
        (funcall done)))))

(provide 'test/benedict-vui-root-e2e-test)
;;; benedict-vui-root-e2e-test.el ends here
