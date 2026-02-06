;;; benedict-vui-text-block.el --- Vui text block component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders markdown-capable text content in the Vui chat UI.

;;; Code:

(require 'vui)

(defun benedict-vui-text-block--normalize (content)
  "Return CONTENT as a string, treating nil as empty."
  (cond
   ((stringp content) content)
   ((null content) "")
   (t (format "%s" content))))

(defun benedict-vui-text-block--propertize (content &optional message-key block-id)
  "Return CONTENT with body text properties applied.

MESSAGE-KEY and BLOCK-ID are stored as text properties when provided."
  (let ((text (benedict-vui-text-block--normalize content)))
    (propertize text
                'benedict-region-kind 'body
                'benedict-message-key message-key
                'benedict-block-id block-id)))

(vui-defcomponent benedict-vui-text-block (content message-key block-id)
  :render
  (vui-text (benedict-vui-text-block--propertize content message-key block-id)))

(provide 'benedict-vui-text-block)
;;; benedict-vui-text-block.el ends here
