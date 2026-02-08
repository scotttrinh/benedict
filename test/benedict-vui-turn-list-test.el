;;; benedict-vui-turn-list-test.el --- Tests for VUI turn list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for mounted VUI turn list behavior.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vui)
(require 'benedict-vui-turn-list)

(defun benedict-vui-turn-list-test--count-matches (text pattern)
  "Count non-overlapping occurrences of PATTERN in TEXT."
  (let ((start 0)
        (count 0))
    (while (string-match pattern text start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(ert-deftest benedict-vui-turn-list-mount-renders-multiple-turns ()
  "Mounted turn list renders multiple user/assistant turns."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-turn-list
                      :conversation (list (list :id "u1" :role 'user :content "Question one")
                                          (list :id "a1" :role 'assistant :content "Answer one")
                                          (list :id "u2" :role 'user :content "Question two")
                                          (list :id "a2" :role 'assistant :content "Answer two"))
                      :collapsed-blocks nil
                      :on-toggle-block #'ignore)
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "Question one" text))
        (should (string-match-p "Answer one" text))
        (should (string-match-p "Question two" text))
        (should (string-match-p "Answer two" text))
        (should (= (benedict-vui-turn-list-test--count-matches text "USER") 2))
        (should (= (benedict-vui-turn-list-test--count-matches text "ASSISTANT") 2))))))

(ert-deftest benedict-vui-turn-list-mount-renders-streaming-message-without-id ()
  "Mounted turn list renders assistant streaming text without message ids."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-turn-list
                      :conversation (list (list :role 'assistant
                                                :content "Streaming partial"
                                                :streaming t))
                      :collapsed-blocks nil
                      :on-toggle-block #'ignore)
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "ASSISTANT" text))
        (should (string-match-p "Streaming partial" text))))))

(ert-deftest benedict-vui-turn-list-mount-applies-navigation-properties ()
  "Mounted turn list propagates message keys to rendered block text."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-turn-list
                      :conversation (list (list :role 'assistant
                                                :content "No id content"))
                      :collapsed-blocks nil
                      :on-toggle-block #'ignore)
       buffer-name)
      (vui-flush-sync)
      (let* ((text (buffer-string))
             (pos (string-match "No id content" text)))
        (should pos)
        (should (eq (get-text-property pos 'benedict-region-kind text) 'body))
        (should (equal (get-text-property pos 'benedict-message-key text) 0))))))

(provide 'test/benedict-vui-turn-list-test)
;;; benedict-vui-turn-list-test.el ends here
