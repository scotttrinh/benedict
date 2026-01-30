;;; benedict-vui-collapsible-test.el --- Tests for VUI collapsible -*- lexical-binding: t; -*-

;;; Commentary:
;; Test the VUI collapsible component helpers.

;;; Code:

(require 'ert)
(require 'benedict-vui-collapsible)

(defvar benedict-vui-collapsible-test--header-calls 0
  "Call count for header helper.")

(defvar benedict-vui-collapsible-test--content-calls 0
  "Call count for content helper.")

(defun benedict-vui-collapsible-test--header ()
  "Return a header marker for render test."
  (setq benedict-vui-collapsible-test--header-calls
        (1+ benedict-vui-collapsible-test--header-calls))
  'header)

(defun benedict-vui-collapsible-test--content ()
  "Return a content marker for render test."
  (setq benedict-vui-collapsible-test--content-calls
        (1+ benedict-vui-collapsible-test--content-calls))
  'content)

(ert-deftest benedict-vui-collapsible-indicator-values ()
  "Test fold indicator for collapsed or expanded state."
  (should (equal (vui-component 'benedict-vui-collapsible--indicator t) "▶"))
  (should (equal (vui-component 'benedict-vui-collapsible--indicator nil) "▼")))

(ert-deftest benedict-vui-collapsible-controlled-and-uncontrolled ()
  "Test collapsed state for controlled and local usage."
  (should (eq (vui-component 'benedict-vui-collapsible--collapsed-p '(:collapsed t) '(:collapsed nil)) t))
  (should (eq (vui-component 'benedict-vui-collapsible--collapsed-p '(:collapsed nil) '(:collapsed t)) nil))
  (should (eq (vui-component 'benedict-vui-collapsible--collapsed-p nil '(:collapsed t)) t)))

(ert-deftest benedict-vui-collapsible-header-and-content-rendering ()
  "Test header rendering and conditional content rendering."
  (setq benedict-vui-collapsible-test--header-calls 0
        benedict-vui-collapsible-test--content-calls 0)
  (should (equal (vui-component 'benedict-vui-collapsible--render-header
                  #'benedict-vui-collapsible-test--header)
                 'header))
  (should (= benedict-vui-collapsible-test--header-calls 1))
  (should (null (vui-component 'benedict-vui-collapsible--render-content
                 t #'benedict-vui-collapsible-test--content)))
  (should (= benedict-vui-collapsible-test--content-calls 0))
  (should (equal (vui-component 'benedict-vui-collapsible--render-content
                  nil #'benedict-vui-collapsible-test--content)
                 'content))
  (should (= benedict-vui-collapsible-test--content-calls 1)))

(ert-deftest benedict-vui-collapsible-toggle-calls-callback ()
  "Test toggle callback invocation and controlled state behavior."
  (let ((callback-value nil))
    (should (eq (vui-component 'benedict-vui-collapsible--apply-toggle
                 t nil (lambda (value) (setq callback-value value)))
                nil))
    (should (eq callback-value nil))
    (setq callback-value :unset)
    (should (eq (vui-component 'benedict-vui-collapsible--apply-toggle
                 t t (lambda (value) (setq callback-value value)))
                t))
    (should (eq callback-value nil))))

(provide 'test/benedict-vui-collapsible-test)
;;; benedict-vui-collapsible-test.el ends here
