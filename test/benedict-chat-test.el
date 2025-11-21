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

(ert-deftest-async benedict-chat-tool-call-flow (done)
  "Tool calls trigger approval, execution, and tool-result rendering."
  (let* ((benedict-provider 'fake)
         (benedict-provider-fake-latency-seconds 0.01)
         (benedict-provider-fake-script
          (list (list :type 'success
                      :content ""
                      :tool-calls (list (list :id "call-123"
                                              :name 'project-search
                                              :arguments '(:query "needle"))))))
         (buffer (generate-new-buffer " *Benedict Chat Tool*"))
         (original-approval (symbol-function 'benedict--prompt-for-approval))
         (original-search (symbol-function 'benedict-search-project-sync))
         (fake-result '(:query "needle"
                         :root "/tmp/project"
                         :limit 5
                         :matches ((:file "README.org"
                                       :absolute "/tmp/project/README.org"
                                       :line 12
                                       :column 5
                                       :match "needle"
                                       :preview "needle appears here.")))))
    (fset 'benedict--prompt-for-approval (lambda (&rest _args) t))
    (fset 'benedict-search-project-sync (lambda (&rest _args) fake-result))
    (condition-case err
        (with-current-buffer buffer
          (benedict-chat-mode)
          (benedict-chat--send-text "Please run project search."))
      (error
       (fset 'benedict--prompt-for-approval original-approval)
       (fset 'benedict-search-project-sync original-search)
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (signal (car err) (cdr err))))
    (run-at-time
     0.4 nil
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (let* ((tool-items
                     (cl-remove-if-not (lambda (item)
                                         (eq (plist-get item :kind) 'tool))
                                       benedict-chat--items))
                    (tool-item (car tool-items))
                    (tool-message
                     (cl-find-if (lambda (message)
                                   (eq (plist-get message :role) 'tool))
                                 benedict-chat--messages))
                    (expected (prin1-to-string fake-result)))
               (should (= (length tool-items) 1))
               (should tool-item)
               (should (eq (plist-get (plist-get tool-item :tool-call) :name)
                           'project-search))
               (let ((ui (plist-get tool-item :ui)))
                 (should ui)
                 (should (eq (plist-get ui :state) 'success))
                 (should (string-match-p "Project search"
                                         (plist-get ui :header)))
                 (should (string-match-p "README.org"
                                         (plist-get tool-item :content)))
                 (should (string-match-p "\\[\\[needle\\]\\]"
                                         (plist-get tool-item :content))))
               (should tool-message)
               (should (equal (plist-get tool-message :tool-call-id) "call-123"))
               (should (string= (plist-get tool-message :content) expected))))
         (fset 'benedict--prompt-for-approval original-approval)
         (fset 'benedict-search-project-sync original-search)
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

(ert-deftest benedict-chat-markdown-lite-decorates-partial-code-block ()
  "Code block faces are applied correctly even when the block is incomplete (streaming)."
  (let ((buffer (generate-new-buffer " *Benedict Chat Partial Code*")))
    (unwind-protect
        (with-current-buffer buffer
          (benedict-chat-mode)
          ;; 1. Initial state with open fence and partial code
          (let* ((assistant (benedict-chat--record-message
                             (list :role 'assistant
                                   :content "Here is code:\n```js\nconst us"
                                   :metadata nil)))
                 (item (plist-get assistant :item))
                 (content-start (marker-position (plist-get item :content-start)))
                 (content-end (marker-position (plist-get item :content-end))))
            (goto-char content-start)
            (search-forward "const us" content-end)
            (let ((pos (- (point) 2))) ;; inside "us"
              (should (eq (get-text-property pos 'face) 'benedict-chat-code-block))))
          
          ;; 2. Update with more content (simulating streaming append)
          (let* ((assistant (car benedict-chat--messages))
                 (item (plist-get assistant :item))
                 (new-content "Here is code:\n```js\nconst user = {};\n```"))
            (benedict-chat--replace-message-content assistant new-content)
            (let ((content-start (marker-position (plist-get item :content-start)))
                  (content-end (marker-position (plist-get item :content-end))))
              (goto-char content-start)
              (search-forward "user" content-end)
              (let ((pos (- (point) 2))) ;; inside "user"
                (should (eq (get-text-property pos 'face) 'benedict-chat-code-block))))))
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

(ert-deftest benedict-chat-resolves-provider-and-model ()
  "Profile/provider/model resolution follows the configured precedence."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-default-model "benedict/fake-default")
        (benedict-provider-openrouter-default-model "openrouter/default")
        (benedict-chat-profiles '((custom :label "Custom"
                                          :provider openrouter
                                          :model "profile/model"))))
    (let ((buffer (generate-new-buffer " *Benedict Chat Resolve*")))
      (unwind-protect
          (with-current-buffer buffer
            (benedict-chat-mode)
            (setq benedict-chat-profile 'custom)
            (should (eq (benedict-chat--resolve-provider) 'openrouter))
            (should (equal (benedict-chat--resolve-model) "profile/model"))
            (setq benedict-chat--compose-model-override "override/model")
            (should (equal (benedict-chat--resolve-model) "override/model"))
            (setq benedict-chat--compose-model-override nil)
            (setq benedict-chat-profile nil)
            (should (eq (benedict-chat--resolve-provider) 'fake))
            (should (equal (benedict-chat--resolve-model)
                           benedict-provider-fake-default-model)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest-async benedict-chat-compose-sends-context (done)
  "Compose buffers include context slices in outgoing messages."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0.01)
        (benedict-provider-fake-script (list (list :type 'success :delay 0.01)))
        (benedict-chat-buffer-name " *Benedict Compose Flow*"))
    (let ((source (generate-new-buffer " *Benedict Compose Source*")))
      (with-current-buffer source
        (insert "Compose region text.")
        (push-mark (point-min) nil t)
        (goto-char (point-max)))
      (with-current-buffer source
        (let ((mark-active t)
              (transient-mark-mode t))
          (benedict-chat-ask-region (point-min) (point-max))))
      (let* ((chat (get-buffer benedict-chat-buffer-name))
             (compose (and chat (with-current-buffer chat benedict-chat--compose-buffer)))
             handle)
        (should (buffer-live-p compose))
        (with-current-buffer compose
          (goto-char (marker-position benedict-chat-compose--body-start))
          (setq handle (when (re-search-forward "\\[\\[\\([^]]+\\)\\]\\]" nil t)
                         (match-string 1)))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert "What do you see?"))
        (with-current-buffer compose
          (benedict-chat-compose-send))
        (let ((deadline (+ (float-time) 2.0)))
          (while (and (buffer-live-p chat)
                      (with-current-buffer chat benedict-chat--pending-request)
                      (< (float-time) deadline))
            (sleep-for 0.05)
            (accept-process-output nil 0.05))
          (unwind-protect
              (when (buffer-live-p chat)
                (with-current-buffer chat
                  (let* ((profile (benedict-chat--effective-profile))
                         (request (plist-get benedict-chat--last-dispatch :request))
                         (messages (and request (plist-get request :messages)))
                         (system (cl-find-if (lambda (msg)
                                               (eq (plist-get msg :role) 'system))
                                             messages))
                         (request-user (cl-find-if (lambda (msg)
                                                     (eq (plist-get msg :role) 'user))
                                                   messages))
                         (user (cl-find-if (lambda (msg)
                                             (eq (plist-get msg :role) 'user))
                                           benedict-chat--messages))
                         (assistant (benedict-chat--find-last-assistant t))
                         (preamble (benedict-chat--profile-preamble profile)))
                    (should handle)
                    (should request)
                    (should (eq (plist-get request :profile) profile))
                    (should messages)
                    (should system)
                    (should (string-match-p "Org-style notation"
                                            (plist-get system :content)))
                    (when preamble
                      (should (string-match-p (regexp-quote preamble)
                                              (plist-get system :content))))
                    (should request-user)
                    (should (plist-get request :tools))
                    (should user)
                    (should (string-match-p "Context:" (plist-get user :content)))
                    (should (string-match-p (regexp-quote (format "<<%s>>" handle))
                                            (plist-get user :content)))
                    (should (string-match-p (regexp-quote (format "[[%s]]" handle))
                                            (plist-get user :content)))
                    (should-not (string-match-p "Org-style notation"
                                                (plist-get user :content)))
                    (should (string-match-p "Compose region text" (plist-get user :content)))
                    (should (string-match-p "What do you see" (plist-get user :content)))
                    (should assistant)
                    (should (string-match-p "Context:" (plist-get assistant :content))))))
            (when (buffer-live-p chat)
              (kill-buffer chat))
            (when (buffer-live-p source)
              (kill-buffer source))))
        (funcall done)))))

(ert-deftest-async benedict-chat-compose-model-override-clears (done)
  "Compose model overrides apply to dispatch and clear after send."
  (let ((benedict-provider 'fake)
        (benedict-chat-buffer-name " *Benedict Compose Override*")
        (benedict-chat-profiles '((override :label "Override"
                                            :provider fake
                                            :model "profile/model")))
        (benedict-provider-fake-latency-seconds 0.01)
        (benedict-provider-fake-script (list (list :type 'success :delay 0.01))))
    (let ((chat (generate-new-buffer benedict-chat-buffer-name)))
      (with-current-buffer chat
        (benedict-chat-mode)
        (setq benedict-chat-profile 'override)
        (benedict-chat-compose-open))
      (let ((compose (with-current-buffer chat benedict-chat--compose-buffer)))
        (with-current-buffer compose
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _) "compose/model")))
            (benedict-chat-choose-model)))
        (with-current-buffer compose
          (goto-char (point-max))
          (insert "Check override usage.")
          (benedict-chat-compose-send)))
      (let ((deadline (+ (float-time) 2.0)))
        (while (and (buffer-live-p chat)
                    (with-current-buffer chat benedict-chat--pending-request)
                    (< (float-time) deadline))
          (sleep-for 0.05)
          (accept-process-output nil 0.05))
        (unwind-protect
            (with-current-buffer chat
              (let ((request (plist-get benedict-chat--last-dispatch :request)))
                (should request)
                (should (eq (plist-get request :provider) 'fake))
                (should (equal (plist-get request :model) "compose/model"))
                (should-not benedict-chat--compose-model-override)))
          (when (buffer-live-p chat)
            (kill-buffer chat)))
  (funcall done)))
))

(ert-deftest benedict-search-project-sync-finds-matches ()
  "Ripgrep-backed project search returns structured matches."
  (skip-unless (executable-find benedict-search-project-executable))
  (let* ((query "Benedict maintainers")
         (result (benedict-search-project-sync query))
         (matches (plist-get result :matches)))
    (should (plist-get result :root))
    (should (plist-get result :match-count))
    (should (listp matches))
    (should (> (length matches) 0))
    (let ((entry (car matches)))
      (should (plist-get entry :file))
      (should (plist-get entry :line))
      (should (plist-get entry :preview)))))

(provide 'benedict-chat-test)
;;; benedict-chat-test.el ends here
