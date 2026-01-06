;;; test/benedict-chat-stream-test.el --- Tests for benedict-chat-stream  -*- lexical-binding: t; -*-

(require 'ert)
(require 'benedict-chat-stream)

(ert-deftest benedict-chat-stream-insertion ()
  "Test streaming insertion into a buffer."
  (with-temp-buffer
    (let* ((item (list :content-start (copy-marker (point-min) nil)
                       :content-end (copy-marker (point-min) t))))
      (benedict-chat--stream-init (current-buffer) item))
    (should benedict-stream-state)
    
    (let* ((item (plist-get benedict-stream-state :item))
           (start (plist-get item :content-start))
           (end (plist-get item :content-end)))
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
      (benedict-chat--render-message-item (current-buffer) item "[ASSISTANT] streaming" "")
      (benedict-chat--stream-init (current-buffer) item)
      (benedict-chat--stream-insert-delta benedict-stream-state "Hi")
      (should (string-match-p "Hi" (buffer-string)))
      (should (eq (get-text-property (marker-position (plist-get item :content-start))
                                     'benedict-region-kind)
                  'body)))))

(provide 'test/benedict-chat-stream-test)
;;; benedict-chat-stream-test.el ends here
