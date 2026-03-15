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

(vui-defcomponent benedict-vui-conversation-view (conversation streaming collapsed-blocks on-toggle-block)
  "Main conversation area containing TurnList and StreamingIndicator."
  :render
  (vui-vstack
   (vui-component 'benedict-vui-turn-list
    :conversation conversation
    :streaming streaming
    :collapsed-blocks collapsed-blocks
    :on-toggle-block on-toggle-block)
   (vui-component 'benedict-vui-streaming-indicator
    :visible (benedict-vui-conversation-view--streaming-active-p streaming))))

(provide 'benedict-vui-conversation-view)
;;; benedict-vui-conversation-view.el ends here
