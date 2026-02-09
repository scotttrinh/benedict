;;; benedict-vui-code-block-test.el --- Tests for VUI code block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI code block component helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vui)
(require 'test/benedict-vui-test-utils)
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
  (with-mounted-vui-component
      (vui-component 'benedict-vui-code-block
                     :code "(+ 1 2)"
                     :language "emacs-lisp"
                     :message-key "msg-1"
                     :block-id "block-1")
    (should (string-match-p "EMACS-LISP" (buffer-string)))
    (should (string-match-p (regexp-quote "(+ 1 2)") (buffer-string)))
    (should (string-match-p "Copy" (buffer-string)))))

(ert-deftest benedict-vui-code-block-copy-feedback-clears-with-stubbed-timer ()
  "Copy helper toggles feedback and clears through captured timer callback."
  (let ((states nil)
        (timer-callback nil)
        (timer-object (list :timer "copy")))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest args)
                 (setq timer-callback (car (last args)))
                 timer-object)))
      (let ((timer (benedict-vui-code-block--copy "hello"
                                                  (lambda (value)
                                                    (push value states)))))
        (should (equal timer timer-object))
        (should (equal states '(t)))
        (should timer-callback)
         (funcall timer-callback)
         (should (equal states '(nil t)))))))

(ert-deftest benedict-vui-code-block-copy-updates-kill-ring ()
  "Copy helper pushes normalized code into the kill ring."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (timer-callback nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest args)
                 (setq timer-callback (car (last args)))
                 :fake-timer)))
      (benedict-vui-code-block--copy "(message \"hello\")" (lambda (&rest _)))
      (should (equal (current-kill 0) "(message \"hello\")"))
      (should timer-callback))))

(ert-deftest benedict-vui-code-block-large-content-display-safety ()
  "Code block renders very large payloads without truncation or crashes."
  (let ((large-code (make-string 12000 ?x)))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-code-block
                       :code large-code
                       :language "text"
                       :message-key "msg-large"
                       :block-id "block-large")
      (should (string-match-p "TEXT" (buffer-string)))
      (should (search-forward (substring large-code 0 64) nil t))
      (should (search-forward (substring large-code (- (length large-code) 64)) nil t))
      (benedict-vui-test--assert-text-properties-for
       (substring large-code 0 32)
       :region-kind 'body
       :message-key "msg-large"
       :block-id "block-large"))))

(ert-deftest benedict-vui-code-block-render-applies-message-properties ()
  "Rendered code carries message and block text properties."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-code-block
                     :code "(+ 1 2)"
                     :language "emacs-lisp"
                     :message-key "msg-1"
                     :block-id "block-1")
    (let* ((text (buffer-string))
           (pos (string-match (regexp-quote "(+ 1 2)") text)))
      (should pos)
      (should (equal (get-text-property pos 'benedict-message-key text) "msg-1"))
      (should (equal (get-text-property pos 'benedict-block-id text) "block-1")))))

(provide 'test/benedict-vui-code-block-test)
;;; benedict-vui-code-block-test.el ends here
