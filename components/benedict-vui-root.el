;;; benedict-vui-root.el --- Vui root component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Root component owning all shared application state.

;;; Code:

(require 'vui)
(require 'benedict-vui-chat-header)
(require 'benedict-vui-conversation-view)
(require 'benedict-vui-input-area)
(require 'benedict-vui-status-bar)

(vui-defcomponent benedict-vui-root (props state)
  "Root component owning all shared application state."
  :state ((conversation nil)
          (streaming nil)
          (provider 'openrouter)
          (model "claude-3-5-sonnet-20241022")
          (collapsed-blocks nil)
          (error nil))
  :render
  (let* ((current-conversation (plist-get state :conversation))
         (current-streaming (plist-get state :streaming))
         (current-provider (plist-get state :provider))
         (current-model (plist-get state :model))
         (current-collapsed-blocks (plist-get state :collapsed-blocks))
         (current-error (plist-get state :error))
         (slices (plist-get props :slices))
         (input-text (plist-get props :input-text))
         (on-input-change (plist-get props :on-input-change))
         (on-submit (plist-get props :on-submit))
         (on-slice-remove (plist-get props :on-slice-remove))
         (on-provider-click (plist-get props :on-provider-click))
         (usage (plist-get props :usage))
         (on-toggle-block (plist-get props :on-toggle-block)))
    (vui-vstack
      (benedict-vui-chat-header
        :provider current-provider
        :model current-model
        :status (when (plist-get current-streaming :status)
                  (plist-get current-streaming :status))
        :title "Chat"
        :on-click on-provider-click)
      (benedict-vui-conversation-view
        :conversation current-conversation
        :streaming current-streaming
        :collapsed-blocks current-collapsed-blocks)
      (benedict-vui-input-area
        :slices slices
        :input-text input-text
        :on-input-change on-input-change
        :on-submit on-submit
        :on-slice-remove on-slice-remove
        :placeholder "Ask Benedict..."
        :size 5
        :field-key 'root-input)
      (benedict-vui-status-bar
        :usage usage
        :error current-error))))

(provide 'benedict-vui-root)
;;; benedict-vui-root.el ends here
