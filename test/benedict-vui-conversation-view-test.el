;;; benedict-vui-conversation-view-test.el --- Tests for VUI conversation view -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI conversation view component helpers.

;;; Code:

(require 'ert)
(require 'benedict-vui-conversation-view)

(ert-deftest benedict-vui-conversation-view-renders-turn-list ()
  "Conversation view renders TurnList with conversation."
  (let* ((conversation (list (list :id "msg-1" :role 'user :content "Hi")
                             (list :id "msg-2" :role 'assistant :content "Hello")))
          (collapsed-blocks nil)
          (node (benedict-vui-conversation-view--render
                 (list :conversation conversation
                       :collapsed-blocks collapsed-blocks
                       :streaming nil))))
    (should node)))

(ert-deftest benedict-vui-conversation-view-shows-streaming-indicator ()
  "Conversation view shows StreamingIndicator during active streaming."
  (let* ((conversation nil)
          (streaming-active (list :status 'active :turn-id "turn-1" :content ""))
          (collapsed-blocks nil)
          (node (benedict-vui-conversation-view--render
                 (list :conversation conversation
                       :collapsed-blocks collapsed-blocks
                       :streaming streaming-active))))
    (should node)
    (should (benedict-vui-conversation-view--streaming-active-p streaming-active))))

(ert-deftest benedict-vui-conversation-view-hides-streaming-indicator-when-idle ()
  "Conversation view hides StreamingIndicator when not streaming."
  (let* ((conversation nil)
         (streaming-inactive (list :status 'complete)))
    (should-not (benedict-vui-conversation-view--streaming-active-p
                 streaming-inactive))))

(ert-deftest benedict-vui-conversation-view-handles-nil-streaming ()
  "Conversation view handles nil streaming gracefully."
  (let* ((conversation nil)
         (streaming nil))
    (should-not (benedict-vui-conversation-view--streaming-active-p
                 streaming))))

(ert-deftest benedict-vui-conversation-view-streaming-active-p ()
  "Helper function correctly identifies active streaming state."
  (should (benedict-vui-conversation-view--streaming-active-p
           (list :status 'active)))
  (should (benedict-vui-conversation-view--streaming-active-p
           (list :status 'active :turn-id "turn-1" :content "text")))
  (should (not (benedict-vui-conversation-view--streaming-active-p
                (list :status 'complete))))
  (should (not (benedict-vui-conversation-view--streaming-active-p
                (list :status 'pending))))
  (should (not (benedict-vui-conversation-view--streaming-active-p
                nil)))
  (should (not (benedict-vui-conversation-view--streaming-active-p
                (list)))))

(provide 'test/benedict-vui-conversation-view-test)
;;; benedict-vui-conversation-view-test.el ends here
