;;; benedict-vui-status-bar.el --- Vui status bar component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a status bar showing token count, cost estimate, and errors.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict)

(defun benedict-vui-status-bar--format-tokens (count)
  "Return formatted string for COUNT tokens."
  (when (and count (numberp count))
    (format "%s tokens" (format "%.0f" count))))

(defun benedict-vui-status-bar--format-cost (cost)
  "Return formatted string for COST."
  (when (and cost (numberp cost) (> cost 0))
    (format "$%.4f" cost)))

(defun benedict-vui-status-bar--total-tokens (usage)
  "Return total token count from USAGE plist."
  (when usage
    (or (plist-get usage :total)
        (plist-get usage :tokens)
        (let ((prompt (plist-get usage :prompt))
              (completion (plist-get usage :completion)))
          (when (and prompt completion)
            (+ prompt completion))))))

(defun benedict-vui-status-bar--cost (usage)
  "Return cost from USAGE plist."
  (when usage
    (plist-get usage :cost)))

(vui-defcomponent benedict-vui-status-bar (props)
  :render
  (let* ((usage (plist-get props :usage))
         (error (plist-get props :error))
         (tokens (benedict-vui-status-bar--total-tokens usage))
         (cost (benedict-vui-status-bar--cost usage))
         (token-label (benedict-vui-status-bar--format-tokens tokens))
         (cost-label (benedict-vui-status-bar--format-cost cost)))
    (vui-hstack
      :spacing 2
      (when token-label
        (vui-text token-label
          :face 'benedict-chat-header-usage))
      (when (and token-label cost-label)
        (vui-text "·"
          :face 'benedict-chat-header-separator))
      (when cost-label
        (vui-text cost-label
          :face 'benedict-chat-header-usage))
      (when error
        (vui-text "·"
          :face 'benedict-chat-header-separator)
        (vui-text (format "%s" error)
          :face 'benedict-chat-error)))))

(provide 'benedict-vui-status-bar)
;;; benedict-vui-status-bar.el ends here
