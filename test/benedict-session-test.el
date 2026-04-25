;;; benedict-session-test.el --- Tests for benedict-session -*- lexical-binding: t -*-

;;; Commentary:
;; Unit and property tests for the benedict-session module.

;;; Code:

(require 'ert)
(require 'propcheck)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-session)
(require 'benedict-store)
(require 'benedict-tools)

;;; Registry Tests

(ert-deftest benedict-session-test-add-message-creates-canonical-entry ()
  "Adding a canonical message stores a durable canonical entry."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create))
           (message (benedict-session-add-message
                     session (benedict-message-user-text "First")))
           (entry (car (benedict-session-entries session))))
      (should (string= (benedict-message-id message) (benedict-message-id entry)))
      (should (eq 'user (benedict-message-role entry)))
      (should (string= "First" (benedict-message-text entry))))))

(ert-deftest benedict-session-test-entries-chronological ()
  "Canonical entries preserve chronological ordering."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session (benedict-message-user-text "First"))
      (benedict-session-add-message session (benedict-message-assistant-text "Second"))
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

(ert-deftest benedict-session-test-delete-removes ()
  "Deleting a session removes it from the registry."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create))
           (id (benedict-session-id session)))
      (should (benedict-session-delete id))
      (should-not (benedict-session-get id))
      (should-not (benedict-session-delete id)))))

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
      (let ((m1 (benedict-session-add-message session
                                              (benedict-message-user-text "First")))
            (m2 (benedict-session-add-message session
                                              (benedict-message-assistant-text "Second"))))
        (should (string= "msg-001" (benedict-message-id m1)))
        (should (string= "msg-002" (benedict-message-id m2)))))))

(ert-deftest benedict-session-test-get-message-by-id ()
  "Can retrieve message by ID."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-add-message session (benedict-message-user-text "Find me"))
      (let ((found (benedict-session-get-message session "msg-001")))
        (should found)
        (should (string= "Find me" (benedict-message-text found)))))))

;;; State Tests

(ert-deftest benedict-session-test-initial-run-state-idle ()
  "New sessions start in idle run-state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (should (eq 'idle (benedict-session-run-state session))))))

;;; Draft Tests

(ert-deftest benedict-session-test-start-draft ()
  "Starting draft creates accumulator."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (should (benedict-session-draft session))
      (should (string= "" (plist-get (benedict-session-draft session) :content))))))

(ert-deftest benedict-session-test-finalize-draft ()
  "Finalizing draft creates message and clears draft."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (benedict-session-append-draft session "Response text")
      (let ((msg (benedict-session-finalize-draft session)))
        (should (eq 'assistant (benedict-message-role msg)))
        (should (string= "Response text" (benedict-message-text msg)))
        (should-not (benedict-session-draft session))))))

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

(ert-deftest benedict-session-test-cancel ()
  "Cancelling clears request and discards draft."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (benedict-session-start-draft session)
      (benedict-session-cancel session)
      (should-not (benedict-session-request-active-p session))
      (should-not (benedict-session-draft session)))))

;;; Persistence Tests

(ert-deftest benedict-session-test-save-load-roundtrip ()
  "Saving and loading a session preserves canonical transcript state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((root (make-temp-file "benedict-store-" t))
           (session (benedict-session-create
                     :title "Persistent Session"
                     :root "/tmp/project"
                     :provider 'fake
                     :model "benedict/fake-echo"
                     :profile 'coder))
           (loaded nil))
      (unwind-protect
          (progn
            (benedict-session-add-message session
                                          (benedict-message-user-text "Persist me"))
            (benedict-session-save session :root root)
            (setq loaded (benedict-session-load
                          (benedict-store-session-path (benedict-session-id session) root)))
            (should (equal (benedict-session-id session) (benedict-session-id loaded)))
            (should (equal "Persistent Session" (benedict-session-title loaded)))
            (should (= 1 (length (benedict-session-entries-chronological loaded))))
            (should (equal "Persist me"
                           (benedict-message-text
                            (car (benedict-session-entries-chronological loaded))))))
        (delete-directory root t)))))

;;; Property Tests

(propcheck-deftest benedict-session-prop-ids-unique ()
  "Session IDs are always unique."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (n (propcheck-generate-integer "count" :min 2 :max 50)))
    (dotimes (_ n) (benedict-session-create))
    (let ((ids (mapcar #'benedict-session-id (benedict-session-list))))
      (propcheck-should (= (length ids) (length (delete-dups (copy-sequence ids))))))))

(provide 'benedict-session-test)
;;; benedict-session-test.el ends here
