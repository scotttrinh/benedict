;;; test/benedict-chat-logic-test.el --- Logic tests for Benedict Chat -*- lexical-binding: t; -*-

(require 'ert)
(require 'ert-async)
(require 'benedict-chat)
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)

(defvar benedict-provider 'fake)

(ert-deftest benedict-chat-telemetry-accumulates-session-seconds ()
  "Completed requests add to session seconds; errors do not."
  (let ((buffer (generate-new-buffer " *Benedict Telemetry Seconds*")))
    (unwind-protect
        (with-current-buffer buffer
          (benedict-chat-mode)
          (benedict-chat--init-buffer)
          (should (equal (plist-get benedict-chat--telemetry :session-seconds) 0.0))
          (benedict-chat--telemetry-begin (list :provider 'fake))
          (benedict-chat--telemetry-finish 'complete (list :latency 1.25))
          (should (= (plist-get benedict-chat--telemetry :session-seconds) 1.25))
          (benedict-chat--telemetry-begin (list :provider 'fake))
          (benedict-chat--telemetry-finish 'error (list :status 500 :error t))
          (should (= (plist-get benedict-chat--telemetry :session-seconds) 1.25)))
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
            (benedict-chat--init-buffer)
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
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
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
                         (user (cl-find-if (lambda (msg)
                                             (eq (plist-get msg :role) 'user))
                                           benedict-chat--messages)))
                    (should handle)
                    (should request)
                    (should messages)
                    (should user)
                    (should (string-match-p "Context:" (plist-get user :content)))
                    (should (string-match-p (regexp-quote (format "<<%s>>" handle))
                                            (plist-get user :content)))
                    (should (string-match-p "Compose region text" (plist-get user :content))))))
            (when (buffer-live-p chat)
              (kill-buffer chat))
            (when (buffer-live-p source)
              (kill-buffer source))))
        (funcall done)))))

(ert-deftest-async benedict-chat-compose-model-override-clears (done)
  "Compose model overrides apply to dispatch and clear after send."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-chat-buffer-name " *Benedict Compose Override*")
       (benedict-chat-profiles '((override :label "Override"
                                           :provider fake
                                           :model "profile/model")))
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script (list (list :type 'success :delay 0.01))))
    (let ((chat (generate-new-buffer benedict-chat-buffer-name)))
      (with-current-buffer chat
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
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
            (kill-buffer chat))))
      (funcall done))))

