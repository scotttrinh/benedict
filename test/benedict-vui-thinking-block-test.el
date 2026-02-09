;;; benedict-vui-thinking-block-test.el --- Tests for VUI thinking block -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI thinking block component behavior.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-thinking-block)

(vui-defcomponent benedict-vui-thinking-block-test--harness (thinking-data message-key block-id)
  :state ((collapsed t))
  :render
  (vui-component 'benedict-vui-thinking-block
                 :thinking-data thinking-data
                 :collapsed collapsed
                 :on-toggle (lambda (next)
                              (vui-set-state :collapsed next))
                 :message-key message-key
                 :block-id block-id))

(ert-deftest benedict-vui-thinking-block-mount-collapsed-by-default ()
  "Thinking block hides content when mounted collapsed."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-thinking-block
                     :thinking-data "Reasoning text"
                     :collapsed t
                     :message-key "msg-1"
                     :block-id "block-1")
    (let ((text (buffer-string)))
      (should (string-match-p "▶" text))
      (should-not (string-match-p "Reasoning text" text)))))

(ert-deftest benedict-vui-thinking-block-mount-toggle-shows-content-with-properties ()
  "Clicking toggle reveals content and thinking text properties."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-thinking-block-test--harness
                     :thinking-data "Why this answer"
                     :message-key "msg-1"
                     :block-id "block-1")
    (should-not (string-match-p "Why this answer" (buffer-string)))
    (benedict-vui-test--click-button-at (point-min))
    (vui-flush-sync)
    (let* ((text (buffer-string))
           (pos (string-match "Why this answer" text)))
      (should pos)
      (should (eq (get-text-property pos 'benedict-region-kind text) 'thinking))
      (should (eq (get-text-property pos 'face text) 'benedict-chat-thinking))
      (should (equal (get-text-property pos 'benedict-message-key text) "msg-1"))
      (should (equal (get-text-property pos 'benedict-block-id text) "block-1")))))

(ert-deftest benedict-vui-thinking-block-mount-streaming-chunks ()
  "Thinking block renders concatenated streaming chunks when expanded."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-thinking-block-test--harness
                     :thinking-data (list (list :id "t1"
                                                :chunks (list "first" " second" " chunk")))
                     :message-key "msg-1"
                     :block-id "block-1")
    (benedict-vui-test--click-button-at (point-min))
    (vui-flush-sync)
    (should (string-match-p "first second chunk" (buffer-string)))))

(ert-deftest benedict-vui-thinking-block-mount-encrypted-placeholder ()
  "Thinking block shows encrypted placeholder for data-only details."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-thinking-block-test--harness
                     :thinking-data (list (list :id "enc-1" :data "ciphertext"))
                     :message-key "msg-1"
                     :block-id "block-1")
    (benedict-vui-test--click-button-at (point-min))
    (vui-flush-sync)
    (let ((text (buffer-string)))
      (should (string-match-p (regexp-quote "[Encrypted reasoning block]") text))
      (should (string-match-p "ciphertext" text)))))

(provide 'test/benedict-vui-thinking-block-test)
;;; benedict-vui-thinking-block-test.el ends here
