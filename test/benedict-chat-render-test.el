;;; test/benedict-chat-render-test.el --- Tests for benedict-chat-render  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'benedict-chat-render)

(ert-deftest benedict-chat-render-insert-message ()
  "Test inserting a message with role and content."
  (with-temp-buffer
    (benedict-chat--insert-message '(:role user :content "Hello"))
    
    (goto-char (point-min))
    (should (looking-at-p "\\[USER\\]"))
    (should (eq (get-text-property (point) 'benedict-region-kind) 'header))
    (should (eq (get-text-property (point) 'face) 'benedict-chat-role))
    
    (forward-line 1)
    (should (looking-at-p "Hello"))
    (should (eq (get-text-property (point) 'benedict-region-kind) 'body))
    ;; Face should be nil initially (left to markdown-mode)
    (should (null (get-text-property (point) 'face)))))

(ert-deftest benedict-chat-render-tool-stacking ()
  "Test that multiple tool calls do not stack/nest incorrectly."
  (with-temp-buffer
    (let ((item1 (list :tool-call '(:name "tool1") :content "Output1"))
          (item2 (list :tool-call '(:name "tool2") :content "Output2")))
      
      ;; Render first tool
      (benedict-chat--render-tool-item item1)
      (should (string-match-p "tool1" (buffer-string)))
      (should (string-match-p "Output1" (buffer-string)))
      
      ;; Render second tool immediately after
      (benedict-chat--render-tool-item item2)
      (should (string-match-p "tool2" (buffer-string)))
      (should (string-match-p "Output2" (buffer-string)))
      
      ;; Verify order
      (goto-char (point-min))
      (search-forward "tool1")
      (search-forward "Output1")
      (search-forward "tool2")
      (search-forward "Output2")
      
      ;; Verify markers of Item 1 do NOT include Item 2
      ;; specifically, item1 end should be before or at item2 start
      (let ((end1 (plist-get item1 :end))
            (start2 (plist-get item2 :start)))
        (should (<= (marker-position end1) (marker-position start2)))))))

(ert-deftest benedict-chat-render-tool-update-content ()
  "Test that updating tool content adjusts markers correctly."
  (with-temp-buffer
    (let ((item (list :tool-call '(:name "tool1") :content "Old")))
      (benedict-chat--render-tool-item item)
      
      ;; Verify initial content
      (should (string-match-p "Old" (buffer-string)))
      
      ;; Update content
      (benedict-chat--write-message-item-content item "NewContent")
      (should (string-match-p "NewContent" (buffer-string)))
      (should-not (string-match-p "Old" (buffer-string)))
      
      ;; Verify markers moved
      (let ((start (plist-get item :content-start))
            (end (plist-get item :content-end)))
        (should (equal (buffer-substring-no-properties start end) "NewContent"))))))

(ert-deftest benedict-chat-render-tool-toggle-does-not-duplicate-header ()
  "Toggling tool visibility should not clone the header line."
  (with-temp-buffer
	(let* ((item (list :metadata (list :status 'success)
	                       :tool-call (list :name 'fold-me)
	                       :content "Body"
	                       :tool-folded t))
	           (label "fold-me"))
	      (benedict-chat--render-tool-item item)
	      ;; Toggle open then closed
	      (goto-char (plist-get item :header-start))
      (benedict-chat-tool-toggle)
      (benedict-chat-tool-toggle)
      ;; Header markers should still wrap the header text
      (let ((start (plist-get item :header-start))
            (end (plist-get item :header-end)))
        (should (< (marker-position start) (marker-position end))))
      ;; Only one header line with the tool label should exist
      (let ((count 0))
        (save-excursion
          (goto-char (point-min))
          (while (search-forward label nil t)
            (cl-incf count)))
        (should (= 1 count))))))

(ert-deftest benedict-chat-render-tool-folds-body ()
  "Tool body starts folded and toggles visibility."
  (with-temp-buffer
    (let ((item (list :metadata (list :status 'success)
                      :tool-call (list :name 'fold-me)
                      :content "HiddenBody"
                      :tool-folded t)))
      (benedict-chat--render-tool-item item)
      (goto-char (plist-get item :header-start))
      (should (eq (get-text-property (plist-get item :content-start) 'invisible)
                  'benedict-tool-details))
      (goto-char (plist-get item :header-start))
      (benedict-chat-tool-toggle)
      (should-not (get-text-property (plist-get item :content-start) 'invisible))
      (goto-char (plist-get item :header-start))
      (benedict-chat-tool-toggle)
      (should (eq (get-text-property (plist-get item :content-start) 'invisible)
                  'benedict-tool-details)))))

(ert-deftest benedict-chat-render-message-item-header-update-preserves-body-markers ()
  "Updating a message header should not move body markers."
  (with-temp-buffer
    (let* ((message (list :role 'assistant :content "Hello"))
           (item (list :kind 'message :message message)))
      (plist-put message :item item)
      (benedict-chat--render-message-item item "[ASSISTANT] initial" "Hello")
      (let ((body-start (marker-position (plist-get item :content-start)))
            (body-end (marker-position (plist-get item :content-end))))
        (benedict-chat--update-message-header item "[ASSISTANT] updated")
        (should (equal body-start (marker-position (plist-get item :content-start))))
        (should (equal body-end (marker-position (plist-get item :content-end))))
        (should (string-match-p "\\[ASSISTANT\\] updated" (buffer-string)))
        (should (string-match-p "Hello" (buffer-string)))))))

(ert-deftest benedict-chat-render-message-item-body-rewrite-updates-end-marker ()
  "Replacing a message body should update the end marker."
  (with-temp-buffer
    (let* ((message (list :role 'assistant :content "Hello"))
           (item (list :kind 'message :message message)))
      (plist-put message :item item)
      (benedict-chat--render-message-item item "[ASSISTANT] hdr" "Hello")
      (let ((old-end (marker-position (plist-get item :content-end))))
        (benedict-chat--write-message-item-body item "Hello world")
        (should (string-match-p "Hello world" (buffer-string)))
        (should (> (marker-position (plist-get item :content-end)) old-end))
        (should (equal (buffer-substring-no-properties
                        (plist-get item :content-start)
                        (plist-get item :content-end))
                       "Hello world"))))))

(provide 'test/benedict-chat-render-test)
;;; benedict-chat-render-test.el ends here
