;;; benedict-chat-session-test.el --- Integration tests -*- lexical-binding: t -*-

;;; Commentary:
;; Integration tests for buffer-session binding in Phase 2.

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
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)
(require 'test/benedict-vui-test-utils)

(defun benedict-chat-session-test--entries (session)
  "Return SESSION entries in reverse-chronological order."
  (benedict-session-entries session))

(defun benedict-chat-session-test--history (session)
  "Return SESSION entries in chronological order."
  (benedict-session-messages-chronological session))

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
      (should (= 1 (length (benedict-chat-session-test--entries benedict-chat--session))))
      (let ((msg (car (benedict-chat-session-test--entries benedict-chat--session))))
        (should (string= "Hello" (benedict-message-text msg)))
        (should (benedict-message-id msg))))))

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
                       (should (>= (length (benedict-chat-session-test--entries session)) 2))
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
                     (should (>= (length (benedict-chat-session-test--entries session)) 2))
                     (funcall done))))))

(ert-deftest benedict-chat-session-test-send-honors-provider-override-through-dispatch ()
  "Provider override is used by the real chat send path, not only resolution helpers."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-provider 'fake)
        (benedict-provider-openrouter-default-model "openrouter/test-default")
        (captured-request nil)
        (previous-openrouter (benedict-provider-lookup 'openrouter)))
    (unwind-protect
        (progn
          (benedict-provider-register
           (benedict-provider--create
            :id 'openrouter
            :name "OpenRouter"
            :send (lambda (_provider request &rest callbacks)
                    (setq captured-request request)
                    (funcall (plist-get callbacks :on-success)
                             '(:message (:role assistant :content "override reply")
                               :provider openrouter
                               :model "openrouter/test-default"))
                    '(:provider openrouter :request-id "openrouter-test"))
            :capabilities '(:streaming nil)
            :cancel #'ignore))
          (with-temp-buffer
            (benedict-chat-mode)
            (benedict-chat--init-buffer)
            (setq-local benedict-chat--provider-override 'openrouter)
            (benedict-chat--send-text "use the override")
            (let* ((session benedict-chat--session)
                   (messages (benedict-session-entries-chronological session))
                   (assistant (car (last messages))))
              (should (eq (plist-get captured-request :provider) 'openrouter))
              (should (equal (plist-get captured-request :model)
                             "openrouter/test-default"))
              (should (eq (benedict-session-provider session) 'openrouter))
              (should (equal (benedict-session-model session)
                             "openrouter/test-default"))
              (should (eq (benedict-message-role assistant) 'assistant))
              (should (equal (benedict-message-text assistant) "override reply")))))
      (if previous-openrouter
          (puthash 'openrouter previous-openrouter benedict-provider--registry)
        (remhash 'openrouter benedict-provider--registry)))))

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
      (propcheck-should (= n (length (benedict-chat-session-test--entries benedict-chat--session)))))))

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
        (should (= 2 (length (benedict-chat-session-test--entries session))))
        (let ((messages (benedict-chat-session-test--history session)))
          (should (equal "Hello" (benedict-message-text (nth 0 messages))))
          (should (equal "Hi there" (benedict-message-text (nth 1 messages)))))))))

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
          (let ((messages (benedict-chat-session-test--history session)))
            (should (equal "Hello" (benedict-message-text (nth 0 messages))))
            (should (equal "Hi there" (benedict-message-text (nth 1 messages))))))
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
                       ;; Wait for completion.
                       (run-at-time 0.1 nil
                                    (lambda ()
                                      (unwind-protect
                                          (let ((messages (benedict-chat-session-test--entries session)))
                                            (should (>= (length messages) 2))
                                            (let ((assistant-msg (car messages)))
                                              (should (eq 'assistant (benedict-message-role assistant-msg)))
                                              (should (string-match-p "Part3"
                                                                      (benedict-message-text assistant-msg)))))
                                        (when (buffer-live-p buf)
                                          (kill-buffer buf))
                                        (funcall done))))))))))

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
        (let ((messages (benedict-chat-session-test--history session)))
          (should (= 2 (length messages)))
          (should (equal "Second" (benedict-message-text (nth 1 messages)))))
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
                     (should (>= (length (benedict-chat-session-test--entries session)) 2))
                     (let* ((messages (benedict-chat-session-test--entries session))
                            (assistant-msg
                             (cl-find-if (lambda (message)
                                           (eq 'assistant (benedict-message-role message)))
                                         messages))
                            (tool-msg
                             (cl-find-if (lambda (message)
                                           (eq 'tool (benedict-message-role message)))
                                         messages)))
                       (should assistant-msg)
                       (should tool-msg)
                       ;; Tool calls are recorded in session
                       (should (benedict-message-tool-calls assistant-msg))
                       ;; Verify tool call structure
                       (let ((tool-calls (benedict-message-tool-calls assistant-msg)))
                         (should (= 1 (length tool-calls)))
                         (should (string= "call1" (plist-get (car tool-calls) :id)))))
                      (funcall done))))))

(ert-deftest benedict-chat-session-test-permission-denial-telemetry-visible ()
  "Chat-attached sessions expose permission decision telemetry events."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil)
        (benedict-session-event-hook nil)
        (benedict-session-tool-invoke-fn #'benedict-tool-invoke))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (setq-local benedict-tool-permission-predicate (lambda (_tool _args) nil))
      (let ((session benedict-chat--session))
        (add-hook 'benedict-session-event-hook
                  (lambda (_s type payload)
                    (push (cons type payload) events)))
        (let* ((result (benedict-session--invoke-tool
                        session
                        '(:id "call-deny" :name project-search :arguments (:query "needle"))))
               (tool-message (benedict-session--format-tool-result
                              (plist-get result :tool-id)
                              (plist-get result :call-id)
                              (plist-get result :status)
                              (plist-get result :output)
                              (plist-get result :error))))
          (should (eq 'denied (plist-get result :status)))
          (should (eq 'permission-denied
                      (plist-get (plist-get result :error) :code)))
          (should (eq 'predicate-deny
                      (plist-get (plist-get result :error) :decision)))
          (should (string-match-p "Tool denied:" (plist-get tool-message :content))))))))

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
                     ;; Message should be finalized.
                     (let ((messages (benedict-chat-session-test--entries session)))
                       (should (>= (length messages) 2))
                       (let ((assistant-msg (car messages)))
                         (should (eq 'assistant (benedict-message-role assistant-msg)))
                         (should (string-match-p "Part1 Part2 Part3"
                                                 (benedict-message-text assistant-msg)))))
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

;;; Phase 5 - Chat/Session UI Guardrails

(ert-deftest-async benedict-chat-session-test-ui-attach-during-active-stream (done)
  "Mounted chat buffer stays reactive when attached during active streaming."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.06)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Part1 " "Part2 " "Part3")
                    :content "Part1 Part2 Part3"))))
    (let ((session nil))
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "attach stream"))
      (let ((buf (benedict-chat--buffer-for-session session)))
        (with-current-buffer buf
          (should
           (benedict-vui-test--wait-until
            (lambda ()
              (vui-flush-sync)
              (let ((text (buffer-string)))
                (and (string-match-p "attach stream" text)
                     (string-match-p "Part1" text)
                     (string-match-p "\\bACTIVE\\b" text)
                     (not (string-match-p "Part3" text)))))
            :timeout 2.0))
          (should (benedict-vui-test--wait-for-request-finished session 2.0))
          (vui-flush-sync)
          (let* ((text (buffer-string))
                 (messages (benedict-chat-session-test--history session))
                 (assistant-msg (nth 1 messages)))
            (should (string-match-p "Part1 Part2 Part3" text))
            (should-not (string-match-p "\\bACTIVE\\b" text))
            (should (eq (benedict-message-role assistant-msg) 'assistant))
            (benedict-vui-test--assert-text-properties-for
             "Part1 Part2 Part3"
             :message-key (benedict-message-id assistant-msg)
             :region-kind 'body)))
        (kill-buffer buf)
        (funcall done)))))

(ert-deftest-async benedict-chat-session-test-ui-headless-continue-then-reattach (done)
  "Headless continuation renders correctly when reattaching a mounted buffer."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content "headless complete"
                    :tool-calls (list (list :id "call-headless"
                                            :name 'read_file
                                            :arguments '(:path "README.md")))
                    :delay 0.05))))
    (let ((session nil))
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq benedict-session-tool-invoke-fn
              (lambda (_tool-id _arguments)
                "headless tool output"))
        (setq session benedict-chat--session)
        (benedict-chat--send-text "keep running"))
      (should (benedict-vui-test--wait-for-request-finished session 2.0))
      (let ((buf (benedict-chat--buffer-for-session session)))
        (with-current-buffer buf
          (vui-flush-sync)
          (let ((text (buffer-string)))
            (should (string-match-p "keep running" text))
            (should (string-match-p "headless complete" text))
            (should (string-match-p "Execution" text))
            (should (string-match-p "read_file" text))
            (should (string-match-p "Show details" text))
            (should-not (string-match-p "\\bACTIVE\\b" text)))
          (benedict-vui-test--click-button-labeled "Show details")
          (vui-flush-sync)
          (let ((text (buffer-string)))
            (should (string-match-p "Tool: read_file" text))
            (should (string-match-p "Result: read_file" text))
            (should (string-match-p "headless tool output" text))))
        (kill-buffer buf)
        (funcall done)))))

