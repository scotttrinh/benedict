;;; benedict-vui-root-test.el --- Tests for VUI root component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI root component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-root)

(ert-deftest benedict-vui-root-mount-renders-baseline-layout ()
  "Mounted root renders baseline UI for an empty session."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-root
                     :session nil
                     :initial-slices nil
                     :initial-input nil
                     :retain-context nil
                     :register-actions nil
                     :on-slices-change nil
                     :on-provider-click nil
                     :on-submit #'ignore)
    (let ((text (buffer-string)))
      (should (string-match-p "Chat" text))
      (should (string-match-p "No context" text))
      (should widget-field-list))))

(provide 'test/benedict-vui-root-test)
;;; benedict-vui-root-test.el ends here
