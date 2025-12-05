;;; test/benedict-chat-fold-test.el --- Tests for chat folding adapter -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'benedict-chat-fold)

(ert-deftest benedict-chat-fold-thinking-overlay-tracks-append ()
  (with-temp-buffer
    (benedict-chat-fold-init-buffer)
    (let* ((start (point-marker))
           (item (list :content-start start)))
      (insert "thinking")
      (let ((end (copy-marker (point) t)))
        (plist-put item :content-end end)
        (plist-put item :thinking-folded t)
        (benedict-chat-fold-set-thinking-folded item t)
        (let ((fold (plist-get item :thinking-fold)))
          (should (benedict-fold-core-folded-p fold))
          (should (eq (get-char-property (marker-position start) 'invisible)
                      'benedict-chat-thinking)))
        (goto-char (marker-position end))
        (insert " more")
        (benedict-chat-fold-update-thinking item)
        (let ((fold (plist-get item :thinking-fold)))
          (should (benedict-fold-core-folded-p fold))
          (should (eq (get-char-property (1- (point)) 'invisible)
                      'benedict-chat-thinking)))))))

(ert-deftest benedict-chat-fold-filter-buffer-substring-strips-properties ()
  (with-temp-buffer
    (benedict-chat-fold-init-buffer)
    (insert (propertize "hidden" 'invisible 'benedict-chat-thinking))
    (let ((text (filter-buffer-substring (point-min) (point-max))))
      (should (equal text "hidden"))
      (should-not (cl-loop for i below (length text)
                           thereis (get-text-property i 'invisible text))))))

(ert-deftest benedict-chat-fold-isearch-clears-and-restores-visibility ()
  (with-temp-buffer
    (benedict-chat-fold-init-buffer)
    (setq buffer-invisibility-spec '(foo benedict-chat-thinking))
    (should (eq search-invisible 'open))
    (benedict-chat-fold--isearch-open)
    (should (null buffer-invisibility-spec))
    (benedict-chat-fold--isearch-close)
    (should (equal buffer-invisibility-spec '(foo benedict-chat-thinking)))))

(provide 'test/benedict-chat-fold-test)
;;; test/benedict-chat-fold-test.el ends here
