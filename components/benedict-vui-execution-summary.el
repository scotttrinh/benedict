;;; benedict-vui-execution-summary.el --- Vui execution summary component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders the compact execution summary for a completed turn.

;;; Code:

(require 'subr-x)
(require 'vui)
(require 'benedict-vui-turn-section)

(defun benedict-vui-execution-summary--summary-line-face (summary)
  "Return summary line face derived from SUMMARY."
  (if (plist-get summary :has-errors)
      '(benedict-chat-turn-summary benedict-chat-error)
    '(benedict-chat-turn-summary benedict-chat-header-time)))

(vui-defcomponent benedict-vui-execution-summary (items summary expanded on-toggle)
  "Render execution summary using ITEMS and SUMMARY."
  :render
  (let ((children nil))
    (when items
      (setq children
            (append children
                    (list (vui-text (mapconcat #'identity items " | ")
                                    :face '(benedict-chat-turn-summary
                                            benedict-chat-header-time))))))
    (when-let ((highlights (plist-get summary :highlights)))
      (setq children
            (append children
                    (list (vui-text (mapconcat #'identity highlights " | ")
                                    :face (benedict-vui-execution-summary--summary-line-face
                                           summary))))))
    (setq children
          (append children
                  (list (vui-button (if expanded "Hide details" "Show details")
                                    :on-click (lambda (&rest _)
                                                (when (functionp on-toggle)
                                                  (funcall on-toggle (not expanded))))))))
    (vui-component 'benedict-vui-turn-section
                   :status 'assistant
                   :title "Execution"
                   :detail nil
                   :face 'benedict-chat-turn-summary
                   :content (apply #'vui-vstack (append (list :spacing 1) children)))))

(provide 'benedict-vui-execution-summary)
;;; benedict-vui-execution-summary.el ends here
