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
  "Turn composes the header and content list nodes."
  (let (header-props list-props stack-children)
    (cl-letf (((symbol-function 'benedict-vui-turn-header)
               (lambda (&rest args)
                 (setq header-props args)
                 'header))
              ((symbol-function 'benedict-vui-content-block-list)
               (lambda (&rest args)
                 (setq list-props args)
                 'blocks))
              ((symbol-function 'vui-vstack)
               (lambda (&rest children)
                 (setq stack-children children)
                 'stack)))
      (vui-component 'benedict-vui-turn--render
       (list :message (list :role 'user :content "Hi" :timestamp 123)))
      (should (equal stack-children '(header blocks)))
      (should (eq (plist-get header-props :role) 'user))
      (should (equal (plist-get header-props :timestamp) 123))
      (should (plist-get list-props :blocks)))))

(ert-deftest benedict-vui-turn-applies-role-face-to-text ()
  "Turn applies role faces to text block content."
  (let* ((user-message (list :role 'user :content "Hello"))
         (assistant-message (list :role 'assistant :content "Hi"))
         (user-block (car (vui-component 'benedict-vui-turn--blocks (list :message user-message))))
         (assistant-block (car (vui-component 'benedict-vui-turn--blocks (list :message assistant-message)))))
    (should (vui-component 'benedict-vui-turn-test--face-member-p
             'benedict-chat-user
             (plist-get user-block :content)))
    (should (vui-component 'benedict-vui-turn-test--face-member-p
             'benedict-chat-assistant
             (plist-get assistant-block :content)))))

(ert-deftest benedict-vui-turn-tool-messages-render-results ()
  "Tool role messages render as tool result blocks."
  (let* ((message (list :role 'tool :content "ok" :metadata '(:status success)))
         (blocks (vui-component 'benedict-vui-turn--blocks (list :message message)))
         (block (car blocks)))
    (should (eq (plist-get block :type) 'tool-result))
    (should (equal (plist-get block :result) message))))

(provide 'test/benedict-vui-turn-test)
;;; benedict-vui-turn-test.el ends here
