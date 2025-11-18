;;; benedict-chat-test.el --- UI tests for chat blocks -*- lexical-binding: t; -*-

(require 'ert)
(require 'ert-async)
(require 'cl-lib)
(require 'subr-x)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-chat)
(require 'benedict-provider)
(require 'benedict-provider-fake)

(defun benedict-chat-test--find-button (buffer label)
  "Return the buffer position of LABEL button inside BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward label nil t)
        (- (point) (length label))))))

(ert-deftest-async benedict-chat-renders-blocks (done)
  "User + assistant messages render as divider blocks."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0.01)
        (benedict-provider-fake-script
         (list (list :type 'success :content "Assistant block contents" :delay 0.01)))
        (buffer (generate-new-buffer " *Benedict Chat Render*")))
    (with-current-buffer buffer
      (benedict-chat-mode)
      (benedict-chat--send-text "User block contents"))
    (run-at-time
     0.2 nil
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (should (= (length benedict-chat--items) 2))
             (should (string-match-p "User block contents" (buffer-string)))
             (should (string-match-p "Assistant block contents" (buffer-string)))
             (should (string-match-p (regexp-quote benedict-chat--block-divider-line)
                                     (buffer-string))))
       (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (funcall done)))))

(ert-deftest-async benedict-chat-thinking-streams (done)
  "Streaming reasoning chunks accumulate into a single folded block."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0.05)
        (benedict-provider-fake-script
         (list (list :type 'success
                     :thinking (list (list :id "chain"
                                           :type "reasoning.text"
                                           :chunks '("First piece. " "Second piece.")))
                     :content "Answer after thinking."
                     :chunk-delay 0.01
                     :delay 0.05)))
        (buffer (generate-new-buffer " *Benedict Chat Thinking Stream*")))
    (with-current-buffer buffer
      (benedict-chat-mode)
      (benedict-chat--send-text "streamed thinking?"))
    (run-at-time
     0.4 nil
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (let* ((thinking-items
                     (cl-remove-if-not (lambda (item)
                                         (eq (plist-get item :kind) 'thinking))
                                       benedict-chat--items))
                    (thinking (car thinking-items))
                    (button-pos (benedict-chat-test--find-button buffer "Show thinking")))
               (should (= (length thinking-items) 1))
               (should button-pos)
               (button-activate (button-at button-pos))
               (should (string-match-p "First piece."
                                       (plist-get thinking :content)))
               (should (string-match-p "Second piece."
                                       (plist-get thinking :content)))))
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))
       (funcall done)))))

(ert-deftest-async benedict-chat-code-block-buttons (done)
  "Copy/Apply buttons appear under fenced blocks and operate on the right text."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0.01)
        (benedict-provider-fake-script
         (list (list :type 'success
                     :content "```elisp\n(message \"hi\")\n```\nTail text"
                     :delay 0.01)))
        (buffer (generate-new-buffer " *Benedict Chat Blocks*")))
    (with-current-buffer buffer
      (benedict-chat-mode)
      (benedict-chat--send-text "show me code"))
    (run-at-time
     0.2 nil
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (let* ((copy-pos (benedict-chat-test--find-button buffer "Copy block"))
                    (apply-pos (benedict-chat-test--find-button buffer "Apply block"))
                    (copy-button (and copy-pos (button-at copy-pos)))
                    (apply-button (and apply-pos (button-at apply-pos))))
               (should copy-button)
               (button-activate copy-button)
               (should (equal (current-kill 0) "(message \"hi\")\n"))
               (should apply-button)
               (let ((result-buffer (button-activate apply-button)))
                 (should (buffer-live-p result-buffer))
                 (with-current-buffer result-buffer
                   (should (equal (buffer-string) "(message \"hi\")\n"))))))
         (when (buffer-live-p buffer)
           (kill-buffer buffer))
       (let ((apply-buffer (get-buffer benedict-chat-apply-buffer-name)))
           (when (buffer-live-p apply-buffer)
             (kill-buffer apply-buffer))))
       (funcall done)))))

