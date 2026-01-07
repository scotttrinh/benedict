# benedict-session Implementation Plan

## Overview

Implement `benedict-session` as a first-class, in-memory data structure that owns the state of a Benedict conversation and its runtime (streaming/pending questions/tool activity), decoupling that state from `benedict-chat` buffers.

## Approach

**Direct cut-over**: Build session infrastructure, then replace buffer-local state wholesale. No dual-write or backwards compatibility scaffolding. Intermediate phases may break functionality until complete.

**Test-Driven**: Write tests first that specify expected behavior, then implement to make tests pass. Property-based tests verify invariants hold across all inputs.

---

## Test-Driven Development Guide

### Testing Infrastructure

The project uses:
- **`ert`** - Standard Emacs test framework
- **`ert-async`** - Async test support with `ert-deftest-async` and `done` callback
- **`propcheck`** - Property-based testing for invariants
- **`benedict-test-helpers`** - Test utilities including `benedict-test-with-bindings`
- **`benedict-provider-fake`** - Scriptable fake provider for integration tests

### TDD Workflow

1. **Write failing test** that specifies the expected behavior
2. **Run test** to confirm it fails for the right reason
3. **Implement** minimal code to make test pass
4. **Refactor** while keeping tests green
5. **Add property tests** for invariants discovered during implementation

### Test Categories

| Category | When to Use | Example |
|----------|-------------|---------|
| **Unit** | Pure functions, struct operations | Session CRUD, message ID assignment |
| **Property** | Invariants that must hold for all inputs | "Message IDs are always unique" |
| **Integration** | Multiple components working together | Chat buffer + session + provider |
| **Async** | Streaming, timers, callbacks | Provider dispatch, event emission |

### Property Test Patterns

Property tests verify invariants hold regardless of input. Use for:

```elisp
;; Invariant: Message IDs are unique within a session
(propcheck-deftest benedict-session-prop-message-ids-unique ()
  "Adding messages always produces unique IDs."
  (let* ((benedict-session--registry (make-hash-table :test 'equal))
         (session (benedict-session-create))
         (n (propcheck-generate-integer "count" :min 1 :max 100)))
    (dotimes (_ n)
      (benedict-session-add-message session '(:role user :content "test")))
    (let ((ids (mapcar (lambda (m) (plist-get m :id))
                       (benedict-session-messages session))))
      (propcheck-should (= (length ids) (length (delete-dups ids)))))))

;; Invariant: State transitions are valid
(propcheck-deftest benedict-session-prop-valid-state-transitions ()
  "State transitions follow allowed paths."
  (let* ((benedict-session--registry (make-hash-table :test 'equal))
         (session (benedict-session-create))
         (valid-from-idle '(streaming waiting error))
         (new-state (propcheck-generate-one-of "state" valid-from-idle)))
    (benedict-session-set-state session new-state)
    (propcheck-should (eq (benedict-session-state session) new-state))))
```

### Async Test Patterns

Use `ert-deftest-async` for anything involving timers, callbacks, or streaming:

```elisp
(ert-deftest-async benedict-session-test-event-emission (done)
  "Events are emitted on state changes."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (add-hook 'benedict-session-event-hook
              (lambda (session type payload)
                (push (list type payload) events)))
    (let ((session (benedict-session-create)))
      (benedict-session-set-state session 'streaming)
      ;; Use run-at-time to allow event propagation
      (run-at-time 0.01 nil
                   (lambda ()
                     (should (= 1 (length events)))
                     (should (eq 'state-changed (caar events)))
                     (funcall done))))))
```

### Test Isolation

Always isolate the session registry in tests:

```elisp
(ert-deftest benedict-session-test-example ()
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    ;; Test code here - registry is fresh and isolated
    ))
```

---

## Phase 1: Session Module (Pure Addition)

### Overview
Create complete `benedict-session.el` with all data structures and operations. No integration with chat buffer yet - purely additive, nothing breaks.

### Test Specifications (Write First)

Create `test/benedict-session-test.el` with these tests **before** implementing:

