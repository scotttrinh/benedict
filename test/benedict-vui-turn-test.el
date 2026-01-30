;;; benedict-vui-turn-test.el --- Tests for VUI turn -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI turn component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-turn)

(defun benedict-vui-turn-test--face-member-p (face value)
  "Return non-nil when VALUE has FACE in its face property."
  (let ((actual (and (stringp value) (get-text-property 0 'face value))))
    (cond
     ((null actual) nil)
     ((listp actual) (memq face actual))
     (t (eq actual face)))))

(ert-deftest benedict-vui-turn-composes-header-and-blocks ()
  "Turn resolves role/timestamp from message and props."
  (let* ((message (list :role 'user :content "Hi" :timestamp 123))
         (role (benedict-vui-turn--message-role message nil))
         (timestamp (benedict-vui-turn--message-timestamp message nil)))
    (should (eq role 'user))
    (should (equal timestamp 123))))

(ert-deftest benedict-vui-turn-applies-role-face-to-text ()
  "Turn applies role faces to text block content."
  (let* ((user-message (list :role 'user :content "Hello"))
         (assistant-message (list :role 'assistant :content "Hi"))
         (user-block (car (benedict-vui-turn--blocks (list :message user-message))))
         (assistant-block (car (benedict-vui-turn--blocks (list :message assistant-message)))))
    (should (benedict-vui-turn-test--face-member-p
             'benedict-chat-user
             (plist-get user-block :content)))
    (should (benedict-vui-turn-test--face-member-p
             'benedict-chat-assistant
             (plist-get assistant-block :content)))))

(ert-deftest benedict-vui-turn-tool-messages-render-results ()
  "Tool role messages render as tool result blocks."
  (let* ((message (list :role 'tool :content "ok" :metadata '(:status success)))
         (blocks (benedict-vui-turn--blocks (list :message message)))
         (block (car blocks)))
    (should (eq (plist-get block :type) 'tool-result))
    (should (equal (plist-get block :result) message))))

(provide 'test/benedict-vui-turn-test)
;;; benedict-vui-turn-test.el ends here
