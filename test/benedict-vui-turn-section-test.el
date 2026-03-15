;;; benedict-vui-turn-section-test.el --- Tests for VUI turn section -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the labeled turn section component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-turn-section)

(ert-deftest benedict-vui-turn-section-applies-navigation-properties-to-label-row ()
  "Turn section label text carries navigation properties end to end."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-turn-section
                     :status 'assistant
                     :title "Activity"
                     :detail "Working"
                     :face 'benedict-chat-turn-active
                     :navigation-properties '(benedict-turn-id "turn-1"
                                              benedict-turn-target activity)
                     :content (vui-text "Streaming body"))
    (let* ((text (buffer-string))
           (title-pos (string-match "Activity" text))
           (detail-pos (string-match "Working" text))
           (body-pos (string-match "Streaming body" text)))
      (should (string-match-p "ASSISTANT" text))
      (should title-pos)
      (should detail-pos)
      (should body-pos)
      (should (equal (get-text-property title-pos 'face text)
                     'benedict-chat-turn-active))
      (should (equal (get-text-property title-pos 'benedict-turn-id text)
                     "turn-1"))
      (should (eq (get-text-property title-pos 'benedict-turn-target text)
                  'activity))
      (should (equal (get-text-property detail-pos 'face text)
                     '(benedict-chat-turn-active benedict-chat-header-time)))
      (should (equal (get-text-property detail-pos 'benedict-turn-id text)
                     "turn-1"))
      (should (eq (get-text-property detail-pos 'benedict-turn-target text)
                  'activity))
      (should-not (get-text-property body-pos 'benedict-turn-id text)))))

(provide 'test/benedict-vui-turn-section-test)
;;; benedict-vui-turn-section-test.el ends here
