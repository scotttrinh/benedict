;;; test/benedict-agent-loop-test.el --- Tests for Agent Loop & Safeguards -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for session-driven loop behavior and chat event handling.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-session)
(require 'benedict-chat)

(ert-deftest benedict-loop-step-dispatches-on-tool-calls ()
  "Loop step dispatches when tool calls are present."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (_id _args) "ok"))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _payload) (push type events)))
      (benedict-session-add-message
       session '(:role assistant :content "" :tool-calls ((:id "call-1" :name tool_a :arguments nil))))
      (benedict-session--loop-step session)
      (should (= 1 (benedict-session-loop-turn-count session)))
      (should (memq 'dispatch-needed events)))))

(ert-deftest benedict-loop-step-stops-on-no-tool-calls ()
  "Loop step does not dispatch when there are no tool calls."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _payload) (push type events)))
      (benedict-session-add-message
       session '(:role assistant :content "Done."))
      (benedict-session--loop-step session)
      (should (= 0 (benedict-session-loop-turn-count session)))
      (should-not (memq 'dispatch-needed events)))))

(ert-deftest benedict-chat-checkpoint-accepts ()
  "Checkpoint continuation uses the explicit chat command path.
Without provider/model configured, `dispatch-needed' is emitted and the
session returns to `idle'."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _payload) (push type events)))
      (with-temp-buffer
        (setq-local benedict-chat--session session)
        (benedict-session-set-state session 'checkpoint)
        (benedict-chat-continue-checkpoint))
      ;; Without provider/model, dispatch fails and session goes idle
      (should (eq 'idle (benedict-session-state session)))
      (should (memq 'dispatch-needed events)))))

(ert-deftest benedict-chat-checkpoint-declines ()
  "Checkpoint stop uses the explicit chat command path."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _payload) (push type events)))
      (with-temp-buffer
        (setq-local benedict-chat--session session)
        (benedict-session-set-state session 'checkpoint)
        (benedict-chat-stop-checkpoint))
      (should (eq 'idle (benedict-session-state session)))
      (should (memq 'loop-stopped events)))))

(provide 'test/benedict-agent-loop-test)
;;; benedict-agent-loop-test.el ends here
