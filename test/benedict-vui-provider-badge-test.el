;;; benedict-vui-provider-badge-test.el --- Tests for VUI provider badge -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI provider/model badge component.

;;; Code:

(require 'ert)
(require 'test/benedict-vui-test-utils)
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
  (should (equal (benedict-vui-provider-badge--format-model "gpt-4")
                 "gpt-4"))
  (should (equal (benedict-vui-provider-badge--format-model "")
                 "unknown"))
  (should (equal (benedict-vui-provider-badge--format-model nil)
                 "unknown"))
  (should (equal (benedict-vui-provider-badge--format-model 'gpt-4)
                 "gpt-4")))

(ert-deftest benedict-vui-provider-badge-invokes-click-handler ()
  "Provider label is clickable when on-click callback is provided."
  (let ((clicked 0))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-provider-badge
                       :provider 'anthropic
                       :model "claude-3-opus"
                       :on-click (lambda ()
                                   (setq clicked (1+ clicked))))
      (benedict-vui-test--click-button-labeled "ANT")
      (vui-flush-sync)
      (should (= clicked 1)))))

(provide 'test/benedict-vui-provider-badge-test)
;;; benedict-vui-provider-badge-test.el ends here
