;;; test/benedict-chat-integration-test.el --- Integration tests for Benedict Chat -*- lexical-binding: t; -*-

(require 'ert)
(require 'ert-async)
(require 'benedict-chat)
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)

(ert-deftest-async benedict-chat-integration-flow (done)
  "Test full chat flow from user prompt to assistant response."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-chat-buffer-name "*Benedict Test Chat*")
       (benedict-provider-fake-latency-seconds 0.01))
    (with-current-buffer (get-buffer-create benedict-chat-buffer-name)
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (let ((target-buffer (current-buffer))
            (chat-buffer-name benedict-chat-buffer-name))
        (benedict-chat-send-prompt "hello integration")
        
        ;; Verify user message inserted immediately
        (goto-char (point-min))
        (should (search-forward "[USER]" nil t))
        (should (search-forward "hello integration" nil t))
        
        ;; Wait for assistant response
        (run-at-time 0.5 nil
                     (lambda ()
                       (with-current-buffer target-buffer
                         (goto-char (point-min))
                         (should (search-forward "[ASSISTANT]" nil t))
                         (should (search-forward "Fake echo: hello integration" nil t))
                         ;; Check regions are correct
                         (goto-char (point-min))
                         (search-forward "Fake echo")
                         (should (eq (get-text-property (point) 'benedict-region-kind) 'body)))
                       (kill-buffer chat-buffer-name)
                       (funcall done)))))))

(provide 'test/benedict-chat-integration-test)
;;; benedict-chat-integration-test.el ends here