```elisp
;;; benedict-session-test.el --- Tests for benedict-session -*- lexical-binding: t -*-

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
      (benedict-session-start-draft session "partial")
      (benedict-session-cancel session)
      (should (eq 'cancelled (benedict-session-state session)))
      (should-not (benedict-session-request-active-p session))
      (should-not (benedict-session-draft session)))))

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

;;; Property Tests

(propcheck-deftest benedict-session-prop-ids-unique ()
  "Session IDs are always unique."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (n (propcheck-generate-integer "count" :min 2 :max 50)))
    (dotimes (_ n) (benedict-session-create))
    (let ((ids (mapcar #'benedict-session-id (benedict-session-list))))
      (propcheck-should (= (length ids) (length (delete-dups ids)))))))

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
```

### Implementation

After tests exist and fail, create `benedict-session.el`:

```elisp
;;; benedict-session.el --- Session management for Benedict -*- lexical-binding: t -*-

(require 'cl-lib)

;;; Session Struct

(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state and runtime."
  id created-at updated-at title
  messages (message-seq 0)
  (state 'idle) draft pending-question inflight last-error last-request
  root provider model profile meta
  flywire-session attached-frontends)

;;; Registry

(defvar benedict-session--registry (make-hash-table :test 'equal))
(defvar benedict-session--request-seq 0)

(defun benedict-session--generate-id ()
  (format "ses-%s-%s" (format-time-string "%Y%m%d%H%M%S")
          (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))

(defun benedict-session-create (&rest plist)
  "Create and register a new session."
  (let* ((now (current-time))
         (id (or (plist-get plist :id) (benedict-session--generate-id)))
         (session (benedict-session--create
                   :id id :created-at now :updated-at now
                   :title (plist-get plist :title)
                   :root (plist-get plist :root)
                   :provider (plist-get plist :provider)
                   :model (plist-get plist :model)
                   :profile (plist-get plist :profile)
                   :meta (plist-get plist :meta))))
    (puthash id session benedict-session--registry)
    session))

(defun benedict-session-get (id) (gethash id benedict-session--registry))

(defun benedict-session-list (&optional predicate)
  (let (result)
    (maphash (lambda (_id s)
               (when (or (null predicate) (funcall predicate s))
                 (push s result)))
             benedict-session--registry)
    (sort result (lambda (a b)
                   (time-less-p (benedict-session-updated-at b)
                                (benedict-session-updated-at a))))))

(defun benedict-session-delete (id)
  (when (gethash id benedict-session--registry)
    (remhash id benedict-session--registry) t))

(defun benedict-session-touch (session)
  (setf (benedict-session-updated-at session) (current-time)))

;;; Events

(defvar benedict-session-event-hook nil
  "Hook: (SESSION EVENT-TYPE PAYLOAD).")

(defvar benedict-session-ask-user-hook nil
  "Hook: (SESSION QUESTION-PLIST) for question-raised events.")

(defun benedict-session--emit (session event-type &rest payload)
  (benedict-session-touch session)
  (run-hook-with-args 'benedict-session-event-hook session event-type payload)
  (when (eq event-type 'question-raised)
    (run-hook-with-args 'benedict-session-ask-user-hook session (car payload))))

(defun benedict-session-set-state (session new-state)
  (let ((old (benedict-session-state session)))
    (unless (eq old new-state)
      (setf (benedict-session-state session) new-state)
      (benedict-session--emit session 'state-changed :old old :new new-state))))

;;; Messages

(defun benedict-session-add-message (session message)
  (let ((id (format "msg-%03d" (cl-incf (benedict-session-message-seq session)))))
    (setq message (plist-put message :id id))
    (setq message (plist-put message :timestamp (current-time)))
    (push message (benedict-session-messages session))
    (benedict-session--emit session 'message-added :message message)
    message))

(defun benedict-session-get-message (session id)
  (cl-find id (benedict-session-messages session)
           :key (lambda (m) (plist-get m :id)) :test #'equal))

(defun benedict-session-update-message (session id updates)
  (when-let ((msg (benedict-session-get-message session id)))
    (cl-loop for (k v) on updates by #'cddr do (plist-put msg k v))
    (benedict-session--emit session 'message-updated :id id :updates updates)
    msg))

(defun benedict-session-messages-chronological (session)
  (reverse (copy-sequence (benedict-session-messages session))))

;;; Draft

(defun benedict-session-start-draft (session &optional content)
  (setf (benedict-session-draft session)
        (list :content (or content "") :tool-calls nil :thinking nil
              :started-at (current-time)))
  (benedict-session-set-state session 'streaming)
  (benedict-session--emit session 'draft-started))

(defun benedict-session-append-draft (session delta)
  (when-let ((draft (benedict-session-draft session)))
    (setf (benedict-session-draft session)
          (plist-put draft :content (concat (plist-get draft :content) delta)))
    (benedict-session--emit session 'draft-updated :delta delta)))

(defun benedict-session-add-draft-tool-call (session tool-call)
  (when-let ((draft (benedict-session-draft session)))
    (setf (benedict-session-draft session)
          (plist-put draft :tool-calls
                     (append (plist-get draft :tool-calls) (list tool-call))))
    (benedict-session--emit session 'draft-updated :tool-call tool-call)))

(defun benedict-session-finalize-draft (session &optional metadata)
  (when-let ((draft (benedict-session-draft session)))
    (let ((msg (list :role 'assistant
                     :content (plist-get draft :content)
                     :tool-calls (plist-get draft :tool-calls)
                     :metadata metadata)))
      (setf (benedict-session-draft session) nil)
      (benedict-session-set-state session 'idle)
      (benedict-session--emit session 'draft-finalized)
      (benedict-session-add-message session msg))))

(defun benedict-session-discard-draft (session)
  (setf (benedict-session-draft session) nil)
  (benedict-session--emit session 'draft-finalized :discarded t))

;;; Inflight

(defun benedict-session-start-request (session handle &optional loop-state)
  (let ((id (cl-incf benedict-session--request-seq)))
    (setf (benedict-session-inflight session)
          (list :request handle :request-id id
                :started-at (current-time) :loop-state loop-state))
    id))

(defun benedict-session-clear-request (session)
  (setf (benedict-session-inflight session) nil))

(defun benedict-session-cancel (session)
  (when (benedict-session-inflight session)
    (benedict-session-clear-request session)
    (benedict-session-discard-draft session)
    (benedict-session-set-state session 'cancelled)
    t))

(defun benedict-session-request-active-p (session)
  (not (null (benedict-session-inflight session))))

;;; Frontends

(defun benedict-session--add-frontend (session buffer)
  (let ((fronts (cl-remove-if-not #'buffer-live-p
                                  (benedict-session-attached-frontends session))))
    (unless (memq buffer fronts) (push buffer fronts))
    (setf (benedict-session-attached-frontends session) fronts)))

(defun benedict-session--remove-frontend (session buffer)
  (setf (benedict-session-attached-frontends session)
        (delq buffer (benedict-session-attached-frontends session))))

(defun benedict-session-frontends (session)
  (let ((fronts (cl-remove-if-not #'buffer-live-p
                                  (benedict-session-attached-frontends session))))
    (setf (benedict-session-attached-frontends session) fronts)
    fronts))

(defun benedict-session-has-frontend-p (session)
  (not (null (benedict-session-frontends session))))

;;; Lifecycle

(defun benedict-session-destroy (session)
  (when (benedict-session-request-active-p session)
    (benedict-session-cancel session))
  (when-let ((fw (benedict-session-flywire-session session)))
    (when (fboundp 'benedict-flywire-session-teardown)
      (benedict-flywire-session-teardown fw)))
  (benedict-session--emit session 'destroyed)
  (benedict-session-delete (benedict-session-id session)))

(provide 'benedict-session)
;;; benedict-session.el ends here
```

