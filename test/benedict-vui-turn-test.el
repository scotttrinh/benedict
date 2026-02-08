;;; benedict-vui-turn-test.el --- Tests for VUI turn -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI turn component mounted behavior.

;;; Code:

(require 'ert)
(require 'vui)
(require 'benedict-vui-turn)

(ert-deftest benedict-vui-turn-mount-user-renders-badge-and-user-styling ()
  "Turn mounts user messages with USER badge and user face text."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-turn
                      :message (list :id "msg-user" :role 'user :content "Hello from user"))
       buffer-name)
      (vui-flush-sync)
      (let* ((text (buffer-string))
             (content-pos (string-match "Hello from user" text)))
        (should (string-match-p "USER" text))
        (should content-pos)
        (should (eq (get-text-property content-pos 'face text) 'benedict-chat-user))))))

(ert-deftest benedict-vui-turn-mount-assistant-renders-badge-and-assistant-styling ()
  "Turn mounts assistant messages with ASSISTANT badge and assistant face text."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-turn
                      :message (list :id "msg-assistant" :role 'assistant :content "Hello from assistant"))
       buffer-name)
      (vui-flush-sync)
      (let* ((text (buffer-string))
             (content-pos (string-match "Hello from assistant" text)))
        (should (string-match-p "ASSISTANT" text))
        (should content-pos)
        (should (eq (get-text-property content-pos 'face text) 'benedict-chat-assistant))))))

(ert-deftest benedict-vui-turn-mount-tool-role-renders-tool-result-content ()
  "Turn mounts tool-role messages as tool-result content blocks."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-turn
                      :message (list :id "msg-tool"
                                     :role 'tool
                                     :content "ok"
                                     :metadata '(:status success)))
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "Result:" text))
        (should (string-match-p "ok" text))))))

(provide 'test/benedict-vui-turn-test)
;;; benedict-vui-turn-test.el ends here
