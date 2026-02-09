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

(defun benedict-vui-chat-header-test--separator-count (text)
  "Return number of separator glyphs in TEXT."
  (1- (length (split-string text (regexp-quote "·") nil))))

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

(ert-deftest benedict-vui-chat-header-mount-nil-provider-model-variants ()
  "Mounted chat header renders provider/model fallback labels for nil values."
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

(ert-deftest benedict-vui-chat-header-mount-nil-status-and-title-variants ()
  "Mounted chat header omits optional status/title regions when nil."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-chat-header
                     :provider 'openrouter
                     :model "openai/gpt-5"
                     :status nil
                     :title nil
                     :on-provider-click nil)
    (let ((text (buffer-string)))
      (should (string-match-p "OPE" text))
      (should (string-match-p "gpt-5" text))
      (should-not (string-match-p "RUNNING" text))
      (should-not (string-match-p "Session" text))
      (should (= 1 (benedict-vui-chat-header-test--separator-count text))))))

(ert-deftest benedict-vui-chat-header-mount-status-badge-transitions ()
  "Mounted chat header renders each status transition label and face."
  (let ((cases '((running "RUNNING" benedict-chat-tool-running)
                 (error "ERROR" benedict-chat-header-error)
                 (success "SUCCESS" benedict-chat-tool-success)
                 (failure "FAILURE" benedict-chat-tool-error)
                 (streaming "STREAMING" benedict-chat-header-time))))
    (dolist (case cases)
      (pcase-let ((`(,status ,label ,face) case))
        (with-mounted-vui-component
            (vui-component 'benedict-vui-chat-header
                           :provider 'openai
                           :model "gpt-5"
                           :status status
                           :title "Session"
                           :on-provider-click nil)
          (let ((text (buffer-string))
                (status-face (benedict-vui-chat-header-test--face-at-string-match label)))
            (should (string-match-p label text))
            (should (benedict-vui-chat-header-test--face-has-p face status-face))))))))

(ert-deftest benedict-vui-chat-header-mount-provider-click-handler-wired ()
  "Mounted chat header calls `on-provider-click' when provider badge clicked."
  (let ((clicks 0))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-chat-header
                       :provider 'openrouter
                       :model "openai/gpt-5"
                       :status nil
                       :title nil
                       :on-provider-click (lambda ()
                                            (setq clicks (1+ clicks))))
      (benedict-vui-test--click-button-labeled "OPE")
      (vui-flush-sync)
      (should (= 1 clicks)))))

(provide 'test/benedict-vui-chat-header-test)
;;; benedict-vui-chat-header-test.el ends here
