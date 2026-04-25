;;; test/benedict-core-test.el --- Tests for Benedict core runtime -*- lexical-binding: t; -*-

;;; Commentary:
;; Headless tests for the Benedict kernel contract.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-core)

(defun benedict-core-test--dispatch (responses &optional record-request)
  "Return a synchronous fake provider dispatch over RESPONSES.
When RECORD-REQUEST is non-nil, call it with each request."
  (let ((queue responses))
    (lambda (request &rest callbacks)
      (when record-request
        (funcall record-request request))
      (let ((response (pop queue))
            (on-success (plist-get callbacks :on-success))
            (on-error (plist-get callbacks :on-error)))
        (if (and (listp response) (plist-get response :error))
            (funcall on-error (plist-get response :error))
          (funcall on-success response))))))

(defun benedict-core-test--event-types (session)
  "Return durable event types recorded on SESSION."
  (mapcar #'benedict-event-type (benedict-session-events session)))

(defun benedict-core-test--tool-result-content (message)
  "Return canonical tool result content from MESSAGE."
  (plist-get (car (benedict-message-blocks-for-display message)) :result))

(ert-deftest benedict-core-runs-final-assistant-message-headlessly ()
  "A session can run one provider response with no tool calls and return to idle."
  (let* ((requests nil)
         (session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Done.")))
                    (lambda (request)
                      (setq requests (append requests (list request))))))))
    (benedict-core-add-user-input session "Hello")
    (benedict-core-run session)
    (should (eq (benedict-session-run-state session) 'idle))
    (should (eq (benedict-session-turn-state session) 'turn-complete))
    (should-not (benedict-session-outstanding-yields session))
    (should (= 1 (length requests)))
    (should (equal '(user assistant)
                   (mapcar #'benedict-message-role
                           (benedict-session-entries-chronological session))))
    (should (equal "Done."
                   (benedict-message-text
                    (car (last (benedict-session-entries-chronological session))))))
    (should (equal '(session-created
                     message-added
                     state-changed
                     state-changed
                     run-started
                     turn-started
                     request-started
                     message-added
                     request-completed
                     state-changed
                     state-changed
                     run-completed)
                   (benedict-core-test--event-types session)))))

(ert-deftest benedict-core-provider-request-includes-session-controls ()
  "Core provider requests include autonomy and verbosity controls."
  (let* ((captured nil)
         (autonomy '(:max-turns 2 :max-time 30))
         (verbosity 'concise)
         (session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :autonomy autonomy
                   :verbosity verbosity
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Done.")))
                    (lambda (request)
                      (setq captured request))))))
    (benedict-core-add-user-input session "Hello")
    (benedict-core-run session)
    (should (equal autonomy (plist-get captured :autonomy)))
    (should (eq verbosity (plist-get captured :verbosity)))))

(ert-deftest benedict-core-continues-after-auto-approved-tool-result ()
  "A provider -> tool -> provider loop completes without chat buffers."
  (let* ((requests nil)
         (tool-calls 0)
         (session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :approved-capabilities '(project-read)
                   :tools (list (list :id 'lookup
                                      :capabilities '(project-read)
                                      :fn (lambda (&rest _args)
                                            (cl-incf tool-calls)
                                            "tool output")))
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant
                                      :content ""
                                      :tool-calls ((:id "call-1"
                                                    :name lookup
                                                    :arguments nil))))
                          '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Final.")))
                    (lambda (request)
                      (setq requests (append requests (list request))))))))
    (benedict-core-add-user-input session "Use a tool")
    (benedict-core-run session)
    (should (eq (benedict-session-run-state session) 'idle))
    (should (eq (benedict-session-turn-state session) 'turn-complete))
    (should (= 1 tool-calls))
    (should (= 2 (length requests)))
    (should (equal '(user assistant tool assistant)
                   (mapcar #'benedict-message-role
                           (benedict-session-entries-chronological session))))
    (let ((tool-message (nth 2 (benedict-session-entries-chronological session))))
      (should (eq (benedict-message-status tool-message) 'success))
      (should (equal "tool output"
                     (plist-get (benedict-core-test--tool-result-content tool-message)
                                :content))))
    (should (member 'tool-started (benedict-core-test--event-types session)))
    (should (member 'tool-completed (benedict-core-test--event-types session)))))

(ert-deftest benedict-core-capability-yield-resumes-after-approval ()
  "Unapproved tool capabilities create a user yield that can be resolved."
  (let* ((requests nil)
         (tool-calls 0)
         (session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :tools (list (list :id 'write-note
                                      :capabilities '(project-write)
                                      :fn (lambda (&rest _args)
                                            (cl-incf tool-calls)
                                            "wrote note")))
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant
                                      :content ""
                                      :tool-calls ((:id "call-approval"
                                                    :name write-note
                                                    :arguments nil))))
                          '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Recovered.")))
                    (lambda (request)
                      (setq requests (append requests (list request))))))))
    (benedict-core-add-user-input session "Write something")
    (benedict-core-run session)
    (should (eq (benedict-session-run-state session) 'waiting))
    (should (eq (benedict-session-turn-state session) 'harness-yielded-approval))
    (should (= 0 tool-calls))
    (let* ((yield (car (benedict-session-outstanding-yields session)))
           (yield-id (plist-get yield :id)))
      (should (eq (plist-get yield :type) 'approval-request))
      (should (equal '(project-write)
                     (plist-get yield :required-capabilities)))
      (benedict-core-resume session yield-id '(:decision approve)))
    (should (eq (benedict-session-run-state session) 'idle))
    (should (eq (benedict-session-turn-state session) 'turn-complete))
    (should-not (benedict-session-outstanding-yields session))
    (should (= 1 tool-calls))
    (should (= 2 (length requests)))
    (should (member 'approval-requested (benedict-core-test--event-types session)))
    (should (member 'approval-resolved (benedict-core-test--event-types session)))
    (should (equal '(project-write)
                   (benedict-session-core-approved-capabilities session)))))

(ert-deftest benedict-core-action-pipeline-can-rewrite-tool-call ()
  "Action pipeline functions can rewrite the invocation executed by the tool."
  (let* ((seen-args nil)
         (session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :approved-capabilities '(project-read)
                   :action-pipeline-functions
                   (list
                    (lambda (_context invocation)
                      (let* ((tool-call (copy-tree (plist-get invocation :tool-call)))
                             (args (copy-tree (plist-get tool-call :arguments))))
                        (setq args (plist-put args :path "/repo/README.org"))
                        (benedict-core-action-update-invocation
                         (benedict-core-invocation-update
                          invocation
                          :tool-call (plist-put tool-call :arguments args))))))
                   :tools (list (list :id 'read-file
                                      :capabilities '(project-read)
                                      :fn (lambda (&rest args)
                                            (setq seen-args args)
                                            "authorized content")))
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant
                                      :content ""
                                      :tool-calls ((:id "call-rewrite"
                                                    :name read-file
                                                    :arguments (:path "../README.org")))))
                          '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Done.")))))))
    (benedict-core-add-user-input session "Read the file")
    (benedict-core-run session)
    (should (equal '(:path "/repo/README.org") seen-args))
    (let* ((event (cl-find 'tool-started (benedict-session-events session)
                           :key #'benedict-event-type))
           (tool-call (plist-get (benedict-event-payload event) :tool-call)))
      (should (equal "/repo/README.org"
                     (plist-get (plist-get tool-call :arguments) :path))))))

(ert-deftest benedict-core-approval-yield-carries-updated-invocation ()
  "Approval yields preserve the updated invocation that will execute later."
  (let* ((seen-args nil)
         (session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :action-pipeline-functions
                   (list
                    (lambda (_context invocation)
                      (let* ((tool-call (copy-tree (plist-get invocation :tool-call)))
                             (args (copy-tree (plist-get tool-call :arguments))))
                        (setq args (plist-put args :path "/repo/safe.el"))
                        (benedict-core-action-update-invocation
                         (benedict-core-invocation-update
                          invocation
                          :tool-call (plist-put tool-call :arguments args))))))
                   :tools (list (list :id 'write-file
                                      :capabilities '(project-write)
                                      :fn (lambda (&rest args)
                                            (setq seen-args args)
                                            "wrote safe file")))
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant
                                      :content ""
                                      :tool-calls ((:id "call-updated-approval"
                                                    :name write-file
                                                    :arguments (:path "/tmp/unsafe.el")))))
                          '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Done.")))))))
    (benedict-core-add-user-input session "Write the file")
    (benedict-core-run session)
    (let* ((yield (car (benedict-session-outstanding-yields session)))
           (invocation (plist-get yield :invocation))
           (tool-call (plist-get invocation :tool-call)))
      (should (equal "/repo/safe.el"
                     (plist-get (plist-get tool-call :arguments) :path)))
      (benedict-core-resume session (plist-get yield :id) '(:decision approve)))
    (should (equal '(:path "/repo/safe.el") seen-args))))

(ert-deftest benedict-core-action-denial-can-return-tool-result ()
  "An action can append an in-band tool result and continue."
  (let* ((session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :tools (list (list :id 'danger
                                      :capabilities '(account-write)
                                      :fn (lambda (&rest _args)
                                            (error "Must not run"))))
                   :action-pipeline-functions
                   (list (lambda (_context invocation)
                           (benedict-core-action-append-tool-result
                            invocation
                            "Denied by test action pipeline")))
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant
                                      :content ""
                                      :tool-calls ((:id "call-denied"
                                                    :name danger
                                                    :arguments nil))))
                          '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Handled.")))))))
    (benedict-core-add-user-input session "Do risky work")
    (benedict-core-run session)
    (should (eq (benedict-session-run-state session) 'idle))
    (let ((tool-message (nth 2 (benedict-session-entries-chronological session))))
      (should (eq (benedict-message-status tool-message) 'denied))
      (should (string-match-p "Denied by test action pipeline"
                              (plist-get (benedict-message-tool-result-details tool-message)
                                         :message))))))

(ert-deftest benedict-core-malformed-action-stage-emits-contract-violation ()
  "Malformed action pipeline output is reported at the pipeline boundary."
  (let* ((session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :action-pipeline-functions
                   (list (lambda (_context _invocation) :bad-stage-result))
                   :tools (list (list :id 'lookup
                                      :capabilities '(project-read)
                                      :fn (lambda (&rest _args)
                                            (error "Must not run"))))
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant
                                      :content ""
                                      :tool-calls ((:id "call-contract"
                                                    :name lookup
                                                    :arguments nil))))
                          '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Handled.")))))))
    (benedict-core-add-user-input session "Use a tool")
    (benedict-core-run session)
    (let* ((event (cl-find 'contract-violation (benedict-session-events session)
                           :key #'benedict-event-type))
           (payload (and event (benedict-event-payload event))))
      (should event)
      (should (eq (plist-get payload :boundary) 'tool-action-pipeline))
      (should (plist-get payload :stage))
      (should (equal nil (plist-get payload :path)))
      (should (equal "tool action plist or nil"
                     (plist-get payload :expected)))
      (should (eq (plist-get payload :actual) :bad-stage-result)))))

(ert-deftest benedict-core-malformed-action-stage-appends-failed-tool-result ()
  "Malformed action pipeline output becomes a paired failed tool result."
  (let* ((session (benedict-core-create-session
                   :provider 'fake
                   :model "fake-model"
                   :action-pipeline-functions
                   (list (lambda (_context _invocation)
                           '(:action execute-tool)))
                   :tools (list (list :id 'lookup
                                      :capabilities '(project-read)
                                      :fn (lambda (&rest _args)
                                            (error "Must not run"))))
                   :provider-dispatch-fn
                   (benedict-core-test--dispatch
                    (list '(:provider fake
                            :model "fake-model"
                            :message (:role assistant
                                      :content ""
                                      :tool-calls ((:id "call-invalid-action"
                                                    :name lookup
                                                    :arguments nil))))
                          '(:provider fake
                            :model "fake-model"
                            :message (:role assistant :content "Handled.")))))))
    (benedict-core-add-user-input session "Use a tool")
    (benedict-core-run session)
    (let ((tool-message (nth 2 (benedict-session-entries-chronological session))))
      (should (eq (benedict-message-status tool-message) 'failure))
      (should (equal "call-invalid-action"
                     (benedict-message-tool-result-id tool-message)))
      (should (string-match-p "invalid result"
                              (plist-get (benedict-message-tool-result-details tool-message)
                                         :message))))))

(ert-deftest benedict-core-action-stage-receives-context-not-session ()
  "Action pipeline stages receive bounded context instead of the session."
  (let (seen-context)
    (let* ((session (benedict-core-create-session
                     :id "ctx-session"
                     :root "/repo"
                     :provider 'fake
                     :model "fake-model"
                     :approved-capabilities '(project-read)
                     :action-pipeline-functions
                     (list (lambda (context _invocation)
                             (setq seen-context context)
                             nil))
                     :tools (list (list :id 'lookup
                                        :capabilities '(project-read)
                                        :fn (lambda (&rest _args) "ok")))
                     :provider-dispatch-fn
                     (benedict-core-test--dispatch
                      (list '(:provider fake
                              :model "fake-model"
                              :message (:role assistant
                                        :content ""
                                        :tool-calls ((:id "call-context"
                                                      :name lookup
                                                      :arguments nil))))
                            '(:provider fake
                              :model "fake-model"
                              :message (:role assistant :content "Done.")))))))
      (benedict-core-add-user-input session "Use a tool")
      (benedict-core-run session)
      (should seen-context)
      (should-not (benedict-session-p seen-context))
      (should (equal "ctx-session" (plist-get seen-context :session-id)))
      (should (equal "/repo" (plist-get seen-context :root)))
      (should (eq (plist-get seen-context :run-state) 'running))
      (should (eq (plist-get seen-context :turn-state) 'harness-evaluating))
      (should (equal '(project-read)
                     (plist-get seen-context :approved-capabilities)))
      (should (plist-get seen-context :harness)))))

(ert-deftest benedict-core-default-policy-executes-approved-capabilities ()
  "The default action policy executes tools with approved capabilities."
  (let* ((session (benedict-core-create-session
                   :approved-capabilities '(project-read)))
         (tool-call '(:id "call-approved" :name lookup :arguments nil))
         (tool-spec '(:id lookup :capabilities (project-read)))
         (context (benedict-core--action-pipeline-context session))
         (invocation (benedict-core--initial-invocation
                      session tool-call tool-spec))
         (action (benedict-core--default-policy-action context invocation)))
    (should (eq (plist-get action :action) 'execute-tool))
    (should (eq (plist-get action :invocation) invocation))))

(ert-deftest benedict-core-default-policy-yields-missing-capabilities ()
  "The default action policy yields for missing capabilities."
  (let* ((session (benedict-core-create-session))
         (tool-call '(:id "call-missing" :name write-file :arguments nil))
         (tool-spec '(:id write-file :capabilities (project-write)))
         (context (benedict-core--action-pipeline-context session))
         (invocation (benedict-core--initial-invocation
                      session tool-call tool-spec))
         (action (benedict-core--default-policy-action context invocation)))
    (should (eq (plist-get action :action) 'request-yield))
    (should (eq (plist-get action :yield-type) 'approval-request))
    (should (equal '(project-write)
                   (plist-get (plist-get action :invocation)
                              :required-capabilities)))))

(provide 'test/benedict-core-test)
;;; benedict-core-test.el ends here