(ert-deftest-async benedict-chat-tool-call-flow (done)
  "Tool calls trigger approval, execution, and history update."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content ""
                    :tool-calls (list (list :id "call-123"
                                            :name 'project-search
                                            :arguments '(:query "needle"))))))
       ((symbol-function benedict--prompt-for-approval) (lambda (&rest _args) t))
       ((symbol-function benedict-search-project-sync)
        (lambda (&rest _args)
          '(:query "needle"
            :root "/tmp/project"
            :limit 5
            :matches ((:file "README.org"))))))
    (let ((buffer (generate-new-buffer " *Benedict Chat Tool Logic*")))
      (with-current-buffer buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (benedict-chat--send-text "Please run project search."))
      
      (run-at-time
       0.4 nil
       (lambda ()
         (let (err)
           (unwind-protect
               (condition-case e
                   (with-current-buffer buffer
                     ;; Check history
                     (let* ((tool-message
                             (cl-find-if (lambda (message)
                                           (eq (plist-get message :role) 'tool))
                                         benedict-chat--messages)))
                       (should tool-message)
                       (should (equal (plist-get tool-message :tool-call-id) "call-123"))
                       ;; We check that history recorded the result, ignoring exact string formatting
                       (should (string-match-p "matches" (plist-get tool-message :content)))

                       ;; Check placeholder rendering
                       (goto-char (point-min))
                       (let ((case-fold-search t))
                         (should (re-search-forward "Project search" nil t)))))
                 (error (setq err e)))
             (when (buffer-live-p buffer)
               (kill-buffer buffer)))
           (if err
               (funcall done (error-message-string err))
             (funcall done))))))))

(ert-deftest-async benedict-chat-tool-error-includes-structured-payload (done)
  "Tool failures capture structured details for the model and UI."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content ""
                    :tool-calls (list (list :id "call-error"
                                            :name 'demo-tool
                                            :arguments '(:foo "bar"))))))
       ((symbol-function benedict--prompt-for-approval) (lambda (&rest _args) t))
       ((symbol-function benedict-chat--loop-step) (lambda (&rest _args) nil))
       ((symbol-function benedict-tool-invoke)
        (lambda (&rest _args)
          (signal 'wrong-type-argument (list 'stringp 123)))))
    (let ((buffer (generate-new-buffer " *Benedict Tool Error Payload*")))
      (with-current-buffer buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (benedict-chat--send-text "please call the failing tool"))
      (run-at-time
       0.5 nil
       (lambda ()
         (let (err)
           (unwind-protect
               (condition-case e
                   (with-current-buffer buffer
                     (let* ((tool-message
                             (cl-find-if (lambda (message)
                                           (eq (plist-get message :role) 'tool))
                                         benedict-chat--messages))
                            (content (and tool-message (plist-get tool-message :content)))
                            (metadata (and tool-message (plist-get tool-message :metadata)))
                            (request (benedict-chat--build-request))
                            (tool-entry
                             (cl-find-if (lambda (message)
                                           (eq (plist-get message :role) 'tool))
                                         (plist-get request :messages))))
                       (should tool-message)
                       (should (plist-get metadata :error))
                       (should (string-match-p "\"type\":\"tool_error\"" content))
                       (should (string-match-p "\"symbol\":\"wrong-type-argument\"" content))
                       (should (string-match-p "\"backtrace\"" content))
                       ;; Ensure follow-up requests carry the structured payload.
                       (should tool-entry)
                    (should (string-match-p "\"type\":\"tool_error\""
                                            (plist-get tool-entry :content)))))
              (error (setq err e)))
            (when (buffer-live-p buffer)
              (kill-buffer buffer)))
          (funcall done err)))))))

(ert-deftest benedict-chat-resolves-provider-override ()
  "Provider override takes precedence in resolution chain."
  (let ((benedict-provider 'fake)
        (benedict-chat-profiles '((custom :label "Custom"
                                          :provider openrouter))))
    (let ((buffer (generate-new-buffer " *Benedict Chat Provider Override*")))
      (unwind-protect
          (with-current-buffer buffer
            (benedict-chat-mode)
            (benedict-chat--init-buffer)
            ;; Profile specifies openrouter, but override takes precedence
            (setq benedict-chat-profile 'custom)
            (should (eq (benedict-chat--resolve-provider) 'openrouter))
            ;; Set override
            (setq benedict-chat--provider-override 'fake)
            (should (eq (benedict-chat--resolve-provider) 'fake))
            ;; Clear override reverts to profile
            (setq benedict-chat--provider-override nil)
            (should (eq (benedict-chat--resolve-provider) 'openrouter)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest benedict-chat-provider-registry ()
  "Provider registry lists and displays available providers."
  ;; Verify fake and openrouter are registered
  (let ((provider-ids (benedict-provider-list-ids)))
    (should (member 'fake provider-ids))
    (should (member 'openrouter provider-ids))))

(ert-deftest benedict-chat-provider-display-name ()
  "Provider display names render correctly."
  (let ((fake-name (benedict-provider-display-name 'fake))
        (openrouter-name (benedict-provider-display-name 'openrouter))
        (unknown-name (benedict-provider-display-name 'nonexistent)))
    (should (stringp fake-name))
    (should (stringp openrouter-name))
    ;; Unknown providers get capitalized symbol name
    (should (equal unknown-name "Nonexistent"))))

(ert-deftest-async benedict-chat-choose-provider-updates-state (done)
  "Choosing a provider updates buffer state and telemetry."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-chat-buffer-name " *Benedict Provider Choice*"))
    (let ((chat (generate-new-buffer benedict-chat-buffer-name)))
      (with-current-buffer chat
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        ;; Verify initial state
        (should-not benedict-chat--provider-override)
        ;; Mock the completing-read to select openrouter
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "OpenRouter")))
          (benedict-chat-choose-provider))
        ;; Verify provider override is set
        (should (eq benedict-chat--provider-override 'openrouter)))
      (when (buffer-live-p chat)
        (kill-buffer chat))
      (funcall done))))

(provide 'test/benedict-chat-logic-test)
;;; benedict-chat-logic-test.el ends here
