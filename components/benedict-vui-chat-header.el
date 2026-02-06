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

(vui-defcomponent benedict-vui-chat-header (provider model status title on-provider-click)
  :render
  (vui-hstack
    :spacing 1
    (vui-component 'benedict-vui-provider-badge
      :provider provider
      :model model
      :on-click on-provider-click)
    (when status
      (vui-text "·"
        :face 'benedict-chat-header-separator))
    (when status
      (vui-component 'benedict-vui-badge
        :status status
        :theme 'benedict-chat-header-time))
    (when (and title (or provider model))
      (vui-text "·"
        :face 'benedict-chat-header-separator))
    (when title
      (vui-text title
        :face 'benedict-chat-header))))

(provide 'benedict-vui-chat-header)
;;; benedict-vui-chat-header.el ends here
