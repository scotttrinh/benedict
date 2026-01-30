;;; benedict-vui-tool-use-block-test.el --- Tests for VUI tool use block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI tool use block component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-tool-use-block)

(ert-deftest benedict-vui-tool-use-block-header-shows-name-and-status ()
  "Header includes tool name and status badge."
  (let ((title (benedict-vui-tool-use-block--header-title '(:name "bash"))))
    (should (string-match-p "bash" title))))

(ert-deftest benedict-vui-tool-use-block-formats-arguments-content ()
  "Expanded content includes formatted arguments."
  (let ((text (benedict-vui-tool-use-block--content-text
               '(:arguments (:foo 1 :bar "hi")))))
    (should (string-match-p "Arguments:" text))
    (should (string-match-p ":foo" text))
    (should (string-match-p "1" text))
    (should (string-match-p "hi" text))))

(ert-deftest benedict-vui-tool-use-block-normalizes-statuses ()
  "Status normalization handles in-progress, success, and failure states."
  (should (eq (benedict-vui-tool-use-block--normalize-status 'in-progress) 'running))
  (should (eq (benedict-vui-tool-use-block--normalize-status 'pending) 'running))
  (should (eq (benedict-vui-tool-use-block--normalize-status 'success) 'success))
  (should (eq (benedict-vui-tool-use-block--normalize-status 'failure) 'failure)))

(ert-deftest benedict-vui-tool-use-block-shows-spinner-when-running ()
  "Spinner is visible for running state only."
  (should (benedict-vui-tool-use-block--spinner-visible-p 'running))
  (should (benedict-vui-tool-use-block--spinner-visible-p 'in-progress))
  (should-not (benedict-vui-tool-use-block--spinner-visible-p 'success))
  (should-not (benedict-vui-tool-use-block--spinner-visible-p 'failure)))

(provide 'test/benedict-vui-tool-use-block-test)
;;; benedict-vui-tool-use-block-test.el ends here
