;;; benedict-vui-content-block-list-test.el --- Tests for VUI content block list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI content block list component behavior.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-content-block-list)

(ert-deftest benedict-vui-content-block-list-mixed-blocks-render-user-visible-output ()
  "Mounted list renders mixed block content and navigation properties."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-content-block-list
                      :blocks (list
                               (list :id "text-1" :type 'text :content "Hello world")
                               (list :id "code-1" :type 'code :code "(+ 1 2)" :language "elisp")
                               (list :id "thinking-1" :type 'thinking :thinking-data "Hidden reasoning")
                               (list :id "tool-use-1" :type 'tool-use
                                     :tool-call '(:name "bash" :arguments "echo hi"))
                               (list :id "tool-result-1" :type 'tool-result
                                     :result '(:name "bash" :content "OK")))
                      :collapsed-blocks '("thinking-1" "tool-use-1")
                      :message-key "msg-1")
       buffer-name)
      (vui-flush-sync)
      (let* ((text (buffer-string))
             (hello-pos (string-match "Hello world" text))
             (code-pos (string-match (regexp-quote "(+ 1 2)") text))
             (result-pos (string-match "OK" text)))
        (should (string-match-p "Hello world" text))
        (should (string-match-p "ELISP" text))
        (should (string-match-p (regexp-quote "(+ 1 2)") text))
        (should (string-match-p "Tool: bash" text))
        (should (string-match-p "Result: bash" text))
        (should (string-match-p "OK" text))
        (should (string-match-p "▶" text))
        (should-not (string-match-p "Hidden reasoning" text))
        (should-not (string-match-p "echo hi" text))
        (should hello-pos)
        (should code-pos)
        (should result-pos)
        (should (equal (get-text-property hello-pos 'benedict-message-key text) "msg-1"))
        (should (equal (get-text-property hello-pos 'benedict-block-id text) "text-1"))
        (should (equal (get-text-property code-pos 'benedict-block-id text) "code-1"))
        (should (equal (get-text-property result-pos 'benedict-block-id text) "tool-result-1"))))))

(ert-deftest benedict-vui-content-block-list-toggle-invokes-callback-with-block-id-and-next ()
  "Clicking a collapsible indicator calls :on-toggle-block with (block-id next)."
  (let (toggle-args)
    (with-temp-buffer
      (let ((buffer-name (buffer-name)))
        (vui-mount
         (vui-component 'benedict-vui-content-block-list
                        :blocks (list (list :id "thinking-1"
                                            :type 'thinking
                                            :thinking-data "Reasoning"))
                        :collapsed-blocks '("thinking-1")
                        :on-toggle-block (lambda (block-id next)
                                           (setq toggle-args (list block-id next))))
         buffer-name)
        (vui-flush-sync)
        (should (string-match-p "▶" (buffer-string)))
        (benedict-vui-test--click-button-at (point-min))
        (vui-flush-sync)
        (should (equal toggle-args '("thinking-1" nil)))))))

(provide 'test/benedict-vui-content-block-list-test)
;;; benedict-vui-content-block-list-test.el ends here
