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

;;; Registry Tests

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
        (should (string= "msg-001" (plist-get m1 :id)))
        (should (string= "msg-002" (plist-get m2 :id)))))))

(ert-deftest benedict-session-test-add-message-assigns-timestamp ()
  "Adding a message assigns a timestamp."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (let ((msg (benedict-session-add-message session '(:role user :content "Test"))))
        (should (plist-get msg :timestamp))))))

(ert-deftest benedict-session-test-messages-newest-first ()
  "Messages are stored newest-first."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "First"))
      (benedict-session-add-message session '(:role assistant :content "Second"))
      (let ((messages (benedict-session-messages session)))
        (should (string= "Second" (plist-get (car messages) :content)))))))

(ert-deftest benedict-session-test-messages-chronological ()
  "Chronological accessor returns oldest-first."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "First"))
      (benedict-session-add-message session '(:role assistant :content "Second"))
      (let ((messages (benedict-session-messages-chronological session)))
        (should (string= "First" (plist-get (car messages) :content)))))))

(ert-deftest benedict-session-test-get-message-by-id ()
  "Can retrieve message by ID."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "Find me"))
      (let ((found (benedict-session-get-message session "msg-001")))
        (should found)
        (should (string= "Find me" (plist-get found :content))))
      (should-not (benedict-session-get-message session "msg-999")))))

(ert-deftest benedict-session-test-update-message ()
  "Can update message fields."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session '(:role user :content "Original"))
      (benedict-session-update-message session "msg-001" '(:metadata (:edited t)))
      (let ((msg (benedict-session-get-message session "msg-001")))
        (should (plist-get (plist-get msg :metadata) :edited))))))

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
        (should (eq 'assistant (plist-get msg :role)))
        (should (string= "Response text" (plist-get msg :content)))
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
      (should (= 0 (length (benedict-session-messages session)))))))

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
          (should (= 1 (length (benedict-session-messages session))))
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
        (should (= 1 (length (benedict-session-messages session))))
        (should (string= "Direct response"
                         (plist-get (car (benedict-session-messages session)) :content)))))))

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
    (let ((ids (mapcar (lambda (m) (plist-get m :id))
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
