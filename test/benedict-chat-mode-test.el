;;; test/benedict-chat-mode-test.el --- Tests for benedict-chat-mode  -*- lexical-binding: t; -*-

(require 'ert)
(require 'benedict-chat)
(require 'benedict-chat-mode) ;; TODO: Remove this require after benedict-chat-mode.el is deleted in Phase 3

(ert-deftest benedict-chat-mode-initialization ()
  "Test that benedict-chat-mode sets up the buffer correctly."
  (with-temp-buffer
    (benedict-chat-mode)
    (should (derived-mode-p 'magit-section-mode))
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
    
    (let ((item (list :content-start (copy-marker (point-min) nil)
                      :content-end (copy-marker (point-min) t))))
      (benedict-chat--stream-init (current-buffer) item))
    
    ;; Insert enough text to potentially trigger font-lock extension
    (benedict-chat--stream-insert-delta benedict-stream-state "Some text\n")
    (benedict-chat--stream-insert-delta benedict-stream-state "```python\nprint('hello')\n```\n")
    
    ;; Trigger fontification explicitly which calls extend-region functions
    (font-lock-ensure)
    
    (should (string-match-p "print" (buffer-string)))))

(provide 'test/benedict-chat-mode-test)
;;; benedict-chat-mode-test.el ends here
