;;; benedict-vui-conversation-view-test.el --- Tests for VUI conversation view -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for mounted VUI conversation view behavior.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-conversation-view)
(require 'benedict-vui-streaming-indicator)

(ert-deftest benedict-vui-conversation-view-mount-renders-turn-list-content ()
  "Mounted conversation view renders conversation turns."
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

(ert-deftest benedict-vui-conversation-view-mount-shows-streaming-indicator-when-active ()
  "Mounted conversation view shows spinner frame when streaming is active."
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
          (should (string-match-p (regexp-quote frame) (buffer-string))))))))

(ert-deftest benedict-vui-conversation-view-mount-hides-streaming-indicator-when-not-active ()
  "Mounted conversation view hides spinner when streaming is nil or inactive."
  (let ((frame (car benedict-vui-streaming-indicator--frames)))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-conversation-view
                       :conversation nil
                       :streaming nil
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (should-not (string-match-p (regexp-quote frame) (buffer-string))))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-conversation-view
                       :conversation nil
                       :streaming (list :status 'complete)
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (should-not (string-match-p (regexp-quote frame) (buffer-string))))))

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

(ert-deftest benedict-vui-conversation-view-mount-transitions-streaming-visibility ()
  "Mounted conversation view shows/hides spinner across status transitions."
  (let ((fake-timer (list :timer "streaming"))
        (frame (car benedict-vui-streaming-indicator--frames))
        (conversation (list (list :id "u1" :role 'user :content "Question")
                            (list :id "a1" :role 'assistant :content "Answer"))))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _args) fake-timer))
              ((symbol-function 'cancel-timer)
               (lambda (&rest _args))))
      (with-mounted-vui-component
          (vui-component 'benedict-vui-conversation-view
                         :conversation conversation
                         :streaming (list :status 'pending :turn-id "a2")
                         :collapsed-blocks nil
                         :on-toggle-block #'ignore)
        (let ((text (buffer-string)))
          (should (string-match-p "Question" text))
          (should (string-match-p "Answer" text))
          (should-not (string-match-p (regexp-quote frame) text))))
      (with-mounted-vui-component
          (vui-component 'benedict-vui-conversation-view
                         :conversation conversation
                         :streaming (list :status 'active :turn-id "a2" :content "")
                         :collapsed-blocks nil
                         :on-toggle-block #'ignore)
        (let ((text (buffer-string)))
          (should (string-match-p "Question" text))
          (should (string-match-p "Answer" text))
          (should (string-match-p (regexp-quote frame) text))))
      (with-mounted-vui-component
          (vui-component 'benedict-vui-conversation-view
                         :conversation conversation
                         :streaming (list :status 'complete :turn-id "a2")
                         :collapsed-blocks nil
                         :on-toggle-block #'ignore)
        (let ((text (buffer-string)))
          (should (string-match-p "Question" text))
          (should (string-match-p "Answer" text))
          (should-not (string-match-p (regexp-quote frame) text)))))))

(ert-deftest benedict-vui-conversation-view-mount-malformed-streaming-safe ()
  "Mounted conversation view tolerates malformed streaming payloads."
  (let ((frame (car benedict-vui-streaming-indicator--frames))
        (inputs (list nil
                      (list)
                      42
                      "active"
                      :active
                      [1 2]
                      (list :status nil)
                      (list :status "active")
                      (list :turn-id "a1"))))
    (dolist (streaming inputs)
      (with-mounted-vui-component
          (vui-component 'benedict-vui-conversation-view
                         :conversation (list (list :id "u1" :role 'user :content "Still renders"))
                         :streaming streaming
                         :collapsed-blocks nil
                         :on-toggle-block #'ignore)
        (let ((text (buffer-string)))
          (should (string-match-p "Still renders" text))
          (should-not (string-match-p (regexp-quote frame) text)))))))

(ert-deftest benedict-vui-conversation-view-mount-integrates-turn-list-multi-turn ()
  "Mounted conversation view renders multi-turn output with nav properties."
  (let ((conversation (list (list :id "u1" :role 'user :content "Question one")
                            (list :id "a1" :role 'assistant :content "Answer one")
                            (list :id "u2" :role 'user :content "Question two")
                            (list :id "a2" :role 'assistant :content "Answer two"))))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-conversation-view
                       :conversation conversation
                       :streaming nil
                       :collapsed-blocks nil
                       :on-toggle-block #'ignore)
      (let* ((text (buffer-string))
             (q1-pos (string-match "Question one" text))
             (a1-pos (string-match "Answer one" text))
             (q2-pos (string-match "Question two" text))
             (a2-pos (string-match "Answer two" text)))
        (should q1-pos)
        (should a1-pos)
        (should q2-pos)
        (should a2-pos)
        (should (< q1-pos a1-pos))
        (should (< a1-pos q2-pos))
        (should (< q2-pos a2-pos))
        (benedict-vui-test--assert-text-properties-for
         "Question one"
         :region-kind 'body
         :message-key "u1")
        (benedict-vui-test--assert-text-properties-for
         "Answer two"
         :region-kind 'body
         :message-key "a2")))))

(ert-deftest benedict-vui-conversation-view-mount-multi-turn-with-active-streaming ()
  "Mounted conversation view keeps turn-list output while streaming is active."
  (let ((fake-timer (list :timer "streaming"))
        (frame (car benedict-vui-streaming-indicator--frames)))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _args) fake-timer))
              ((symbol-function 'cancel-timer)
               (lambda (&rest _args))))
      (with-mounted-vui-component
          (vui-component 'benedict-vui-conversation-view
                         :conversation (list (list :id "u1" :role 'user :content "Question one")
                                             (list :id "a1" :role 'assistant :content "Answer one")
                                             (list :id "u2" :role 'user :content "Question two"))
                         :streaming (list :status 'active :turn-id "a2" :content "Stream")
                         :collapsed-blocks nil
                         :on-toggle-block #'ignore)
        (let* ((text (buffer-string))
               (q1-pos (string-match "Question one" text))
               (a1-pos (string-match "Answer one" text))
               (q2-pos (string-match "Question two" text))
               (frame-pos (string-match (regexp-quote frame) text)))
          (should q1-pos)
          (should a1-pos)
          (should q2-pos)
          (should frame-pos)
          (should (< q1-pos a1-pos))
          (should (< a1-pos q2-pos))
          (should (< q2-pos frame-pos)))))))

(provide 'test/benedict-vui-conversation-view-test)
;;; benedict-vui-conversation-view-test.el ends here
