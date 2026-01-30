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
  (let ((text (vui-component 'benedict-vui-code-block--fontify "(message \"hi\")" "emacs-lisp")))
    (should (vui-component 'benedict-vui-code-block-test--face-member-p
             'markdown-code-face
             (get-text-property 0 'face text)))))

(ert-deftest benedict-vui-code-block-fontify-adds-syntax-face ()
  "Fontified code preserves syntax highlighting faces."
  (let ((text (vui-component 'benedict-vui-code-block--fontify ";; comment" "emacs-lisp")))
    (should (or (vui-component 'benedict-vui-code-block-test--face-member-p
                 'font-lock-comment-face
                 (get-text-property 0 'face text))
                (vui-component 'benedict-vui-code-block-test--face-member-p
                 'font-lock-comment-delimiter-face
                 (get-text-property 0 'face text))))))

(ert-deftest-async benedict-vui-code-block-copy-feedback-clears (done)
  "Copy feedback toggles on and clears after timeout."
  (let ((vui-component 'benedict-vui-code-block-copy-feedback-timeout 0.01)
        (states nil))
    (vui-component 'benedict-vui-code-block--copy "hello"
                                   (lambda (value)
                                     (push value states)))
    (should (equal states '(t)))
    (run-at-time 0.02 nil
                 (lambda ()
                   (should (equal states '(nil t)))
                   (funcall done)))))

(ert-deftest benedict-vui-code-block-handles-unknown-language ()
  "Unknown languages fall back to plain rendering."
  (let ((text (vui-component 'benedict-vui-code-block--fontify "hi" "unknownlang")))
    (should (stringp text))
    (should (equal text "hi"))
    (should (vui-component 'benedict-vui-code-block-test--face-member-p
             'markdown-code-face
             (get-text-property 0 'face text)))))

(provide 'test/benedict-vui-code-block-test)
;;; benedict-vui-code-block-test.el ends here