(ert-deftest benedict-chat-markdown-lite-decorates-messages ()
  "Markdown-lite applies faces for headings, lists, inline code, emphasis, and links."
  (let ((buffer (generate-new-buffer " *Benedict Chat Markdown*")))
    (unwind-protect
        (with-current-buffer buffer
          (benedict-chat-mode)
          (let* ((assistant (benedict-chat--record-message
                             (list :role 'assistant
                                   :content
                                   (string-join
                                    '("# Heading One"
                                      "## Heading Two"
                                      "- bullet item with [link](https://example.com)"
                                      "Inline `code` with _italic_ and **strong** accents."
                                      "```elisp"
                                      "(message \"hi\")"
                                      "```")
                                    "\n")
                                   :metadata nil)))
                 (item (plist-get assistant :item))
                 (content-start (and item (marker-position (plist-get item :content-start))))
                 (content-end (and item (marker-position (plist-get item :content-end)))))
            (should content-start)
            (should content-end)
            (goto-char content-start)
            (search-forward "Heading One" content-end)
            (let ((heading-pos (- (point) (length "Heading One"))))
              (should (eq (get-text-property heading-pos 'face)
                          'benedict-chat-heading-1)))
            (goto-char content-start)
            (search-forward "Heading Two" content-end)
            (let ((heading-pos (- (point) (length "Heading Two"))))
              (should (eq (get-text-property heading-pos 'face)
                          'benedict-chat-heading-2)))
            (goto-char content-start)
            (search-forward "- bullet" content-end)
            (let ((bullet-pos (- (point) (length "- bullet"))))
              (should (eq (get-text-property bullet-pos 'face)
                          'benedict-chat-list-bullet)))
            (goto-char content-start)
            (search-forward "code" content-end)
            (let ((code-pos (- (point) (length "code"))))
              (should (eq (get-text-property code-pos 'face)
                          'benedict-chat-inline-code)))
            (goto-char content-start)
            (search-forward "strong" content-end)
            (let ((strong-pos (- (point) (length "strong"))))
              (should (eq (get-text-property strong-pos 'face)
                          'benedict-chat-strong)))
            (goto-char content-start)
            (search-forward "italic" content-end)
            (let ((italic-pos (- (point) (length "italic"))))
              (should (eq (get-text-property italic-pos 'face)
                          'benedict-chat-emphasis)))
            (goto-char content-start)
            (search-forward "[link]" content-end)
            (let* ((link-pos (- (point) (length "link]")))
                   (help (get-text-property link-pos 'help-echo)))
              (should (eq (get-text-property link-pos 'face)
                          'benedict-chat-link))
              (should (string= help "https://example.com")))
            (goto-char content-start)
            (search-forward "(message \"hi\")" content-end)
            (let ((code-pos (- (point) (length "(message \"hi\")"))))
              (should (get-text-property code-pos 'benedict-chat-code-block)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest-async benedict-chat-thinking-blocks (done)
  "Scripted thinking entries render before the assistant response."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0.01)
        (benedict-provider-fake-script
         (list (list :type 'success
                     :thinking '("Step 1: gather context." "Step 2: respond.")
                     :content "Final answer." :delay 0.01)))
        (buffer (generate-new-buffer " *Benedict Chat Thinking*")))
    (with-current-buffer buffer
      (benedict-chat-mode)
      (benedict-chat--send-text "thinking?"))
    (run-at-time
     0.2 nil
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (let* ((thinking-items
                     (cl-remove-if-not (lambda (item)
                                         (eq (plist-get item :kind) 'thinking))
                                       benedict-chat--items))
                    (thinking (car thinking-items))
                    (overlay (and thinking (plist-get thinking :thinking-overlay)))
                    (button-pos (benedict-chat-test--find-button buffer "Show thinking")))
               (should (= (length thinking-items) 1))
               (should thinking)
               (should overlay)
               (should (eq (overlay-get overlay 'invisible) 'benedict-chat-thinking))
               (should button-pos)
               (button-activate (button-at button-pos))
               (should-not (overlay-get overlay 'invisible))
               (should (string-match-p "Step 1: gather context."
                                       (buffer-string)))
               (should (string-match-p "Final answer."
                                       (buffer-string)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (funcall done)))))

(ert-deftest-async benedict-chat-empty-response-placeholder (done)
  "Empty assistant content displays a placeholder while preserving history."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0.01)
        (benedict-provider-fake-script
         (list (list :type 'success
                     :thinking '("Internal chain-of-thought only.")
                     :content ""
                     :delay 0.01)))
        (buffer (generate-new-buffer " *Benedict Chat Empty Response*")))
    (with-current-buffer buffer
      (benedict-chat-mode)
      (benedict-chat--send-text "thinking only?"))
    (run-at-time
     0.2 nil
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (let ((placeholder benedict-chat--empty-response-thinking-placeholder)
                   (assistant (car benedict-chat--messages)))
               (should (string-match-p (regexp-quote placeholder)
                                       (buffer-string)))
               (should assistant)
               (should (string= (plist-get assistant :content) ""))))
         (when (buffer-live-p buffer)
         (kill-buffer buffer)))
      (funcall done)))))

(ert-deftest-async benedict-chat-renders-usage-in-header (done)
  "Usage metadata appears in the assistant header line."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0.01)
        (benedict-provider-fake-script
         (list (list :type 'success
                     :content "With usage metadata."
                     :usage '((prompt_tokens . 10)
                              (completion_tokens . 5)
                              (total_tokens . 15)
                              (cost . 0.12))
                     :delay 0.01)))
        (buffer (generate-new-buffer " *Benedict Chat Usage*")))
    (with-current-buffer buffer
      (benedict-chat-mode)
      (benedict-chat--send-text "Show usage header."))
    (run-at-time
     0.2 nil
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (should (string-match-p "tokens p:10 / c:5 / t:15 / cost:0.12"
                                     (buffer-string))))
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))
       (funcall done)))))

(ert-deftest benedict-chat-thinking-toggle-hides-only-reasoning ()
  "Toggling thinking twice never hides the assistant response."
  (let ((buffer (generate-new-buffer " *Benedict Chat Thinking Toggle*")))
    (unwind-protect
        (with-current-buffer buffer
          (benedict-chat-mode)
          (let* ((thinking (benedict-chat--record-thinking
                            "First thought.\nSecond thought."
                            nil
                            :thinking-id "toggle-test"))
                 (assistant-message (benedict-chat--record-message
                                     (list :role 'assistant
                                           :content "Visible answer."
                                           :metadata nil)))
                 (assistant-item (plist-get assistant-message :item))
                 (overlay (plist-get thinking :thinking-overlay))
                 (assistant-start (marker-position (plist-get assistant-item :content-start)))
                 (initial-start (overlay-start overlay))
                 (initial-end (overlay-end overlay)))
            (should overlay)
            (should assistant-start)
            (should (< initial-end assistant-start))
            (benedict-chat--set-thinking-folded thinking nil)
            (should-not (overlay-get overlay 'invisible))
            (should (= (overlay-start overlay) initial-start))
            (should (= (overlay-end overlay) initial-end))
            (benedict-chat--set-thinking-folded thinking t)
            (should (eq (overlay-get overlay 'invisible) 'benedict-chat-thinking))
            (should (= (overlay-start overlay) initial-start))
            (should (= (overlay-end overlay) initial-end))
            (should (< (overlay-end overlay) assistant-start))
            (should (string-match-p "Visible answer\\."
                                    (buffer-string)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'benedict-chat-test)
;;; benedict-chat-test.el ends here
