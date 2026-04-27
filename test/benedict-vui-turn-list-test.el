;;; benedict-vui-turn-list-test.el --- Tests for VUI turn list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for mounted VUI turn list behavior.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-turn)
(require 'benedict-vui-turn-list)

(ert-deftest benedict-vui-turn-list-mount-empty-renders-nothing ()
  "Mounted turn list renders nothing for nil values."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-list
                     :session nil
                     :turns nil
                     :active-turn nil
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (should (string-empty-p (string-trim (buffer-string))))))

(ert-deftest benedict-vui-turn-list-renders-completed-and-active-turns ()
  "Mounted turn list renders explicit completed turns plus the active turn."
  (let* ((benedict-session--registry (make-hash-table :test #'equal))
         (session (benedict-session-create))
         (u1 (benedict-session-add-message session (benedict-message-user-text "Completed prompt")))
         (a1 (benedict-session-add-message session (benedict-message-assistant-text "Completed answer")))
         (u2 (benedict-session-add-message session (benedict-message-user-text "Active prompt")))
         (completed (benedict-turn-create (benedict-session-id session)
                                          :id "turn-completed"
                                          :prompt-message-id (benedict-message-id u1)
                                          :outcome-message-id (benedict-message-id a1)
                                          :message-ids (list (benedict-message-id u1)
                                                             (benedict-message-id a1))
                                          :state 'turn-complete))
         (active (benedict-turn-create (benedict-session-id session)
                                       :id "turn-active"
                                       :prompt-message-id (benedict-message-id u2)
                                       :message-ids (list (benedict-message-id u2))
                                       :state 'running)))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn-list
                       :session session
                       :turns (list completed)
                       :active-turn active
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (let ((text (buffer-string)))
        (should (string-match-p "Completed prompt" text))
        (should (string-match-p "Completed answer" text))
        (should (string-match-p "Active prompt" text))
        (should (string-match-p "Activity" text))))))

(provide 'test/benedict-vui-turn-list-test)
;;; benedict-vui-turn-list-test.el ends here
