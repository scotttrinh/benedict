;;; test/benedict-chat-thinking-test.el --- Thinking section tests  -*- lexical-binding: t; -*-

(require 'ert)
(require 'eieio)
(require 'magit-section)
(require 'benedict-chat)
(require 'benedict-chat-thinking)
(require 'benedict-chat-tool-ui)

(ert-deftest benedict-chat-thinking-streaming-appends-and-replaces ()
  "Streaming thinking deltas append then replace on final detail."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (let* ((metadata (list :provider 'fake))
           (delta (list :id "thinking-1" :type "reasoning.text" :text "first")))
      (benedict-chat-thinking--display-detail (current-buffer) delta metadata t)
      (benedict-chat-thinking--display-detail
       (current-buffer)
       (list :id "thinking-1" :type "reasoning.text" :text " second")
       metadata t)
      (let* ((item (benedict-chat-thinking--lookup-item "thinking-1"))
             (content (plist-get item :content)))
        (should item)
        (should (string-match-p "first\\s-+second" content))
        (benedict-chat-thinking--display-detail
         (current-buffer)
         (list :id "thinking-1" :type "reasoning.summary" :summary "final")
         metadata nil)
        (should (equal (plist-get item :content) "final"))
        (should (plist-get item :thinking-folded))))))

(ert-deftest benedict-chat-thinking-magit-section-syncs-fold-state ()
  "Magit-section visibility stays in sync with item metadata."
  (with-temp-buffer
    (benedict-chat-mode)
    (let* ((section (make-instance 'magit-section))
           (item (list :thinking-folded t)))
      (oset section type 'thinking)
      (oset section hidden t)
      (plist-put item :section section)
      (benedict-chat-sections--register section 'thinking item)
      (should (benedict-chat-sections--section-p section))
      (should (plist-get item :thinking-folded))
      (should (oref section hidden))
      (oset section hidden nil)
      (benedict-chat-sections--sync-fold-state section)
      (should-not (plist-get item :thinking-folded))
      (oset section hidden t)
      (benedict-chat-sections--sync-fold-state section)
      (should (plist-get item :thinking-folded))
      (should (oref section hidden)))))

(ert-deftest benedict-chat-thinking-ui-nests-under-latest-assistant ()
  "UI thinking/tool sections attach to the latest assistant message section."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (current-buffer)
                                   (list :role 'assistant :content "Hello"))
    (let* ((assistant-item (benedict-chat-nav--last-assistant-item))
           (assistant-section (plist-get assistant-item :section))
           (thinking (benedict-chat-thinking--record-block (current-buffer) "analysis" (list :provider 'fake)))
           (thinking-section (plist-get thinking :section))
           (tool (benedict-chat-tool-ui--record-block
                  (current-buffer)
                  (list :id "call-1" :name "demo")
                  (list :provider 'fake :status 'running)))
           (tool-section (plist-get tool :section)))
      (should (benedict-chat-sections--section-p assistant-section))
      (should (benedict-chat-sections--section-p thinking-section))
      (should (benedict-chat-sections--section-p tool-section))
      (should (eq (plist-get thinking :parent-section) assistant-section))
      (should (eq (plist-get tool :parent-section) assistant-section)))))

(ert-deftest benedict-chat-thinking-ui-sync-refreshes-header-arrow ()
  "Fold sync updates the thinking header indicator without magit hide/show."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (current-buffer)
                                   (list :role 'assistant :content "Hello"))
    (let* ((thinking (benedict-chat-thinking--record-block (current-buffer) "analysis" (list :provider 'fake)))
           (section (plist-get thinking :section)))
      (should (benedict-chat-sections--section-p section))
      (let* ((header-start (plist-get thinking :header-start))
             (header-end (plist-get thinking :header-end)))
        (should (and (markerp header-start) (markerp header-end)))
        (oset section hidden nil)
        (benedict-chat-sections--sync-fold-state section)
        (should-not (plist-get thinking :thinking-folded))
        (should (string-prefix-p
                 "▼"
                 (buffer-substring-no-properties
                  (marker-position header-start)
                  (marker-position header-end))))
        (oset section hidden t)
        (benedict-chat-sections--sync-fold-state section)
        (should (plist-get thinking :thinking-folded))
        (should (string-prefix-p
                 "▶"
                 (buffer-substring-no-properties
                  (marker-position header-start)
                  (marker-position header-end))))))))

;; SKIPPED: This test verifies classic overlay folding via benedict-chat-fold
;; which is being removed in favor of magit-section based folding.

(ert-deftest benedict-chat-thinking-navigation-moves-between-blocks ()
  "Navigation commands move between thinking blocks."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (current-buffer)
                                   (list :role 'assistant :content "Hello"))
    (let* ((thinking-1 (benedict-chat-thinking--record-block (current-buffer) "analysis-1" (list :provider 'fake)))
           (start-1 (plist-get thinking-1 :header-start)))
      (benedict-chat--record-message (current-buffer)
                                     (list :role 'assistant :content "World"))
      (let* ((thinking-2 (benedict-chat-thinking--record-block (current-buffer) "analysis-2" (list :provider 'fake)))
             (start-2 (plist-get thinking-2 :header-start)))
        (should (and (markerp start-1) (markerp start-2)))
        (goto-char (point-min))
        (benedict-chat-nav-next-thinking)
        (should (= (point) (marker-position start-1)))
        (benedict-chat-nav-next-thinking)
        (should (= (point) (marker-position start-2)))
        (benedict-chat-nav-previous-thinking)
        (should (= (point) (marker-position start-1)))))))

(ert-deftest benedict-chat-thinking-toggle-under-assistant-ui ()
  "Toggle thinking under assistant sections in UI mode."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (current-buffer)
                                   (list :role 'assistant :content "Hello"))
    (let* ((assistant (benedict-chat-nav--last-assistant-item))
           (assistant-start (plist-get assistant :header-start))
           (thinking (benedict-chat-thinking--record-block (current-buffer) "analysis" (list :provider 'fake)))
           (thinking-section (plist-get thinking :section)))
      (should (and (markerp assistant-start) (markerp (plist-get thinking :header-start))))
      (should (plist-get thinking :thinking-folded))
      (goto-char (marker-position assistant-start))
      (benedict-chat-nav-toggle-thinking)
      (should-not (plist-get thinking :thinking-folded))
      (should (benedict-chat-sections--section-p thinking-section))
      (should-not (oref thinking-section hidden)))))

(ert-deftest benedict-chat-nav-jump-to-last-assistant-with-tools-finds-parent ()
  "Test that jump-to-last-assistant-with-tools correctly navigates to the parent assistant message."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    
    ;; Assistant 1: No tools
    (benedict-chat--record-message (current-buffer)
                                   (list :role 'assistant :content "Assistant 1"))
    
    ;; Assistant 2: Has tools
    (benedict-chat--record-message (current-buffer)
                                   (list :role 'assistant :content "Assistant 2"))
    (let ((assistant-2 (benedict-chat-nav--last-assistant-item)))
      (benedict-chat-tool-ui--record-block (current-buffer)
                                           (list :id "call-1" :name "test")
                                           (list :provider 'fake :status 'success))
      
      (goto-char (point-min))
      (benedict-chat-nav-jump-to-last-assistant-with-tools)
      
      (should (equal (benedict-chat-nav--item-at-point) assistant-2)))))

(provide 'test/benedict-chat-thinking-test)
;;; benedict-chat-thinking-test.el ends here
