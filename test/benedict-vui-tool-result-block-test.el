;;; benedict-vui-tool-result-block-test.el --- Tests for VUI tool result block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI tool result block component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-tool-result-block)

(ert-deftest benedict-vui-tool-result-block-header-prefers-ui-header ()
  "Header uses UI header hint when available."
  (let ((title (benedict-vui-tool-result-block--header-title
                '(:ui (:header "Read file — foo.txt")))))
    (should (string-match-p "Read file" title))))

(ert-deftest benedict-vui-tool-result-block-body-prefers-ui-body ()
  "Body prefers UI :body text when present."
  (let ((body (benedict-vui-tool-result-block--body-text
               '(:content "Fallback"
                 :ui (:body "From UI")))))
    (should (equal body "From UI"))))

(ert-deftest benedict-vui-tool-result-block-truncates-long-body ()
  "Long body text is truncated with marker."
  (let* ((text (make-string 520 ?a))
         (truncation (benedict-vui-tool-result-block--truncate
                      text
                      benedict-vui-tool-result-block--truncate-limit)))
    (should (cdr truncation))
    (should (< (length (car truncation)) (length text)))))

(ert-deftest benedict-vui-tool-result-block-error-styles-body ()
  "Failure status applies error face to body text."
  (let ((text (benedict-vui-tool-result-block--propertize "Oops" 'failure)))
    (should (eq (get-text-property 0 'face text) 'benedict-chat-tool-error))))

(ert-deftest benedict-vui-tool-result-block-normalizes-actions ()
  "Actions are filtered to valid label/handler pairs."
  (let* ((actions (list (list :label "Open" :handler #'ignore)
                        (list :label 12 :handler #'ignore)
                        (list :label "Bad" :handler nil)))
         (normalized (benedict-vui-tool-result-block--normalize-actions actions)))
    (should (= (length normalized) 1))
    (should (equal (plist-get (car normalized) :label) "Open"))))

(ert-deftest benedict-vui-tool-result-block-error-overrides-status ()
  "Error info forces failure status even with success hints."
  (let ((status (benedict-vui-tool-result-block--result-status
                 nil
                 '(:ui (:state success)
                   :metadata (:error (:message "boom"))))))
    (should (eq status 'failure))))

(ert-deftest benedict-vui-tool-result-block-mount-prefers-ui-body-and-header ()
  "Mount renders UI header/body hints when provided."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-tool-result-block
                      :collapsed nil
                      :result '(:content "Fallback"
                                :ui (:header "Read file — foo.txt"
                                             :body "From UI")))
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "Read file — foo.txt" text))
        (should (string-match-p "From UI" text))))))

(ert-deftest benedict-vui-tool-result-block-mount-falls-back-to-content ()
  "Mount renders :content when no UI body is provided."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-tool-result-block
                      :collapsed nil
                      :result '(:content "Fallback content"))
       buffer-name)
      (vui-flush-sync)
      (should (string-match-p "Fallback content" (buffer-string))))))

(ert-deftest benedict-vui-tool-result-block-mount-applies-message-properties ()
  "Mount applies message and block ids to body text."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-tool-result-block
                      :collapsed nil
                      :message-key "msg-1"
                      :block-id "block-1"
                      :result '(:content "Payload"))
       buffer-name)
      (vui-flush-sync)
      (let* ((text (buffer-string))
             (pos (string-match "Payload" text)))
        (should pos)
        (should (equal (get-text-property pos 'benedict-message-key text) "msg-1"))
        (should (equal (get-text-property pos 'benedict-block-id text) "block-1"))))))

(ert-deftest benedict-vui-tool-result-block-mount-error-styles-body ()
  "Mount applies error face for failure status."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-tool-result-block
                      :collapsed nil
                      :status 'failure
                      :result '(:content "Oops"))
       buffer-name)
      (vui-flush-sync)
      (let* ((text (buffer-string))
             (pos (string-match "Oops" text)))
        (should pos)
        (should (eq (get-text-property pos 'face text) 'benedict-chat-tool-error))))))

(ert-deftest benedict-vui-tool-result-block-mount-truncation-toggle ()
  "Mount shows truncation and toggles full body."
  (let ((long-text (concat (make-string 500 ?a) "TAIL")))
    (with-temp-buffer
      (let ((buffer-name (buffer-name)))
        (vui-mount
         (vui-component 'benedict-vui-tool-result-block
                        :collapsed nil
                        :result (list :content long-text))
         buffer-name)
        (vui-flush-sync)
        (let ((text (buffer-string)))
          (should (string-match-p "... \\[truncated\\]" text))
          (should (string-match-p "Show more" text))
          (should-not (string-match-p "TAIL" text)))
        (benedict-vui-test--click-button-labeled "Show more")
        (vui-flush-sync)
        (let ((text (buffer-string)))
          (should (string-match-p "Show less" text))
          (should (string-match-p "TAIL" text))
          (should-not (string-match-p "... \\[truncated\\]" text)))
        (benedict-vui-test--click-button-labeled "Show less")
        (vui-flush-sync)
        (let ((text (buffer-string)))
          (should (string-match-p "Show more" text))
          (should (string-match-p "... \\[truncated\\]" text)))))))

(ert-deftest benedict-vui-tool-result-block-mount-actions-click ()
  "Mount renders actions and invokes handlers on click."
  (let ((clicked nil))
    (with-temp-buffer
      (let ((buffer-name (buffer-name)))
        (vui-mount
         (vui-component 'benedict-vui-tool-result-block
                        :collapsed nil
                        :actions (list (list :label "Open" :handler (lambda () (setq clicked t))))
                        :result '(:content "Done"))
         buffer-name)
        (vui-flush-sync)
        (should (string-match-p "Open" (buffer-string)))
        (benedict-vui-test--click-button-labeled "Open")
        (vui-flush-sync)
        (should clicked)))))

(provide 'test/benedict-vui-tool-result-block-test)
;;; benedict-vui-tool-result-block-test.el ends here