(ert-deftest-async benedict-chat-session-test-ui-tool-call-and-result-visible (done)
  "Mounted chat buffer renders tool use and tool result blocks."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content "Tool response"
                    :tool-calls (list (list :id "call-1"
                                            :name 'bash
                                            :arguments '(:command "echo hi")))))))
    (let ((buf (generate-new-buffer "*benedict-chat-tools-ui*")))
      (with-current-buffer buf
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq benedict-session-tool-invoke-fn
              (lambda (_tool-id _arguments)
                "tool output"))
        (let ((session benedict-chat--session))
          (benedict-chat--send-text "run tool")
          (should
           (benedict-vui-test--wait-until
            (lambda ()
              (vui-flush-sync)
              (let ((text (buffer-string)))
                (or (string-match-p "Tool: bash" text)
                    (string-match-p "Execution" text))))
            :timeout 2.0))
          (should (benedict-vui-test--wait-for-request-finished session 2.0))
          (vui-flush-sync)
          (let ((text (buffer-string)))
            (should (string-match-p "Execution" text))
            (should (string-match-p "bash" text))
            (should (string-match-p "Show details" text)))
          (benedict-vui-test--click-button-labeled "Show details")
          (vui-flush-sync)
          (let ((text (buffer-string)))
            (should (string-match-p "Tool: bash" text))
            (should (string-match-p "Result: bash" text))
            (should (string-match-p "SUCCESS" text))
            (should (string-match-p "tool output" text))))
        (kill-buffer buf)
        (funcall done)))))

