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

(defun benedict-vui-text-block--propertize (content)
  "Return CONTENT with body text properties applied."
  (propertize (vui-component 'benedict-vui-text-block--normalize content)
              'benedict-region-kind 'body))

(vui-defcomponent benedict-vui-text-block (props)
  :render
  (let ((content (plist-get props :content)))
    (vui-text (vui-component 'benedict-vui-text-block--propertize content))))

(defun benedict-vui-text-block (&rest props)
  "Create a text block component node from PROPS."
  (apply #'vui-component 'benedict-vui-text-block props))

(provide 'benedict-vui-text-block)
;;; benedict-vui-text-block.el ends here
