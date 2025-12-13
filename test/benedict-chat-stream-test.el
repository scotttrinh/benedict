;;; test/benedict-chat-stream-test.el --- Tests for benedict-chat-stream  -*- lexical-binding: t; -*-

(require 'ert)
(require 'benedict-chat-stream)

(ert-deftest benedict-chat-stream-insertion ()
  "Test streaming insertion into a buffer."
  (with-temp-buffer
    (benedict-chat--stream-init (current-buffer))
    (should benedict-stream-state)
    
    (let ((start (plist-get benedict-stream-state :content-start))
          (end (plist-get benedict-stream-state :content-end)))
      (should (markerp start))
      (should (markerp end))
      (should (= (marker-position start) (point-min)))
      (should (= (marker-position end) (point-min)))
      
      (benedict-chat--stream-insert-delta benedict-stream-state "Chunk 1")
      (should (string= (buffer-string) "Chunk 1"))
      (should (= (marker-position start) (point-min)))
      (should (= (marker-position end) (point-max)))
      (should (eq (get-text-property (point-min) 'benedict-region-kind) 'body))
      
      (benedict-chat--stream-insert-delta benedict-stream-state "Chunk 2")
      (should (string= (buffer-string) "Chunk 1Chunk 2"))
      (should (= (marker-position end) (point-max))))))

(ert-deftest benedict-chat-stream-insertion-into-message-item ()
  "Streaming insertion should append inside a message item body region."
  (require 'benedict-chat-render)
  (with-temp-buffer
    (let* ((message (list :role 'assistant :content ""))
           (item (list :kind 'message :message message)))
      (plist-put message :item item)
      (benedict-chat--render-message-item item "[ASSISTANT] streaming" "")
      (benedict-chat--stream-init (current-buffer)
                                  (plist-get item :content-start)
                                  (plist-get item :content-end))
      (benedict-chat--stream-insert-delta benedict-stream-state "Hi")
      (should (string-match-p "Hi" (buffer-string)))
      (should (eq (get-text-property (marker-position (plist-get item :content-start))
                                     'benedict-region-kind)
                  'body)))))

(provide 'test/benedict-chat-stream-test)
;;; benedict-chat-stream-test.el ends here