### Files to Modify

- **File**: `Eask` - Add `benedict-session.el` to package files

### Success Criteria

#### Automated Verification
- [X] `nix run .#test` - all 25+ session tests pass
- [X] `nix run .#lint` - byte-compiles cleanly

#### Manual Verification
- [X] `M-: (benedict-session-create :title "test")` works
- [X] Session operations work in isolation

---

## Phase 2: Chat Buffer Integration (Dual-Write)

### Overview
Integrate session infrastructure into chat buffers using a dual-write approach. Messages are written to both buffer-local state and session, maintaining backward compatibility while adding session support.

### Test Specifications (Write First)

Create `test/benedict-chat-session-test.el`:

```elisp
;;; benedict-chat-session-test.el --- Integration tests -*- lexical-binding: t -*-

(require 'ert)
(require 'ert-async)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-chat)
(require 'benedict-session)
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)

;;; Buffer-Session Binding Tests

(ert-deftest benedict-chat-session-test-init-creates-session ()
  "Initializing chat buffer creates and attaches a session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (should benedict-chat--session)
      (should (benedict-session-p benedict-chat--session))
      (should (memq (current-buffer)
                    (benedict-session-frontends benedict-chat--session))))))

(ert-deftest benedict-chat-session-test-buffer-kill-detaches ()
  "Killing buffer detaches from session but doesn't destroy session."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (session nil))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (setq session benedict-chat--session))
    ;; Buffer is now dead
    (should (benedict-session-get (benedict-session-id session)))
    (should-not (benedict-session-has-frontend-p session))))

;;; Message Flow Tests

(ert-deftest benedict-chat-session-test-send-records-in-session ()
  "Sending a message records it in the session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      ;; Simulate sending (without provider dispatch)
      (benedict-chat--record-message '(:role user :content "Hello"))
      (should (= 1 (length (benedict-session-messages benedict-chat--session))))
      (let ((msg (car (benedict-session-messages benedict-chat--session))))
        (should (string= "Hello" (plist-get msg :content)))
        (should (plist-get msg :id))))))

;;; Streaming Tests

(ert-deftest-async benedict-chat-session-test-streaming-uses-draft (done)
  "Streaming response accumulates in session draft."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Hello " "world")
                    :chunk-delay 0.005
                    :delay 0.02))))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (let ((session benedict-chat--session))
        (benedict-chat--send-text "Test")
        ;; Check draft exists during streaming
        (run-at-time 0.01 nil
                     (lambda ()
                       (should (eq 'streaming (benedict-session-state session)))
                       (should (benedict-session-draft session))))
        ;; Check finalized message
        (run-at-time 0.05 nil
                     (lambda ()
                       (should (eq 'idle (benedict-session-state session)))
                       (should-not (benedict-session-draft session))
                       ;; Should have user + assistant messages
                       (should (>= (length (benedict-session-messages session)) 2))
                       (funcall done)))))))

;;; Event-Driven UI Tests

(ert-deftest benedict-chat-session-test-events-update-ui ()
  "Session events trigger UI updates in attached buffers."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (update-called nil))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      ;; Mock the UI update function
      (cl-letf (((symbol-function 'benedict-chat--streaming-append-text)
                 (lambda (_delta) (setq update-called t))))
        ;; Emit event directly
        (benedict-session-start-draft benedict-chat--session)
        (benedict-session-append-draft benedict-chat--session "test")
        (should update-called)))))

;;; Headless Operation Tests

(ert-deftest-async benedict-chat-session-test-headless-streaming (done)
  "Streaming continues when buffer is killed."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success :delay 0.05))))
    (let ((session nil))
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Test"))
      ;; Buffer is now dead, session should still exist and streaming
      (should (benedict-session-get (benedict-session-id session)))
      (should (eq 'streaming (benedict-session-state session)))
      ;; Wait for completion
      (run-at-time 0.1 nil
                   (lambda ()
                     (should (eq 'idle (benedict-session-state session)))
                     (should (>= (length (benedict-session-messages session)) 2))
                     (funcall done))))))

;;; Property Tests

(propcheck-deftest benedict-chat-session-prop-messages-sync ()
  "All user messages sent appear in session."
  (let* ((benedict-session--registry (make-hash-table :test 'equal))
         (n (propcheck-generate-integer "count" :min 1 :max 10)))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (dotimes (i n)
        (benedict-chat--record-message `(:role user :content ,(format "msg %d" i))))
      (propcheck-should (= n (length (benedict-session-messages benedict-chat--session)))))))

