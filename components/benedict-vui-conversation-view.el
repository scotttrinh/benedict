;;; benedict-vui-conversation-view.el --- Vui conversation view component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Main conversation area containing TurnList and StreamingIndicator.

;;; Code:

(require 'vui)
(require 'benedict-vui-turn-list)
(require 'benedict-vui-streaming-indicator)

(defun benedict-vui-conversation-view--streaming-active-p (streaming)
  "Return non-nil if STREAMING indicates active streaming."
  (and (listp streaming)
       (eq (plist-get streaming :status) 'active)))

(defun benedict-vui-conversation-view--render (props)
  "Render the conversation view for PROPS."
  (let ((conversation (plist-get props :conversation))
        (streaming (plist-get props :streaming))
        (collapsed-blocks (plist-get props :collapsed-blocks)))
    (vui-vstack
     (vui-component 'benedict-vui-turn-list
      :conversation conversation
      :collapsed-blocks collapsed-blocks)
     (vui-component 'benedict-vui-streaming-indicator
      :visible (benedict-vui-conversation-view--streaming-active-p streaming)))))

(vui-defcomponent benedict-vui-conversation-view (props)
  "Main conversation area containing TurnList and StreamingIndicator."
  :render
  (benedict-vui-conversation-view--render props))

(defun benedict-vui-conversation-view (&rest props)
  "Create a conversation view component node from PROPS."
  (apply #'vui-component 'benedict-vui-conversation-view props))

(provide 'benedict-vui-conversation-view)
;;; benedict-vui-conversation-view.el ends here
