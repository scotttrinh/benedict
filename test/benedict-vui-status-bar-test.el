;;; benedict-vui-status-bar-test.el --- Tests for VUI status bar -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI status bar component.

;;; Code:

(require 'ert)
(require 'benedict-vui-status-bar)

(ert-deftest benedict-vui-status-bar-format-tokens ()
  "Token formatting handles various inputs."
  (should (equal (benedict-vui-status-bar--format-tokens 1234) "1234 tokens"))
  (should (equal (benedict-vui-status-bar--format-tokens 1234.6) "1235 tokens"))
  (should (equal (benedict-vui-status-bar--format-tokens 0) "0 tokens"))
  (should (equal (benedict-vui-status-bar--format-tokens nil) nil)))

(ert-deftest benedict-vui-status-bar-format-cost ()
  "Cost formatting handles various inputs."
  (should (equal (benedict-vui-status-bar--format-cost 0.01234) "$0.0123"))
  (should (equal (benedict-vui-status-bar--format-cost 1.0) "$1.0000"))
  (should (equal (benedict-vui-status-bar--format-cost 0) nil))
  (should (equal (benedict-vui-status-bar--format-cost nil) nil)))

(ert-deftest benedict-vui-status-bar-total-tokens ()
  "Total token extraction from usage plist."
  (should (equal (benedict-vui-status-bar--total-tokens '(:total 100)) 100))
  (should (equal (benedict-vui-status-bar--total-tokens '(:prompt 50 :completion 50)) 100))
  (should (equal (benedict-vui-status-bar--total-tokens '(:tokens 200)) 200))
  (should (equal (benedict-vui-status-bar--total-tokens nil) nil))
  (should (equal (benedict-vui-status-bar--total-tokens '(:prompt 50)) nil)))

(ert-deftest benedict-vui-status-bar-cost ()
  "Cost extraction from usage plist."
  (should (equal (benedict-vui-status-bar--cost '(:cost 0.01234)) 0.01234))
  (should (equal (benedict-vui-status-bar--cost '(:total 100 :cost 0.05)) 0.05))
  (should (equal (benedict-vui-status-bar--cost nil) nil))
  (should (equal (benedict-vui-status-bar--cost '(:total 100)) nil)))

(provide 'test/benedict-vui-status-bar-test)
;;; benedict-vui-status-bar-test.el ends here
