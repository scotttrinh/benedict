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
  (with-mounted-vui-component
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
      (should (equal (get-text-property result-pos 'benedict-block-id text) "tool-result-1")))))

(ert-deftest benedict-vui-content-block-list-toggle-invokes-callback-with-block-id-and-next ()
  "Clicking a collapsible indicator calls :on-toggle-block with (block-id next)."
  (let (toggle-args)
    (with-mounted-vui-component
        (vui-component 'benedict-vui-content-block-list
                       :blocks (list (list :id "thinking-1"
                                           :type 'thinking
                                           :thinking-data "Reasoning"))
                       :collapsed-blocks '("thinking-1")
                       :on-toggle-block (lambda (block-id next)
                                          (setq toggle-args (list block-id next))))
      (should (string-match-p "▶" (buffer-string)))
      (benedict-vui-test--click-button-at (point-min))
      (vui-flush-sync)
      (should (equal toggle-args '("thinking-1" nil))))))

(ert-deftest benedict-vui-content-block-list-empty-blocks-render-empty-output ()
  "Empty block lists render no visible text."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-content-block-list
                     :blocks nil
                     :message-key "msg-empty")
    (should (string-empty-p (buffer-string)))))

(ert-deftest benedict-vui-content-block-list-unknown-type-falls-back-to-text-block ()
  "Unknown block types render via text-block fallback with navigation properties."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-content-block-list
                     :blocks (list (list :id "unknown-1"
                                         :type 'mystery
                                         :body "Fallback body"))
                     :message-key "msg-fallback")
    (should (string-match-p "Fallback body" (buffer-string)))
    (benedict-vui-test--assert-text-properties-for
     "Fallback body"
     :region-kind 'body
     :message-key "msg-fallback"
     :block-id "unknown-1")))

(ert-deftest benedict-vui-content-block-list-toggle-propagates-through-tool-use-block ()
  "Tool-use collapse toggles propagate as (block-id next) callback arguments."
  (let (toggle-args)
    (with-mounted-vui-component
        (vui-component 'benedict-vui-content-block-list
                       :blocks (list
                                (list :id "tool-use-1"
                                      :type 'tool-use
                                      :tool-call '(:name "bash" :arguments "echo hi")))
                       :collapsed-blocks nil
                       :on-toggle-block (lambda (block-id next)
                                          (setq toggle-args (list block-id next))))
      (should (string-match-p "▼" (buffer-string)))
      (benedict-vui-test--click-button-at (point-min))
      (vui-flush-sync)
      (should (equal toggle-args '("tool-use-1" t))))))

(ert-deftest benedict-vui-content-block-list-propagates-message-and-block-properties ()
  "Rendered block bodies carry message/block navigation properties by block type."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-content-block-list
                     :blocks (list
                              (list :id "text-1" :type 'text :content "Text body")
                              (list :id "code-1" :type 'code :code "(+ 1 2)" :language "elisp")
                              (list :id "thinking-1" :type 'thinking :thinking-data "Thinking body")
                              (list :id "tool-use-1" :type 'tool-use
                                    :tool-call '(:name "bash" :arguments "echo hi"))
                              (list :id "tool-result-1" :type 'tool-result
                                    :result '(:name "bash" :content "Result body")))
                     :collapsed-blocks nil
                     :message-key "msg-props")
    (benedict-vui-test--assert-text-properties-for
     "Text body"
     :region-kind 'body
     :message-key "msg-props"
     :block-id "text-1")
    (benedict-vui-test--assert-text-properties-for
     "(+ 1 2)"
     :region-kind 'body
     :message-key "msg-props"
     :block-id "code-1")
    (benedict-vui-test--assert-text-properties-for
     "Arguments:"
     :region-kind 'tool-ui
     :message-key "msg-props"
     :block-id "tool-use-1")
    (benedict-vui-test--assert-text-properties-for
     "Result body"
     :region-kind 'tool-ui
     :message-key "msg-props"
     :block-id "tool-result-1")))

(provide 'test/benedict-vui-content-block-list-test)
;;; benedict-vui-content-block-list-test.el ends here
