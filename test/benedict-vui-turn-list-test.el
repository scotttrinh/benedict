;;; benedict-vui-turn-list-test.el --- Tests for VUI turn list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for mounted VUI turn list behavior.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-turn-list)

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
                                                        :arguments "pwd")))
                          (list :id "t1" :role 'tool
                                :tool-call-id "call-1"
                                :name "bash"
                                :content "Tool error: boom"
                                :metadata '(:status failure
                                           :error (:message "boom"))))))
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
    (should (= (plist-get summary :error-count) 1))
    (should (plist-get summary :has-thinking))
    (should (equal (plist-get summary :highlights)
                   '("bash: Tool error: boom")))))

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

(provide 'test/benedict-vui-turn-list-test)
;;; benedict-vui-turn-list-test.el ends here
