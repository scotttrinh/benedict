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

(provide 'test/benedict-vui-provider-badge-test)
;;; benedict-vui-provider-badge-test.el ends here
