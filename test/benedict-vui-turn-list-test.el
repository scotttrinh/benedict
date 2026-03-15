;;; benedict-vui-turn-list-test.el --- Tests for VUI turn list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for mounted VUI turn list behavior.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-turn-list)

(defun benedict-vui-turn-list-test--count-matches (text pattern)
  "Count non-overlapping occurrences of PATTERN in TEXT."
  (let ((start 0)
        (count 0))
    (while (string-match pattern text start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(ert-deftest benedict-vui-turn-list-mount-groups-and-orders-turns ()
  "Mounted turn list preserves grouped turn ordering in output."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-list
                     :conversation (list (list :role 'assistant :content "Lead assistant")
                                         (list :id "u1" :role 'user :content "Question one")
                                         (list :id "a1" :role 'assistant :content "Answer one")
                                         (list :role 'assistant :content "Answer one followup")
                                         (list :id "u2" :role 'user :content "Question two")
                                         (list :id "a2" :role 'assistant :content "Answer two"))
                     :streaming nil
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (let* ((text (buffer-string))
           (lead-pos (string-match "Lead assistant" text))
           (q1-pos (string-match "Question one" text))
           (a1-pos (string-match "Answer one" text))
           (a1-followup-pos (string-match "Answer one followup" text))
           (q2-pos (string-match "Question two" text))
           (a2-pos (string-match "Answer two" text)))
      (should lead-pos)
      (should q1-pos)
      (should a1-pos)
      (should a1-followup-pos)
      (should q2-pos)
      (should a2-pos)
      (should (< lead-pos q1-pos))
      (should (< q1-pos a1-pos))
      (should (< a1-pos a1-followup-pos))
      (should (< a1-followup-pos q2-pos))
      (should (< q2-pos a2-pos))
      (should (= (benedict-vui-turn-list-test--count-matches text "USER") 2))
      (should (>= (benedict-vui-turn-list-test--count-matches text "ASSISTANT") 4)))))

(ert-deftest benedict-vui-turn-list-mount-streaming-prefers-display-content-and-synthetic-key ()
  "Mounted streaming message uses display content and nav-index fallback key."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-list
                     :conversation (list (list :role 'assistant
                                               :content "Hidden raw content"
                                               :display-content "Streaming partial"
                                               :streaming t))
                     :streaming nil
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (let* ((text (buffer-string))
           (pos (string-match "Streaming partial" text)))
      (should (string-match-p "ASSISTANT" text))
      (should (string-match-p "Streaming partial" text))
      (should-not (string-match-p "Hidden raw content" text))
      (should pos)
      (should (eq (get-text-property pos 'benedict-region-kind text) 'body))
      (should (equal (get-text-property pos 'benedict-message-key text) 0)))))

(ert-deftest benedict-vui-turn-list-mount-applies-navigation-properties-across-turns ()
  "Mounted turn list propagates message keys across id and nav-index cases."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-list
                     :conversation (list (list :id "u1" :role 'user :content "Question with id")
                                         (list :role 'assistant :content "Answer without id")
                                         (list :role 'user :content "Question without id")
                                         (list :id "a2" :role 'assistant :content "Answer with id"))
                     :streaming nil
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (benedict-vui-test--assert-text-properties-for
     "Question with id"
     :region-kind 'body
     :message-key "u1")
    (benedict-vui-test--assert-text-properties-for
     "Answer without id"
     :region-kind 'body
     :message-key 1)
    (benedict-vui-test--assert-text-properties-for
     "Question without id"
     :region-kind 'body
     :message-key 2)
    (benedict-vui-test--assert-text-properties-for
     "Answer with id"
     :region-kind 'body
     :message-key "a2")))

(ert-deftest benedict-vui-turn-list-mount-empty-conversation-renders-nothing ()
  "Mounted turn list renders nothing for nil and empty conversation values."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-list
                     :conversation nil
                     :streaming nil
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (should (string-empty-p (string-trim (buffer-string)))))
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-list
                     :conversation (list nil)
                     :streaming nil
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (should (string-empty-p (string-trim (buffer-string))))))

(ert-deftest benedict-vui-turn-list-derive-turns-exposes-turn-metadata ()
  "Derived turns expose lifecycle and outcome metadata at turn scope."
  (let* ((messages (benedict-vui-turn-list--normalize-messages
                    (list (list :id "u1" :role 'user :content "Question one")
                          (list :id "a1" :role 'assistant
                                :content "Answer one"
                                :thinking "Reasoning"
                                :tool-calls (list (list :id "call-1"
                                                        :name "bash"
                                                        :arguments "pwd"))))))
         (turns (benedict-vui-turn-list--derive-turns messages nil))
         (turn (car turns))
         (summary (plist-get turn :execution-summary))
         (outcome (plist-get turn :outcome-message)))
    (should (= 1 (length turns)))
    (should (equal (plist-get turn :id) "u1"))
    (should (equal (plist-get turn :prompt-text) "Question one"))
    (should (equal (benedict-message-id outcome) "a1"))
    (should (plist-get turn :completed))
    (should (plist-get turn :historical))
    (should-not (plist-get turn :active))
    (should (plist-get turn :has-execution-blocks))
    (should (= (plist-get summary :tool-count) 1))
    (should (equal (plist-get summary :tool-names) '("bash")))
    (should (plist-get summary :has-thinking))))

(ert-deftest benedict-vui-turn-list-derive-turns-merges-active-streaming-into-last-turn ()
  "Active streaming is attached to the current turn and marked as in-flight."
  (let* ((messages (benedict-vui-turn-list--normalize-messages
                    (list (list :id "u1" :role 'user :content "Question one"))))
         (turns (benedict-vui-turn-list--derive-turns
                 messages
                 '(:status active
                   :content "Draft answer"
                   :thinking "Working"
                   :tool-calls ((:id "call-1" :name "bash" :arguments "pwd")))))
         (turn (car turns))
         (outcome (plist-get turn :outcome-message))
         (summary (plist-get turn :execution-summary)))
    (should (= 1 (length turns)))
    (should (plist-get turn :active))
    (should (plist-get turn :streaming))
    (should-not (plist-get turn :completed))
    (should-not (plist-get turn :historical))
    (should (equal (plist-get turn :prompt-text) "Question one"))
    (should (equal (benedict-message-text outcome) "Draft answer"))
    (should (plist-get turn :has-execution-blocks))
    (should (equal (plist-get summary :tool-names) '("bash")))
    (should (plist-get summary :has-thinking))))

(ert-deftest benedict-vui-turn-list-mount-active-turn-uses-prompt-activity-layout ()
  "Mounted active turns keep the prompt attached to live assistant work."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-list
                     :conversation (list (list :id "u1" :role 'user :content "Question one"))
                     :streaming '(:status active
                               :content "Draft answer"
                               :thinking "Working"
                               :tool-calls ((:id "call-1" :name "bash" :arguments "pwd")))
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (let* ((text (buffer-string))
           (prompt-pos (string-match "Prompt" text))
           (question-pos (string-match "Question one" text))
           (activity-pos (string-match "Activity" text))
           (tool-pos (string-match "Tool: bash" text))
           (draft-label-pos (string-match "Draft answer" text))
           (draft-text-pos (string-match "Draft answer" text (1+ draft-label-pos))))
      (should prompt-pos)
      (should question-pos)
      (should activity-pos)
      (should tool-pos)
      (should draft-label-pos)
      (should draft-text-pos)
      (should (< prompt-pos question-pos))
      (should (< question-pos activity-pos))
      (should (< activity-pos tool-pos))
      (should (< tool-pos draft-label-pos))
      (should (< draft-label-pos draft-text-pos)))))

(provide 'test/benedict-vui-turn-list-test)
;;; benedict-vui-turn-list-test.el ends here
