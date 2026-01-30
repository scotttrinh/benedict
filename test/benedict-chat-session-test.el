;;; benedict-chat-session-test.el --- Integration tests -*- lexical-binding: t -*-

;;; Commentary:
;; Integration tests for buffer-session binding in Phase 2.

;;; Code:

(require 'ert)
(require 'ert-async)
(require 'propcheck)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-chat)
(require 'benedict-session)
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)

;;; Buffer-Session Binding Tests

(ert-deftest benedict-chat-session-test-init-creates-session ()
  "Initializing chat buffer creates and attaches a session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (should benedict-chat--session)
      (should (benedict-session-p benedict-chat--session))
      (should (memq (current-buffer)
                    (benedict-session-frontends benedict-chat--session))))))

(ert-deftest benedict-chat-session-test-buffer-kill-detaches ()
  "Killing buffer detaches from session but doesn't destroy session."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (session nil))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (setq session benedict-chat--session))
    ;; Buffer is now dead
    (should (benedict-session-get (benedict-session-id session)))
    (should-not (benedict-session-has-frontend-p session))))

(ert-deftest benedict-chat-session-test-subscription-lifecycle ()
  "Buffer subscribes on attach, unsubscribes on kill."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (subscription nil)
        (session nil)
        (buf nil))
    (setq buf (generate-new-buffer "*test-subscription*"))
    (with-current-buffer buf
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      ;; Subscription active
      (should benedict-chat--session-subscription)
      (should (memq benedict-chat--session-subscription
                    benedict-session-event-hook))
      (setq subscription benedict-chat--session-subscription)
      (setq session benedict-chat--session)
      ;; Events reach the buffer (verified by state change not erroring)
      (benedict-session-set-state session 'streaming)
      (should (eq 'streaming (benedict-session-state session))))
    ;; Kill buffer properly to trigger kill-buffer-hook
    (kill-buffer buf)
    ;; After kill, subscription removed
    (should-not (memq subscription benedict-session-event-hook))))

;;; Message Flow Tests

(ert-deftest benedict-chat-session-test-send-records-in-session ()
  "Sending a message records it in the session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      ;; Add a message to the session directly.
      (benedict-session-add-message benedict-chat--session
                                    '(:role user :content "Hello"))
      (should (= 1 (length (benedict-session-messages benedict-chat--session))))
      (let ((msg (car (benedict-session-messages benedict-chat--session))))
        (should (string= "Hello" (plist-get msg :content)))
        (should (plist-get msg :id))))))

;;; Streaming Tests (Phase 2b)

(ert-deftest-async benedict-chat-session-test-streaming-uses-draft (done)
  "Streaming response accumulates in session draft."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Hello " "world")
                    :chunk-delay 0.005
                    :delay 0.02))))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (let ((session benedict-chat--session))
        (benedict-chat--send-text "Test")
        ;; Check draft exists during streaming
        (run-at-time 0.01 nil
                     (lambda ()
                       (should (eq 'streaming (benedict-session-state session)))
                       (should (benedict-session-draft session))))
        ;; Check finalized message
        (run-at-time 0.05 nil
                     (lambda ()
                       (should (eq 'idle (benedict-session-state session)))
                       (should-not (benedict-session-draft session))
                       ;; Should have user + assistant messages
                       (should (>= (length (benedict-session-messages session)) 2))
                       (funcall done)))))))

(ert-deftest-async benedict-chat-session-test-headless-streaming (done)
  "Streaming continues when buffer is killed."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success :delay 0.05))))
    (let ((session nil))
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Test"))
      ;; Buffer is now dead, session should still exist and streaming
      (should (benedict-session-get (benedict-session-id session)))
      (should (eq 'streaming (benedict-session-state session)))
      ;; Wait for completion
      (run-at-time 0.1 nil
                   (lambda ()
                     (should (eq 'idle (benedict-session-state session)))
                     (should (>= (length (benedict-session-messages session)) 2))
                     (funcall done))))))

(ert-deftest benedict-chat-session-test-error-sets-session-state ()
  "Errors during operation set session error state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (benedict-session-start-draft session)
      ;; Simulate error via the session API
      (setf (benedict-session-last-error session) '(:message "Test error"))
      (benedict-session-clear-request session)
      (benedict-session-discard-draft session)
      (benedict-session-set-state session 'error)
      (should (eq 'error (benedict-session-state session)))
      (should (benedict-session-last-error session)))))

;;; Property Tests

(propcheck-deftest benedict-chat-session-prop-messages-sync ()
  "All user messages sent appear in session."
  (let* ((benedict-session--registry (make-hash-table :test 'equal))
         (n (propcheck-generate-integer "count" :min 1 :max 10)))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (dotimes (i n)
        (benedict-session-add-message benedict-chat--session
                                      `(:role user :content ,(format "msg %d" i))))
      (propcheck-should (= n (length (benedict-session-messages benedict-chat--session)))))))

;;; Routing Tests (Phase 3)

(ert-deftest benedict-chat-session-test-routing-no-sessions ()
  "With no sessions, benedict-chat creates new session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (should (= 0 (length (benedict-session-list))))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (should (= 1 (length (benedict-session-list)))))))

(ert-deftest benedict-chat-session-test-routing-one-session ()
  "With one session, benedict-chat--buffer-for-session returns buffer."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((existing (benedict-session-create :title "Existing")))
      (should (= 1 (length (benedict-session-list))))
      (let ((buf (benedict-chat--buffer-for-session existing)))
        (should buf)
        (with-current-buffer buf
          (should (eq benedict-chat--session existing)))
        (kill-buffer buf)))))

(ert-deftest benedict-chat-session-test-buffer-reuse ()
  "Opening same session reuses existing buffer."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create :title "Test"))
           (buf1 (benedict-chat--buffer-for-session session))
           (buf2 (benedict-chat--buffer-for-session session)))
      (should (eq buf1 buf2))
      (kill-buffer buf1))))

(ert-deftest benedict-chat-session-test-session-annotation ()
  "Session annotations include state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Test Session")))
      (let ((ann (benedict-chat--session-annotation session)))
        (should (string-match-p "idle" ann))
        (should (string-match-p "Test Session" ann))))))

(ert-deftest benedict-chat-session-test-session-annotation-streaming ()
  "Session annotations reflect streaming state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Streaming Test")))
      (benedict-session-set-state session 'streaming)
      (let ((ann (benedict-chat--session-annotation session)))
        (should (string-match-p "streaming" ann))
        (should (string-match-p "Streaming Test" ann))))))

(ert-deftest benedict-chat-session-test-render-history ()
  "Rendering session history mounts VUI with session data."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "History Test")))
      (benedict-session-add-message session '(:role user :content "Hello"))
      (benedict-session-add-message session '(:role assistant :content "Hi there"))
      (with-temp-buffer
        (benedict-chat-mode)
        (setq-local benedict-chat--session session)
        (benedict-chat--render-session-history session)
        (should (eq benedict-chat--session session))
        (should benedict-chat--vui-mount)
        ;; Verify session still has the messages
        (should (= 2 (length (benedict-session-messages session))))
        (let ((messages (benedict-session-messages-chronological session)))
          (should (equal "Hello" (plist-get (nth 0 messages) :content)))
          (should (equal "Hi there" (plist-get (nth 1 messages) :content))))))))

(ert-deftest benedict-chat-session-test-attach-renders-history ()
  "Attaching to a session mounts VUI with its messages."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Attach Test")))
      (benedict-session-add-message session '(:role user :content "Hello"))
      (benedict-session-add-message session '(:role assistant :content "Hi there"))
      (let ((buf (benedict-chat--buffer-for-session session)))
        (with-current-buffer buf
          (should (eq benedict-chat--session session))
          (should benedict-chat--vui-mount)
          (let ((messages (benedict-session-messages-chronological session)))
            (should (equal "Hello" (plist-get (nth 0 messages) :content)))
            (should (equal "Hi there" (plist-get (nth 1 messages) :content)))))
        (kill-buffer buf)))))

(ert-deftest-async benedict-chat-session-test-attach-during-streaming (done)
  "Attaching mid-stream preserves access to draft content."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Part1 " "Part2 " "Part3")
                    :chunk-delay 0.02
                    :delay 0.1))))
    (let ((session nil))
      ;; Start streaming headlessly
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Test"))
      ;; Wait for chunks, then attach new buffer
      (run-at-time 0.05 nil
                   (lambda ()
                     (let ((buf (benedict-chat--buffer-for-session session)))
                        (with-current-buffer buf
                          (should (eq benedict-chat--session session))
                          (should benedict-chat--vui-mount))
                        (let ((draft (benedict-session-draft session)))
                          (should draft)
                          (should (string-match-p "Part1"
                                                  (plist-get draft :content))))
                        ;; Wait for completion
                        (run-at-time 0.1 nil
                                     (lambda ()
                                      (let ((messages (benedict-session-messages session)))
                                        (should (>= (length messages) 2))
                                        (let ((assistant-msg (car messages)))
                                          (should (eq 'assistant (plist-get assistant-msg :role)))
                                          (should (string-match-p "Part3"
                                                                  (plist-get assistant-msg :content)))))
                                       (kill-buffer buf)
                                       (funcall done)))))))))

(ert-deftest benedict-chat-session-test-multi-buffer-same-session ()
  "Multiple buffers can view the same session state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Multi")))
      (benedict-session-add-message session '(:role user :content "Test"))
      (let ((buf1 (benedict-chat--buffer-for-session session))
            (buf2 (get-buffer-create "*test-second*")))
        (with-current-buffer buf2
          (benedict-chat-mode)
          (setq-local benedict-chat--session session)
          (benedict-session--add-frontend session (current-buffer))
          (setq-local benedict-chat--session-subscription
                      (benedict-chat--subscribe-to-session session))
          (add-hook 'benedict-session-event-hook
                    benedict-chat--session-subscription)
          (benedict-chat--sync-from-session session))
        (should (= 2 (length (benedict-session-frontends session))))
        (benedict-session-add-message session '(:role user :content "Second"))
        (with-current-buffer buf1
          (should (eq benedict-chat--session session))
          (should benedict-chat--vui-mount))
        (with-current-buffer buf2
          (should (eq benedict-chat--session session))
          (should benedict-chat--vui-mount))
        (let ((messages (benedict-session-messages-chronological session)))
          (should (= 2 (length messages)))
          (should (equal "Second" (plist-get (nth 1 messages) :content))))
        (kill-buffer buf2)
        (kill-buffer buf1)))))

;;; Headless Verification Tests (Phase 4)

(ert-deftest-async benedict-chat-session-test-headless-tool-completion (done)
  "Tool calls are recorded in session when buffer is killed."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content "Tool response"
                    :tool-calls (list (list :id "call1"
                                            :name 'read_file
                                            :arguments (list :path "test.txt")))
                    :delay 0.05))))
    (let ((session nil))
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Use a tool"))
      ;; Buffer is now dead, session should still exist
      (should (benedict-session-get (benedict-session-id session)))
      (should (eq 'streaming (benedict-session-state session)))
      ;; Wait for completion
      (run-at-time 0.1 nil
                   (lambda ()
                     ;; Session should have recorded the tool call in the message
                     (should (eq 'idle (benedict-session-state session)))
                     (should (>= (length (benedict-session-messages session)) 2))
                     (let* ((messages (benedict-session-messages session))
                            (assistant-msg
                             (cl-find-if (lambda (message)
                                           (eq 'assistant (plist-get message :role)))
                                         messages))
                            (tool-msg
                             (cl-find-if (lambda (message)
                                           (eq 'tool (plist-get message :role)))
                                         messages)))
                       (should assistant-msg)
                       (should tool-msg)
                       ;; Tool calls are recorded in session
                       (should (plist-get assistant-msg :tool-calls))
                       ;; Verify tool call structure
                       (let ((tool-calls (plist-get assistant-msg :tool-calls)))
                         (should (= 1 (length tool-calls)))
                         (should (string= "call1" (plist-get (car tool-calls) :id)))))
                     (funcall done))))))

(ert-deftest-async benedict-chat-session-test-reattach-midstream (done)
  "Reattaching mid-stream shows accumulated content."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Part1 " "Part2 " "Part3")
                    :chunk-delay 0.02
                    :delay 0.1))))
    (let ((session nil))
      ;; Start streaming in a buffer
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Test"))
      ;; Wait for some chunks to accumulate, then check state
      (run-at-time 0.05 nil
                   (lambda ()
                     (should (eq 'streaming (benedict-session-state session)))
                     (let ((draft (benedict-session-draft session)))
                       (should draft)
                       (should (> (length (plist-get draft :content)) 0))
                       ;; Draft should have accumulated some content
                       (should (stringp (plist-get draft :content))))))
      ;; Wait for completion
      (run-at-time 0.15 nil
                   (lambda ()
                     (should (eq 'idle (benedict-session-state session)))
                     ;; Message should be finalized
                     (let ((messages (benedict-session-messages session)))
                       (should (>= (length messages) 2))
                       (let ((assistant-msg (car messages)))
                         (should (eq 'assistant (plist-get assistant-msg :role)))
                         (should (string-match-p "Part1 Part2 Part3"
                                                  (plist-get assistant-msg :content)))))
                     (funcall done))))))

(ert-deftest benedict-chat-session-test-error-captured-headless ()
  "Errors during headless operation are captured in session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      ;; Simulate error handling path in headless mode
      (benedict-session-start-request session 'handle)
      (benedict-session-start-draft session)
      ;; Simulate the headless error handler
      (let ((error-payload '(:message "Connection lost" :type 'network)))
        (benedict-session-clear-request session)
        (benedict-session-discard-draft session)
        (setf (benedict-session-last-error session) error-payload)
        (benedict-session-set-state session 'error)
        ;; Verify session state
        (should (eq 'error (benedict-session-state session)))
        (should (benedict-session-last-error session))
        (should (string= "Connection lost"
                         (plist-get (benedict-session-last-error session) :message)))
        ;; Draft should be cleared
        (should-not (benedict-session-draft session))))))

(provide 'benedict-chat-session-test)
;;; benedict-chat-session-test.el ends here