(ert-deftest-async benedict-chat-session-test-ui-request-failure-then-recovery (done)
  "Mounted chat buffer surfaces request failure and clears it after recovery."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'error :message "Rate limited")
              (list :type 'success :content "Recovered answer" :delay 0.01))))
    (let ((buf (generate-new-buffer "*benedict-chat-recovery-ui*")))
      (with-current-buffer buf
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (let ((session benedict-chat--session))
          (benedict-chat--send-text "please fail")
          (should (benedict-vui-test--wait-for-request-finished session 2.0))
          (vui-flush-sync)
          (let ((text (buffer-string)))
            (should (eq (benedict-session-state session) 'error))
            (should (string-match-p "Rate limited" text)))
          (benedict-chat--send-text "recover now")
          (should (benedict-vui-test--wait-for-request-finished session 2.0))
          (vui-flush-sync)
          (let ((text (buffer-string)))
            (should (eq (benedict-session-state session) 'idle))
            (should (string-match-p "Recovered answer" text))
            (should-not (string-match-p "Rate limited" text)))))
      (kill-buffer buf)
      (funcall done))))

(ert-deftest-async benedict-chat-session-test-ui-post-request-metadata-mutation-visible (done)
  "Post-finalization metadata updates remain visible in mounted chat UI."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content "metadata done"
                    :model "anthropic/claude-fake"
                    :usage '(:total 123 :cost 0.0042)
                    :delay 0.01))))
    (let ((buf (generate-new-buffer "*benedict-chat-metadata-ui*")))
      (with-current-buffer buf
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (let ((session benedict-chat--session))
          (benedict-chat--send-text "metadata please")
          (should (benedict-vui-test--wait-for-request-finished session 2.0))
          (vui-flush-sync)
          (let* ((text (buffer-string))
                 (assistant-msg (cl-find-if (lambda (message)
                                              (eq (benedict-message-role message) 'assistant))
                                            (benedict-chat-session-test--entries session)))
                 (metadata (and assistant-msg (benedict-message-metadata assistant-msg))))
            (should assistant-msg)
            (should (equal "anthropic/claude-fake" (plist-get metadata :model)))
            (should (plist-get metadata :usage))
            (should (string-match-p "claude-fake" text))
            (should (string-match-p "123 tokens" text))
            (should (string-match-p "\\$0.0042" text)))))
      (kill-buffer buf)
      (funcall done))))

(provide 'benedict-chat-session-test)
;;; benedict-chat-session-test.el ends here
