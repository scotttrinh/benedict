;;; benedict-vui-thinking-block-test.el --- Tests for VUI thinking block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI thinking block component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-thinking-block)

(ert-deftest benedict-vui-thinking-block-wraps-collapsible ()
  "Thinking block builds collapsible props with header/content."
  (let ((props (benedict-vui-thinking-block--collapsible-props
                '(:thinking-data "hi")
                '(:collapsed t)
                #'ignore)))
    (should (functionp (plist-get props :header)))
    (should (functionp (plist-get props :content)))))

(ert-deftest benedict-vui-thinking-block-propertizes-content ()
  "Thinking block applies thinking face and region kind."
  (let ((text (benedict-vui-thinking-block--propertize "why")))
    (should (eq (get-text-property 0 'benedict-region-kind text) 'thinking))
    (should (eq (get-text-property 0 'face text) 'benedict-chat-thinking))))

(ert-deftest benedict-vui-thinking-block-defaults-collapsed ()
  "Thinking block defaults to collapsed state."
  (should (benedict-vui-thinking-block--collapsed-p nil '(:collapsed t))))

(ert-deftest benedict-vui-thinking-block-handles-streaming-chunks ()
  "Thinking block concatenates streaming chunks."
  (let ((text (benedict-vui-thinking-block--content-text
               (list (list :id "t1" :chunks (list "first" " second"))))))
    (should (equal text "first second"))))

(provide 'test/benedict-vui-thinking-block-test)
;;; benedict-vui-thinking-block-test.el ends here
