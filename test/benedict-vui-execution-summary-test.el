;;; benedict-vui-execution-summary-test.el --- Tests for VUI execution summary -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the compact execution summary component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-execution-summary)

(ert-deftest benedict-vui-execution-summary-renders-items-highlights-and-toggle ()
  "Execution summary shows compact facts, highlights, and the toggle button."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-execution-summary
                     :items '("1 tool" "bash" "thinking")
                     :summary '(:has-errors t :highlights ("bash: boom"))
                     :expanded nil
                     :on-toggle #'ignore)
    (let* ((text (buffer-string))
           (highlight-pos (string-match "bash: boom" text)))
      (should (string-match-p "Execution" text))
      (should (string-match-p "1 tool | bash | thinking" text))
      (should highlight-pos)
      (should (string-match-p "Show details" text))
      (should (equal (get-text-property highlight-pos 'face text)
                     '(benedict-chat-turn-summary benedict-chat-error))))))

(ert-deftest benedict-vui-execution-summary-toggle-invokes-callback-with-next-state ()
  "Toggle button reports the next expanded state."
  (let ((calls nil))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-execution-summary
                       :items '("1 tool")
                       :summary nil
                       :expanded nil
                       :on-toggle (lambda (next)
                                    (push next calls)))
      (benedict-vui-test--click-button-labeled "Show details")
      (should (equal calls '(t))))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-execution-summary
                       :items '("1 tool")
                       :summary nil
                       :expanded t
                       :on-toggle (lambda (next)
                                    (push next calls)))
      (benedict-vui-test--click-button-labeled "Hide details")
      (should (equal calls '(nil t))))))

(provide 'test/benedict-vui-execution-summary-test)
;;; benedict-vui-execution-summary-test.el ends here
