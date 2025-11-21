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

(provide 'test/benedict-chat-stream-test)
;;; benedict-chat-stream-test.el ends here
