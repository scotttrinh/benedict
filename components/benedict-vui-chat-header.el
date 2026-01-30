;;; benedict-vui-chat-header.el --- Vui chat header component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders the header bar with provider badge, status indicator, and session title.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict)
(require 'benedict-vui-provider-badge)
(require 'benedict-vui-badge)

(vui-defcomponent benedict-vui-chat-header (props)
  :render
  (let* ((provider (plist-get props :provider))
         (model (plist-get props :model))
         (status (plist-get props :status))
         (title (plist-get props :title))
         (on-provider-click (plist-get props :on-provider-click)))
    (vui-hstack
      :spacing 1
      (benedict-vui-provider-badge
        :provider provider
        :model model
        :on-click on-provider-click)
      (when status
        (vui-text "·"
          :face 'benedict-chat-header-separator))
      (when status
        (benedict-vui-badge
          :status status
          :theme 'benedict-chat-header-time))
      (when (and title (or provider model))
        (vui-text "·"
          :face 'benedict-chat-header-separator))
      (when title
        (vui-text title
          :face 'benedict-chat-header)))))

(provide 'benedict-vui-chat-header)
;;; benedict-vui-chat-header.el ends here
