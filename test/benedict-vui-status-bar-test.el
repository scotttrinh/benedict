;;; benedict-vui-status-bar-test.el --- Tests for VUI status bar -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI status bar component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-status-bar)

(ert-deftest benedict-vui-status-bar-total-tokens-prefers-total-and-falls-back-to-sum ()
  "Token helpers keep their precedence rules explicit."
  (should (= 123 (benedict-vui-status-bar--total-tokens '(:total 123 :tokens 99))))
  (should (= 88 (benedict-vui-status-bar--total-tokens '(:tokens 88))))
  (should (= 12 (benedict-vui-status-bar--total-tokens '(:prompt 5 :completion 7))))
  (should-not (benedict-vui-status-bar--total-tokens '(:prompt 5))))

(ert-deftest benedict-vui-status-bar-formatters-drop-empty-values ()
  "Formatting helpers omit zero or non-numeric values."
  (should (equal "55 tokens" (benedict-vui-status-bar--format-tokens 55)))
  (should (equal "$0.0123" (benedict-vui-status-bar--format-cost 0.01234)))
  (should-not (benedict-vui-status-bar--format-tokens nil))
  (should-not (benedict-vui-status-bar--format-cost 0))
  (should-not (benedict-vui-status-bar--format-cost "oops")))

(ert-deftest benedict-vui-status-bar-renders-combined-usage-and-error-line ()
  "Mounted status bar still composes usage, cost, and error into one line."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:prompt 50 :completion 70 :cost 0.42)
                     :error "Network timeout")
    (let ((text (buffer-string)))
      (should (string-match-p "120 tokens" text))
      (should (string-match-p (regexp-quote "$0.4200") text))
      (should (string-match-p "Network timeout" text))
      (should (= 3 (length (split-string text (regexp-quote "·") t)))))))

(ert-deftest benedict-vui-status-bar-renders-empty-with-no-usage-or-error ()
  "Mounted status bar renders empty output when no usage or error exists."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage nil
                     :error nil)
    (should (string= "" (buffer-string)))))

(provide 'test/benedict-vui-status-bar-test)
;;; benedict-vui-status-bar-test.el ends here
