;;; benedict-session-test.el --- Tests for benedict-session -*- lexical-binding: t -*-

;;; Commentary:
;; Unit and property tests for the benedict-session module.

;;; Code:

(require 'ert)
(require 'ert-async)
(require 'propcheck)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-session)
(require 'benedict-store)
(require 'benedict-tools)

;;; Registry Tests

(ert-deftest benedict-session-test-add-message-creates-canonical-entry ()
  "Adding a legacy message also stores a canonical entry."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create))
           (message (benedict-session-add-message session '(:role user :content "First")))
           (entry (car (benedict-session-entries session))))
      (should (string= (benedict-message-id message) (benedict-message-id entry)))
      (should (eq 'user (benedict-message-role entry)))
      (should (string= "First" (benedict-message-text entry))))))

(ert-deftest benedict-session-test-entries-chronological ()
  "Canonical entries preserve chronological ordering."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "First"))
      (benedict-session-add-message session '(:role assistant :content "Second"))
      (let ((entries (benedict-session-entries-chronological session)))
        (should (string= "First" (benedict-message-text (car entries))))
        (should (string= "Second" (benedict-message-text (cadr entries))))))))

(ert-deftest benedict-session-test-create-registers ()
  "Creating a session registers it in the registry."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Test")))
      (should (benedict-session-p session))
      (should (stringp (benedict-session-id session)))
      (should (benedict-session-get (benedict-session-id session))))))

(ert-deftest benedict-session-test-create-with-fields ()
  "Session creation accepts initial field values."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create
                    :title "My Session"
                    :profile 'test-profile
                    :root "/tmp/project")))
      (should (string= "My Session" (benedict-session-title session)))
      (should (eq 'test-profile (benedict-session-profile session)))
      (should (string= "/tmp/project" (benedict-session-root session))))))

(ert-deftest benedict-session-test-list-returns-all ()
  "Listing sessions returns all registered sessions."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (benedict-session-create :title "First")
    (benedict-session-create :title "Second")
    (benedict-session-create :title "Third")
    (should (= 3 (length (benedict-session-list))))))

(ert-deftest benedict-session-test-list-with-predicate ()
  "Listing sessions accepts a filter predicate."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (benedict-session-create :title "Alpha")
    (benedict-session-create :title "Beta")
    (let ((alphas (benedict-session-list
                   (lambda (s) (string-prefix-p "A" (benedict-session-title s))))))
      (should (= 1 (length alphas))))))

(ert-deftest benedict-session-test-delete-removes ()
  "Deleting a session removes it from the registry."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create))
           (id (benedict-session-id session)))
      (should (benedict-session-delete id))
      (should-not (benedict-session-get id))
      (should-not (benedict-session-delete id)))))  ; Returns nil if not found

(ert-deftest benedict-session-test-touch-updates-timestamp ()
  "Touching a session updates its updated-at timestamp."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create))
           (original (benedict-session-updated-at session)))
      (sleep-for 0.01)
      (benedict-session-touch session)
      (should (time-less-p original (benedict-session-updated-at session))))))

;;; Message Tests

(ert-deftest benedict-session-test-add-message-assigns-id ()
  "Adding a message assigns a sequential ID."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (let ((m1 (benedict-session-add-message session '(:role user :content "First")))
            (m2 (benedict-session-add-message session '(:role assistant :content "Second"))))
        (should (string= "msg-001" (benedict-message-id m1)))
        (should (string= "msg-002" (benedict-message-id m2)))))))

(ert-deftest benedict-session-test-add-message-assigns-timestamp ()
  "Adding a message assigns a timestamp."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (let ((msg (benedict-session-add-message session '(:role user :content "Test"))))
        (should (benedict-message-timestamp msg))))))

(ert-deftest benedict-session-test-messages-newest-first ()
  "Messages are stored newest-first."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "First"))
      (benedict-session-add-message session '(:role assistant :content "Second"))
      (let ((messages (benedict-session-entries session)))
        (should (string= "Second" (benedict-message-text (car messages))))))))

(ert-deftest benedict-session-test-messages-chronological ()
  "Chronological accessor returns oldest-first."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "First"))
      (benedict-session-add-message session '(:role assistant :content "Second"))
      (let ((messages (benedict-session-messages-chronological session)))
        (should (string= "First" (benedict-message-text (car messages))))))))

(ert-deftest benedict-session-test-get-message-by-id ()
  "Can retrieve message by ID."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "Find me"))
      (let ((found (benedict-session-get-message session "msg-001")))
        (should found)
        (should (string= "Find me" (benedict-message-text found))))
      (should-not (benedict-session-get-message session "msg-999")))))

(ert-deftest benedict-session-test-update-message ()
  "Can update message fields."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "Original"))
      (benedict-session-update-message session "msg-001" '(:metadata (:edited t)))
      (let ((msg (benedict-session-get-message session "msg-001")))
        (should (plist-get (benedict-message-metadata msg) :edited))))))

;;; State Tests

