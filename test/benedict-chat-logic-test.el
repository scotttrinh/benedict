;;; test/benedict-chat-logic-test.el --- Logic tests for Benedict Chat -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'ert-async)
(require 'benedict-chat)
(require 'benedict-message)
(require 'benedict-chat-profiles)
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)

(defvar benedict-provider 'fake)

(ert-deftest benedict-chat-session-accumulates-seconds ()
  "Completed requests add to session seconds; errors do not."
  (let ((buffer (generate-new-buffer " *Benedict Telemetry Seconds*")))
    (unwind-protect
        (with-current-buffer buffer
          (benedict-chat-mode)
          (benedict-chat--init-buffer)
          (let* ((session benedict-chat--session)
                 (start (seconds-to-time 1000))
                 (finish (seconds-to-time 1010)))
            (should (equal (benedict-session-accumulated-seconds session) 0.0))
            (cl-letf (((symbol-function 'current-time) (lambda () start)))
              (benedict-session-start-request session 'handle)
              (benedict-session-start-draft session))
            (cl-letf (((symbol-function 'current-time) (lambda () finish)))
              (benedict-session--on-success
               session
               (list :provider 'fake
                     :model "fake-model"
                     :latency 1.25
                     :usage '(:prompt-tokens 1 :completion-tokens 1 :total-tokens 2)
                     :message (list :role 'assistant :content "ok"))))
            (should (= (benedict-session-accumulated-seconds session) 1.25))
            (cl-letf (((symbol-function 'current-time) (lambda () finish)))
              (benedict-session-start-request session 'handle)
              (benedict-session-start-draft session)
              (benedict-session--on-error
               session (list :provider 'fake :message "fail")))
            (should (= (benedict-session-accumulated-seconds session) 1.25))))
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
            (should (eq (benedict-chat-profiles--resolve-provider) 'openrouter))
            (should (equal (benedict-chat-profiles--resolve-model) "profile/model"))
            (setq benedict-chat--compose-model-override "override/model")
            (should (equal (benedict-chat-profiles--resolve-model) "override/model"))
            (setq benedict-chat--compose-model-override nil)
            (setq benedict-chat-profile nil)
            (should (eq (benedict-chat-profiles--resolve-provider) 'fake))
            (should (equal (benedict-chat-profiles--resolve-model)
                           benedict-provider-fake-default-model)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest-async benedict-chat-compose-sends-context (done)
  "Compose buffers include context slices in outgoing messages."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script (list (list :type 'success :delay 0.01)))
       (benedict-chat-buffer-name " *Benedict Compose Flow*")
       (benedict-session--registry (make-hash-table :test #'equal)))
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
                      (with-current-buffer chat
                        (and benedict-chat--session
                             (benedict-session-request-active-p benedict-chat--session)))
                      (< (float-time) deadline))
            (sleep-for 0.05)
            (accept-process-output nil 0.05))
          (unwind-protect
              (when (buffer-live-p chat)
                (with-current-buffer chat
                  (let* ((profile (benedict-chat-profiles--effective-profile))
                         (messages (when benedict-chat--session
                                     (benedict-session-entries benedict-chat--session)))
                         (user (cl-find-if (lambda (msg)
                                             (eq (benedict-message-role msg) 'user))
                                           messages)))
                    (should handle)
                    (should messages)
                    (should user)
                    (should (string-match-p "Context:" (benedict-message-text user)))
                    (should (string-match-p (regexp-quote (format "<<%s>>" handle))
                                            (benedict-message-text user)))
                    (should (string-match-p "Compose region text" (benedict-message-text user))))))
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
       (benedict-session--registry (make-hash-table :test #'equal))
       (benedict-chat-profiles '((override :label "Override"
                                           :provider fake
                                           :model "profile/model")))
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script (list (list :type 'success :model "compose/model" :delay 0.01)))
       ((symbol-function benedict-chat--mount-ui) (lambda () nil))
       ((symbol-function benedict-chat-status--status-refresh) (lambda () nil))
       ((symbol-function benedict-chat-compose--refresh-header) (lambda () nil)))
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
                    (with-current-buffer chat
                      (and benedict-chat--session
                           (benedict-session-request-active-p benedict-chat--session)))
                    (< (float-time) deadline))
          (sleep-for 0.05)
          (accept-process-output nil 0.05))
        (unwind-protect
            (with-current-buffer chat
              (should (eq (benedict-session-provider benedict-chat--session) 'fake))
              (should (equal (benedict-session-model benedict-chat--session) "compose/model"))
              (should-not benedict-chat--compose-model-override))
          (when (buffer-live-p chat)
            (kill-buffer chat))))
      (funcall done))))

(ert-deftest-async benedict-chat-tool-call-flow (done)
  "Tool calls trigger approval, execution, and history update."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-session--registry (make-hash-table :test #'equal))
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
                     ;; Check history from session
                      (let* ((tool-message
                              (cl-find-if (lambda (message)
                                            (eq (benedict-message-role message) 'tool))
                                          (when benedict-chat--session
                                            (benedict-session-entries benedict-chat--session)))))
                        (should tool-message)
                        (should (equal (benedict-message-tool-result-id tool-message) "call-123"))
                        ;; We check that history recorded the result, ignoring exact string formatting
                        (should (string-match-p "matches" (benedict-message-text tool-message)))))
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
       (benedict-session--registry (make-hash-table :test #'equal))
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content ""
                    :tool-calls (list (list :id "call-error"
                                            :name 'demo-tool
                                            :arguments '(:foo "bar"))))))
       ((symbol-function benedict--prompt-for-approval) (lambda (&rest _args) t))
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
                                           (eq (benedict-message-role message) 'tool))
                                         (when benedict-chat--session
                                           (benedict-session-entries benedict-chat--session))))
                            (content (and tool-message (benedict-message-text tool-message)))
                            (metadata (and tool-message (benedict-message-metadata tool-message)))
                            (request (benedict-session--build-request benedict-chat--session))
                            (tool-entry
                             (cl-find-if (lambda (message)
                                           (eq (plist-get message :role) 'tool))
                                         (plist-get request :messages))))
                       (should tool-message)
                       (should (plist-get metadata :error))
                       (should (string-match-p "Tool error:" content))
                       ;; Ensure follow-up requests carry the tool error content.
                       (should tool-entry)
                    (should (string-match-p "Tool error:"
                                            (plist-get tool-entry :content)))))
              (error (setq err e)))
            (when (buffer-live-p buffer)
              (kill-buffer buffer)))
           (funcall done err)))))))

(ert-deftest-async benedict-chat-tool-denial-recovers-in-loop (done)
  "Permission-denied tool calls are structured and the loop can recover."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-session--registry (make-hash-table :test #'equal))
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :content ""
                    :tool-calls (list (list :id "call-denied"
                                            :name 'project-search
                                            :arguments '(:query "needle"))))
              (list :type 'success
                    :content "Recovered after permission denial.")))
       (benedict-tool-permission-predicate (lambda (_tool _args) nil)))
    (let ((buffer (generate-new-buffer " *Benedict Tool Denial Recovery*")))
      (with-current-buffer buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (benedict-chat--send-text "Try project-search, then recover if denied."))
      (let ((deadline (+ (float-time) 3.0)))
        (while (and (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (and benedict-chat--session
                           (benedict-session-request-active-p benedict-chat--session)))
                    (< (float-time) deadline))
          (sleep-for 0.05)
          (accept-process-output nil 0.05))
        (with-current-buffer buffer
          (benedict-chat--send-text "Okay, recover with an alternative."))
        (let ((second-deadline (+ (float-time) 3.0)))
          (while (and (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (and benedict-chat--session
                             (benedict-session-request-active-p benedict-chat--session)))
                      (< (float-time) second-deadline))
            (sleep-for 0.05)
            (accept-process-output nil 0.05)))
        (let (err)
          (unwind-protect
              (condition-case e
                  (with-current-buffer buffer
                    (let* ((messages (and benedict-chat--session
                                          (benedict-session-messages-chronological benedict-chat--session)))
                           (tool-message
                            (cl-find-if (lambda (message)
                                          (eq (benedict-message-role message) 'tool))
                                        messages))
                           (tool-metadata (and tool-message (benedict-message-metadata tool-message)))
                           (tool-error (and tool-metadata (plist-get tool-metadata :error)))
                           (assistant-messages
                            (cl-remove-if-not (lambda (message)
                                                (eq (benedict-message-role message) 'assistant))
                                              messages))
                           (latest-assistant (car (last assistant-messages))))
                      (should tool-message)
                      (should (eq 'denied (plist-get tool-metadata :status)))
                      (should (eq 'permission-denied (plist-get tool-error :code)))
                      (should (string-match-p "Tool denied:" (benedict-message-text tool-message)))
                      (should latest-assistant)
                      (should (string-match-p "Recovered after permission denial"
                                              (benedict-message-text latest-assistant)))))
                (error (setq err e)))
            (when (buffer-live-p buffer)
              (kill-buffer buffer)))
          (funcall done err))))))

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
            (should (eq (benedict-chat-profiles--resolve-provider) 'openrouter))
            ;; Set override
            (setq benedict-chat--provider-override 'fake)
            (should (eq (benedict-chat-profiles--resolve-provider) 'fake))
            ;; Clear override reverts to profile
            (setq benedict-chat--provider-override nil)
            (should (eq (benedict-chat-profiles--resolve-provider) 'openrouter)))
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
  "Choosing a provider updates buffer state and session provider."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-chat-buffer-name " *Benedict Provider Choice*")
       (benedict-session--registry (make-hash-table :test #'equal))
       ((symbol-function benedict-chat--mount-ui) (lambda () nil))
       ((symbol-function benedict-chat-status--status-refresh) (lambda () nil))
       ((symbol-function benedict-chat-compose--refresh-header) (lambda () nil)))
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
        ;; Verify provider override is set and session updated
        (should (eq benedict-chat--provider-override 'openrouter))
        (should (eq (benedict-session-provider benedict-chat--session) 'openrouter)))
      (when (buffer-live-p chat)
        (kill-buffer chat))
      (funcall done))))

(provide 'test/benedict-chat-logic-test)
;;; benedict-chat-logic-test.el ends here
