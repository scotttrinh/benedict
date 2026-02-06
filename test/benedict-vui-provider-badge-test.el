;;; benedict-vui-provider-badge-test.el --- Tests for VUI provider badge -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI provider/model badge component.

;;; Code:

(require 'ert)
(require 'benedict-vui-provider-badge)

(ert-deftest benedict-vui-provider-badge-displays-provider ()
  "Badge displays provider name correctly."
  (should (equal (benedict-vui-provider-badge--format-provider 'openrouter)
                 "OPE"))
  (should (equal (benedict-vui-provider-badge--format-provider 'anthropic)
                 "ANT"))
  (should (equal (benedict-vui-provider-badge--format-provider nil)
                 "???")))

(ert-deftest benedict-vui-provider-badge-displays-model ()
  "Badge displays model name correctly."
  (should (equal (benedict-vui-provider-badge--format-model
                  "anthropic/claude-3-sonnet-20240229")
                 "claude-3-sonnet-20240229"))
  (should (equal (benedict-vui-provider-badge--format-model
                  "openai/gpt-4")
                 "gpt-4"))
  (should (equal (benedict-vui-provider-badge--format-model nil)
                 "unknown")))

(ert-deftest benedict-vui-provider-badge-render-test ()
  "Provider badge renders formatted provider and model."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-provider-badge
                      :provider 'anthropic
                      :model "claude-3-opus"
                      :on-click nil)
       buffer-name)
      
      ;; Verify formatted output
      ;; Expecting "ANT · claude-3-opus"
      (let ((content (buffer-string)))
        (should (string-match-p "ANT" content))
        (should (string-match-p "·" content))
        (should (string-match-p "claude-3-opus" content)))
      
      ;; Verify faces
      (goto-char (point-min))
      (let* ((text (buffer-string))
             ;; Get face of first char (ANT)
             (provider-face (get-text-property 0 'face text)))
        (should (eq provider-face 'benedict-chat-header-provider))))))

(provide 'test/benedict-vui-provider-badge-test)
;;; benedict-vui-provider-badge-test.el ends here
