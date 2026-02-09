;;; benedict-vui-chat-header-test.el --- Tests for ChatHeader component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the benedict-vui-chat-header component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-chat-header)

(defun benedict-vui-chat-header-test--face-at-string-match (regexp)
  "Return face at first match of REGEXP in current buffer text."
  (save-match-data
    (let* ((text (buffer-string))
           (match-index (string-match regexp text)))
      (when match-index
        (get-text-property match-index 'face text)))))

(defun benedict-vui-chat-header-test--face-has-p (face face-prop)
  "Return non-nil when FACE appears in FACE-PROP."
  (if (listp face-prop)
      (memq face face-prop)
    (eq face face-prop)))

(ert-deftest benedict-vui-chat-header-mount-renders-provider-model-and-title ()
  "Mounted chat header renders provider/model/title with expected faces."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-chat-header
                     :provider 'gemini
                     :model "models/gemini-2.0-flash"
                     :status nil
                     :title "Chat"
                     :on-provider-click nil)
    (let ((text (buffer-string))
          (provider-face (benedict-vui-chat-header-test--face-at-string-match "GEM"))
          (model-face (benedict-vui-chat-header-test--face-at-string-match "gemini-2.0-flash"))
          (title-face (benedict-vui-chat-header-test--face-at-string-match "Chat")))
      (should (string-match-p "GEM" text))
      (should (string-match-p "gemini-2.0-flash" text))
      (should (string-match-p "Chat" text))
      (should (benedict-vui-chat-header-test--face-has-p
               'benedict-chat-header-provider provider-face))
      (should (benedict-vui-chat-header-test--face-has-p
               'benedict-chat-header-model model-face))
      (should (benedict-vui-chat-header-test--face-has-p
               'benedict-chat-header title-face)))))

(ert-deftest benedict-vui-chat-header-mount-renders-status-and-separators ()
  "Mounted chat header renders status badge and separators."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-chat-header
                     :provider 'openai
                     :model "gpt-5-mini"
                     :status 'running
                     :title "Session"
                     :on-provider-click nil)
    (let ((text (buffer-string))
          (status-face (benedict-vui-chat-header-test--face-at-string-match "RUNNING"))
          (separator-face (benedict-vui-chat-header-test--face-at-string-match (regexp-quote "·"))))
      (should (string-match-p "RUNNING" text))
      (should (string-match-p "Session" text))
      (should (>= (length (split-string text (regexp-quote "·") t)) 3))
      (should (benedict-vui-chat-header-test--face-has-p
               'benedict-chat-tool-running status-face))
      (should (benedict-vui-chat-header-test--face-has-p
               'benedict-chat-header-separator separator-face)))))

(provide 'test/benedict-vui-chat-header-test)
;;; benedict-vui-chat-header-test.el ends here
