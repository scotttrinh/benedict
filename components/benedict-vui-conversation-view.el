;;; benedict-vui-conversation-view.el --- Vui conversation view component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Main conversation area containing TurnList and StreamingIndicator.

;;; Code:

(require 'vui)
(require 'benedict-turn)
(require 'benedict-vui-turn-list)
(require 'benedict-vui-streaming-indicator)

(defun benedict-vui-conversation-view--streaming-active-p (active-turn)
  "Return non-nil if ACTIVE-TURN indicates active streaming."
  (and active-turn
       (not (memq (benedict-turn-state active-turn) '(idle error turn-complete cancelled)))))

(vui-defcomponent benedict-vui-conversation-view (session turns active-turn collapsed-blocks on-toggle-block)
  "Main conversation area containing TurnList and StreamingIndicator."
  :render
  (vui-vstack
   (vui-component 'benedict-vui-turn-list
    :session session
    :turns turns
    :active-turn active-turn
    :collapsed-blocks collapsed-blocks
    :on-toggle-block on-toggle-block)
   (vui-component 'benedict-vui-streaming-indicator
    :visible (benedict-vui-conversation-view--streaming-active-p active-turn))))

(provide 'benedict-vui-conversation-view)
;;; benedict-vui-conversation-view.el ends here
