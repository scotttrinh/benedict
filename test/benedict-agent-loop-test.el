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
  "Chat handler continues session on checkpoint acceptance."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil)
        (last-prompt nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _payload) (push type events)))
      (with-temp-buffer
        (setq-local benedict-chat--session session)
        (benedict-session-set-state session 'checkpoint)
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt)
                     (setq last-prompt prompt)
                     t)))
          (benedict-chat--handle-session-event
           'checkpoint-requested
           '(:reason turn-limit :turn-count 3 :limit 3))))
      (should (string-match-p "run 3 autonomous steps" last-prompt))
      (should (eq 'running (benedict-session-state session)))
      (should (memq 'dispatch-needed events)))))

(ert-deftest benedict-chat-checkpoint-declines ()
  "Chat handler stops session on checkpoint rejection."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _payload) (push type events)))
      (with-temp-buffer
        (setq-local benedict-chat--session session)
        (benedict-session-set-state session 'checkpoint)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
          (benedict-chat--handle-session-event
           'checkpoint-requested
           '(:reason token-limit :limit 100))))
      (should (eq 'idle (benedict-session-state session)))
      (should (memq 'loop-stopped events)))))

(provide 'test/benedict-agent-loop-test)
;;; benedict-agent-loop-test.el ends here
