;;; benedict-chat-session-test.el --- Integration tests for chat and core -*- lexical-binding: t -*-

;;; Commentary:
;; Integration tests for buffer-session binding using the new core runtime.

;;; Code:

(require 'ert)
(require 'ert-async)
(require 'propcheck)
(require 'vui)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-chat)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-core)
(require 'benedict-provider-fake)
(require 'benedict-tools)
(require 'benedict-test-helpers)
(require 'test/benedict-vui-test-utils)

;;; Buffer-Session Binding Tests

(ert-deftest benedict-chat-session-test-init-creates-core-session ()
  "Initializing chat buffer creates and attaches a session via core."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (let ((session benedict-chat--session))
        (should (benedict-session-p session))
        (should (eq (benedict-session-run-state session) 'idle))
        (should (memq (current-buffer) (benedict-session-frontends session)))))))

(ert-deftest-async benedict-chat-session-test-send-runs-core (done)
  "Sending text in chat buffer drives the core loop."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success :content "Core response" :delay 0.02))))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (let ((session benedict-chat--session))
        (benedict-chat--send-text "Hello Core")
        ;; Verify core is running
        (should (eq (benedict-session-run-state session) 'running))
        ;; Wait for completion
        (run-at-time 0.05 nil
                     (lambda ()
                       (should (eq (benedict-session-run-state session) 'idle))
                       (should (= 2 (length (benedict-session-entries session))))
                       (funcall done)))))))

(ert-deftest-async benedict-chat-session-test-streaming-visible (done)
  "Streaming deltas from core are visible in the chat buffer via VUI."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Part A " "Part B")
                    :content "Part A Part B"
                    :chunk-delay 0.05
                    :delay 0.15))))
    (let ((buf (generate-new-buffer "*benedict-streaming-test*")))
      (with-current-buffer buf
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (let ((session benedict-chat--session))
          (benedict-chat--send-text "stream me")
          ;; Wait for first chunk
          (should (benedict-vui-test--wait-until
                   (lambda ()
                     (vui-flush-sync)
                     (string-match-p "Part A" (buffer-string)))
                   :timeout 1.0))
          (should (benedict-session-draft session))
          ;; Wait for finish
          (should (benedict-vui-test--wait-for-request-finished session 1.0))
          (vui-flush-sync)
          (should (string-match-p "Part A Part B" (buffer-string)))
          (should-not (benedict-session-draft session))))
      (kill-buffer buf)
      (funcall done))))

(ert-deftest benedict-chat-session-test-cancel-stops-core ()
  "Cancelling in chat buffer stops the core runtime."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-provider 'fake)
        (benedict-provider-fake-script
         (list (list :type 'success :delay 1.0)))) ; Long delay
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (let ((session benedict-chat--session))
        (benedict-chat--send-text "interrupt me")
        (should (eq (benedict-session-run-state session) 'running))
        (benedict-chat-cancel)
        (should (eq (benedict-session-run-state session) 'cancelled))
        (should-not (benedict-session-inflight session))))))

(provide 'benedict-chat-session-test)
;;; benedict-chat-session-test.el ends here
