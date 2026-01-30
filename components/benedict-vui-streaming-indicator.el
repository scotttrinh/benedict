;;; benedict-vui-streaming-indicator.el --- Vui streaming indicator component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders an animated spinner during active streaming.

;;; Code:

(require 'vui)

(defconst benedict-vui-streaming-indicator--frames
  '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Spinner animation frames.")

(defconst benedict-vui-streaming-indicator--interval 0.1
  "Seconds between animation frames.")

(defun benedict-vui-streaming-indicator--frame (index)
  "Return the frame at INDEX, wrapping around the frame list."
  (elt benedict-vui-streaming-indicator--frames
       (mod index (length benedict-vui-streaming-indicator--frames))))

(vui-defcomponent benedict-vui-streaming-indicator (props state)
  :state ((frame-index 0))
  :render
  (let ((visible (plist-get props :visible))
        (timer-ref (vui-use-ref nil)))
    (vui-use-effect (visible)
      (when visible
        (setcar timer-ref
                (run-with-timer benedict-vui-streaming-indicator--interval
                                 benedict-vui-streaming-indicator--interval
                                 (vui-async-callback ()
                                   (vui-set-state :frame-index
                                     (lambda (idx)
                                       (mod (1+ idx)
                                            (length benedict-vui-streaming-indicator--frames))))))))
      (lambda ()
        (when (car timer-ref)
          (cancel-timer (car timer-ref))
          (setcar timer-ref nil))))
    (when visible
      (let* ((current-frame (vui-component 'benedict-vui-streaming-indicator--frame
                             (plist-get state :frame-index)))
             (spinner-text (concat " " current-frame " ")))
        (vui-text (propertize spinner-text 'face 'benedict-chat-header-time))))))

(provide 'benedict-vui-streaming-indicator)
;;; benedict-vui-streaming-indicator.el ends here
