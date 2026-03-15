;;; benedict-chat-nav-test.el --- Tests for chat turn navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Focused tests for turn-aware transcript navigation commands.

;;; Code:

(require 'ert)
(require 'vui)
(require 'benedict-chat)
(require 'benedict-session)

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
    (benedict-session-add-message session '(:id "u1" :role user :content "First question"))
    (benedict-session-add-message session '(:id "a1" :role assistant :content "First answer"))
    (benedict-session-add-message session '(:id "u2" :role user :content "Second question"))
    (benedict-session-add-message session '(:id "a2" :role assistant :content "Second answer"))
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
    (benedict-session-add-message session '(:id "u1" :role user :content "Question"))
    (benedict-session-add-message
     session
     '(:id "a1"
       :role assistant
       :content "Final answer"
       :thinking "Reasoning"
       :tool-calls ((:id "call-1" :name "bash" :arguments "pwd"))))
    (benedict-session-add-message
     session
     '(:id "t1"
       :role tool
       :tool-call-id "call-1"
       :name "bash"
       :content "done"))
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
