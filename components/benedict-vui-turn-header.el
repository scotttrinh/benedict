;;; benedict-vui-turn-header.el --- Vui turn header component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders the turn header with role badge and timestamp.

;;; Code:

(require 'vui)
(require 'benedict-vui-badge)

(defconst benedict-vui-turn-header--timestamp-format "%H:%M:%S"
  "Format string for turn header timestamps.")

(defun benedict-vui-turn-header--normalize-role (role)
  "Normalize ROLE to a known symbol."
  (cond
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t 'assistant)))

(defun benedict-vui-turn-header--timestamp-string (timestamp)
  "Return a formatted timestamp string or nil for TIMESTAMP."
  (cond
   ((null timestamp) nil)
   ((stringp timestamp) timestamp)
   ((numberp timestamp)
    (format-time-string benedict-vui-turn-header--timestamp-format
                        (seconds-to-time timestamp)))
   ((consp timestamp)
    (format-time-string benedict-vui-turn-header--timestamp-format timestamp))
   (t (format "%s" timestamp))))

(defun benedict-vui-turn-header--timestamp-node (timestamp)
  "Return a timestamp node for TIMESTAMP or nil."
  (let ((text (benedict-vui-turn-header--timestamp-string timestamp)))
    (when text
      (vui-text (propertize text 'face 'benedict-chat-header-time)))))

(defun benedict-vui-turn-header--render (props)
  "Render the turn header for PROPS."
  (let* ((role (benedict-vui-turn-header--normalize-role (plist-get props :role)))
         (timestamp-node (benedict-vui-turn-header--timestamp-node
                          (plist-get props :timestamp)))
         (children (list (benedict-vui-badge :status role))))
    (when timestamp-node
      (setq children (append children (list timestamp-node))))
    (apply #'vui-hstack children)))

(vui-defcomponent benedict-vui-turn-header (props)
  :render
  (benedict-vui-turn-header--render props))

(provide 'benedict-vui-turn-header)
;;; benedict-vui-turn-header.el ends here