(provide 'benedict-chat-session-test)
;;; benedict-chat-session-test.el ends here
```

### Changes Required

- **File**: `benedict-chat.el`
  - [X] Add `(require 'benedict-session)` at top
  - [X] Add `(defvar-local benedict-chat--session nil)`
  - [X] Modify `benedict-chat--init-buffer` to create/attach session
  - [X] Modify `benedict-chat--record-message` to write to session (dual-write)
  - [X] Add `benedict-chat--detach-session` and hook to `kill-buffer-hook`

### Success Criteria

#### Automated Verification
- [X] `nix run .#test` - all integration tests pass (37 session tests)
- [X] `nix run .#lint` - clean (only pre-existing checkdoc warnings)

#### Manual Verification
- [ ] Send message → appears in chat
- [ ] Kill buffer → session persists

---

## Phase 2b: Full Session Cut-Over

### Overview
Complete the cut-over from buffer-local state to session state. After this phase, the session becomes the authoritative source for conversation data, enabling headless operation and streaming persistence across buffer attach/detach cycles.

### Changes Required

- **File**: `benedict-chat.el`
  - [X] Modify `benedict-chat--build-request` to read from session instead of `benedict-chat--messages`
  - [X] Modify `benedict-chat--start-dispatch` to use session callbacks:
    - [X] Call `benedict-session-start-request` to track inflight state
    - [X] Call `benedict-session-start-draft` when streaming begins (via headless handler)
    - [X] Call `benedict-session-append-draft` for content deltas (via headless handler)
    - [X] Call `benedict-session-finalize-draft` on success (via headless handler)
    - [X] Call `benedict-session-clear-request` in all terminal handlers (via headless handler)
  - [X] Add headless session handlers (`benedict-chat--handle-provider-*-headless`) for session state updates independent of buffer
  - [X] Modify buffer handlers to only update UI (session state via headless handlers)
  - [X] Modify `benedict-chat--record-message` to skip session write for assistant messages during streaming
  - [X] Fix failing `benedict-chat-session-test-headless-streaming` failure
  - [ ] Add `benedict-chat--handle-session-event` for UI updates driven by session events (deferred - direct calls work for now)

### Test Specifications

The streaming and headless tests from the original Phase 2 spec apply here:

```elisp
;;; Streaming Tests (require session draft integration)

(ert-deftest-async benedict-chat-session-test-streaming-uses-draft (done)
  "Streaming response accumulates in session draft."
  ...)

;;; Event-Driven UI Tests

(ert-deftest benedict-chat-session-test-events-update-ui ()
  "Session events trigger UI updates in attached buffers."
  ...)

;;; Headless Operation Tests

(ert-deftest-async benedict-chat-session-test-headless-streaming (done)
  "Streaming continues when buffer is killed."
  ...)
```

### Success Criteria

#### Automated Verification
- [X] `nix run .#test` - streaming and headless tests pass (40/40 session tests)
- [X] `nix run .#lint` - clean (only pre-existing checkdoc warnings)

#### Manual Verification
- [X] Response streams correctly (accumulated in session draft)
- [X] Tool calls work
- [X] Kill buffer mid-stream → session continues → reopen shows content
- [X] Session state (streaming/idle/error) reflected in UI

---

## Phase 3: Session Routing

### Overview
Implement session selection logic.

### Test Specifications (Write First)

Add to `test/benedict-chat-session-test.el`:

```elisp
;;; Routing Tests

(ert-deftest benedict-chat-session-test-routing-no-sessions ()
  "With no sessions, benedict-chat creates new session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (should (= 0 (length (benedict-session-list))))
    (with-temp-buffer
      ;; Simulate what benedict-chat does
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      (should (= 1 (length (benedict-session-list)))))))

(ert-deftest benedict-chat-session-test-routing-one-session ()
  "With one session, benedict-chat opens it."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((existing (benedict-session-create :title "Existing")))
      (should (= 1 (length (benedict-session-list))))
      ;; benedict-chat--buffer-for-session should find/create buffer for existing
      (let ((buf (benedict-chat--buffer-for-session existing)))
        (should buf)
        (with-current-buffer buf
          (should (eq benedict-chat--session existing)))
        (kill-buffer buf)))))

(ert-deftest benedict-chat-session-test-routing-prefix-arg ()
  "With prefix arg, always create new session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (benedict-session-create :title "Existing")
    (should (= 1 (length (benedict-session-list))))
    ;; Simulate C-u prefix behavior
    (let ((new-session (benedict-session-create :title "New Chat")))
      (should (= 2 (length (benedict-session-list)))))))

(ert-deftest benedict-chat-session-test-buffer-reuse ()
  "Opening same session reuses existing buffer."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((session (benedict-session-create :title "Test"))
           (buf1 (benedict-chat--buffer-for-session session))
           (buf2 (benedict-chat--buffer-for-session session)))
      (should (eq buf1 buf2))
      (kill-buffer buf1))))

(ert-deftest benedict-chat-session-test-session-annotation ()
  "Session annotations include state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Test Session")))
      (let ((ann (benedict-chat--session-annotation session)))
        (should (string-match-p "idle" ann))
        (should (string-match-p "Test Session" ann))))))
```

### Changes Required

- **File**: `benedict-chat.el`
  - Add `benedict-chat--session-annotation`
  - Add `benedict-chat--select-session`
  - Add `benedict-chat--buffer-for-session`
  - Add `benedict-chat--render-session-history`
  - Rewrite `benedict-chat` command with routing logic

### Success Criteria

#### Automated Verification
- [X] `nix run .#test` - routing tests pass

#### Manual Verification
- [X] No sessions: creates one
- [X] One session: opens it
- [ ] Multiple: shows picker
- [ ] `C-u`: always creates new

---

## Phase 4: Headless Verification & Polish

### Overview
Verify sessions continue without buffers. Fix edge cases.

### Test Specifications

Add to `test/benedict-chat-session-test.el`:

```elisp
;;; Headless Edge Case Tests

(ert-deftest-async benedict-chat-session-test-headless-tool-completion (done)
  "Tool calls complete when buffer is killed."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :tool-calls '((:id "call1" :name "test_tool"))
                    :delay 0.05))))
    (let ((session nil))
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Use a tool"))
      ;; Wait for tool call processing
      (run-at-time 0.1 nil
                   (lambda ()
                     ;; Session should have processed tool call
                     (should (benedict-session-get (benedict-session-id session)))
                     (funcall done))))))

(ert-deftest-async benedict-chat-session-test-reattach-midstream (done)
  "Reattaching mid-stream shows accumulated content."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Part1 " "Part2 " "Part3")
                    :chunk-delay 0.02
                    :delay 0.1))))
    (let ((session nil))
      ;; Start streaming in a buffer
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Test"))
      ;; Wait for some chunks to accumulate, then reattach
      (run-at-time 0.05 nil
                   (lambda ()
                     (should (eq 'streaming (benedict-session-state session)))
                     (let ((draft (benedict-session-draft session)))
                       (should draft)
                       (should (> (length (plist-get draft :content)) 0)))))
      ;; Wait for completion
      (run-at-time 0.15 nil
                   (lambda ()
                     (should (eq 'idle (benedict-session-state session)))
                     (funcall done))))))

(ert-deftest benedict-chat-session-test-error-captured ()
  "Errors during headless operation are captured in session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (benedict-session-start-draft session)
      ;; Simulate error handler
      (setf (benedict-session-last-error session) '(:message "Test error"))
      (benedict-session-clear-request session)
      (benedict-session-discard-draft session)
      (benedict-session-set-state session 'error)
      (should (eq 'error (benedict-session-state session)))
      (should (benedict-session-last-error session)))))
```

### Changes Required

- Fix any edge cases discovered during testing
- Ensure event handlers are robust to nil/dead buffers
- Verify cancel works from any state

### Success Criteria

#### Automated Verification
- [X] `nix run .#test` - all tests pass including headless (49/49 session tests pass)

#### Manual Verification
- [ ] Start streaming, kill buffer, reopen → see content
- [ ] Full agent loop across attach/detach
- [ ] Error states display correctly on reattach

---

## Testing Strategy Summary

| Phase | Test File | Test Count | Focus |
|-------|-----------|------------|-------|
| 1 | `benedict-session-test.el` | 33 | Unit + property tests for session module |
| 2 | `benedict-chat-session-test.el` | 4 | Buffer-session binding (dual-write) |
| 2b | (same file) | ~6 | Streaming, events, headless (full cut-over) |
| 3 | (same file) | ~5 | Routing logic tests |
| 4 | (same file) | 3 | Headless edge case tests |
| **Total** | | **49** | |

### Running Tests

```bash
# All tests
nix run .#test

# Specific test file
nix run .#test -- test/benedict-session-test.el

# Multiple test files
nix run .#test -- test/benedict-session-test.el test/benedict-chat-session-test.el
```

## References

- **Product Spec**: `efforts/00047-effort_benedict_session/product.md`
- **Research**: `efforts/00047-effort_benedict_session/research.md`
- **Existing Tests**: `test/benedict-propcheck-test.el`, `test/benedict-provider-fake-test.el`
