;;; benedict-vui-collapsible-test.el --- Tests for VUI collapsible -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI collapsible component behavior.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-collapsible)

(vui-defcomponent benedict-vui-collapsible-test--harness ()
  :state ((collapsed t))
  :render
  (vui-component 'benedict-vui-collapsible
                 :collapsed collapsed
                 :on-toggle (lambda (next)
                              (vui-set-state :collapsed next))
                 :header (lambda ()
                           (vui-text "Section"))
                 :content (lambda ()
                            (vui-text "Details visible"))))

(ert-deftest benedict-vui-collapsible-mount-toggle-indicator-and-content ()
  "Toggle updates fold indicator and content visibility in mounted buffer."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-collapsible-test--harness)
    (let ((initial (buffer-string)))
      (should (string-match-p (regexp-quote "▶") initial))
      (should (string-match-p "Section" initial))
      (should-not (string-match-p "Details visible" initial)))
    (save-excursion
      (goto-char (point-min))
      (should (search-forward "▶" nil t))
      (benedict-vui-test--click-button-at (match-beginning 0)))
    (vui-flush-sync)
    (let ((expanded (buffer-string)))
      (should (string-match-p (regexp-quote "▼") expanded))
      (should (string-match-p "Details visible" expanded)))))

(ert-deftest benedict-vui-collapsible-nil-toggle-callback-is-safe ()
  "Clicking toggle with nil on-toggle does not signal errors."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-collapsible
                     :collapsed t
                     :on-toggle nil
                     :header (lambda () (vui-text "Section"))
                     :content (lambda () (vui-text "Details")))
    (benedict-vui-test--click-button-at (point-min))
    (vui-flush-sync)
    (should (string-match-p "Section" (buffer-string)))))

(ert-deftest benedict-vui-collapsible-non-function-header-content-fallback ()
  "Non-function header/content values fall back without errors."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-collapsible
                     :collapsed nil
                     :on-toggle nil
                     :header "not-a-function"
                     :content "not-a-function")
    (should (string-match-p (regexp-quote "▼") (buffer-string)))))

(provide 'test/benedict-vui-collapsible-test)
;;; benedict-vui-collapsible-test.el ends here
