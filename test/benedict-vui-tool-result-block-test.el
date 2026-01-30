;;; benedict-vui-tool-result-block-test.el --- Tests for VUI tool result block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI tool result block component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-tool-result-block)

(ert-deftest benedict-vui-tool-result-block-header-prefers-ui-header ()
  "Header uses UI header hint when available."
  (let ((title (benedict-vui-tool-result-block--header-title
                '(:ui (:header "Read file — foo.txt")))))
    (should (string-match-p "Read file" title))))

(ert-deftest benedict-vui-tool-result-block-body-prefers-ui-body ()
  "Body prefers UI :body text when present."
  (let ((body (benedict-vui-tool-result-block--body-text
               '(:content "Fallback"
                 :ui (:body "From UI")))))
    (should (equal body "From UI"))))

(ert-deftest benedict-vui-tool-result-block-truncates-long-body ()
  "Long body text is truncated with marker."
  (let* ((text (make-string 520 ?a))
         (truncation (benedict-vui-tool-result-block--truncate
                      text
                      benedict-vui-tool-result-block--truncate-limit)))
    (should (cdr truncation))
    (should (< (length (car truncation)) (length text)))))

(ert-deftest benedict-vui-tool-result-block-error-styles-body ()
  "Failure status applies error face to body text."
  (let ((text (benedict-vui-tool-result-block--propertize "Oops" 'failure)))
    (should (eq (get-text-property 0 'face text) 'benedict-chat-tool-error))))

(ert-deftest benedict-vui-tool-result-block-normalizes-actions ()
  "Actions are filtered to valid label/handler pairs."
  (let* ((actions (list (list :label "Open" :handler #'ignore)
                        (list :label 12 :handler #'ignore)
                        (list :label "Bad" :handler nil)))
         (normalized (benedict-vui-tool-result-block--normalize-actions actions)))
    (should (= (length normalized) 1))
    (should (equal (plist-get (car normalized) :label) "Open"))))

(ert-deftest benedict-vui-tool-result-block-error-overrides-status ()
  "Error info forces failure status even with success hints."
  (let ((status (benedict-vui-tool-result-block--result-status
                 nil
                 '(:ui (:state success)
                   :metadata (:error (:message "boom"))))))
    (should (eq status 'failure))))

(provide 'test/benedict-vui-tool-result-block-test)
;;; benedict-vui-tool-result-block-test.el ends here
