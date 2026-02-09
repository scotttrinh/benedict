;;; benedict-vui-text-block-test.el --- Tests for VUI text block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI text block component.

;;; Code:

(require 'ert)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-text-block)

(ert-deftest benedict-vui-text-block-propertizes-body-region ()
  "Text block marks content for markdown fontification."
  (let ((text (benedict-vui-text-block--propertize "**bold**")))
    (should (equal text "**bold**"))
    (should (eq (get-text-property 0 'benedict-region-kind text) 'body))))

(ert-deftest benedict-vui-text-block-handles-empty-content ()
  "Text block handles empty or nil content without errors."
  (let ((text (benedict-vui-text-block--propertize nil)))
    (should (equal text ""))))

(ert-deftest benedict-vui-text-block-normalizes-non-strings ()
  "Text block normalizes non-string content."
  (let ((text (benedict-vui-text-block--propertize 42)))
    (should (equal text "42"))
    (should (eq (get-text-property 0 'benedict-region-kind text) 'body))))

(ert-deftest benedict-vui-text-block-render-test ()
  "Text block renders content directly to buffer."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-text-block
                     :content "Hello world"
                     :message-key "msg-1"
                     :block-id "block-1")
    (should (string-match-p "Hello world" (buffer-string)))
    (benedict-vui-test--assert-text-properties-for
     "Hello world"
     :region-kind 'body
     :message-key "msg-1"
     :block-id "block-1")))

(ert-deftest benedict-vui-text-block-preserves-whitespace ()
  "Text block keeps leading/trailing and multiline whitespace intact."
  (let* ((content "  first line\n\n second line  ")
         (text (benedict-vui-text-block--propertize content "msg-ws" "block-ws")))
    (should (equal text content))
    (should (eq (get-text-property 0 'benedict-region-kind text) 'body))
    (should (equal (get-text-property 0 'benedict-message-key text) "msg-ws"))
    (should (equal (get-text-property (1- (length text)) 'benedict-block-id text) "block-ws"))))

(ert-deftest benedict-vui-text-block-long-content-retains-properties ()
  "Long content remains intact and fully propertized."
  (let* ((content (make-string 10000 ?a))
         (text (benedict-vui-text-block--propertize content "msg-long" "block-long")))
    (should (= (length text) 10000))
    (should (eq (get-text-property 0 'benedict-region-kind text) 'body))
    (should (eq (get-text-property 9999 'benedict-region-kind text) 'body))
    (should (equal (get-text-property 9999 'benedict-message-key text) "msg-long"))
    (should (equal (get-text-property 9999 'benedict-block-id text) "block-long"))))

(provide 'test/benedict-vui-text-block-test)
;;; benedict-vui-text-block-test.el ends here
