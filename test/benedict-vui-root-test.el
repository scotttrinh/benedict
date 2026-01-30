;;; benedict-vui-root-test.el --- Tests for VUI root component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI root component.

;;; Code:

(require 'ert)
(require 'benedict-vui-root)

(ert-deftest benedict-vui-root-component-can-be-loaded ()
  "BenedictRoot component can be loaded successfully."
  (should (featurep 'benedict-vui-root)))

(provide 'test/benedict-vui-root-test)
;;; benedict-vui-root-test.el ends here
