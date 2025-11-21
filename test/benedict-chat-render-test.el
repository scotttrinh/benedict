;;; test/benedict-chat-render-test.el --- Tests for benedict-chat-render  -*- lexical-binding: t; -*-

(require 'ert)
(require 'benedict-chat-render)

(ert-deftest benedict-chat-render-insert-message ()
  "Test inserting a message with role and content."
  (with-temp-buffer
    (benedict-chat--insert-message '(:role user :content "Hello"))
    
    (goto-char (point-min))
    (should (looking-at-p "\\[USER\\]"))
    (should (eq (get-text-property (point) 'benedict-region-kind) 'header))
    (should (eq (get-text-property (point) 'face) 'benedict-chat-role))
    
    (forward-line 1)
    (should (looking-at-p "Hello"))
    (should (eq (get-text-property (point) 'benedict-region-kind) 'body))
    ;; Face should be nil initially (left to markdown-mode)
    (should (null (get-text-property (point) 'face)))))

(provide 'test/benedict-chat-render-test)
;;; benedict-chat-render-test.el ends here
