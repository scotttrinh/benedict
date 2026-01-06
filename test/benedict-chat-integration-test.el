;;; test/benedict-chat-integration-test.el --- Integration tests for Benedict Chat -*- lexical-binding: t; -*-

(require 'ert)
(require 'ert-async)
(require 'cl-lib)
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

(ert-deftest benedict-chat-integration-streaming-preserves-body-across-header-refresh ()
  "Streaming should append into the assistant body region even as headers refresh."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-script nil))
    (with-temp-buffer
      (rename-buffer "*Benedict Streaming Integration*" t)
      (benedict-chat-mode)
      (benedict-chat--init-buffer)

      ;; Avoid real timers; we manually call `benedict-chat--status-tick' to
      ;; simulate header refresh interleaving with delta insertions.
      (cl-letf (((symbol-function 'benedict-chat--status-start-timer) #'ignore)
                ((symbol-function 'benedict-chat--status-refresh) #'ignore))
        (let* ((request (list :provider 'fake :model "fake-model" :messages nil))
               (benedict-chat--request-seq 0)
               (benedict-chat--active-request-id 1)
               (benedict-chat--last-dispatch (list :request request :timestamp (current-time))))
          (benedict-chat--telemetry-begin request)
          (benedict-chat--record-message (current-buffer)
                                         (list :role 'user :content "hi" :time (current-time)))

          (benedict-chat--handle-provider-delta
           (current-buffer)
           (list :kind 'content-delta :provider 'fake :model "fake-model" :text "Hello **bo"))

          (let* ((assistant (cl-find-if (lambda (msg) (eq (plist-get msg :role) 'assistant))
                                        benedict-chat--messages))
                 (item (plist-get assistant :item))
                 (body (lambda ()
                         (buffer-substring-no-properties
                          (marker-position (plist-get item :content-start))
                          (marker-position (plist-get item :content-end))))))
            (should assistant)
            (should item)
            (should (string= (funcall body) "Hello **bo"))

            ;; Timer tick updates the header while stream is in-flight.
            (benedict-chat--status-tick (current-buffer))
            (should (string= (funcall body) "Hello **bo"))

            (benedict-chat--handle-provider-delta
             (current-buffer)
             (list :kind 'content-delta :provider 'fake :model "fake-model" :text "ld**"))
            (should (string= (funcall body) "Hello **bold**"))

            (benedict-chat--status-tick (current-buffer))
            (should (string= (funcall body) "Hello **bold**"))

            ;; Completion updates metadata + replaces the body with final content.
            (benedict-chat--handle-provider-success
             (current-buffer)
             (list :provider 'fake
                   :model "fake-model"
                   :latency 0.42
                   :usage '(("prompt_tokens" . 10)
                            ("completion_tokens" . 20)
                            ("total_tokens" . 30)
                            ("cost" . 0.0123))
                   :message (list :role 'assistant :content "Hello **bold**")))

            (should (string= (funcall body) "Hello **bold**"))
            ;; Completion should preserve markdown-mode styling.  This can be
            ;; lost if we rewrite the body without re-fontifying it.
            (save-excursion
              (goto-char (marker-position (plist-get item :content-start)))
              (should (search-forward "bold" (marker-position (plist-get item :content-end)) t))
              (let* ((pos (match-beginning 0))
                     (face (or (get-text-property pos 'face)
                               (get-text-property pos 'font-lock-face))))
                (should face)
                (should (or (eq face 'markdown-bold-face)
                            (and (listp face) (memq 'markdown-bold-face face))))))))
            (goto-char (point-min))
            (should (search-forward "[USER]" nil t))
            (should (search-forward "hi" nil t))
            (should (search-forward "[ASSISTANT]" nil t))
            (should (search-forward "Hello **bold**" nil t))))))

(ert-deftest benedict-chat-integration-streaming-header-refresh-moves-point-to-message-end ()
  "Header refresh should leave point at the end of the in-flight message body."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-script nil))
    (with-temp-buffer
      (rename-buffer "*Benedict Streaming Point Integration*" t)
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (cl-letf (((symbol-function 'benedict-chat--status-start-timer) #'ignore)
                ((symbol-function 'benedict-chat--status-refresh) #'ignore))
        (let* ((request (list :provider 'fake :model "fake-model" :messages nil))
               (benedict-chat--request-seq 0)
               (benedict-chat--active-request-id 1)
               (benedict-chat--last-dispatch (list :request request :timestamp (current-time))))
          (benedict-chat--telemetry-begin request)
          (benedict-chat--handle-provider-delta
           (current-buffer)
           (list :kind 'content-delta :provider 'fake :model "fake-model" :text "Hello"))
          (let* ((assistant (cl-find-if (lambda (msg) (eq (plist-get msg :role) 'assistant))
                                        benedict-chat--messages))
                 (item (plist-get assistant :item))
                 (body-end (plist-get item :content-end)))
            (should assistant)
            (should item)
            (should (markerp body-end))
            ;; Put point somewhere that will obviously change if the header
            ;; rewrite doesn't preserve it.
            (goto-char (point-min))
            (benedict-chat--status-tick (current-buffer))
            (should (= (point) (marker-position body-end)))))))))

(ert-deftest benedict-chat-integration-streaming-delta-targets-stable-buffer ()
  "Streaming deltas should land in the chat buffer even if the user switches buffers."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-script nil)
        (chat-buffer (generate-new-buffer "*Benedict Buffer Switch Integration*"))
        (other-buffer (generate-new-buffer "*Benedict Other Buffer*")))
    (unwind-protect
        (with-current-buffer chat-buffer
          (benedict-chat-mode)
          (benedict-chat--init-buffer)
          (cl-letf (((symbol-function 'benedict-chat--status-start-timer) #'ignore)
                    ((symbol-function 'benedict-chat--status-refresh) #'ignore))
            (let* ((request (list :provider 'fake :model "fake-model" :messages nil))
                   (benedict-chat--request-seq 0)
                   (benedict-chat--active-request-id 1)
                   (benedict-chat--last-dispatch (list :request request :timestamp (current-time))))
              (benedict-chat--telemetry-begin request)
              (with-current-buffer other-buffer
                (benedict-chat--handle-provider-delta
                 chat-buffer
                 (list :kind 'content-delta :provider 'fake :model "fake-model"
                       :text "Hello from delta"))))
            (with-current-buffer chat-buffer
              (goto-char (point-min))
              (should (search-forward "[ASSISTANT]" nil t))
              (should (search-forward "Hello from delta" nil t)))
            (with-current-buffer other-buffer
              (goto-char (point-min))
              (should-not (search-forward "Hello from delta" nil t)))))
      (when (buffer-live-p other-buffer)
        (kill-buffer other-buffer))
      (when (buffer-live-p chat-buffer)
        (kill-buffer chat-buffer)))))

(ert-deftest benedict-chat-integration-tool-update-targets-stable-buffer ()
  "Tool UI updates should land in the chat buffer even if the user switches buffers."
  (let ((chat-buffer (generate-new-buffer "*Benedict Tool Update Integration*"))
        (other-buffer (generate-new-buffer "*Benedict Tool Update Other*")))
    (unwind-protect
        (with-current-buffer chat-buffer
          (benedict-chat-mode)
          (benedict-chat--init-buffer)
          (cl-letf (((symbol-function 'benedict-chat--status-start-timer) #'ignore)
                    ((symbol-function 'benedict-chat--status-refresh) #'ignore))
            (let* ((call (list :id "call-1" :name "demo" :arguments '(:foo "bar")))
                   (metadata (list :status 'running :provider 'fake))
                   (item (benedict-chat--record-tool-block chat-buffer call metadata)))
              (with-current-buffer other-buffer
                (benedict-chat--update-tool-block
                 chat-buffer
                 item
                 (list :status 'success :provider 'fake)
                 (list :body "Tool updated")
                 "Tool fallback"))
              (with-current-buffer chat-buffer
                (goto-char (point-min))
                (should (search-forward "Tool updated" nil t)))
              (with-current-buffer other-buffer
                (goto-char (point-min))
                (should-not (search-forward "Tool updated" nil t))))))
      (when (buffer-live-p other-buffer)
        (kill-buffer other-buffer))
      (when (buffer-live-p chat-buffer)
        (kill-buffer chat-buffer)))))

(ert-deftest benedict-chat-integration-thinking-update-targets-stable-buffer ()
  "Thinking updates should land in the chat buffer even if the user switches buffers."
  (let ((chat-buffer (generate-new-buffer "*Benedict Thinking Update Integration*"))
        (other-buffer (generate-new-buffer "*Benedict Thinking Update Other*")))
    (unwind-protect
        (with-current-buffer chat-buffer
          (benedict-chat-mode)
          (benedict-chat--init-buffer)
          (let* ((metadata (list :provider 'fake))
                 (item (benedict-chat--record-thinking chat-buffer "" metadata)))
            (with-current-buffer other-buffer
              (benedict-chat--write-thinking-content chat-buffer item "Thinking update" t))
            (with-current-buffer chat-buffer
              (goto-char (point-min))
              (should (search-forward "Thinking update" nil t)))
            (with-current-buffer other-buffer
              (goto-char (point-min))
              (should-not (search-forward "Thinking update" nil t)))))
      (when (buffer-live-p other-buffer)
        (kill-buffer other-buffer))
      (when (buffer-live-p chat-buffer)
        (kill-buffer chat-buffer)))))

(ert-deftest benedict-chat-integration-streaming-finalization-targets-stable-buffer ()
  "Streaming success/error callbacks should land in the chat buffer even if the user switches buffers."
  (cl-labels
      ((run-case (chat-name finish-fn expected-text)
         (let ((chat-buffer (generate-new-buffer chat-name))
               (other-buffer (generate-new-buffer (concat chat-name " Other"))))
           (unwind-protect
               (with-current-buffer chat-buffer
                 (benedict-chat-mode)
                 (benedict-chat--init-buffer)
                 (cl-letf (((symbol-function 'benedict-chat--status-start-timer) #'ignore)
                           ((symbol-function 'benedict-chat--status-refresh) #'ignore))
                   (let* ((request (list :provider 'fake :model "fake-model" :messages nil))
                          (benedict-chat--request-seq 0)
                          (benedict-chat--active-request-id 1)
                          (benedict-chat--last-dispatch (list :request request :timestamp (current-time))))
                     (benedict-chat--telemetry-begin request)
                     (benedict-chat--handle-provider-delta
                      chat-buffer
                      (list :kind 'content-delta :provider 'fake :model "fake-model"
                            :text "Partial"))
                     (with-current-buffer other-buffer
                       (funcall finish-fn chat-buffer))
                     (with-current-buffer chat-buffer
                       (goto-char (point-min))
                       (should (search-forward expected-text nil t)))
                     (with-current-buffer other-buffer
                       (goto-char (point-min))
                       (should-not (search-forward expected-text nil t)))))
             (when (buffer-live-p other-buffer)
               (kill-buffer other-buffer))
             (when (buffer-live-p chat-buffer)
               (kill-buffer chat-buffer)))))
    (run-case "*Benedict Stream Success*" 
              (lambda (buffer)
                (benedict-chat--handle-provider-success
                 buffer
                 (list :provider 'fake
                       :model "fake-model"
                       :message (list :role 'assistant :content "Final success"))))
              "Final success")
    (run-case "*Benedict Stream Error*"
              (lambda (buffer)
                (benedict-chat--handle-provider-error
                 buffer
                 (list :provider 'fake :message "Oops error")))
              "Oops error")))))

(ert-deftest benedict-chat-integration-inserts-blank-line-between-blocks ()
  "Rendering adjacent blocks should include a blank line between them."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-script nil))
    (with-temp-buffer
      (rename-buffer "*Benedict Block Gap Integration*" t)
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (cl-letf (((symbol-function 'benedict-chat--status-start-timer) #'ignore)
                ((symbol-function 'benedict-chat--status-refresh) #'ignore))
        (let* ((request (list :provider 'fake :model "fake-model" :messages nil))
               (benedict-chat--request-seq 0)
               (benedict-chat--active-request-id 1)
               (benedict-chat--last-dispatch (list :request request :timestamp (current-time))))
          (benedict-chat--telemetry-begin request)
          (benedict-chat--record-message (current-buffer)
                                         (list :role 'user :content "hi" :time (current-time)))
          (benedict-chat--handle-provider-delta
           (current-buffer)
           (list :kind 'content-delta :provider 'fake :model "fake-model" :text "Hello"))

          (let* ((assistant (cl-find-if (lambda (msg) (eq (plist-get msg :role) 'assistant))
                                        benedict-chat--messages))
                 (assistant-item (plist-get assistant :item))
                 (tool-item (benedict-chat--record-tool-block
                             (current-buffer)
                             (list :id "call-1" :name 'demo :arguments '(:foo "bar"))
                             (list :status 'running)))
                 (assistant-end (plist-get assistant-item :end))
                 (tool-start (plist-get tool-item :start)))
            (should assistant)
            (should assistant-item)
            (should tool-item)
            (should (markerp assistant-end))
            (should (markerp tool-start))
            (should (string=
                     (buffer-substring-no-properties
                      (marker-position assistant-end)
                      (marker-position tool-start))
                     "\n\n"))))))))

(ert-deftest benedict-chat-integration-header-precedes-messages ()
  "Buffer header should stay above the first rendered message."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-script nil))
    (with-temp-buffer
      (rename-buffer "*Benedict Header Ordering Integration*" t)
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (benedict-chat--record-message (current-buffer)
                                     (list :role 'user :content "hi" :time (current-time)))
      (cl-labels ((find-pos (needle)
                    (save-excursion
                      (goto-char (point-min))
                      (when (search-forward needle nil t)
                        (- (point) (length needle))))))
        (let ((header-pos (find-pos "Benedict Chat"))
              (user-pos (find-pos "[USER]")))
          (should header-pos)
          (should user-pos)
          (should (< header-pos user-pos)))))))

(ert-deftest-async benedict-chat-integration-agent-run-preserves-ordering (done)
  "Streaming agent runs keep user, assistant, thinking, and tool blocks ordered."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.01)
       (benedict-provider-fake-script
        (list
         (list :type 'success
               :content "Final response"
               :chunks (list "Final " "response")
               :thinking (list (list :id "benedict-thinking-1-stream"
                                     :type "reasoning.text"
                                     :chunks (list "Thinking " "chunk")))
               :tool-calls (list (list :id "call-1"
                                       :name 'demo-tool
                                       :arguments '(:foo "bar"))))))
       ((symbol-function benedict-tool-invoke)
        (lambda (&rest _args) "Tool output"))
       ((symbol-function benedict-chat--loop-step) (lambda (&rest _args) nil)))
    (let ((buffer (generate-new-buffer "*Benedict Agent Ordering*")))
      (unwind-protect
          (with-current-buffer buffer
            (benedict-chat-mode)
            (benedict-chat--init-buffer)
            (benedict-chat-send-prompt "User prompt")
            (let ((deadline (+ (float-time) 1.0)))
              (while (and benedict-chat--pending-request
                          (< (float-time) deadline))
                (accept-process-output nil 0.01)))
            (should-not benedict-chat--pending-request)
            (cl-labels ((find-pos (needle)
                          (save-excursion
                            (goto-char (point-min))
                            (when (search-forward needle nil t)
                              (- (point) (length needle))))))
              (let ((user-pos (find-pos "User prompt"))
                    (assistant-pos (find-pos "Final response"))
                    (thinking-pos (find-pos "Thinking chunk"))
                    (tool-header-pos (find-pos "demo-tool"))
                    (tool-output-pos (find-pos "Tool output")))
                (should user-pos)
                (should assistant-pos)
                (should thinking-pos)
                (should tool-header-pos)
                (should tool-output-pos)
                (should (< user-pos assistant-pos))
                (should (< assistant-pos thinking-pos))
                (should (< thinking-pos tool-header-pos))
                (should (< tool-header-pos tool-output-pos)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (funcall done))))

(ert-deftest benedict-chat-section-end-marker-advances ()
  "Parent section end markers should advance as new blocks are inserted."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-script nil))
    (with-temp-buffer
      (rename-buffer "*Benedict Section End Integration*" t)
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (let* ((root benedict-chat--conversation-section)
             (root-end (and root (ignore-errors (oref root end))))
             (after-first nil))
        (should (benedict-chat--section-p root))
        (should (markerp root-end))
        (let ((initial (marker-position root-end)))
          (benedict-chat--record-message
           (current-buffer)
           (list :role 'user :content "first" :time (current-time)))
          (setq after-first (marker-position root-end))
          (should (< initial after-first))
          (benedict-chat--record-message
           (current-buffer)
           (list :role 'assistant :content "second" :time (current-time)))
          (let ((after-second (marker-position root-end)))
            (should (< after-first after-second))))))))

(provide 'test/benedict-chat-integration-test)
;;; benedict-chat-integration-test.el ends here
