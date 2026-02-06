;;; benedict-vui-input-area.el --- Vui input area component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Compose area with context indicators and input field.

;;; Code:

(require 'vui)
(require 'benedict-vui-context-indicator)
(require 'benedict-vui-compose-field)

(vui-defcomponent benedict-vui-input-area (slices input-text on-input-change on-submit on-slice-remove history placeholder size field-key)
  "Compose area with context indicators and input field."
  :render
  (vui-vstack
   (vui-component 'benedict-vui-context-indicator
    :slices slices
    :on-remove on-slice-remove)
   (vui-component 'benedict-vui-compose-field
    :value input-text
    :on-change on-input-change
    :on-submit on-submit
    :history history
    :placeholder placeholder
    :size size
    :key field-key)))

(provide 'benedict-vui-input-area)
;;; benedict-vui-input-area.el ends here
