;;; benedict-vui-context-indicator.el --- Vui context slice indicator -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Displays attached context slices in the compose area.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict)
(require 'benedict-context)

(defun benedict-vui-context-indicator--summary (slices)
  "Return a summary string for SLICES."
  (if (null slices)
      "No context"
    (benedict-context-summary slices)))

(defun benedict-vui-context-indicator--slice-label (slice)
  "Return a label for SLICE."
  (let ((handle (plist-get slice :handle))
        (label (or (plist-get slice :label) "Context"))
        (kind (upcase (format "%s" (plist-get slice :kind))))
        (truncated (plist-get slice :truncated-p)))
    (format "%s%s [%s]%s"
            (if handle (format "<<%s>> " handle) "")
            label
            kind
            (if truncated " (truncated)" ""))))

(vui-defcomponent benedict-vui-context-indicator (slices on-remove)
  :state ((expanded nil))
  :render
  (let* ((toggle-handler (lambda (&rest _)
                           (vui-set-state :expanded (not expanded)))))
    (vui-component 'benedict-vui-collapsible
      :header (lambda ()
                (vui-hstack
                 (vui-component 'benedict-vui-badge :status 'context :theme 'benedict-chat-header-time)
                 (vui-text (benedict-vui-context-indicator--summary slices))))
      :content (lambda ()
                 (vui-vstack
                  (vui-list slices
                            (lambda (slice)
                              (let ((id (plist-get slice :id)))
                                (vui-hstack
                                 (vui-text (benedict-vui-context-indicator--slice-label slice))
                                 (vui-text " ")
                                 (when (functionp on-remove)
                                   (vui-button "×"
                                               :on-click (lambda (&rest _)
                                                           (funcall on-remove id)))))))
                            (lambda (slice) (plist-get slice :id)))))
      :on-toggle toggle-handler
      :collapsed (not expanded))))

(provide 'benedict-vui-context-indicator)
;;; benedict-vui-context-indicator.el ends here
