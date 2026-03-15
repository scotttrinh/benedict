;;; benedict-vui-turn-test.el --- Tests for VUI turn -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI turn component mounted behavior.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-turn)

(defun benedict-vui-turn-test--face-member-p (actual expected)
  "Return non-nil when ACTUAL face includes EXPECTED."
  (cond
   ((eq actual expected) t)
   ((listp actual) (memq expected actual))
   (t nil)))

(ert-deftest benedict-vui-turn-mount-user-renders-badge-and-user-styling ()
  "Turn mounts user messages with USER badge and user face text."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :message (list :id "msg-user" :role 'user :content "Hello from user"))
    (let* ((text (buffer-string))
           (content-pos (string-match "Hello from user" text)))
      (should (string-match-p "USER" text))
      (should content-pos)
      (should (eq (get-text-property content-pos 'face text) 'benedict-chat-user)))))

(ert-deftest benedict-vui-turn-mount-assistant-renders-badge-and-assistant-styling ()
  "Turn mounts assistant messages with ASSISTANT badge and assistant face text."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :message (list :id "msg-assistant" :role 'assistant :content "Hello from assistant"))
    (let* ((text (buffer-string))
           (content-pos (string-match "Hello from assistant" text)))
      (should (string-match-p "ASSISTANT" text))
      (should content-pos)
      (should (eq (get-text-property content-pos 'face text) 'benedict-chat-assistant)))))

(ert-deftest benedict-vui-turn-mount-system-renders-badge-and-system-styling ()
  "Turn mounts system messages with SYSTEM badge and system face text."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :message (list :id "msg-system" :role 'system :content "System notice"))
    (let* ((text (buffer-string))
           (content-pos (string-match "System notice" text)))
      (should (string-match-p "SYSTEM" text))
      (should content-pos)
      (should (eq (get-text-property content-pos 'face text) 'benedict-chat-system)))))

(ert-deftest benedict-vui-turn-mount-tool-role-renders-tool-result-content ()
  "Turn mounts tool-role messages as tool-result content blocks."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :message (list :id "msg-tool"
                                    :role 'tool
                                    :content "ok"
                                    :metadata '(:status success)))
    (let ((text (buffer-string)))
      (should (string-match-p "Result:" text))
      (should (string-match-p "ok" text)))))

(ert-deftest benedict-vui-turn-assistant-composes-thinking-and-tool-use-blocks ()
  "Assistant turns compose text, thinking, and tool-use blocks from message payloads."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :message (list :id "msg-compose"
                                    :role 'assistant
                                    :content "Primary response"
                                    :thinking "Reasoning details"
                                    :tool-calls (list
                                                 (list :id "call-1"
                                                       :name "bash"
                                                       :arguments "echo hi"))))
    (let ((text (buffer-string)))
      (should (string-match-p "ASSISTANT" text))
      (should (string-match-p "Primary response" text))
      (should (string-match-p "THINKING" text))
      (should (string-match-p "Tool: bash" text))
      (should (string-match-p "Arguments:" text)))))

(ert-deftest benedict-vui-turn-error-metadata-uses-error-face ()
  "Error metadata overrides role-specific styling with error face."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :message (list :id "msg-error"
                                    :role 'assistant
                                    :content "Failure text"
                                    :metadata '(:error t)))
    (let* ((text (buffer-string))
           (content-pos (string-match "Failure text" text))
           (face (and content-pos (get-text-property content-pos 'face text))))
      (should content-pos)
      (should (benedict-vui-turn-test--face-member-p face 'benedict-chat-error)))))

(ert-deftest benedict-vui-turn-non-error-metadata-preserves-role-face ()
  "Non-error metadata keeps the role styling for message content."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :message (list :id "msg-meta"
                                    :role 'assistant
                                    :content "Metadata text"
                                    :metadata '(:status success)))
    (let* ((text (buffer-string))
           (content-pos (string-match "Metadata text" text))
           (face (and content-pos (get-text-property content-pos 'face text))))
      (should content-pos)
      (should (benedict-vui-turn-test--face-member-p face 'benedict-chat-assistant)))))

(ert-deftest benedict-vui-turn-timestamp-header-renders-with-or-without-metadata ()
  "Timestamp appears in header regardless of metadata presence."
  (let ((timestamp (encode-time 0 0 12 1 1 2025)))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn
                       :message (list :id "msg-ts"
                                      :role 'user
                                      :content "With timestamp"
                                      :timestamp timestamp
                                      :metadata '(:status success)))
      (let* ((text (buffer-string))
             (ts-pos (string-match "12:00:00" text)))
        (should (string-match-p "USER" text))
        (should (string-match-p "·" text))
        (should ts-pos)
        (should (eq (get-text-property ts-pos 'face text) 'benedict-chat-header-time))))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn
                       :message (list :id "msg-no-ts"
                                      :role 'user
                                      :content "Without timestamp"
                                      :metadata '(:status success)))
      (let ((text (buffer-string)))
        (should (string-match-p "USER" text))
        (should-not (string-match-p "·" text))
        (should-not (string-match-p "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]" text))))))

(ert-deftest benedict-vui-turn-renders-derived-turn-message-list ()
  "Turn component accepts explicit turn records from the conversation layer."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn
                     :turn (list :id "u1"
                                 :prompt-text "Question"
                                 :active t
                                 :streaming t
                                 :completed nil
                                 :historical nil
                                 :has-execution-blocks t
                                 :execution-expanded nil
                                 :execution-summary '(:tool-count 1 :tool-names ("bash"))
                                 :messages (list (list :id "u1" :role 'user :content "Question")
                                                 (list :role 'assistant
                                                       :content "Draft answer"
                                                       :thinking "Working"
                                                       :tool-calls (list
                                                                    (list :id "call-1"
                                                                          :name "bash"
                                                                          :arguments "pwd"))))))
    (let ((text (buffer-string)))
      (should (string-match-p "Question" text))
      (should (string-match-p "Draft answer" text))
      (should (string-match-p "THINKING" text))
      (should (string-match-p "Tool: bash" text)))))

(provide 'test/benedict-vui-turn-test)
;;; benedict-vui-turn-test.el ends here
