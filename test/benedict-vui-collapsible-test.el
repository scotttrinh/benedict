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
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-collapsible-test--harness)
       buffer-name)
      (vui-flush-sync)
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
        (should (string-match-p "Details visible" expanded))))))

(provide 'test/benedict-vui-collapsible-test)
;;; benedict-vui-collapsible-test.el ends here