(ert-deftest benedict-session-test-initial-state-idle ()
  "New sessions start in idle state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (should (eq 'idle (benedict-session-state session))))))

(ert-deftest benedict-session-test-set-state ()
  "Can transition session state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-set-state session 'streaming)
      (should (eq 'streaming (benedict-session-state session))))))

(ert-deftest benedict-session-test-set-state-no-op-same ()
  "Setting same state doesn't emit event."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _p) (push type events)))
      (benedict-session-set-state session 'idle)  ; Already idle
      (should-not (memq 'state-changed events)))))

;;; Draft Tests

(ert-deftest benedict-session-test-start-draft ()
  "Starting draft creates accumulator and sets streaming state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (should (benedict-session-draft session))
      (should (eq 'streaming (benedict-session-state session)))
      (should (string= "" (plist-get (benedict-session-draft session) :content))))))

(ert-deftest benedict-session-test-append-draft ()
  "Appending to draft accumulates content."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (benedict-session-append-draft session "Hello ")
      (benedict-session-append-draft session "world")
      (should (string= "Hello world"
                       (plist-get (benedict-session-draft session) :content))))))

(ert-deftest benedict-session-test-draft-tool-calls ()
  "Can accumulate tool calls in draft."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (benedict-session-add-draft-tool-call session '(:id "call1" :name read_file))
      (benedict-session-add-draft-tool-call session '(:id "call2" :name write_file))
      (should (= 2 (length (plist-get (benedict-session-draft session) :tool-calls)))))))

(ert-deftest benedict-session-test-finalize-draft ()
  "Finalizing draft creates message and clears draft."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (benedict-session-append-draft session "Response text")
      (let ((msg (benedict-session-finalize-draft session)))
        (should (eq 'assistant (benedict-message-role msg)))
        (should (string= "Response text" (benedict-message-text msg)))
        (should-not (benedict-session-draft session))
        (should (eq 'idle (benedict-session-state session)))))))

(ert-deftest benedict-session-test-discard-draft ()
  "Discarding draft clears without creating message."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (benedict-session-append-draft session "Partial")
      (benedict-session-discard-draft session)
      (should-not (benedict-session-draft session))
      (should (= 0 (length (benedict-session-entries session)))))))

;;; Inflight Request Tests

(ert-deftest benedict-session-test-start-request ()
  "Starting request records handle and returns ID."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (let ((id (benedict-session-start-request session 'fake-handle)))
        (should (numberp id))
        (should (benedict-session-request-active-p session))
        (should (eq 'fake-handle
                    (plist-get (benedict-session-inflight session) :request)))))))

(ert-deftest benedict-session-test-clear-request ()
  "Clearing request removes inflight state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (benedict-session-clear-request session)
      (should-not (benedict-session-request-active-p session)))))

(ert-deftest benedict-session-test-cancel ()
  "Cancelling clears request, discards draft, sets cancelled state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (benedict-session-start-draft session)
      (benedict-session-cancel session)
      (should (eq 'cancelled (benedict-session-state session)))
      (should-not (benedict-session-request-active-p session))
      (should-not (benedict-session-draft session)))))

;;; Dispatch Tests

(ert-deftest benedict-session-test-busy-p-idle ()
  "Idle session is not busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (should-not (benedict-session-busy-p session)))))

(ert-deftest benedict-session-test-busy-p-streaming ()
  "Streaming session is busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (should (benedict-session-busy-p session)))))

(ert-deftest benedict-session-test-busy-p-request ()
  "Session with active request is busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (should (benedict-session-busy-p session)))))

(ert-deftest benedict-session-test-dispatch-rejects-busy ()
  "Dispatch signals error when session is busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (should-error
       (benedict-session-dispatch session '(:provider test :model test :messages []))))))

(ert-deftest benedict-session-test-dispatch-headless ()
  "Dispatch works without any buffer (headless operation)."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (captured-callbacks nil)
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let ((mock-dispatch
             (lambda (request &rest callbacks)
               (setq captured-callbacks callbacks)
               'mock-handle)))
        (let ((request-id (benedict-session-dispatch
                           session
                           '(:provider mock :model mock :messages [(:role user :content "test")])
                           :dispatch-fn mock-dispatch)))
          (should (numberp request-id))
          (should (benedict-session-busy-p session))
          (should (cl-find 'request-started events :key #'car))
          (funcall (plist-get captured-callbacks :on-delta)
                   '(:kind content-delta :text "Hello "))
          (funcall (plist-get captured-callbacks :on-delta)
                   '(:kind content-delta :text "world"))
          (should (string= "Hello world"
                           (plist-get (benedict-session-draft session) :content)))
          (funcall (plist-get captured-callbacks :on-success)
                   '(:message (:role assistant :content "Hello world")
                     :provider mock :model mock
                     :usage (:prompt_tokens 10 :completion_tokens 5 :total_tokens 15)))
          (should-not (benedict-session-busy-p session))
          (should (eq 'idle (benedict-session-state session)))
          (should (= 1 (length (benedict-session-entries session))))
          (should (cl-find 'request-completed events :key #'car)))))))

(ert-deftest benedict-session-test-dispatch-error-headless ()
  "Dispatch handles errors correctly without buffer."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (captured-callbacks nil))
    (let ((session (benedict-session-create)))
      (let ((mock-dispatch
             (lambda (_request &rest callbacks)
               (setq captured-callbacks callbacks)
               'mock-handle)))
        (benedict-session-dispatch
         session '(:provider mock :model mock :messages [])
         :dispatch-fn mock-dispatch)
        (funcall (plist-get captured-callbacks :on-error)
                 '(:type api :message "Rate limited" :retryable t))
        (should-not (benedict-session-busy-p session))
        (should (eq 'error (benedict-session-state session)))
        (should (equal "Rate limited"
                       (plist-get (benedict-session-last-error session) :message)))))))

(ert-deftest benedict-session-test-dispatch-non-streaming ()
  "Dispatch handles non-streaming responses."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (captured-callbacks nil))
    (let ((session (benedict-session-create)))
      (let ((mock-dispatch
             (lambda (_request &rest callbacks)
               (setq captured-callbacks callbacks)
               'mock-handle)))
        (benedict-session-dispatch
         session '(:provider mock :model mock :messages [])
         :dispatch-fn mock-dispatch)
        (funcall (plist-get captured-callbacks :on-success)
                 '(:message (:role assistant :content "Direct response")
                   :provider mock :model mock))
        (should (= 1 (length (benedict-session-entries session))))
        (should (string= "Direct response"
                         (benedict-message-text (car (benedict-session-entries session)))))))))

;;; Tool Execution Tests

(ert-deftest benedict-session-test-invoke-tool-success ()
  "Tool invocation records result and emits events."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (id _args)
                                           (format "Result for %s" id)))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let ((result (benedict-session--invoke-tool
                     session '(:id "call-1" :name read_file :arguments (:path "/tmp")))))
        (should (eq 'success (plist-get result :status)))
        (should (string-match "Result for" (plist-get result :output)))
        (should (cl-find 'tool-started events :key #'car))
        (should (cl-find 'tool-completed events :key #'car))))))

(ert-deftest benedict-session-test-invoke-tool-failure ()
  "Tool failure is captured and emitted."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (_id _args)
                                           (error "Tool failed")))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let ((result (benedict-session--invoke-tool
                     session '(:id "call-1" :name broken_tool :arguments nil))))
        (should (eq 'failure (plist-get result :status)))
        (should (plist-get result :error))
        (should (cl-find 'tool-completed events :key #'car))))))

(ert-deftest benedict-session-test-invoke-tool-permission-denied ()
  "Permission denials are captured as structured failures."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn
         (lambda (_id _args &rest _options)
           '(:status denied
             :error (:message "Denied by policy"
                     :code permission-denied))))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let* ((result (benedict-session--invoke-tool
                      session '(:id "call-1" :name project-search :arguments nil)))
             (error-info (plist-get result :error)))
        (should (eq 'denied (plist-get result :status)))
        (should (eq 'permission-denied (plist-get error-info :code)))
        (should (cl-find 'tool-completed events :key #'car))))))

(ert-deftest benedict-session-test-invoke-tool-emits-permission-allow-decision-event ()
  "Predicate allow decisions emit permission audit events."
  (let* ((tool-id 'benedict-session-test-permission-allow)
         (events nil)
         (old-default (default-value 'benedict-tool-permission-predicate))
         (benedict-session--registry (make-hash-table :test 'equal))
         (benedict-session-event-hook nil)
         (benedict-session-tool-invoke-fn #'benedict-tool-invoke))
    (unwind-protect
        (progn
          (benedict-tools-register
           :id tool-id
           :fn (lambda (&rest _args) "ok")
           :approval 'confirm)
          (set-default 'benedict-tool-permission-predicate
                       (lambda (_tool _args) t))
          (let ((session (benedict-session-create)))
            (add-hook 'benedict-session-event-hook
                      (lambda (_s type payload)
                        (push (cons type payload) events)))
            (let* ((result (benedict-session--invoke-tool
                            session
                            `(:id "call-allow" :name ,tool-id :arguments (:a 1))))
                   (audit-event
                    (cl-find-if
                     (lambda (event)
                       (and (eq 'tool-audit (car event))
                            (eq 'authorization
                                (plist-get (plist-get (cdr event) :audit) :phase))))
                     events))
                   (decision-event (and audit-event
                                        (plist-get (cdr audit-event) :audit))))
              (should (eq 'success (plist-get result :status)))
              (should decision-event)
              (should (eq 'allow (plist-get decision-event :policy)))
              (should (eq 'predicate-allow (plist-get decision-event :decision)))
              (should (eq tool-id (plist-get decision-event :tool-id))))))
      (set-default 'benedict-tool-permission-predicate old-default)
      (remhash tool-id benedict--tools))))

(ert-deftest benedict-session-test-invoke-tool-emits-permission-deny-decision-event ()
  "Predicate deny decisions emit permission audit events."
  (let* ((tool-id 'benedict-session-test-permission-deny)
         (events nil)
         (old-default (default-value 'benedict-tool-permission-predicate))
         (benedict-session--registry (make-hash-table :test 'equal))
         (benedict-session-event-hook nil)
         (benedict-session-tool-invoke-fn #'benedict-tool-invoke))
    (unwind-protect
        (progn
          (benedict-tools-register
           :id tool-id
           :fn (lambda (&rest _args) "ok")
           :approval 'auto)
          (set-default 'benedict-tool-permission-predicate
                       (lambda (_tool _args) nil))
          (let ((session (benedict-session-create)))
            (add-hook 'benedict-session-event-hook
                      (lambda (_s type payload)
                        (push (cons type payload) events)))
            (let* ((result (benedict-session--invoke-tool
                            session
                            `(:id "call-deny" :name ,tool-id :arguments nil)))
                   (error-info (plist-get result :error))
                   (audit-event
                    (cl-find-if
                     (lambda (event)
                       (and (eq 'tool-audit (car event))
                            (eq 'authorization
                                (plist-get (plist-get (cdr event) :audit) :phase))))
                     events))
                   (decision-event (and audit-event
                                        (plist-get (cdr audit-event) :audit))))
              (should (eq 'denied (plist-get result :status)))
              (should (eq 'permission-denied (plist-get error-info :code)))
              (should decision-event)
              (should (eq 'deny (plist-get decision-event :policy)))
              (should (eq 'predicate-deny
                          (plist-get decision-event :decision))))))
      (set-default 'benedict-tool-permission-predicate old-default)
      (remhash tool-id benedict--tools))))

(ert-deftest benedict-session-test-invoke-tool-emits-permission-fallback-on-error-event ()
  "Predicate errors emit fallback audit events and yield pending approval."
  (let* ((tool-id 'benedict-session-test-permission-fallback)
         (events nil)
         (old-default (default-value 'benedict-tool-permission-predicate))
         (benedict-session--registry (make-hash-table :test 'equal))
         (benedict-session-event-hook nil)
         (benedict-session-tool-invoke-fn #'benedict-tool-invoke))
    (unwind-protect
        (progn
          (benedict-tools-register
           :id tool-id
           :fn (lambda (&rest _args) "ok")
           :approval 'confirm)
          (set-default 'benedict-tool-permission-predicate
                       (lambda (_tool _args)
                         (error "Permission predicate blew up")))
          (let ((session (benedict-session-create))
                (frontend (generate-new-buffer " *benedict-session-approval*")))
            (unwind-protect
                (progn
                  (benedict-session--add-frontend session frontend)
                  (add-hook 'benedict-session-event-hook
                            (lambda (_s type payload)
                              (push (cons type payload) events)))
                  (let* ((result (benedict-session--invoke-tool
                                  session
                                  `(:id "call-fallback" :name ,tool-id :arguments nil)))
                         (audit-event
                          (cl-find-if
                           (lambda (event)
                             (and (eq 'tool-audit (car event))
                                  (eq 'authorization
                                      (plist-get (plist-get (cdr event) :audit) :phase))))
                           events))
                         (decision-event (and audit-event
                                              (plist-get (cdr audit-event) :audit))))
                    (should (eq 'pending (plist-get result :status)))
                    (should decision-event)
                    (should (eq 'fallback (plist-get decision-event :policy)))
                    (should (eq 'fallback-on-error (plist-get decision-event :decision)))
                    (should (string-match-p "predicate blew up"
                                            (or (plist-get decision-event :error-message)
                                                "")))))
              (kill-buffer frontend))))
      (set-default 'benedict-tool-permission-predicate old-default)
      (remhash tool-id benedict--tools))))

(ert-deftest benedict-session-test-process-tool-calls ()
  "Processing multiple tool calls records all results."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (id _args)
                                           (format "Output from %s" id))))
    (let ((session (benedict-session-create)))
      (benedict-session--process-tool-calls
       session
       '((:id "call-1" :name tool_a :arguments nil)
         (:id "call-2" :name tool_b :arguments nil)))
      (let ((entries (benedict-session-entries session)))
        (should (= 2 (length entries)))
        (should (eq 'tool (benedict-message-role (car entries))))))))

(ert-deftest benedict-session-test-process-tool-calls-records-denial-message ()
  "Denied tool calls still leave a readable transcript entry."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn
         (lambda (_id _args &rest _options)
           '(:status denied
             :error (:message "Denied by policy"
                     :code permission-denied)))))
    (let ((session (benedict-session-create)))
      (benedict-session--process-tool-calls
       session
       '((:id "call-1" :name project-search :arguments (:query "needle"))))
      (let* ((entry (car (benedict-session-entries session)))
             (details (benedict-message-tool-result-details entry)))
        (should (eq 'tool (benedict-message-role entry)))
        (should (eq 'denied (benedict-message-status entry)))
        (should (string-match-p "Tool denied:" (benedict-message-text entry)))
        (should (eq 'permission-denied (plist-get details :code)))))))

(ert-deftest benedict-session-test-process-tool-calls-preserves-structured-success-result ()
  "Successful tool calls retain structured metadata for persistence and UI."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn
         (lambda (_id _args &rest _options)
           '(:status success
             :output (:content "Project summary"
                      :ui (:header "Project search — \"needle\""
                           :body "Showing 1 result")
                      :effects ((:kind read :path "README.org"))
                      :data (:matches ((:file "README.org"))))))))
    (let ((session (benedict-session-create)))
      (benedict-session--process-tool-calls
       session
       '((:id "call-1" :name project-search :arguments (:query "needle"))))
      (let ((entry (car (benedict-session-entries session))))
        (should (eq 'tool (benedict-message-role entry)))
        (should (eq 'success (benedict-message-status entry)))
        (should (equal "Project summary" (benedict-message-text entry)))
        (should (equal "Project search — \"needle\""
                       (plist-get (benedict-message-tool-result-ui entry) :header)))
        (should (equal '((:kind read :path "README.org"))
                       (benedict-message-tool-result-effects entry)))
        (should (equal '(:matches ((:file "README.org")))
                       (plist-get (benedict-message-tool-result-details entry) :data)))))))

(ert-deftest benedict-session-test-process-tool-calls-records-scope-denial-without-approval ()
  "Out-of-scope tool calls record a denial and never enter approval-pending state."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn #'benedict-tool-invoke))
    (let* ((session (benedict-session-create
                     :root "/tmp/project"
                     :harness (benedict-harness-create
                               :scope '(:paths ("/tmp/project"))
                               :permission-predicate (lambda (_tool _args) t))))
           (result (benedict-session--process-tool-calls
                    session
                    '((:id "call-1"
                       :name read-file
                       :arguments (:path "../elsewhere.txt")))))
           (entry (car (benedict-session-entries session)))
           (details (benedict-message-tool-result-details entry)))
      (should (eq 'complete (plist-get result :status)))
      (should-not (benedict-session-approval-pending-p session))
      (should (eq 'tool (benedict-message-role entry)))
      (should (eq 'denied (benedict-message-status entry)))
      (should (eq 'scope-expansion-required (plist-get details :code)))
      (should (equal '(:paths ("../elsewhere.txt"))
                     (plist-get details :scope-request)))
      (should (string-match-p "Tool requires scope expansion:"
                              (benedict-message-text entry))))))

(ert-deftest benedict-session-test-process-tool-calls-stops-for-approval ()
  "Approval-required tool calls stop the loop and store pending approval state."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn
         (lambda (tool-id _args &rest _options)
           (if (eq tool-id 'tool_a)
               '(:status pending
                 :approval (:tool-id tool_a :approval confirm :args (:foo "bar")))
             '(:status success :output "ok")))))
    (let ((session (benedict-session-create))
          (frontend (generate-new-buffer " *benedict-session-approval*")))
      (unwind-protect
          (progn
            (benedict-session--add-frontend session frontend)
            (benedict-session-add-message
             session
             '(:role assistant :content "" :tool-calls ((:id "call-1" :name tool_a :arguments (:foo "bar"))
                                                       (:id "call-2" :name tool_b :arguments nil))))
            (let ((result (benedict-session--process-tool-calls
                           session
                           '((:id "call-1" :name tool_a :arguments (:foo "bar"))
                             (:id "call-2" :name tool_b :arguments nil)))))
              (should (eq 'pending (plist-get result :status)))
              (should (benedict-session-approval-pending-p session))
              (should (equal "call-1"
                             (plist-get (benedict-session-pending-question session) :call-id)))))
        (kill-buffer frontend)))))

(ert-deftest benedict-session-test-approve-pending-tool-records-result ()
  "Approving a pending tool executes it and clears the pending state."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn
         (lambda (_tool-id _args &rest options)
           (if (plist-get options :skip-approval)
               '(:status success :output "approved output")
             '(:status pending
               :approval (:tool-id tool_a :approval confirm :args (:foo "bar")))))))
    (let ((session (benedict-session-create))
          (frontend (generate-new-buffer " *benedict-session-approval*")))
      (unwind-protect
          (progn
            (benedict-session--add-frontend session frontend)
            (benedict-session-add-message
             session
             '(:role assistant :content "" :tool-calls ((:id "call-1" :name tool_a :arguments (:foo "bar")))))
            (benedict-session--process-tool-calls
             session
             '((:id "call-1" :name tool_a :arguments (:foo "bar"))))
            (let ((result (benedict-session-approve-pending-tool session)))
              (should (eq 'success (plist-get result :status)))
              (should-not (benedict-session-approval-pending-p session))
              (should (string-match-p "approved output"
                                      (benedict-message-text (car (benedict-session-entries session)))))))
        (kill-buffer frontend)))))

(ert-deftest benedict-session-test-deny-pending-tool-records-result ()
  "Denying a pending tool records a denied result and clears the pending state."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn
         (lambda (_tool-id _args &rest _options)
           '(:status pending
             :approval (:tool-id tool_a :approval confirm :args (:foo "bar"))))))
    (let ((session (benedict-session-create))
          (frontend (generate-new-buffer " *benedict-session-approval*")))
      (unwind-protect
          (progn
            (benedict-session--add-frontend session frontend)
            (benedict-session-add-message
             session
             '(:role assistant :content "" :tool-calls ((:id "call-1" :name tool_a :arguments (:foo "bar")))))
            (benedict-session--process-tool-calls
             session
             '((:id "call-1" :name tool_a :arguments (:foo "bar"))))
            (let ((result (benedict-session-deny-pending-tool session)))
              (should (eq 'denied (plist-get result :status)))
              (should-not (benedict-session-approval-pending-p session))
              (should (string-match-p "Tool denied:"
                                      (benedict-message-text (car (benedict-session-entries session)))))))
        (kill-buffer frontend)))))

(ert-deftest benedict-session-test-tool-event-ordering ()
  "Tool events fire after request completion and preserve message order."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (_id _args) "OK"))
        (events nil)
        (captured-callbacks nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let ((mock-dispatch
             (lambda (_request &rest callbacks)
               (setq captured-callbacks callbacks)
               'mock-handle)))
        (benedict-session-dispatch
         session
         '(:provider mock :model mock :messages [])
         :dispatch-fn mock-dispatch)
        (funcall (plist-get captured-callbacks :on-success)
                 '(:message (:role assistant
                            :content "Done"
                            :tool-calls ((:id "call-1"
                                          :name demo-tool
                                          :arguments (:foo "bar"))))
                   :provider mock :model mock))
        (let* ((ordered (nreverse events))
               (types (mapcar #'car ordered))
               (assistant-idx (cl-position 'message-added types))
               (request-idx (cl-position 'request-completed types))
               (tool-start-idx (cl-position 'tool-started types))
               (tool-complete-idx (cl-position 'tool-completed types))
               (tool-msg-idx (cl-position 'message-added types
                                          :start (1+ assistant-idx))))
          (should assistant-idx)
          (should request-idx)
          (should tool-start-idx)
          (should tool-complete-idx)
          (should tool-msg-idx)
          (should (< assistant-idx request-idx))
          (should (< request-idx tool-start-idx))
          (should (< tool-start-idx tool-complete-idx))
          (should (< tool-complete-idx tool-msg-idx)))
        (let ((history (benedict-session-messages-chronological session)))
          (should (= 2 (length history)))
          (should (eq 'assistant (benedict-message-role (car history))))
          (should (eq 'tool (benedict-message-role (cadr history)))))))))

;;; Loop Management Tests

(ert-deftest benedict-session-test-check-repetition ()
  "Repetition detection finds duplicate tool calls."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message
       session '(:role assistant :content "" :tool-calls [(:name foo)]))
      (benedict-session-add-message
       session '(:role tool :content "result"))
      (benedict-session-add-message
       session '(:role assistant :content "" :tool-calls [(:name foo)]))
      (should (benedict-session--check-repetition session '[(:name foo)])))))

(ert-deftest benedict-session-test-check-turn-limit ()
  "Turn limit emits checkpoint event."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (setf (benedict-session-loop-config session) '(:max-turns 5))
      (setf (benedict-session-loop-turn-count session) 5)
      (should (benedict-session--check-turn-limit session))
      (should (cl-find 'checkpoint-requested events :key #'car)))))

(ert-deftest benedict-session-test-continue-after-checkpoint ()
  "Session can continue after checkpoint.
When provider/model are not configured, dispatch-needed is emitted and
session returns to idle state."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (benedict-session-set-state session 'checkpoint)
      (benedict-session-continue session)
      ;; Without provider/model, dispatch fails and session goes idle
      (should (eq 'idle (benedict-session-state session)))
      (should (cl-find 'dispatch-needed events :key #'car)))))

(ert-deftest benedict-session-test-stop-loop ()
  "Session can be stopped."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (benedict-session-set-state session 'running)
      (benedict-session-stop session)
      (should (eq 'idle (benedict-session-state session)))
      (should (cl-find 'loop-stopped events :key #'car)))))

;;; Request Building Tests

(ert-deftest benedict-session-test-build-request ()
  "Request building uses session state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create
                    :provider 'openrouter
                    :model "claude-3"
                    :tools '((:name read_file)))))
      (benedict-session-add-message session '(:role user :content "Hello"))
      (let ((request (benedict-session--build-request session)))
        (should (eq 'openrouter (plist-get request :provider)))
        (should (string= "claude-3" (plist-get request :model)))
        (should (= 1 (length (plist-get request :messages))))))))

(ert-deftest benedict-session-test-configure ()
  "Configuration updates session state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-configure session
                                  :provider 'anthropic
                                  :model "claude-4"
                                  :loop-config '(:max-turns 10))
      (should (eq 'anthropic (benedict-session-provider session)))
      (should (string= "claude-4" (benedict-session-model session)))
      (should (= 10 (plist-get (benedict-session-loop-config session) :max-turns))))))

;;; Frontend Tests

(ert-deftest benedict-session-test-add-frontend ()
  "Can attach buffer as frontend."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (with-temp-buffer
        (benedict-session--add-frontend session (current-buffer))
        (should (benedict-session-has-frontend-p session))
        (should (memq (current-buffer) (benedict-session-frontends session)))))))

(ert-deftest benedict-session-test-remove-frontend ()
  "Can detach buffer from session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (with-temp-buffer
        (benedict-session--add-frontend session (current-buffer))
        (benedict-session--remove-frontend session (current-buffer))
        (should-not (benedict-session-has-frontend-p session))))))

(ert-deftest benedict-session-test-dead-buffer-cleanup ()
  "Dead buffers are automatically removed from frontends."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create))
          (buf (generate-new-buffer " *test*")))
      (benedict-session--add-frontend session buf)
      (should (benedict-session-has-frontend-p session))
      (kill-buffer buf)
      (should-not (benedict-session-has-frontend-p session)))))

;;; Event Tests

(ert-deftest benedict-session-test-event-on-state-change ()
  "State changes emit events."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (s type payload)
                  (push (list s type payload) events)))
      (benedict-session-set-state session 'streaming)
      (should (= 1 (length events)))
      (should (eq 'state-changed (cadr (car events)))))))

(ert-deftest benedict-session-test-event-on-message-add ()
  "Adding message emits event."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (s type payload)
                  (push (list s type payload) events)))
      (benedict-session-add-message session '(:role user :content "Test"))
      (should (cl-find 'message-added events :key #'cadr)))))

(ert-deftest benedict-session-test-event-payload-includes-canonical-event ()
  "Session event payloads include a `benedict-event' object."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (captured nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s _type payload)
                  (setq captured (plist-get payload :event))))
      (benedict-session-add-message session '(:role user :content "Test"))
      (should (benedict-event-p captured))
      (should (eq 'message-added (benedict-event-type captured)))
      (should (equal (benedict-session-id session)
                     (benedict-event-session-id captured))))))

(ert-deftest benedict-session-test-event-on-draft-update ()
  "Draft updates emit events."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (s type payload)
                  (push (list s type payload) events)))
      (benedict-session-start-draft session)
      (benedict-session-append-draft session "chunk")
      (should (cl-find 'draft-started events :key #'cadr))
      (should (cl-find 'draft-updated events :key #'cadr)))))

;;; Lifecycle Tests

(ert-deftest benedict-session-test-destroy ()
  "Destroying session cleans up and removes from registry."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create))
           (id (benedict-session-id session)))
      (benedict-session-start-request session 'handle)
      (benedict-session-destroy session)
      (should-not (benedict-session-get id)))))

;;; Telemetry Accumulation Tests

(ert-deftest benedict-session-test-accumulate-usage ()
  "Usage accumulates across multiple calls."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-accumulate-usage session
        '(:prompt-tokens 100 :completion-tokens 50 :total-tokens 150) 1.5)
      (should (= 100 (plist-get (benedict-session-accumulated-usage session) :prompt)))
      (should (= 50 (plist-get (benedict-session-accumulated-usage session) :completion)))
      (should (= 150 (plist-get (benedict-session-accumulated-usage session) :total)))
      (should (= 1.5 (benedict-session-accumulated-seconds session)))
      ;; Second call accumulates
      (benedict-session-accumulate-usage session
        '(:prompt-tokens 200 :completion-tokens 100 :total-tokens 300) 2.0)
      (should (= 300 (plist-get (benedict-session-accumulated-usage session) :prompt)))
      (should (= 150 (plist-get (benedict-session-accumulated-usage session) :completion)))
      (should (= 450 (plist-get (benedict-session-accumulated-usage session) :total)))
      (should (= 3.5 (benedict-session-accumulated-seconds session))))))

(ert-deftest benedict-session-test-accumulate-usage-with-cost ()
  "Cost accumulates correctly."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-accumulate-usage session
        '(:prompt-tokens 100 :completion-tokens 50 :total-tokens 150 :cost 0.01) 1.0)
      (should (= 0.01 (plist-get (benedict-session-accumulated-usage session) :cost)))
      (benedict-session-accumulate-usage session
        '(:prompt-tokens 100 :completion-tokens 50 :total-tokens 150 :cost 0.02) 1.0)
      (should (= 0.03 (plist-get (benedict-session-accumulated-usage session) :cost))))))

(ert-deftest benedict-session-test-accumulate-usage-nil-safe ()
  "Accumulation handles nil usage and elapsed gracefully."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      ;; nil usage, non-nil elapsed
      (benedict-session-accumulate-usage session nil 1.0)
      (should (= 1.0 (benedict-session-accumulated-seconds session)))
      (should-not (benedict-session-accumulated-usage session))
      ;; non-nil usage, nil elapsed
      (benedict-session-accumulate-usage session
        '(:prompt-tokens 100 :completion-tokens 50 :total-tokens 150) nil)
      (should (= 100 (plist-get (benedict-session-accumulated-usage session) :prompt)))
      (should (= 1.0 (benedict-session-accumulated-seconds session))))))

(ert-deftest benedict-session-test-save-load-roundtrip ()
  "Saving and loading a session preserves canonical transcript state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((root (make-temp-file "benedict-store-" t))
           (session (benedict-session-create
                     :title "Persistent Session"
                     :root "/tmp/project"
                     :provider 'fake
                     :model "benedict/fake-echo"
                     :profile 'coder
                     :meta '(:instruction-sources ("AGENTS.md" ".wigg/specs/01_overview.md")
                             :branch-parent-id "ses-parent-001")
                     :system-prompt '((:role system :content "System seed"))))
           (loaded nil)
           (request nil))
      (unwind-protect
          (progn
            (setf (benedict-session-loop-config session) '(:max-turns 3 :max-tool-calls 2))
            (setf (benedict-harness-audit-log (benedict-session-harness session))
                  '((:phase authorization :tool-id read-file :policy allow :decision allow)))
            (benedict-session-add-message session '(:role user :content "Persist me"))
            (benedict-session-add-message
             session
             (benedict-message-tool-result
              "call-1" 'read-file 'success "Tool output"
              '(:path "README.org" :line-count 12)
              '(:header "Read file — README.org" :body "Showing README.org")
              '((:kind read :path "README.org"))))
            (benedict-session-save session :root root)
            (setq loaded (benedict-session-load
                          (benedict-store-session-path (benedict-session-id session) root)))
            (setq request (benedict-session--build-request loaded))
            (should (equal (benedict-session-id session) (benedict-session-id loaded)))
            (should (equal "Persistent Session" (benedict-session-title loaded)))
            (should (equal 'fake (plist-get request :provider)))
            (should (equal "benedict/fake-echo" (plist-get request :model)))
            (should (= 2 (length (benedict-session-entries-chronological loaded))))
            (should (equal '(:max-turns 3 :max-tool-calls 2)
                           (benedict-session-loop-config loaded)))
            (should (equal "ses-parent-001"
                           (plist-get (benedict-session-meta loaded) :branch-parent-id)))
            (should (= 1 (length (benedict-harness-audit-log
                                  (benedict-session-harness loaded)))))
            (should (equal "Persist me"
                           (benedict-message-text
                            (car (benedict-session-entries-chronological loaded)))))
            (should (equal 'tool
                           (benedict-message-role
                            (cadr (benedict-session-entries-chronological loaded)))))
            (should (equal '(:path "README.org" :line-count 12)
                           (benedict-message-tool-result-details
                            (cadr (benedict-session-entries-chronological loaded)))))
            (should (equal "Read file — README.org"
                           (plist-get
                            (benedict-message-tool-result-ui
                             (cadr (benedict-session-entries-chronological loaded)))
                            :header)))
            (should (equal '((:kind read :path "README.org"))
                           (benedict-message-tool-result-effects
                            (cadr (benedict-session-entries-chronological loaded)))))
            (should (equal "Tool output"
                           (plist-get (car (last (plist-get request :messages))) :content))))
        (delete-directory root t)))))

;;; Property Tests

(propcheck-deftest benedict-session-prop-ids-unique ()
  "Session IDs are always unique."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (n (propcheck-generate-integer "count" :min 2 :max 50)))
    (dotimes (_ n) (benedict-session-create))
    (let ((ids (mapcar #'benedict-session-id (benedict-session-list))))
      (propcheck-should (= (length ids) (length (delete-dups (copy-sequence ids))))))))

(propcheck-deftest benedict-session-prop-message-ids-sequential ()
  "Message IDs are always sequential within a session."
  (let* ((benedict-session--registry (make-hash-table :test 'equal))
         (session (benedict-session-create))
         (n (propcheck-generate-integer "count" :min 1 :max 100)))
    (dotimes (i n)
      (benedict-session-add-message session `(:role user :content ,(format "msg %d" i))))
    (let ((ids (mapcar #'benedict-message-id
                       (benedict-session-messages-chronological session))))
      (propcheck-should (equal ids
                               (cl-loop for i from 1 to n
                                        collect (format "msg-%03d" i)))))))

(propcheck-deftest benedict-session-prop-draft-accumulates ()
  "Draft content accumulates all appended deltas."
  (let* ((benedict-session--registry (make-hash-table :test 'equal))
         (session (benedict-session-create))
         (chunks (list (propcheck-generate-string "c1")
                       (propcheck-generate-string "c2")
                       (propcheck-generate-string "c3"))))
    (benedict-session-start-draft session)
    (dolist (chunk chunks)
      (benedict-session-append-draft session chunk))
    (propcheck-should (string= (apply #'concat chunks)
                               (plist-get (benedict-session-draft session) :content)))))

(provide 'benedict-session-test)
;;; benedict-session-test.el ends here
