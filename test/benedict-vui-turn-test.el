;;; benedict-vui-turn-test.el --- Tests for VUI turn -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI turn component mounted behavior.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-turn)

(defun benedict-vui-turn-test--face-member-p (actual expected)
  "Return non-nil when ACTUAL face includes EXPECTED."
  (cond
   ((eq actual expected) t)
   ((listp actual) (memq expected actual))
   (t nil)))

(defun benedict-vui-turn-test--assert-face-at-match (needle face &optional start)
  "Assert NEEDLE text includes FACE, searching from START when provided."
  (let* ((text (buffer-string))
         (pos (string-match needle text start))
         (actual (and pos (get-text-property pos 'face text))))
    (should pos)
    (should (benedict-vui-turn-test--face-member-p actual face))
    pos))

(ert-deftest benedict-vui-turn-renders-derived-turn-message-list ()
  "Active turn records render prompt, activity, and draft in order."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "u1"
                                 :prompt-text "Question"
                                 :active t
                                 :streaming t
                                 :completed nil
                                 :historical nil
                                 :has-execution-blocks t
                                 :execution-expanded nil
                                 :execution-summary '(:tool-count 1 :tool-names ("bash"))
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :role 'assistant
                                                       :content "Draft answer"
                                                       :thinking "Working"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                         :name "bash"
                                                                         :arguments "pwd"))))))
    (let* ((text (buffer-string))
           (prompt-pos (string-match "Prompt" text))
           (question-pos (string-match "Question" text))
           (activity-pos (string-match "Activity" text))
           (thinking-pos (string-match "THINKING" text))
           (tool-pos (string-match "Tool: bash" text))
           (draft-label-pos (string-match "Draft answer" text))
           (draft-text-pos (string-match "Draft answer" text (1+ draft-label-pos))))
      (should prompt-pos)
      (should question-pos)
      (should activity-pos)
      (should thinking-pos)
      (should tool-pos)
      (should draft-label-pos)
      (should draft-text-pos)
      (should (< prompt-pos question-pos))
      (should (< question-pos activity-pos))
      (should (< activity-pos thinking-pos))
      (should (< thinking-pos draft-label-pos))
      (should (< draft-label-pos draft-text-pos))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property prompt-pos 'face text)
               'benedict-chat-turn-prompt-header))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property activity-pos 'face text)
               'benedict-chat-turn-active))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property draft-text-pos 'face text)
               'benedict-chat-turn-active)))))

