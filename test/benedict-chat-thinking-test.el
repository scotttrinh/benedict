;;; test/benedict-chat-thinking-test.el --- Thinking section tests  -*- lexical-binding: t; -*-

(require 'ert)
(require 'eieio)
(require 'magit-section)
(require 'benedict-chat)
(require 'benedict-chat-fold)
(require 'benedict-chat-ui)

(ert-deftest benedict-chat-thinking-records-folded-block ()
  "Thinking blocks render folded with overlays in classic mode."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (let* ((item (benedict-chat--record-thinking "analysis" (list :provider 'fake)))
           (start (plist-get item :content-start))
           (end (plist-get item :content-end)))
      (should item)
      (should (plist-get item :thinking-folded))
      (should (markerp start))
      (should (markerp end))
      (with-current-buffer (marker-buffer start)
        (let ((pos (marker-position start)))
          (should (eq (get-text-property pos 'benedict-region-kind) 'thinking))
          (should (invisible-p pos))
          (should (equal (buffer-substring-no-properties pos (marker-position end))
                         "analysis")))))))

(ert-deftest benedict-chat-thinking-streaming-appends-and-replaces ()
  "Streaming thinking deltas append then replace on final detail."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (let* ((metadata (list :provider 'fake))
           (delta (list :id "thinking-1" :type "reasoning.text" :text "first")))
      (benedict-chat--display-thinking-detail delta metadata t)
      (benedict-chat--display-thinking-detail
       (list :id "thinking-1" :type "reasoning.text" :text " second")
       metadata t)
      (let* ((item (benedict-chat--lookup-thinking-item "thinking-1"))
             (content (plist-get item :content)))
        (should item)
        (should (string-match-p "first\\s-+second" content))
        (benedict-chat--display-thinking-detail
         (list :id "thinking-1" :type "reasoning.summary" :summary "final")
         metadata nil)
        (should (equal (plist-get item :content) "final"))
        (should (plist-get item :thinking-folded))))))

(ert-deftest benedict-chat-thinking-magit-section-syncs-fold-state ()
  "Magit-section visibility stays in sync with item metadata."
  (with-temp-buffer
    (benedict-chat-ui-mode)
    (let* ((section (make-instance 'magit-section))
           (item (list :thinking-folded t)))
      (oset section type 'thinking)
      (oset section hidden t)
      (plist-put item :section section)
      (benedict-chat-ui--register-section section 'thinking item)
      (should (benedict-chat-ui--section-p section))
      (should (plist-get item :thinking-folded))
      (should (oref section hidden))
      (oset section hidden nil)
      (benedict-chat-ui--sync-fold-state section)
      (should-not (plist-get item :thinking-folded))
      (oset section hidden t)
      (benedict-chat-ui--sync-fold-state section)
      (should (plist-get item :thinking-folded))
      (should (oref section hidden)))))

(ert-deftest benedict-chat-thinking-ui-nests-under-latest-assistant ()
  "UI thinking/tool sections attach to the latest assistant message section."
  (with-temp-buffer
    (benedict-chat-ui-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (list :role 'assistant :content "Hello"))
    (let* ((assistant-item (benedict-chat--last-assistant-item))
           (assistant-section (plist-get assistant-item :section))
           (thinking (benedict-chat--record-thinking "analysis" (list :provider 'fake)))
           (thinking-section (plist-get thinking :section))
           (tool (benedict-chat--record-tool-block (list :id "call-1" :name "demo")
                                                   (list :provider 'fake :status 'running)))
           (tool-section (plist-get tool :section)))
      (should (benedict-chat-ui--section-p assistant-section))
      (should (benedict-chat-ui--section-p thinking-section))
      (should (benedict-chat-ui--section-p tool-section))
      (should (eq (plist-get thinking :parent-section) assistant-section))
      (should (eq (plist-get tool :parent-section) assistant-section)))))

(ert-deftest benedict-chat-thinking-ui-sync-refreshes-header-arrow ()
  "Fold sync updates the thinking header indicator without magit hide/show."
  (with-temp-buffer
    (benedict-chat-ui-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (list :role 'assistant :content "Hello"))
    (let* ((thinking (benedict-chat--record-thinking "analysis" (list :provider 'fake)))
           (section (plist-get thinking :section)))
      (should (benedict-chat-ui--section-p section))
      (let* ((header-start (plist-get thinking :header-start))
             (header-end (plist-get thinking :header-end)))
        (should (and (markerp header-start) (markerp header-end)))
        (oset section hidden nil)
        (benedict-chat-ui--sync-fold-state section)
        (should-not (plist-get thinking :thinking-folded))
        (should (string-prefix-p
                 "▼"
                 (buffer-substring-no-properties
                  (marker-position header-start)
                  (marker-position header-end))))
        (oset section hidden t)
        (benedict-chat-ui--sync-fold-state section)
        (should (plist-get thinking :thinking-folded))
        (should (string-prefix-p
                 "▶"
                 (buffer-substring-no-properties
                  (marker-position header-start)
                  (marker-position header-end))))))))

(ert-deftest benedict-chat-thinking-classic-fold-mirrors-metadata ()
  "Classic thinking folding updates `:thinking-folded' like UI sync."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (let ((item (benedict-chat--record-thinking "analysis" (list :provider 'fake))))
      (should (plist-get item :thinking-folded))
      (benedict-chat-fold-set-thinking-folded item nil)
      (should-not (plist-get item :thinking-folded))
      (benedict-chat-fold-set-thinking-folded item t)
      (should (plist-get item :thinking-folded)))))

(ert-deftest benedict-chat-thinking-navigation-moves-between-blocks ()
  "Navigation commands move between thinking blocks."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (list :role 'assistant :content "Hello"))
    (let* ((thinking-1 (benedict-chat--record-thinking "analysis-1" (list :provider 'fake)))
           (start-1 (plist-get thinking-1 :header-start)))
      (benedict-chat--record-message (list :role 'assistant :content "World"))
      (let* ((thinking-2 (benedict-chat--record-thinking "analysis-2" (list :provider 'fake)))
             (start-2 (plist-get thinking-2 :header-start)))
        (should (and (markerp start-1) (markerp start-2)))
        (goto-char (point-min))
        (benedict-chat-next-thinking)
        (should (= (point) (marker-position start-1)))
        (benedict-chat-next-thinking)
        (should (= (point) (marker-position start-2)))
        (benedict-chat-previous-thinking)
        (should (= (point) (marker-position start-1)))))))

(ert-deftest benedict-chat-thinking-toggle-under-assistant-ui ()
  "Toggle thinking under assistant sections in UI mode."
  (with-temp-buffer
    (benedict-chat-ui-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (list :role 'assistant :content "Hello"))
    (let* ((assistant (benedict-chat--last-assistant-item))
           (assistant-start (plist-get assistant :header-start))
           (thinking (benedict-chat--record-thinking "analysis" (list :provider 'fake)))
           (thinking-section (plist-get thinking :section)))
      (should (and (markerp assistant-start) (markerp (plist-get thinking :header-start))))
      (should (plist-get thinking :thinking-folded))
      (goto-char (marker-position assistant-start))
      (benedict-chat-toggle-thinking)
      (should-not (plist-get thinking :thinking-folded))
      (should (benedict-chat-ui--section-p thinking-section))
      (should-not (oref thinking-section hidden)))))

(ert-deftest benedict-chat-jump-to-last-assistant-with-tools-finds-parent ()
  "Jump-to-last-assistant-with-tools goes to the last assistant with tool blocks."
  (with-temp-buffer
    (benedict-chat-mode)
    (benedict-chat--init-buffer)
    (benedict-chat--record-message (list :role 'assistant :content "With tools"))
    (let* ((assistant-1 (benedict-chat--last-assistant-item))
           (assistant-1-start (plist-get assistant-1 :header-start)))
      (benedict-chat--record-tool-block (list :id "call-1" :name "demo")
                                        (list :provider 'fake :status 'success))
      (benedict-chat--record-message (list :role 'assistant :content "No tools"))
      (goto-char (point-max))
      (benedict-chat-jump-to-last-assistant-with-tools)
      (should (= (point) (marker-position assistant-1-start))))))

(provide 'test/benedict-chat-thinking-test)
;;; benedict-chat-thinking-test.el ends here
