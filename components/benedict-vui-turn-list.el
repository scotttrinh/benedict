;;; benedict-vui-turn-list.el --- Vui turn list component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a conversation as a list of turns with stable keys.

;;; Code:

(require 'subr-x)
(require 'vui)
(require 'benedict-vui-turn)

(defun benedict-vui-turn-list--alist-to-plist (alist)
  "Convert ALIST into a plist with keyword keys."
  (let (plist)
    (dolist (pair alist plist)
      (let* ((key (car pair))
             (keyword (cond
                       ((keywordp key) key)
                       ((symbolp key) (intern (format ":%s" (symbol-name key))))
                       ((stringp key) (intern (concat ":" (downcase key))))
                       (t nil))))
        (when keyword
          (setq plist (plist-put plist keyword (cdr pair))))))))

(defun benedict-vui-turn-list--normalize-message (message)
  "Return MESSAGE normalized to a plist or nil."
  (cond
   ((null message) nil)
   ((stringp message) (list :role 'assistant :content message))
   ((vectorp message)
    (vui-component 'benedict-vui-turn-list--normalize-message (append message nil)))
   ((listp message)
    (let ((plist (if (and (consp (car message))
                          (not (keywordp (caar message))))
                     (vui-component 'benedict-vui-turn-list--alist-to-plist message)
                   message)))
      (copy-sequence plist)))
   (t (list :role 'assistant :content (format "%s" message)))))

(defun benedict-vui-turn-list--normalize-messages (messages)
  "Return MESSAGES normalized to a list of message plists."
  (cond
   ((null messages) nil)
   ((vectorp messages)
    (vui-component 'benedict-vui-turn-list--normalize-messages (append messages nil)))
   ((listp messages)
    (delq nil (mapcar #'benedict-vui-turn-list--normalize-message messages)))
   (t (list (vui-component 'benedict-vui-turn-list--normalize-message messages)))))

(defun benedict-vui-turn-list--normalize-role (role)
  "Normalize ROLE into a symbol."
  (cond
   ((keywordp role) (intern (substring (symbol-name role) 1)))
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t nil)))

(defun benedict-vui-turn-list--group-turns (messages)
  "Group MESSAGES into turns, starting a new turn at each user message."
  (let (turns current)
    (dolist (message messages)
      (let ((role (vui-component 'benedict-vui-turn-list--normalize-role (plist-get message :role))))
        (if (eq role 'user)
            (progn
              (when current
                (push (nreverse current) turns))
              (setq current (list message)))
          (if current
              (push message current)
            (setq current (list message))))))
    (when current
      (push (nreverse current) turns))
    (nreverse turns)))

(defun benedict-vui-turn-list--message-id (message)
  "Return a stable identifier for MESSAGE when present."
  (or (plist-get message :id)
      (plist-get message :message-id)
      (plist-get message :turn-id)
      (plist-get message :uuid)))

(defun benedict-vui-turn-list--turn-message (turn)
  "Return the first message plist for TURN."
  (if (and (listp turn) (keywordp (car turn)))
      turn
    (car turn)))

(defun benedict-vui-turn-list--turn-id (turn index)
  "Return a stable identifier for TURN at INDEX."
  (let* ((message (vui-component 'benedict-vui-turn-list--turn-message turn))
          (id (and (listp message) (vui-component 'benedict-vui-turn-list--message-id message))))
    (or id
        (format "turn-%s"
                (if (numberp index)
                    index
                  (sxhash turn))))))

(defun benedict-vui-turn-list--scroll-deps (messages)
  "Return dependency list for scroll-to-bottom effects on MESSAGES."
  (let* ((count (length messages))
         (last-message (car (last messages)))
         (id (and last-message (vui-component 'benedict-vui-turn-list--message-id last-message)))
         (content (and last-message
                       (or (plist-get last-message :display-content)
                           (plist-get last-message :content))))
         (content-length (and (stringp content) (length content))))
    (list count id content-length)))

(defun benedict-vui-turn-list--scroll-to-bottom ()
  "Scroll the current buffer to the bottom when possible."
  (cond
   ((fboundp 'vui-scroll-to-bottom) (vui-scroll-to-bottom))
   ((fboundp 'vui-scroll-to-end) (vui-scroll-to-end))
   (t (when-let ((window (get-buffer-window (current-buffer) t)))
        (with-selected-window window
          (goto-char (point-max)))))))

(defun benedict-vui-turn-list--render-turn (turn collapsed-blocks)
  "Return a Vui node for TURN using COLLAPSED-BLOCKS."
  (let* ((messages (if (and (listp turn) (keywordp (car turn)))
                       (list turn)
                     turn))
         (nodes (delq nil
                      (mapcar (lambda (message)
                                (vui-component 'benedict-vui-turn :message message
                                                   :collapsed-blocks collapsed-blocks))
                              messages))))
    (apply #'vui-vstack nodes)))

(defun benedict-vui-turn-list--render (props)
  "Render the turn list for PROPS."
  (let* ((messages (vui-component 'benedict-vui-turn-list--normalize-messages
                    (plist-get props :conversation)))
         (turns (vui-component 'benedict-vui-turn-list--group-turns messages))
         (collapsed-blocks (plist-get props :collapsed-blocks)))
     (vui-use-effect ((vui-component 'benedict-vui-turn-list--scroll-deps messages))
       (vui-component 'benedict-vui-turn-list--scroll-to-bottom)
       nil)
     (vui-list turns
               (lambda (turn &optional index)
                 (vui-component 'benedict-vui-turn-list--render-turn
                  turn collapsed-blocks))
               (lambda (turn &optional index)
                 (vui-component 'benedict-vui-turn-list--turn-id turn index)))))

(vui-defcomponent benedict-vui-turn-list (props)
  :render
  (vui-component 'benedict-vui-turn-list--render props))

(defun benedict-vui-turn-list (&rest props)
  "Create a turn list component node from PROPS."
  (apply #'vui-component 'benedict-vui-turn-list props))

(provide 'benedict-vui-turn-list)
;;; benedict-vui-turn-list.el ends here