(ert-deftest benedict-vui-turn-active-turn-without-execution-renders-working-state ()
  "Active turns without execution blocks still render a working activity lane."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "u1"
                                 :prompt-text "Question"
                                 :active t
                                 :streaming t
                                 :completed nil
                                 :historical nil
                                 :has-execution-blocks nil
                                 :execution-expanded nil
                                 :execution-summary nil
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :role 'assistant
                                                       :content "Draft answer"))))
    (let ((text (buffer-string)))
      (should (string-match-p "Prompt" text))
      (should (string-match-p "Activity" text))
      (should (string-match-p "Waiting for assistant output." text))
      (should (string-match-p "Draft answer" text))
      (benedict-vui-turn-test--assert-face-at-match
       "Waiting for assistant output."
       'benedict-chat-turn-active))))

(ert-deftest benedict-vui-turn-active-turn-sections-expose-turn-navigation-properties ()
  "Active turn sections mark prompt, activity, and draft as turn-level targets."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "turn-1"
                                 :prompt-text "Question"
                                 :active t
                                 :streaming t
                                 :completed nil
                                 :historical nil
                                 :has-execution-blocks t
                                 :execution-expanded nil
                                 :execution-summary '(:tool-count 1 :tool-names ("bash"))
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :id "a1"
                                                       :role 'assistant
                                                       :content "Draft answer"
                                                       :thinking "Working"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                          :name "bash"
                                                                          :arguments "pwd"))))))
    (let* ((text (buffer-string))
           (prompt-pos (string-match "Prompt" text))
           (activity-pos (string-match "Activity" text))
           (draft-pos (string-match "Draft answer" text)))
      (should prompt-pos)
      (should activity-pos)
      (should draft-pos)
      (should (equal (get-text-property prompt-pos 'benedict-turn-id text) "turn-1"))
      (should (eq (get-text-property prompt-pos 'benedict-turn-target text) 'prompt))
      (should (equal (get-text-property prompt-pos 'benedict-message-key text) "u1"))
      (should (equal (get-text-property activity-pos 'benedict-turn-id text) "turn-1"))
      (should (eq (get-text-property activity-pos 'benedict-turn-target text) 'activity))
      (should (equal (get-text-property activity-pos 'benedict-message-key text) "a1"))
      (should (equal (get-text-property draft-pos 'benedict-turn-id text) "turn-1"))
      (should (eq (get-text-property draft-pos 'benedict-turn-target text) 'draft))
      (should (equal (get-text-property draft-pos 'benedict-message-key text) "a1")))))

(ert-deftest benedict-vui-turn-completed-turn-promotes-answer-and-collapses-details ()
  "Completed turns show the final answer first and hide execution detail by default."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "u1"
                                 :prompt-text "Question"
                                 :active nil
                                 :streaming nil
                                 :completed t
                                 :historical t
                                 :has-execution-blocks t
                                 :execution-expanded nil
                                 :execution-summary '(:tool-count 1
                                                     :tool-names ("bash")
                                                     :error-count 1
                                                     :warning-count 0
                                                     :has-thinking t
                                                     :has-errors t
                                                     :has-approvals nil
                                                     :highlights ("bash: Tool error: boom"))
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :id "a1"
                                                       :role 'assistant
                                                       :content "Final answer"
                                                       :thinking "Reasoning"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                          :name "bash"
                                                                          :arguments "pwd")))
                                                 (list :id "t1"
                                                       :role 'tool
                                                       :tool-call-id "call-1"
                                                       :name "bash"
                                                       :content "Tool error: boom"
                                                       :metadata '(:status failure
                                                                  :error (:message "boom"))))))
    (let* ((text (buffer-string))
           (prompt-pos (string-match "Prompt" text))
           (answer-pos (string-match "Answer" text))
           (final-pos (string-match "Final answer" text))
           (execution-pos (string-match "Execution" text))
           (summary-pos (string-match "1 tool" text))
           (highlight-pos (string-match "bash: Tool error: boom" text)))
      (should prompt-pos)
      (should answer-pos)
      (should final-pos)
      (should execution-pos)
      (should summary-pos)
      (should highlight-pos)
      (should (< prompt-pos answer-pos))
      (should (< answer-pos final-pos))
      (should (< final-pos execution-pos))
      (should-not (string-match-p "Execution details" text))
      (should-not (string-match-p "Tool: bash" text))
      (let ((case-fold-search nil))
      (should-not (string-match-p "THINKING" text)))
      (should (string-match-p "Show details" text))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property prompt-pos 'face text)
               'benedict-chat-turn-prompt-header))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property answer-pos 'face text)
               'benedict-chat-turn-outcome))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property final-pos 'face text)
               'benedict-chat-turn-outcome))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property execution-pos 'face text)
               'benedict-chat-turn-summary))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property summary-pos 'face text)
               'benedict-chat-turn-summary))
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property highlight-pos 'face text)
               'benedict-chat-turn-summary)))))

(ert-deftest benedict-vui-turn-expanded-execution-details-use-detail-face ()
  "Expanded execution detail regions keep turn-level detail styling."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "u1"
                                 :prompt-text "Question"
                                 :active nil
                                 :streaming nil
                                 :completed t
                                 :historical t
                                 :has-execution-blocks t
                                 :execution-expanded t
                                 :execution-summary '(:tool-count 1
                                                     :tool-names ("bash")
                                                     :has-thinking t)
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :id "a1"
                                                       :role 'assistant
                                                       :content "Final answer"
                                                       :thinking "Reasoning"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                          :name "bash"
                                                                          :arguments "pwd"))))))
    (let* ((text (buffer-string))
           (details-pos (string-match "Execution details" text))
           (thinking-pos (string-match "THINKING" text)))
      (should details-pos)
      (should thinking-pos)
      (should (benedict-vui-turn-test--face-member-p
               (get-text-property details-pos 'face text)
               'benedict-chat-turn-detail)))))

(ert-deftest benedict-vui-turn-completed-turn-without-user-message-falls-back-to-first-message ()
  "Completed turns still render a prompt section when history starts mid-turn."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "turn-1"
                                 :active nil
                                 :streaming nil
                                 :completed t
                                 :historical t
                                 :execution-expanded nil
                                 :execution-summary nil
                                 :messages (list (list :id "a1"
                                                       :role 'assistant
                                                       :content "Recovered answer")
                                                 (list :id "t1"
                                                       :role 'tool
                                                       :tool-call-id "call-1"
                                                       :name "bash"
                                                       :content "tool output"
                                                       :metadata '(:status success)))))
    (let* ((text (buffer-string))
           (prompt-pos (string-match "Prompt" text))
           (prompt-text-pos (string-match "Recovered answer" text))
           (answer-pos (string-match "Answer" text)))
      (should prompt-pos)
      (should prompt-text-pos)
      (should answer-pos)
      (should (< prompt-pos prompt-text-pos))
      (should (< prompt-text-pos answer-pos)))))

(ert-deftest benedict-vui-turn-completed-turn-expands-execution-details-when-enabled ()
  "Completed turns render execution blocks when expansion is enabled at turn scope."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "u1"
                                 :prompt-text "Question"
                                 :active nil
                                 :streaming nil
                                 :completed t
                                 :historical t
                                 :has-execution-blocks t
                                 :execution-expanded t
                                 :execution-summary '(:tool-count 1
                                                     :tool-names ("bash")
                                                     :error-count 0
                                                     :warning-count 0
                                                     :has-thinking t
                                                     :has-errors nil
                                                     :has-approvals t
                                                     :highlights nil)
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :id "a1"
                                                       :role 'assistant
                                                       :content "Final answer"
                                                       :thinking "Reasoning"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                          :name "bash"
                                                                          :arguments "pwd"
                                                                          :status 'awaiting-approval))))))
    (let ((text (buffer-string)))
      (should (string-match-p "Execution details" text))
      (should (string-match-p "THINKING" text))
      (should (string-match-p "Tool: bash" text))
      (should (string-match-p "Hide details" text)))))

(ert-deftest benedict-vui-turn-completed-turn-toggle-reveals-and-hides-details ()
  "Execution summary toggle updates the mounted completed turn in place."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "u1"
                                 :prompt-text "Question"
                                 :active nil
                                 :streaming nil
                                 :completed t
                                 :historical t
                                 :has-execution-blocks t
                                 :execution-expanded nil
                                 :execution-summary '(:tool-count 1
                                                     :tool-names ("bash")
                                                     :has-thinking t)
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :id "a1"
                                                       :role 'assistant
                                                       :content "Final answer"
                                                       :thinking "Reasoning"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                          :name "bash"
                                                                          :arguments "pwd"))))))
    (let ((text (buffer-string)))
      (should (string-match-p "Show details" text))
      (should-not (string-match-p "Execution details" text))
      (should-not (string-match-p "Tool: bash" text)))
    (benedict-vui-test--click-button-labeled "Show details")
    (vui-flush-sync)
    (let ((text (buffer-string)))
      (should (string-match-p "Hide details" text))
      (should (string-match-p "Execution details" text))
      (should (string-match-p "THINKING" text))
      (should (string-match-p "Tool: bash" text)))
    (benedict-vui-test--click-button-labeled "Hide details")
    (vui-flush-sync)
    (let ((text (buffer-string)))
      (should (string-match-p "Show details" text))
      (should-not (string-match-p "Execution details" text))
      (should-not (string-match-p "Tool: bash" text)))))

(ert-deftest benedict-vui-turn-turn-sections-expose-turn-navigation-properties ()
  "Turn sections mark prompt, outcome, and execution summary as turn-level targets."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "turn-1"
                                 :prompt-text "Question"
                                 :active nil
                                 :streaming nil
                                 :completed t
                                 :historical t
                                 :has-execution-blocks t
                                 :execution-expanded nil
                                 :execution-summary '(:tool-count 1
                                                     :tool-names ("bash")
                                                     :has-thinking t)
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :id "a1"
                                                       :role 'assistant
                                                       :content "Final answer"
                                                       :thinking "Reasoning"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                          :name "bash"
                                                                          :arguments "pwd"))))))
    (let* ((text (buffer-string))
           (prompt-pos (string-match "Prompt" text))
           (answer-pos (string-match "Answer" text))
           (execution-pos (string-match "Execution" text)))
      (should prompt-pos)
      (should answer-pos)
      (should execution-pos)
      (should (equal (get-text-property prompt-pos 'benedict-turn-id text) "turn-1"))
      (should (eq (get-text-property prompt-pos 'benedict-turn-target text) 'prompt))
      (should (equal (get-text-property prompt-pos 'benedict-message-key text) "u1"))
      (should (equal (get-text-property answer-pos 'benedict-turn-id text) "turn-1"))
      (should (eq (get-text-property answer-pos 'benedict-turn-target text) 'outcome))
      (should (equal (get-text-property answer-pos 'benedict-message-key text) "a1"))
      (should (equal (get-text-property execution-pos 'benedict-turn-id text) "turn-1"))
      (should (eq (get-text-property execution-pos 'benedict-turn-target text)
                  'execution-summary)))))

(provide 'test/benedict-vui-turn-test)
;;; benedict-vui-turn-test.el ends here
