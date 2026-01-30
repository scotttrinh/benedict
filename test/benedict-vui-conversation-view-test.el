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
         captured-props)
    (cl-letf (((symbol-function 'benedict-vui-turn-list)
               (lambda (&rest args)
                 (setq captured-props args)
                 'turn-list))
              ((symbol-function 'benedict-vui-streaming-indicator)
               (lambda (&rest _args) 'streaming-indicator))
              ((symbol-function 'vui-vstack)
               (lambda (&rest args) 'vstack)))
      (vui-component 'benedict-vui-conversation-view--render (list :conversation conversation
                                                    :collapsed-blocks collapsed-blocks
                                                    :streaming nil))
      (should captured-props)
      (should (equal (plist-get captured-props :conversation) conversation))
      (should (equal (plist-get captured-props :collapsed-blocks) collapsed-blocks)))))

(ert-deftest benedict-vui-conversation-view-shows-streaming-indicator ()
  "Conversation view shows StreamingIndicator during active streaming."
  (let* ((conversation nil)
         (streaming-active (list :status 'active :turn-id "turn-1" :content ""))
         (collapsed-blocks nil)
         captured-props)
    (cl-letf (((symbol-function 'benedict-vui-turn-list)
               (lambda (&rest _args) 'turn-list))
              ((symbol-function 'benedict-vui-streaming-indicator)
               (lambda (&rest args)
                 (setq captured-props args)
                 'streaming-indicator))
              ((symbol-function 'vui-vstack)
               (lambda (&rest args) 'vstack)))
      (vui-component 'benedict-vui-conversation-view--render (list :conversation conversation
                                                    :collapsed-blocks collapsed-blocks
                                                    :streaming streaming-active))
      (should captured-props)
      (should (plist-get captured-props :visible)))))

(ert-deftest benedict-vui-conversation-view-hides-streaming-indicator-when-idle ()
  "Conversation view hides StreamingIndicator when not streaming."
  (let* ((conversation nil)
         (streaming-inactive (list :status 'complete))
         (collapsed-blocks nil)
         captured-visible)
    (cl-letf (((symbol-function 'benedict-vui-turn-list)
               (lambda (&rest _args) 'turn-list))
              ((symbol-function 'benedict-vui-streaming-indicator)
               (lambda (&rest args)
                 (setq captured-visible (plist-get (car args) :visible))
                 'streaming-indicator))
              ((symbol-function 'vui-vstack)
               (lambda (&rest args) 'vstack)))
      (vui-component 'benedict-vui-conversation-view--render (list :conversation conversation
                                                    :collapsed-blocks collapsed-blocks
                                                    :streaming streaming-inactive))
      (should (not captured-visible)))))

(ert-deftest benedict-vui-conversation-view-handles-nil-streaming ()
  "Conversation view handles nil streaming gracefully."
  (let* ((conversation nil)
         (collapsed-blocks nil)
         captured-visible)
    (cl-letf (((symbol-function 'benedict-vui-turn-list)
               (lambda (&rest _args) 'turn-list))
              ((symbol-function 'benedict-vui-streaming-indicator)
               (lambda (&rest args)
                 (setq captured-visible (plist-get (car args) :visible))
                 'streaming-indicator))
              ((symbol-function 'vui-vstack)
               (lambda (&rest args) 'vstack)))
      (vui-component 'benedict-vui-conversation-view--render (list :conversation conversation
                                                    :collapsed-blocks collapsed-blocks
                                                    :streaming nil))
      (should (not captured-visible)))))

(ert-deftest benedict-vui-conversation-view-streaming-active-p ()
  "Helper function correctly identifies active streaming state."
  (should (vui-component 'benedict-vui-conversation-view--streaming-active-p
           (list :status 'active)))
  (should (vui-component 'benedict-vui-conversation-view--streaming-active-p
           (list :status 'active :turn-id "turn-1" :content "text")))
  (should (not (vui-component 'benedict-vui-conversation-view--streaming-active-p
                (list :status 'complete))))
  (should (not (vui-component 'benedict-vui-conversation-view--streaming-active-p
                (list :status 'pending))))
  (should (not (vui-component 'benedict-vui-conversation-view--streaming-active-p
                nil)))
  (should (not (vui-component 'benedict-vui-conversation-view--streaming-active-p
                (list)))))

(provide 'test/benedict-vui-conversation-view-test)
;;; benedict-vui-conversation-view-test.el ends here
