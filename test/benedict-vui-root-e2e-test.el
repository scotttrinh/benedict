;;; benedict-vui-root-e2e-test.el --- End-to-end tests for VUI root -*- lexical-binding: t; -*-

;;; Commentary:
;; Full mounted-root flows using fake provider scripts.

;;; Code:

(require 'ert)
(require 'ert-async)
(require 'vui)
(require 'benedict-provider)
(require 'benedict-provider-fake)
(require 'benedict-session)
(require 'benedict-vui-root)
(require 'benedict-test-helpers)
(require 'test/benedict-vui-test-utils)

(defun benedict-vui-root-e2e-test--dispatch (session prompt)
  "Submit PROMPT through SESSION for mounted root test flows."
  (benedict-session-add-message
   session
   (list :role 'user
         :content prompt
         :time (current-time)))
  (benedict-session-run session))

(defun benedict-vui-root-e2e-test--buffer-text ()
  "Return the mounted buffer text."
  (buffer-string))

(defun benedict-vui-root-e2e-test--messages (session)
  "Return SESSION messages in chronological order."
  (benedict-session-messages-chronological session))

(ert-deftest-async benedict-vui-root-e2e-simple-success-lifecycle (done)
  "Simple success shows user + assistant lifecycle and settles session state."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
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
        (should (eq (benedict-session-state session) 'idle))
        (should (= 2 (length messages))))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-streaming-chunks-incremental-draft (done)
  "Streaming chunks appear incrementally before final assistant message settles."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
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
        (should (eq (benedict-session-state session) 'idle)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-streaming-tool-calls-show-use-and-result-status (done)
  "Streaming + tool calls render tool use/result blocks with statuses."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.02)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Tooling")
                    :content "Tooling done"
                    :tool-calls (list (list :id "call-1"
                                            :name 'read_file
                                            :arguments '(:path "README.md"))))))
       (benedict-session-tool-invoke-fn
        (lambda (_tool-id _arguments)
          "mock tool output")))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "run tool")
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text)))
        (should (string-match-p "Tooling" text))
        (should (string-match-p "Tool: read_file" text))
        (should (string-match-p "RUNNING" text))
        (should (string-match-p "Result: read_file" text))
        (should (string-match-p "SUCCESS" text))
        (should (string-match-p "mock tool output" text)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-streaming-thinking-payload-visible (done)
  "Streaming + thinking payload renders the thinking block label."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
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
      ((benedict-provider 'fake)
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
      ((benedict-provider 'fake)
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
        (should (eq (benedict-session-state session) 'error)))
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
      (should (benedict-session-cancel session))
      (vui-flush-sync)
      (let ((text (benedict-vui-root-e2e-test--buffer-text))
            (messages (benedict-vui-root-e2e-test--messages session)))
        (should-not (string-match-p "ACTIVE" text))
        (should (eq (benedict-session-state session) 'cancelled))
        (should (= 1 (length messages)))
        (should (equal (plist-get (car messages) :content) "cancel me")))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-empty-assistant-response-does-not-crash (done)
  "Empty assistant responses keep UI/session stable without streaming residue."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
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
        (should (equal (plist-get (nth 1 messages) :content) ""))
        (should (eq (benedict-session-state session) 'idle)))
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-multi-turn-continuity-keeps-navigation-stable (done)
  "Multi-turn scripted runs preserve transcript continuity and navigation properties."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
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
          (setq first-user-id (plist-get (nth 0 messages) :id))
          (setq first-assistant-id (plist-get (nth 1 messages) :id))
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
          (setq second-user-id (plist-get (nth 2 messages) :id))
          (setq second-assistant-id (plist-get (nth 3 messages) :id))
          (should (equal (plist-get (nth 0 messages) :id) first-user-id))
          (should (equal (plist-get (nth 1 messages) :id) first-assistant-id))
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
          (setq third-user-id (plist-get (nth 4 messages) :id))
          (setq third-assistant-id (plist-get (nth 5 messages) :id))
          (should (equal (plist-get (nth 0 messages) :id) first-user-id))
          (should (equal (plist-get (nth 1 messages) :id) first-assistant-id))
          (should (equal (plist-get (nth 2 messages) :id) second-user-id))
          (should (equal (plist-get (nth 3 messages) :id) second-assistant-id))
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
          (should (eq (benedict-session-state session) 'idle)))
        (funcall done)))))

(provide 'test/benedict-vui-root-e2e-test)
;;; benedict-vui-root-e2e-test.el ends here
