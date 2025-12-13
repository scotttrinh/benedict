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
          (benedict-chat--record-message (list :role 'user :content "hi" :time (current-time)))

          (benedict-chat--handle-provider-delta
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
             (list :kind 'content-delta :provider 'fake :model "fake-model" :text "ld**"))
            (should (string= (funcall body) "Hello **bold**"))

            (benedict-chat--status-tick (current-buffer))
            (should (string= (funcall body) "Hello **bold**"))

            ;; Completion updates metadata + replaces the body with final content.
            (benedict-chat--handle-provider-success
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
          (benedict-chat--record-message (list :role 'user :content "hi" :time (current-time)))
          (benedict-chat--handle-provider-delta
           (list :kind 'content-delta :provider 'fake :model "fake-model" :text "Hello"))

          (let* ((assistant (cl-find-if (lambda (msg) (eq (plist-get msg :role) 'assistant))
                                        benedict-chat--messages))
                 (assistant-item (plist-get assistant :item))
                 (tool-item (benedict-chat--record-tool-block
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

(provide 'test/benedict-chat-integration-test)
;;; benedict-chat-integration-test.el ends here
