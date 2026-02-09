;;; test/benedict-chat-integration-test.el --- Integration tests for Benedict Chat -*- lexical-binding: t; -*-

;;; Commentary:
;; Integration tests for Benedict chat flows using the vui.el UI.

;;; Code:

(require 'ert)
(require 'ert-async)
(require 'cl-lib)
(require 'vui)
(require 'benedict-chat)
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)
(require 'test/benedict-vui-test-utils)

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
        (run-at-time 0.5 nil
                     (lambda ()
                       (with-current-buffer target-buffer
                          (let* ((session benedict-chat--session)
                                 (messages (and session (benedict-session-messages session)))
                                 (user (and messages
                                            (cl-find-if (lambda (msg)
                                                          (eq (plist-get msg :role) 'user))
                                                        messages)))
                                 (assistant (and messages
                                                 (cl-find-if (lambda (msg)
                                                               (eq (plist-get msg :role) 'assistant))
                                                             messages))))
                            (should session)
                            (should user)
                            (should (string-match-p "hello integration"
                                                    (plist-get user :content)))
                            (should assistant)
                            (should (string-match-p "Fake echo: hello integration"
                                                    (plist-get assistant :content)))))
                         (kill-buffer chat-buffer-name)
                         (funcall done)))))))

(ert-deftest-async benedict-chat-integration-chat-command-reactive-streaming-regression (done)
  "Chat command flow stays reactive while session emits lifecycle events."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-chat-buffer-name "*Benedict Test Chat Reactive*")
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.08)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Reactive " "stream")
                    :content "Reactive stream"))))
    (let ((chat-buffer nil)
          (compose-buffer nil)
          (target-session nil)
          (seen-events nil)
          (event-handler nil))
      (save-window-excursion
        (benedict-chat)
        (setq chat-buffer (get-buffer benedict-chat-buffer-name)))
      (should (buffer-live-p chat-buffer))
      (with-current-buffer chat-buffer
        (should benedict-chat--vui-mount)
        (setq target-session benedict-chat--session)
        (setq event-handler
              (lambda (session event-type _payload)
                (when (eq session target-session)
                  (push event-type seen-events)
                  (message "Reactive regression saw event: %s" event-type))))
        (add-hook 'benedict-session-event-hook event-handler)
        (benedict-chat-compose-open)
        (setq compose-buffer (with-current-buffer chat-buffer
                               benedict-chat--compose-buffer))
        (should (buffer-live-p compose-buffer))
        (with-current-buffer compose-buffer
          (goto-char (point-max))
          (insert "prove reactivity")
          (benedict-chat-compose-send))
        (should
         (benedict-vui-test--wait-until
          (lambda ()
            (vui-flush-sync)
            (and (memq 'draft-started seen-events)
                 (let ((text (buffer-string)))
                   (and (string-match-p "prove reactivity" text)
                        (string-match-p "\\bACTIVE\\b" text)
                        (not (string-match-p "Reactive stream" text))))))
          :timeout 2.0))
        (should
         (benedict-vui-test--wait-until
          (lambda ()
            (vui-flush-sync)
            (and (memq 'draft-updated seen-events)
                 (let ((text (buffer-string)))
                   (and (string-match-p "Reactive" text)
                        (not (string-match-p "Reactive stream" text))
                        (string-match-p "\\bACTIVE\\b" text)))))
          :timeout 2.0))
        (should
         (benedict-vui-test--wait-until
          (lambda ()
            (vui-flush-sync)
            (and (memq 'message-added seen-events)
                 (string-match-p "Reactive stream" (buffer-string))))
          :timeout 2.0))
        (should (benedict-vui-test--wait-for-request-finished target-session 2.0))
        (should
         (benedict-vui-test--wait-until
          (lambda ()
            (vui-flush-sync)
            (and (memq 'request-completed seen-events)
                 (>= (cl-count 'state-changed seen-events) 2)
                 (not (string-match-p "\\bACTIVE\\b" (buffer-string)))))
          :timeout 2.0))
        (vui-flush-sync)
        (let* ((ordered-events (nreverse seen-events))
               (draft-started-idx (cl-position 'draft-started ordered-events))
               (draft-updated-idx (and draft-started-idx
                                       (cl-position 'draft-updated
                                                    ordered-events
                                                    :start draft-started-idx)))
               (message-added-idx (and draft-updated-idx
                                       (cl-position 'message-added
                                                    ordered-events
                                                    :start (1+ draft-updated-idx))))
               (request-completed-idx (and message-added-idx
                                           (cl-position 'request-completed
                                                        ordered-events
                                                        :start message-added-idx)))
               (state-changed-count (cl-count 'state-changed ordered-events))
               (text (buffer-string)))
          (should draft-started-idx)
          (should draft-updated-idx)
          (should message-added-idx)
          (should request-completed-idx)
          (should (> state-changed-count 0))
          (should (< draft-started-idx draft-updated-idx))
          (should (< draft-updated-idx message-added-idx))
          (should (< message-added-idx request-completed-idx))
          (should (string-match-p "prove reactivity" text))
          (should (string-match-p "Reactive stream" text))
          (should-not (string-match-p "\\bACTIVE\\b" text)))
        (remove-hook 'benedict-session-event-hook event-handler)
        (kill-buffer chat-buffer)
        (funcall done)))))

(provide 'test/benedict-chat-integration-test)
;;; benedict-chat-integration-test.el ends here
