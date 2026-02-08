;;; benedict-vui-conversation-view-test.el --- Tests for VUI conversation view -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for mounted VUI conversation view behavior.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vui)
(require 'benedict-vui-conversation-view)
(require 'benedict-vui-streaming-indicator)

(ert-deftest benedict-vui-conversation-view-mount-renders-turn-list-content ()
  "Mounted conversation view renders conversation turns."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-conversation-view
                      :conversation (list (list :id "u1" :role 'user :content "Hi there")
                                          (list :id "a1" :role 'assistant :content "Hello back"))
                      :streaming nil
                      :collapsed-blocks nil
                      :on-toggle-block #'ignore)
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "USER" text))
        (should (string-match-p "ASSISTANT" text))
        (should (string-match-p "Hi there" text))
        (should (string-match-p "Hello back" text))))))

(ert-deftest benedict-vui-conversation-view-mount-shows-streaming-indicator-when-active ()
  "Mounted conversation view shows spinner frame when streaming is active."
  (let ((fake-timer (list :timer "streaming")))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _args) fake-timer))
              ((symbol-function 'cancel-timer)
               (lambda (&rest _))))
      (with-temp-buffer
        (let ((buffer-name (buffer-name))
              (frame (car benedict-vui-streaming-indicator--frames)))
          (vui-mount
           (vui-component 'benedict-vui-conversation-view
                          :conversation nil
                          :streaming (list :status 'active :turn-id "turn-1" :content "")
                          :collapsed-blocks nil
                          :on-toggle-block #'ignore)
           buffer-name)
          (vui-flush-sync)
          (should (string-match-p (regexp-quote frame) (buffer-string))))))))

(ert-deftest benedict-vui-conversation-view-mount-hides-streaming-indicator-when-not-active ()
  "Mounted conversation view hides spinner when streaming is nil or inactive."
  (let ((frame (car benedict-vui-streaming-indicator--frames)))
    (with-temp-buffer
      (let ((buffer-name (buffer-name)))
        (vui-mount
         (vui-component 'benedict-vui-conversation-view
                        :conversation nil
                        :streaming nil
                        :collapsed-blocks nil
                        :on-toggle-block #'ignore)
         buffer-name)
        (vui-flush-sync)
        (should-not (string-match-p (regexp-quote frame) (buffer-string)))
        (vui-mount
         (vui-component 'benedict-vui-conversation-view
                        :conversation nil
                        :streaming (list :status 'complete)
                        :collapsed-blocks nil
                        :on-toggle-block #'ignore)
         buffer-name)
        (vui-flush-sync)
        (should-not (string-match-p (regexp-quote frame) (buffer-string)))))))

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

(provide 'test/benedict-vui-conversation-view-test)
;;; benedict-vui-conversation-view-test.el ends here
