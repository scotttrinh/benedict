;;; benedict-vui-session-panel.el --- Vui session metadata panel -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders session metadata such as instructions and persistence path.

;;; Code:

(require 'subr-x)
(require 'vui)
(require 'benedict-vui-collapsible)

(defun benedict-vui-session-panel--time-label (value)
  "Return a readable timestamp string for VALUE."
  (when value
    (format-time-string "%Y-%m-%d %H:%M:%SZ" value t)))

(defun benedict-vui-session-panel--lines (session-info)
  "Return display lines for SESSION-INFO."
  (let ((session-id (plist-get session-info :session-id))
        (title (plist-get session-info :title))
        (state (plist-get session-info :state))
        (turn-state (plist-get session-info :turn-state))
        (yield-count (plist-get session-info :outstanding-yield-count))
        (root (plist-get session-info :root))
        (store-path (plist-get session-info :store-path))
        (saved-at (plist-get session-info :last-saved-at))
        (sources (plist-get session-info :instruction-sources))
        lines)
    (when session-id
      (push (format "Session: %s" session-id) lines))
    (when title
      (push (format "Title: %s" title) lines))
    (when state
      (push (format "Run state: %s" state) lines))
    (when turn-state
      (push (format "Turn state: %s" turn-state) lines))
    (when (and yield-count (> yield-count 0))
      (push (format "Outstanding yields: %s" yield-count) lines))
    (when root
      (push (format "Root: %s" root) lines))
    (when store-path
      (push (format "Saved to: %s" store-path) lines))
    (when saved-at
      (push (format "Last saved: %s"
                    (benedict-vui-session-panel--time-label saved-at))
            lines))
    (when sources
      (push (format "Instructions: %s" (string-join sources ", ")) lines))
    (nreverse lines)))

(vui-defcomponent benedict-vui-session-panel (session-info collapsed on-toggle)
  "Render SESSION-INFO in a collapsible panel."
  :render
  (when session-info
    (vui-component 'benedict-vui-collapsible
      :collapsed collapsed
      :on-toggle on-toggle
      :header (lambda ()
                (vui-text "Session Context" :face 'benedict-chat-header))
      :content (lambda ()
                 (apply #'vui-vstack
                        (mapcar (lambda (line)
                                  (vui-text line :face 'benedict-chat-system))
                                (benedict-vui-session-panel--lines session-info)))))))

(provide 'benedict-vui-session-panel)
;;; benedict-vui-session-panel.el ends here
