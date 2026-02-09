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
  "Submit PROMPT through SESSION for mounted root tests."
  (benedict-session-add-message
   session
   (list :role 'user
         :content prompt
         :time (current-time)))
  (benedict-session-run session))

(ert-deftest-async benedict-vui-root-e2e-submit-success-updates-ui (done)
  "Submitting through mounted root shows user/assistant flow and metadata updates."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.005)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Hello" " there")
                    :model "vendor/fake-e2e"
                    :usage '(:total 42 :cost 0.125)))))
    (with-mounted-vui-root
      (benedict-vui-root-e2e-test--dispatch session "Ping")
      (vui-flush-sync)
      (should (string-match-p "Ping" (buffer-string)))
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "Hello there" text))
        (should (string-match-p "FAK" text))
        (should (string-match-p "fake-e2e" text))
        (should (string-match-p "42 tokens" text))
        (should-not (string-match-p "ACTIVE" text)))
      (benedict-vui-test--assert-text-properties-for
       "Ping"
       :message-key "msg-001"
       :region-kind 'body)
      (benedict-vui-test--assert-text-properties-for
       "Hello there"
       :message-key "msg-002"
       :region-kind 'body)
      (funcall done))))

(ert-deftest-async benedict-vui-root-e2e-tool-call-produces-tool-blocks (done)
  "Tool calls emitted by fake provider render both tool use and result blocks."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
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
      (let ((text (buffer-string)))
        (should (string-match-p "Tool: read_file" text))
        (should (string-match-p "Result: read_file" text))
        (should (string-match-p "mock tool output" text)))
      (benedict-vui-test--assert-text-properties-for
       "Tool: read_file"
       :message-key "msg-002")
      (benedict-vui-test--assert-text-properties-for
       "mock tool output"
       :message-key "msg-003"
       :region-kind 'tool-ui)
      (funcall done))))

(provide 'test/benedict-vui-root-e2e-test)
;;; benedict-vui-root-e2e-test.el ends here
