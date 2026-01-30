;;; benedict-vui-text-block-test.el --- Tests for VUI text block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI text block component.

;;; Code:

(require 'ert)
(require 'benedict-vui-text-block)

(ert-deftest benedict-vui-text-block-propertizes-body-region ()
  "Text block marks content for markdown fontification."
  (let ((text (vui-component 'benedict-vui-text-block--propertize "**bold**")))
    (should (equal text "**bold**"))
    (should (eq (get-text-property 0 'benedict-region-kind text) 'body))))

(ert-deftest benedict-vui-text-block-handles-empty-content ()
  "Text block handles empty or nil content without errors."
  (let ((text (vui-component 'benedict-vui-text-block--propertize nil)))
    (should (equal text ""))))

(ert-deftest benedict-vui-text-block-normalizes-non-strings ()
  "Text block normalizes non-string content."
  (let ((text (vui-component 'benedict-vui-text-block--propertize 42)))
    (should (equal text "42"))
    (should (eq (get-text-property 0 'benedict-region-kind text) 'body))))

(provide 'test/benedict-vui-text-block-test)
;;; benedict-vui-text-block-test.el ends here
