;;; benedict-chat-nav-test.el --- Tests for chat turn navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Focused tests for turn-aware transcript navigation commands.

;;; Code:

(require 'ert)
(require 'vui)
(require 'benedict-chat)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-turn)

(defun benedict-chat-nav-test--message-with-id (message id)
  "Return MESSAGE with ID assigned."
  (setf (benedict-message-id message) id)
  message)

(defun benedict-chat-nav-test--completed-turn (session id prompt-id outcome-id message-ids)
  "Return completed turn for SESSION with ID, PROMPT-ID, OUTCOME-ID, and MESSAGE-IDS."
  (benedict-turn-create (benedict-session-id session)
                        :id id
                        :state 'turn-complete
                        :prompt-message-id prompt-id
                        :outcome-message-id outcome-id
                        :message-ids message-ids))

(defmacro benedict-chat-nav-test--with-chat-buffer (session &rest body)
  "Mount SESSION in a chat buffer and evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (benedict-chat-mode)
     (setq-local benedict-chat--session ,session)
     (benedict-chat--mount-ui)
     (unwind-protect
         (progn
           (vui-flush-sync)
           ,@body)
       (when (and benedict-chat--vui-mount
                  (fboundp 'vui-unmount))
         (ignore-errors (vui-unmount benedict-chat--vui-mount)))
       (vui-flush-sync))))

(ert-deftest benedict-chat-nav-prompt-navigation-and-outcome-jump-use-turn-targets ()
  "Prompt navigation and outcome jumps follow turn-level targets."
  (let ((benedict-session--registry (make-hash-table :test #'equal))
        (session (benedict-session-create :title "nav"
                                          :provider 'fake
                                          :model "fake/model")))
    (puthash (benedict-session-id session) session benedict-session--registry)
    (benedict-session-add-message
     session (benedict-chat-nav-test--message-with-id
              (benedict-message-user-text "First question") "u1"))
    (benedict-session-add-message
     session (benedict-chat-nav-test--message-with-id
              (benedict-message-assistant-text "First answer") "a1"))
    (benedict-session-add-message
     session (benedict-chat-nav-test--message-with-id
              (benedict-message-user-text "Second question") "u2"))
    (benedict-session-add-message
     session (benedict-chat-nav-test--message-with-id
              (benedict-message-assistant-text "Second answer") "a2"))
    (setf (benedict-session-turns session)
          (list (benedict-chat-nav-test--completed-turn
                 session "turn-1" "u1" "a1" '("u1" "a1"))
                (benedict-chat-nav-test--completed-turn
                 session "turn-2" "u2" "a2" '("u2" "a2"))))
    (benedict-chat-nav-test--with-chat-buffer session
      (goto-char (point-min))
      (benedict-chat-nav-next-prompt)
      (should (eq (get-text-property (point) 'benedict-turn-target) 'prompt))
      (should (equal (get-text-property (point) 'benedict-turn-id) "u1"))
      (benedict-chat-nav-next-prompt)
      (should (eq (get-text-property (point) 'benedict-turn-target) 'prompt))
      (should (equal (get-text-property (point) 'benedict-turn-id) "u2"))
      (benedict-chat-nav-jump-to-current-turn-outcome)
      (should (eq (get-text-property (point) 'benedict-turn-target) 'outcome))
      (should (equal (get-text-property (point) 'benedict-turn-id) "u2"))
      (benedict-chat-nav-previous-prompt)
      (should (eq (get-text-property (point) 'benedict-turn-target) 'prompt))
      (should (equal (get-text-property (point) 'benedict-turn-id) "u2"))
      (benedict-chat-nav-previous-prompt)
      (should (eq (get-text-property (point) 'benedict-turn-target) 'prompt))
      (should (equal (get-text-property (point) 'benedict-turn-id) "u1")))))

(ert-deftest benedict-chat-nav-toggle-current-turn-execution-uses-summary-button ()
  "Execution toggling works from turn content without block-local navigation."
  (let ((benedict-session--registry (make-hash-table :test #'equal))
        (session (benedict-session-create :title "execution"
                                          :provider 'fake
                                          :model "fake/model")))
    (puthash (benedict-session-id session) session benedict-session--registry)
    (benedict-session-add-message
     session (benedict-chat-nav-test--message-with-id
              (benedict-message-user-text "Question") "u1"))
    (benedict-session-add-message
     session
     (benedict-chat-nav-test--message-with-id
      (benedict-message-assistant-response
       :text "Final answer"
       :thinking "Reasoning"
       :tool-calls '((:id "call-1" :name "bash" :arguments "pwd")))
      "a1"))
    (benedict-session-add-message
     session
     (benedict-chat-nav-test--message-with-id
      (benedict-message-tool-result "call-1" "bash" 'success "done")
      "t1"))
    (setf (benedict-session-turns session)
          (list (benedict-chat-nav-test--completed-turn
                 session "turn-1" "u1" "a1" '("u1" "a1" "t1"))))
    (benedict-chat-nav-test--with-chat-buffer session
      (should-not (string-match-p "Execution details" (buffer-string)))
      (goto-char (point-min))
      (search-forward "Final answer")
      (goto-char (match-beginning 0))
      (benedict-chat-nav-toggle-current-turn-execution)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "Execution details" text))
        (should (string-match-p "THINKING" text))
        (should (string-match-p "Tool: bash" text)))
      (benedict-chat-nav-toggle-current-turn-execution)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should-not (string-match-p "Execution details" text))
        (should-not (string-match-p "Tool: bash" text))))))

(provide 'test/benedict-chat-nav-test)
;;; benedict-chat-nav-test.el ends here
