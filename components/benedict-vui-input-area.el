;;; benedict-vui-input-area.el --- Vui input area component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Compose area with context indicators and input field.

;;; Code:

(require 'vui)
(require 'benedict-vui-context-indicator)
(require 'benedict-vui-compose-field)

(vui-defcomponent benedict-vui-input-area (props)
  "Compose area with context indicators and input field."
  :render
  (let ((slices (plist-get props :slices))
        (input-text (plist-get props :input-text))
        (on-input-change (plist-get props :on-input-change))
        (on-submit (plist-get props :on-submit))
        (on-slice-remove (plist-get props :on-slice-remove))
        (placeholder (plist-get props :placeholder))
        (size (plist-get props :size))
        (field-key (plist-get props :field-key)))
    (vui-vstack
     (benedict-vui-context-indicator
      :slices slices
      :on-remove on-slice-remove)
     (benedict-vui-compose-field
      :value input-text
      :on-change on-input-change
      :on-submit on-submit
      :placeholder placeholder
      :size size
      :key field-key))))

(provide 'benedict-vui-input-area)
;;; benedict-vui-input-area.el ends here
