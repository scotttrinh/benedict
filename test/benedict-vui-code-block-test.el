;;; benedict-vui-code-block-test.el --- Tests for VUI code block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI code block component helpers.

;;; Code:

(require 'ert)
(require 'ert-async)
(require 'benedict-vui-code-block)

(defun benedict-vui-code-block-test--face-member-p (face value)
  "Return non-nil when FACE is present in VALUE."
  (cond
   ((null value) nil)
   ((eq value face) t)
   ((listp value) (memq face value))
   (t nil)))

(ert-deftest benedict-vui-code-block-fontify-applies-base-face ()
  "Fontified code includes the base code face."
  (let ((text (benedict-vui-code-block--fontify "(message \"hi\")" "emacs-lisp")))
    (should (benedict-vui-code-block-test--face-member-p
             'markdown-code-face
             (get-text-property 0 'face text)))))

(ert-deftest benedict-vui-code-block-fontify-adds-syntax-face ()
  "Fontified code preserves syntax highlighting faces."
  (let ((text (benedict-vui-code-block--fontify ";; comment" "emacs-lisp")))
    (should (or (benedict-vui-code-block-test--face-member-p
                 'font-lock-comment-face
                 (get-text-property 0 'face text))
                (benedict-vui-code-block-test--face-member-p
                 'font-lock-comment-delimiter-face
                 (get-text-property 0 'face text))))))

(ert-deftest-async benedict-vui-code-block-copy-feedback-clears (done)
  "Copy feedback toggles on and clears after timeout."
  (let ((benedict-vui-code-block-copy-feedback-timeout 0.01)
        (states nil))
    (benedict-vui-code-block--copy "hello"
                                   (lambda (value)
                                     (push value states)))
    (should (equal states '(t)))
    (run-at-time 0.02 nil
                 (lambda ()
                   (should (equal states '(nil t)))
                   (funcall done)))))

(ert-deftest benedict-vui-code-block-handles-unknown-language ()
  "Unknown languages fall back to plain rendering."
  (let ((text (benedict-vui-code-block--fontify "hi" "unknownlang")))
    (should (stringp text))
    (should (equal text "hi"))
    (should (benedict-vui-code-block-test--face-member-p
             'markdown-code-face
             (get-text-property 0 'face text)))))

(ert-deftest benedict-vui-code-block-render-test ()
  "Code block renders content and language label."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-code-block
                      :code "(+ 1 2)"
                      :language "emacs-lisp"
                      :message-key "msg-1"
                      :block-id "block-1")
       buffer-name)
      
      ;; Verify language label
      (should (string-match-p "EMACS-LISP" (buffer-string)))
      
      ;; Verify code content
      (should (string-match-p (regexp-quote "(+ 1 2)") (buffer-string)))
      
      ;; Verify copy button
      (should (string-match-p "Copy" (buffer-string))))))

(provide 'test/benedict-vui-code-block-test)
;;; benedict-vui-code-block-test.el ends here
