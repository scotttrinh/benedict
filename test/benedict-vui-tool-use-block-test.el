;;; benedict-vui-tool-use-block-test.el --- Tests for VUI tool use block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI tool use block component behavior.

;;; Code:

(require 'ert)
(require 'vui)
(require 'benedict-vui-tool-use-block)
(require 'test/benedict-vui-test-utils)

(vui-defcomponent benedict-vui-tool-use-block-test--harness (tool-call status)
  :state ((collapsed t))
  :render
  (vui-component 'benedict-vui-tool-use-block
                 :tool-call tool-call
                 :status status
                 :collapsed collapsed
                 :on-toggle (lambda (next)
                              (vui-set-state :collapsed next))
                 :message-key "msg-1"
                 :block-id "block-1"))

(ert-deftest benedict-vui-tool-use-block-header-shows-name-and-status ()
  "Header includes tool name and status badge."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-tool-use-block
                     :tool-call '(:name "bash")
                     :status 'running
                     :collapsed t
                     :message-key "msg-1"
                     :block-id "block-1")
    (should (string-match-p "Tool: bash" (buffer-string)))
    (should (string-match-p "RUNNING" (buffer-string)))))

(ert-deftest benedict-vui-tool-use-block-formats-arguments-content ()
  "Expanded content includes formatted arguments."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-tool-use-block
                     :tool-call '(:arguments (:foo 1 :bar "hi"))
                     :status 'success
                     :collapsed nil
                     :message-key "msg-1"
                     :block-id "block-1")
    (should (string-match-p "Arguments:" (buffer-string)))
    (should (string-match-p ":foo" (buffer-string)))
    (should (string-match-p "1" (buffer-string)))
    (should (string-match-p "hi" (buffer-string)))))

(ert-deftest benedict-vui-tool-use-block-normalizes-statuses ()
  "Status normalization handles in-progress, success, and failure states."
  (dolist (entry '((pending "RUNNING")
                   (in-progress "RUNNING")
                   (success "SUCCESS")
                   (failure "FAILURE")))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-tool-use-block
                       :tool-call '(:name "bash")
                       :status (car entry)
                       :collapsed t
                       :message-key "msg-1"
                       :block-id "block-1")
      (should (string-match-p (cadr entry) (buffer-string))))))

(ert-deftest benedict-vui-tool-use-block-shows-spinner-when-running ()
  "Spinner is visible for running state only."
  (dolist (entry '((running t)
                   (in-progress t)
                   (success nil)
                   (failure nil)))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-tool-use-block
                       :tool-call '(:name "bash")
                       :status (car entry)
                       :collapsed t
                       :message-key "msg-1"
                       :block-id "block-1")
      (if (cadr entry)
          (should (string-match-p (regexp-quote "...") (buffer-string)))
        (should-not (string-match-p (regexp-quote "...") (buffer-string)))))))

(ert-deftest benedict-vui-tool-use-block-render-test ()
  "Tool use block renders header and content."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-tool-use-block
                     :tool-call '(:name "my-tool" :arguments "args")
                     :status 'running
                     :collapsed nil
                     :message-key "msg-1"
                     :block-id "block-1")
    (should (string-match-p "Tool: my-tool" (buffer-string)))
    (should (string-match-p "args" (buffer-string)))))

(ert-deftest benedict-vui-tool-use-block-toggle-test ()
  "Toggle button reveals tool arguments in the buffer."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-tool-use-block-test--harness
                     :tool-call '(:name "my-tool" :arguments "args")
                     :status 'running)
    (should (string-match-p "Tool: my-tool" (buffer-string)))
    (should-not (string-match-p "Arguments:" (buffer-string)))
    (goto-char (point-min))
    (benedict-vui-test--click-button-at (point-min))
    (vui-flush-sync)
    (should (string-match-p "Arguments:" (buffer-string)))
    (should (string-match-p "args" (buffer-string)))))

(provide 'test/benedict-vui-tool-use-block-test)
;;; benedict-vui-tool-use-block-test.el ends here
