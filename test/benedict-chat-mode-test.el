;;; test/benedict-chat-mode-test.el --- Tests for benedict-chat-mode  -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'benedict-chat)

(ert-deftest benedict-chat-mode-initialization ()
  "Test that benedict-chat-mode sets up the buffer correctly."
  (with-temp-buffer
    (benedict-chat-mode)
    (should (derived-mode-p 'vui-mode))
    (should buffer-read-only)
    (should (eq benedict-region-kind-property 'benedict-region-kind))
    (should (local-variable-p 'markdown-fontify-code-blocks-natively))
    (should markdown-fontify-code-blocks-natively)))

(ert-deftest benedict-reproduce-jit-lock-error ()
  "Attempt to reproduce the jit-lock error by inserting text in benedict-chat-mode.
Ensures that `font-lock-extend-region-functions' are correctly defined (0 arguments)
and `syntax-propertize-function' is valid."
  (with-temp-buffer
    (benedict-chat-mode)
    ;; Force font-lock to be active
    (font-lock-mode 1)

    ;; Insert enough text to potentially trigger font-lock extension.
    (let ((inhibit-read-only t))
      (insert (propertize "Some text\n" 'benedict-region-kind 'body))
      (insert (propertize "```python\nprint('hello')\n```\n"
                          'benedict-region-kind 'body)))
    
    ;; Trigger fontification explicitly which calls extend-region functions
    (font-lock-ensure)
    
    (should (string-match-p "print" (buffer-string)))))

(provide 'test/benedict-chat-mode-test)
;;; benedict-chat-mode-test.el ends here
