;;; benedict-vui-turn-test.el --- Tests for VUI turn -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI turn component mounted behavior.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-message)
(require 'benedict-vui-turn)
(require 'benedict-session)
(require 'benedict-turn)
(require 'benedict-store)

(defun benedict-vui-turn-test--face-member-p (actual expected)
  "Return non-nil when ACTUAL face includes EXPECTED."
  (cond
   ((eq actual expected) t)
   ((listp actual) (memq expected actual))
   (t nil)))

(defun benedict-vui-turn-test--assert-face-at-match (needle face &optional start)
  "Assert NEEDLE text includes FACE, searching from START when provided."
  (let* ((text (buffer-string))
         (pos (string-match needle text start))
         (actual (and pos (get-text-property pos 'face text))))
    (should pos)
    (should (benedict-vui-turn-test--face-member-p actual face))
    pos))

(defun benedict-vui-turn-test--with-id (message id)
  "Return MESSAGE with ID."
  (setf (benedict-message-id message) id)
  message)

(defun benedict-vui-turn-test--setup-session ()
  "Create and return a fresh test session."
  (let ((session (benedict-session--create :id (format "test-session-%s" (random)))))
    (puthash (benedict-session-id session) session benedict-session--registry)
    session))

(ert-deftest benedict-vui-turn-active-turn-without-execution-renders-working-state ()
  "Active turns without execution blocks still render a working activity lane."
  (let* ((session (benedict-vui-turn-test--setup-session))
         (u1 (benedict-vui-turn-test--with-id (benedict-message-user-text "Question") "u1"))
         (a1 (benedict-vui-turn-test--with-id (benedict-message-assistant-text "Draft answer") "a1"))
         (turn (benedict-turn-create (benedict-session-id session)
                                     :id "turn-u1"
                                     :prompt-message-id "u1"
                                     :outcome-message-id "a1"
                                     :message-ids '("u1" "a1")
                                     :state 'running)))
    (benedict-session-add-message session u1)
    (benedict-session-add-message session a1)
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn
                       :session session
                       :turn turn
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (let ((text (buffer-string)))
        (should (string-match-p "Prompt" text))
        (should (string-match-p "Activity" text))
        (should (string-match-p "Waiting for assistant output." text))
        (should (string-match-p "Draft answer" text))
        (benedict-vui-turn-test--assert-face-at-match
         "Waiting for assistant output."
         'benedict-chat-turn-active)))))

(ert-deftest benedict-vui-turn-renders-with-explicit-session-without-registry ()
  "Turn rendering resolves message IDs through the explicit session prop."
  (let* ((session (benedict-vui-turn-test--setup-session))
         (u1 (benedict-vui-turn-test--with-id (benedict-message-user-text "Explicit prompt") "u1"))
         (a1 (benedict-vui-turn-test--with-id (benedict-message-assistant-text "Explicit answer") "a1"))
         (turn (benedict-turn-create (benedict-session-id session)
                                     :id "turn-explicit"
                                     :prompt-message-id "u1"
                                     :outcome-message-id "a1"
                                     :message-ids '("u1" "a1")
                                     :state 'turn-complete)))
    (benedict-session-add-message session u1)
    (benedict-session-add-message session a1)
    (let ((benedict-session--registry (make-hash-table :test #'equal)))
      (with-mounted-vui-component
          (vui-component 'benedict-vui-turn
                         :session session
                         :turn turn
                         :collapsed-blocks nil
                         :on-toggle-block #'ignore)
        (let ((text (buffer-string)))
          (should (string-match-p "Explicit prompt" text))
          (should (string-match-p "Explicit answer" text)))))))

(ert-deftest benedict-vui-turn-expanded-execution-details-use-detail-face ()
  "Expanded execution detail regions keep turn-level detail styling."
  (let* ((session (benedict-vui-turn-test--setup-session))
         (u1 (benedict-vui-turn-test--with-id (benedict-message-user-text "Question") "u1"))
         (a1 (benedict-vui-turn-test--with-id (benedict-message-assistant-response
                                               :text "Final answer"
                                               :thinking "Reasoning"
                                               :tool-calls (list
                                                            (list :id "call-1"
                                                                  :name "bash"
                                                                  :arguments "pwd")))
                                              "a1"))
         (turn (benedict-turn-create (benedict-session-id session)
                                     :id "turn-u1"
                                     :prompt-message-id "u1"
                                     :outcome-message-id "a1"
                                     :message-ids '("u1" "a1")
                                     :state 'turn-complete)))
    (benedict-session-add-message session u1)
    (benedict-session-add-message session a1)
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn
                       :session session
                       :turn turn
                       :execution-expanded t
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (let* ((text (buffer-string))
             (details-pos (string-match "Execution details" text))
             (thinking-pos (string-match "THINKING" text)))
        (should details-pos)
        (should thinking-pos)
        (should (benedict-vui-turn-test--face-member-p
                 (get-text-property details-pos 'face text)
                 'benedict-chat-turn-detail))))))

(ert-deftest benedict-vui-turn-completed-turn-without-user-message-falls-back-to-first-message ()
  "Completed turns still render a prompt section when history starts mid-turn."
  (let* ((session (benedict-vui-turn-test--setup-session))
         (a1 (benedict-vui-turn-test--with-id (benedict-message-assistant-text "Recovered answer") "a1"))
         (t1 (benedict-vui-turn-test--with-id (benedict-message-tool-result "call-1" "bash" 'success "tool output") "t1"))
         (turn (benedict-turn-create (benedict-session-id session)
                                     :id "turn-1"
                                     :message-ids '("a1" "t1")
                                     :state 'turn-complete)))
    (benedict-session-add-message session a1)
    (benedict-session-add-message session t1)
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn
                       :session session
                       :turn turn
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (let* ((text (buffer-string))
             (prompt-pos (string-match "Prompt" text))
             (prompt-text-pos (string-match "Recovered answer" text))
             (answer-pos (string-match "Answer" text)))
        (should prompt-pos)
        (should prompt-text-pos)
        (should answer-pos)
        (should (< prompt-pos prompt-text-pos))
        (should (< prompt-text-pos answer-pos))))))

(ert-deftest benedict-vui-turn-completed-turn-expands-execution-details-when-enabled ()
  "Completed turns render execution blocks when expansion is enabled at turn scope."
  (let* ((session (benedict-vui-turn-test--setup-session))
         (u1 (benedict-vui-turn-test--with-id (benedict-message-user-text "Question") "u1"))
         (a1 (benedict-vui-turn-test--with-id (benedict-message-assistant-response
                                               :text "Final answer"
                                               :thinking "Reasoning"
                                               :tool-calls (list
                                                            (list :id "call-1"
                                                                  :name "bash"
                                                                  :arguments "pwd"
                                                                  :status 'awaiting-approval)))
                                              "a1"))
         (turn (benedict-turn-create (benedict-session-id session)
                                     :id "turn-u1"
                                     :prompt-message-id "u1"
                                     :outcome-message-id "a1"
                                     :message-ids '("u1" "a1")
                                     :state 'turn-complete)))
    (benedict-session-add-message session u1)
    (benedict-session-add-message session a1)
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn
                       :session session
                       :turn turn
                       :execution-expanded t
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (let ((text (buffer-string)))
        (should (string-match-p "Execution details" text))
        (should (string-match-p "THINKING" text))
        (should (string-match-p "Tool: bash" text))
        (should (string-match-p "Hide details" text))))))

(ert-deftest benedict-vui-turn-completed-turn-toggle-reveals-and-hides-details ()
  "Execution summary toggle updates the mounted completed turn in place."
  (let* ((session (benedict-vui-turn-test--setup-session))
         (u1 (benedict-vui-turn-test--with-id (benedict-message-user-text "Question") "u1"))
         (a1 (benedict-vui-turn-test--with-id (benedict-message-assistant-response
                                               :text "Final answer"
                                               :thinking "Reasoning"
                                               :tool-calls (list
                                                            (list :id "call-1"
                                                                  :name "bash"
                                                                  :arguments "pwd")))
                                              "a1"))
         (turn (benedict-turn-create (benedict-session-id session)
                                     :id "turn-u1"
                                     :prompt-message-id "u1"
                                     :outcome-message-id "a1"
                                     :message-ids '("u1" "a1")
                                     :state 'turn-complete)))
    (benedict-session-add-message session u1)
    (benedict-session-add-message session a1)
    (with-mounted-vui-component
        (vui-component 'benedict-vui-turn
                       :session session
                       :turn turn
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (let ((text (buffer-string)))
        (should (string-match-p "Show details" text))
        (should-not (string-match-p "Execution details" text))
        (should-not (string-match-p "Tool: bash" text)))
      (benedict-vui-test--click-button-labeled "Show details")
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "Hide details" text))
        (should (string-match-p "Execution details" text))
        (should (string-match-p "THINKING" text))
        (should (string-match-p "Tool: bash" text)))
      (benedict-vui-test--click-button-labeled "Hide details")
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "Show details" text))
        (should-not (string-match-p "Execution details" text))
        (should-not (string-match-p "Tool: bash" text))))))

(provide 'test/benedict-vui-turn-test)
;;; benedict-vui-turn-test.el ends here
