;;; benedict-vui-approval-block.el --- Vui approval block -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders persistent in-chat approval controls for pending tool calls.

;;; Code:

(require 'pp)
(require 'subr-x)
(require 'vui)
(require 'benedict-vui-badge)

(defun benedict-vui-approval-block--tool-name (approval)
  "Return a display name for APPROVAL."
  (let ((tool-id (plist-get approval :tool-id)))
    (cond
     ((symbolp tool-id) (symbol-name tool-id))
     ((stringp tool-id) tool-id)
     (t "tool"))))

(defun benedict-vui-approval-block--reason (approval)
  "Return human-readable approval reason text for APPROVAL."
  (pcase (plist-get approval :approval)
    ('always "High-risk tool requires approval")
    (_ "Tool requires approval")))

(defun benedict-vui-approval-block--args (approval)
  "Return pretty-printed args for APPROVAL."
  (string-trim-right
   (pp-to-string (plist-get approval :args))))

(vui-defcomponent benedict-vui-approval-block (approval on-approve on-deny)
  "Render a persistent approval block for APPROVAL."
  :render
  (when approval
    (vui-vstack
     (vui-hstack
      :spacing 1
      (vui-component 'benedict-vui-badge :status 'awaiting-approval)
      (vui-text (format "Approval request: %s" (benedict-vui-approval-block--tool-name approval))
                :face 'benedict-chat-tool-label))
     (vui-text (benedict-vui-approval-block--reason approval)
               :face 'benedict-chat-system)
     (vui-text (format "Arguments:\n%s"
                       (benedict-vui-approval-block--args approval))
               :face 'benedict-chat-system)
     (vui-hstack
      :spacing 1
      (vui-button "Approve" :on-click on-approve)
      (vui-button "Deny" :on-click on-deny)))))

(provide 'benedict-vui-approval-block)
;;; benedict-vui-approval-block.el ends here
