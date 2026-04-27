;;; benedict-vui-turn-list.el --- Vui turn list component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a list of explicit benedict-turn records.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict-turn)
(require 'benedict-vui-turn)

(defun benedict-vui-turn-list--scroll-deps (turns active-turn)
  "Return scroll effect dependency list from TURNS and ACTIVE-TURN."
  (list (length turns)
        (and active-turn (benedict-turn-updated-at active-turn))))

(defun benedict-vui-turn-list--scroll-to-bottom ()
  "Scroll the current buffer to the bottom when possible."
  (cond
   ((fboundp 'vui-scroll-to-bottom) (vui-scroll-to-bottom))
   ((fboundp 'vui-scroll-to-end) (vui-scroll-to-end))
   (t (when-let ((window (get-buffer-window (current-buffer) t)))
        (with-selected-window window
          (goto-char (point-max)))))))

(defun benedict-vui-turn-list--render-turn (turn session collapsed-blocks on-toggle-block)
  "Return a Vui node for TURN and SESSION.
COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK are forwarded to the turn component."
  (vui-component 'benedict-vui-turn
   :turn turn
   :session session
   :collapsed-blocks collapsed-blocks
   :on-toggle-block on-toggle-block))

(vui-defcomponent benedict-vui-turn-list (session turns active-turn collapsed-blocks on-toggle-block)
  :render
  (let ((all-turns (append turns (when active-turn (list active-turn)))))
     (vui-use-effect ((benedict-vui-turn-list--scroll-deps turns active-turn))
       (benedict-vui-turn-list--scroll-to-bottom)
       nil)
     (vui-list all-turns
               (lambda (turn &optional _index)
                 (benedict-vui-turn-list--render-turn
                  turn session collapsed-blocks on-toggle-block))
               (lambda (turn &optional index)
                 (or (and turn (benedict-turn-id turn))
                     (format "turn-%s" index))))))

(defalias 'benedict-vui-turn-list--render
  (lambda (props)
    (let* ((turns (plist-get props :turns))
           (session (plist-get props :session))
           (active-turn (plist-get props :active-turn))
           (collapsed-blocks (plist-get props :collapsed-blocks))
           (on-toggle-block (plist-get props :on-toggle-block))
           (all-turns (append turns (when active-turn (list active-turn)))))
       (vui-use-effect ((benedict-vui-turn-list--scroll-deps turns active-turn))
         (benedict-vui-turn-list--scroll-to-bottom)
         nil)
       (vui-list all-turns
                 (lambda (turn &optional _index)
                   (benedict-vui-turn-list--render-turn
                    turn session collapsed-blocks on-toggle-block))
                 (lambda (turn &optional index)
                   (or (and turn (benedict-turn-id turn))
                       (format "turn-%s" index)))))))

(provide 'benedict-vui-turn-list)
;;; benedict-vui-turn-list.el ends here
