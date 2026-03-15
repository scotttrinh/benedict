;;; benedict-vui-conversation-view-test.el --- Tests for VUI conversation view -*- lexical-binding: t; -*-

;;; Commentary:
;; Focused tests for conversation view wrapper behavior.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-conversation-view)
(require 'benedict-vui-streaming-indicator)

(ert-deftest benedict-vui-conversation-view-mount-preserves-turn-list-content ()
  "Conversation view keeps canonical turn-list content visible."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-conversation-view
                     :conversation (list (list :id "u1" :role 'user :content "Hi there")
                                         (list :id "a1" :role 'assistant :content "Hello back"))
                     :streaming nil
                     :collapsed-blocks nil
                     :on-toggle-block #'ignore)
    (let ((text (buffer-string)))
      (should (string-match-p "USER" text))
      (should (string-match-p "ASSISTANT" text))
      (should (string-match-p "Hi there" text))
      (should (string-match-p "Hello back" text)))))

(ert-deftest benedict-vui-conversation-view-mount-only-shows-spinner-when-active ()
  "Conversation view only exposes spinner output for active streaming."
  (let ((fake-timer (list :timer "streaming")))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _args) fake-timer))
              ((symbol-function 'cancel-timer)
               (lambda (&rest _))))
      (let ((frame (car benedict-vui-streaming-indicator--frames)))
        (with-mounted-vui-component
            (vui-component 'benedict-vui-conversation-view
                           :conversation nil
                           :streaming (list :status 'active :turn-id "turn-1" :content "")
                           :collapsed-blocks nil
                           :on-toggle-block #'ignore)
          (should (string-match-p (regexp-quote frame) (buffer-string)))))
      (let ((frame (car benedict-vui-streaming-indicator--frames)))
        (dolist (streaming (list nil
                                 (list :status 'pending)
                                 (list :status 'complete)
                                 (list :turn-id "turn-1")
                                 (list :status "active")
                                 42))
          (with-mounted-vui-component
              (vui-component 'benedict-vui-conversation-view
                             :conversation nil
                             :streaming streaming
                             :collapsed-blocks nil
                             :on-toggle-block #'ignore)
            (should-not (string-match-p (regexp-quote frame) (buffer-string)))))))))

(ert-deftest benedict-vui-conversation-view-streaming-active-p ()
  "Streaming helper identifies active state from streaming plist values."
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

(ert-deftest benedict-vui-conversation-view-streaming-active-p-malformed-safe ()
  "Streaming helper treats malformed payloads as inactive."
  (should-not (benedict-vui-conversation-view--streaming-active-p 42))
  (should-not (benedict-vui-conversation-view--streaming-active-p "active"))
  (should-not (benedict-vui-conversation-view--streaming-active-p :active))
  (should-not (benedict-vui-conversation-view--streaming-active-p [1 2 3]))
  (should-not (benedict-vui-conversation-view--streaming-active-p
               (list :status "active")))
  (should-not (benedict-vui-conversation-view--streaming-active-p
               (list :turn-id "turn-1"))))

(provide 'test/benedict-vui-conversation-view-test)
;;; benedict-vui-conversation-view-test.el ends here
