;;; benedict-vui-chat-header-test.el --- Tests for ChatHeader component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the benedict-vui-chat-header component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-chat-header)

(defun benedict-vui-chat-header-test--separator-count (text)
  "Return number of separator glyphs in TEXT."
  (1- (length (split-string text (regexp-quote "·") nil))))

(ert-deftest benedict-vui-chat-header-omits-title-separator-without-explicit-provider-or-model ()
  "Header keeps the title adjacent when only fallback provider/model labels exist."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-chat-header
                     :provider nil
                     :model nil
                     :status nil
                     :title "Chat"
                     :on-provider-click nil)
    (let ((text (buffer-string)))
      (should (string-match-p "\?\?\?" text))
      (should (string-match-p "unknown" text))
      (should (string-match-p "Chat" text))
      (should (= 1 (benedict-vui-chat-header-test--separator-count text))))))

(ert-deftest benedict-vui-chat-header-adds-status-and-title-separators-when-configured ()
  "Header inserts distinct separators for status and title sections."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-chat-header
                     :provider 'openai
                     :model "gpt-5-mini"
                     :status 'running
                     :title "Session"
                     :on-provider-click nil)
    (let ((text (buffer-string)))
      (should (string-match-p "RUNNING" text))
      (should (string-match-p "Session" text))
      (should (= 3 (benedict-vui-chat-header-test--separator-count text))))))

(provide 'test/benedict-vui-chat-header-test)
;;; benedict-vui-chat-header-test.el ends here
