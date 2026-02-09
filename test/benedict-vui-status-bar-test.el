;;; benedict-vui-status-bar-test.el --- Tests for VUI status bar -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI status bar component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-status-bar)

(defun benedict-vui-status-bar-test--face-at-string-match (regexp)
  "Return face at first match of REGEXP in current buffer text."
  (save-match-data
    (let* ((text (buffer-string))
           (match-index (string-match regexp text)))
      (when match-index
        (get-text-property match-index 'face text)))))

(defun benedict-vui-status-bar-test--face-has-p (face face-prop)
  "Return non-nil when FACE appears in FACE-PROP."
  (if (listp face-prop)
      (memq face face-prop)
    (eq face face-prop)))

(ert-deftest benedict-vui-status-bar-mount-renders-token-usage ()
  "Mounted status bar renders token usage text and face."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:total 1234)
                     :error nil)
    (let ((text (buffer-string))
          (usage-face (benedict-vui-status-bar-test--face-at-string-match "1234 tokens")))
      (should (string-match-p "1234 tokens" text))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-header-usage usage-face)))))

(ert-deftest benedict-vui-status-bar-mount-renders-cost ()
  "Mounted status bar renders cost text and face."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:cost 0.01234)
                     :error nil)
    (let ((text (buffer-string))
          (usage-face (benedict-vui-status-bar-test--face-at-string-match (regexp-quote "$0.0123"))))
      (should (string-match-p (regexp-quote "$0.0123") text))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-header-usage usage-face)))))

(ert-deftest benedict-vui-status-bar-mount-renders-token-cost-and-separator ()
  "Mounted status bar renders usage, cost, and separator faces."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:prompt 50 :completion 70 :cost 0.42)
                     :error nil)
    (let ((text (buffer-string))
          (separator-face (benedict-vui-status-bar-test--face-at-string-match (regexp-quote "·"))))
      (should (string-match-p "120 tokens" text))
      (should (string-match-p (regexp-quote "$0.4200") text))
      (should (string-match-p (regexp-quote "·") text))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-header-separator separator-face)))))

(ert-deftest benedict-vui-status-bar-mount-renders-error-with-separator ()
  "Mounted status bar renders error text with separator and error face."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:total 99)
                     :error "Network timeout")
    (let ((text (buffer-string))
          (error-face (benedict-vui-status-bar-test--face-at-string-match "Network timeout"))
          (separator-face (benedict-vui-status-bar-test--face-at-string-match (regexp-quote "·"))))
      (should (string-match-p "99 tokens" text))
      (should (string-match-p "Network timeout" text))
      (should (string-match-p (regexp-quote "·") text))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-header-separator separator-face))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-error error-face)))))

(ert-deftest benedict-vui-status-bar-mount-renders-all-segments ()
  "Mounted status bar renders tokens, cost, and error with separators."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:tokens 300 :cost 1.5)
                     :error "Partial failure")
    (let ((text (buffer-string)))
      (should (string-match-p "300 tokens" text))
      (should (string-match-p (regexp-quote "$1.5000") text))
      (should (string-match-p "Partial failure" text))
      (should (= (length (split-string text (regexp-quote "·") t)) 3)))))

(ert-deftest benedict-vui-status-bar-mount-renders-empty-with-no-usage-or-error ()
  "Mounted status bar renders empty output when no usage or error exists."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage nil
                     :error nil)
    (should (string= "" (buffer-string)))))

(ert-deftest benedict-vui-status-bar-mount-renders-error-without-separator-when-usage-empty ()
  "Mounted status bar renders error without separator when usage has no labels."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:prompt 70)
                     :error "Prompt-only usage")
    (let ((text (buffer-string))
          (error-face (benedict-vui-status-bar-test--face-at-string-match "Prompt-only usage")))
      (should-not (string-match-p "tokens" text))
      (should-not (string-match-p (regexp-quote "$") text))
      (should-not (string-match-p (regexp-quote "·") text))
      (should (string-match-p "Prompt-only usage" text))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-error error-face)))))

(ert-deftest benedict-vui-status-bar-mount-renders-tokens-without-separator-when-cost-zero ()
  "Mounted status bar omits cost and separators when cost is zero."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:total 88 :cost 0)
                     :error nil)
    (let ((text (buffer-string)))
      (should (string-match-p "88 tokens" text))
      (should-not (string-match-p (regexp-quote "$0.0000") text))
      (should-not (string-match-p (regexp-quote "·") text)))))

(ert-deftest benedict-vui-status-bar-mount-renders-cost-and-error-with-single-separator ()
  "Mounted status bar renders cost+error with one separator when tokens absent."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage '(:cost 2.3)
                     :error "Rate limited")
    (let ((text (buffer-string))
          (separator-face (benedict-vui-status-bar-test--face-at-string-match (regexp-quote "·")))
          (usage-face (benedict-vui-status-bar-test--face-at-string-match (regexp-quote "$2.3000")))
          (error-face (benedict-vui-status-bar-test--face-at-string-match "Rate limited")))
      (should-not (string-match-p "tokens" text))
      (should (string-match-p (regexp-quote "$2.3000") text))
      (should (string-match-p "Rate limited" text))
      (should (= (length (split-string text (regexp-quote "·") t)) 2))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-header-separator separator-face))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-header-usage usage-face))
      (should (benedict-vui-status-bar-test--face-has-p
               'benedict-chat-error error-face)))))

(ert-deftest benedict-vui-status-bar-mount-renders-error-only-without-separator ()
  "Mounted status bar renders error-only output without separators."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-status-bar
                     :usage nil
                     :error "Only error")
    (let ((text (buffer-string)))
      (should-not (string-match-p "tokens" text))
      (should-not (string-match-p (regexp-quote "$") text))
      (should-not (string-match-p (regexp-quote "·") text))
      (should (string-match-p "Only error" text)))))

(provide 'test/benedict-vui-status-bar-test)
;;; benedict-vui-status-bar-test.el ends here
