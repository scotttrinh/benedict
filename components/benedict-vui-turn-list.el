;;; benedict-vui-turn-list.el --- Vui turn list component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a conversation as a list of turns with stable keys.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict-message)
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
  "Return MESSAGE normalized to a canonical entry or nil."
  (cond
   ((null message) nil)
   ((stringp message) (benedict-message-assistant-text message))
   ((vectorp message)
    (benedict-vui-turn-list--normalize-message (append message nil)))
   ((benedict-message-p message) message)
   ((listp message)
    (let* ((plist (if (and (consp (car message))
                           (not (keywordp (caar message))))
                      (benedict-vui-turn-list--alist-to-plist message)
                    (copy-sequence message)))
           (display-content (plist-get plist :display-content)))
      (when display-content
        (setq plist (plist-put plist :content display-content)))
      (benedict-message-from-data plist)))
   (t (benedict-message-assistant-text (format "%s" message)))))

(defun benedict-vui-turn-list--normalize-messages (messages)
  "Return MESSAGES normalized to a list of message plists.

Each normalized message is a canonical entry."
  (cond
   ((null messages) nil)
   ((vectorp messages)
    (benedict-vui-turn-list--normalize-messages (append messages nil)))
   ((listp messages)
    (delq nil
          (cl-loop for message in messages
                   for index from 0
                   for normalized = (benedict-vui-turn-list--normalize-message message)
                   when normalized
                   collect (if (benedict-message-id normalized)
                               normalized
                             (progn
                               (setf (benedict-message-id normalized) index)
                               normalized)))))
   (t (list (benedict-vui-turn-list--normalize-message messages)))))

(defun benedict-vui-turn-list--normalize-role (role)
  "Normalize ROLE into a symbol."
  (cond
   ((keywordp role) (intern (substring (symbol-name role) 1)))
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t nil)))

(defun benedict-vui-turn-list--group-turns (messages)
  "Turn MESSAGES into grouped entries starting at each user message."
  (let (turns current)
    (dolist (message messages)
      (let ((role (benedict-vui-turn-list--normalize-role
                    (benedict-message-role message))))
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

(defun benedict-vui-turn-list--streaming-message (streaming)
  "Return a synthetic assistant message for STREAMING, or nil."
  (when (and (listp streaming)
             (eq (plist-get streaming :status) 'active))
    (benedict-message-from-data
     (list :role 'assistant
           :content (plist-get streaming :content)
           :thinking (plist-get streaming :thinking)
           :tool-calls (plist-get streaming :tool-calls)
           :metadata '(:streaming t)))))

(defun benedict-vui-turn-list--message-text (message)
  "Return the primary text content for MESSAGE, or nil."
  (when (benedict-message-p message)
    (benedict-message-text message)))

(defun benedict-vui-turn-list--message-has-execution-blocks-p (message)
  "Return non-nil when MESSAGE has non-text display blocks."
  (and (benedict-message-p message)
       (cl-some (lambda (block)
                  (not (eq (plist-get block :type) 'text)))
                (benedict-message-blocks-for-display message))))

(defun benedict-vui-turn-list--assistant-message-p (message)
  "Return non-nil when MESSAGE is an assistant entry."
  (eq (benedict-vui-turn-list--normalize-role
       (and (benedict-message-p message)
            (benedict-message-role message)))
      'assistant))

(defun benedict-vui-turn-list--user-message-p (message)
  "Return non-nil when MESSAGE is a user entry."
  (eq (benedict-vui-turn-list--normalize-role
       (and (benedict-message-p message)
            (benedict-message-role message)))
      'user))

(defun benedict-vui-turn-list--turn-prompt-message (messages)
  "Return the prompt message for turn MESSAGES."
  (or (cl-find-if #'benedict-vui-turn-list--user-message-p messages)
      (car messages)))

(defun benedict-vui-turn-list--turn-prompt-text (messages)
  "Return prompt text for turn MESSAGES."
  (when-let ((prompt-message (benedict-vui-turn-list--turn-prompt-message messages)))
    (benedict-vui-turn-list--message-text prompt-message)))

(defun benedict-vui-turn-list--turn-outcome-message (messages)
  "Return the final assistant outcome message for turn MESSAGES."
  (car (last (cl-remove-if-not #'benedict-vui-turn-list--assistant-message-p messages))))

(defun benedict-vui-turn-list--turn-tool-names (messages)
  "Return tool names observed across turn MESSAGES."
  (let (names)
    (dolist (message messages)
      (dolist (block (and (benedict-message-p message)
                          (benedict-message-blocks-for-display message)))
        (pcase (plist-get block :type)
          ('tool-use
           (push (plist-get (plist-get block :tool-call) :name) names))
          ('tool-result
           (push (plist-get (plist-get block :result) :name) names)))))
    (delete-dups (delq nil (nreverse names)))))

(defun benedict-vui-turn-list--turn-error-count (messages)
  "Return the number of error-marked messages in MESSAGES."
  (cl-count-if (lambda (message)
                 (plist-get (benedict-message-metadata message) :error))
               messages))

(defun benedict-vui-turn-list--execution-summary (messages)
  "Return summarized execution metadata for turn MESSAGES."
  (let* ((tool-names (benedict-vui-turn-list--turn-tool-names messages))
         (tool-count (length tool-names))
         (error-count (benedict-vui-turn-list--turn-error-count messages))
         (has-thinking (cl-some (lambda (message)
                                  (benedict-message-thinking message))
                                messages)))
    (list :tool-count tool-count
          :tool-names tool-names
          :error-count error-count
          :has-thinking has-thinking
          :has-errors (> error-count 0)
          :has-approvals nil)))

(defun benedict-vui-turn-list--turn-has-execution-blocks-p (messages)
  "Return non-nil when MESSAGES contain execution detail."
  (cl-some #'benedict-vui-turn-list--message-has-execution-blocks-p messages))

(defun benedict-vui-turn-list--make-turn (messages index &optional streaming)
  "Return explicit turn data for MESSAGES at INDEX.

When STREAMING is non-nil, the turn is treated as the active streaming turn."
  (let* ((actual-messages (copy-sequence messages))
         (streaming-message (and streaming
                                 (benedict-vui-turn-list--streaming-message streaming)))
         (messages-with-streaming (if streaming-message
                                      (append actual-messages (list streaming-message))
                                    actual-messages))
         (prompt-message (benedict-vui-turn-list--turn-prompt-message messages-with-streaming))
         (outcome-message (benedict-vui-turn-list--turn-outcome-message messages-with-streaming))
         (turn-id (or (and prompt-message
                           (benedict-vui-turn-list--message-id prompt-message))
                      (and outcome-message
                           (benedict-vui-turn-list--message-id outcome-message))
                      (format "turn-%s" index))))
    (list :id turn-id
          :messages messages-with-streaming
          :prompt-message prompt-message
          :prompt-text (benedict-vui-turn-list--turn-prompt-text messages-with-streaming)
          :outcome-message outcome-message
          :execution-summary (benedict-vui-turn-list--execution-summary messages-with-streaming)
          :active (not (null streaming-message))
          :historical (null streaming-message)
          :streaming (not (null streaming-message))
          :completed (null streaming-message)
          :has-execution-blocks
          (benedict-vui-turn-list--turn-has-execution-blocks-p messages-with-streaming)
          :execution-expanded nil)))

(defun benedict-vui-turn-list--derive-turns (messages streaming)
  "Return explicit turn records for canonical MESSAGES and STREAMING."
  (let* ((grouped-turns (benedict-vui-turn-list--group-turns messages))
         (turn-count (length grouped-turns))
         (active-streaming-p (not (null (benedict-vui-turn-list--streaming-message streaming))))
         (turns nil))
    (cl-loop for grouped in grouped-turns
             for index from 0
             do (push (benedict-vui-turn-list--make-turn
                       grouped
                       index
                       (and active-streaming-p
                            (= index (1- turn-count))
                            streaming))
                      turns))
    (when (and active-streaming-p (null grouped-turns))
      (push (benedict-vui-turn-list--make-turn nil 0 streaming) turns))
    (nreverse turns)))

(defun benedict-vui-turn-list--message-id (message)
  "Return a stable identifier for MESSAGE when present."
  (and (benedict-message-p message)
       (benedict-message-id message)))

(defun benedict-vui-turn-list--turn-id (turn index)
  "Return a stable identifier for TURN at INDEX."
  (let ((id (plist-get turn :id)))
    (or id
        (format "turn-%s"
                (if (numberp index)
                    index
                  (sxhash turn))))))

(defun benedict-vui-turn-list--scroll-deps (messages streaming)
  "Return dependency list for scroll-to-bottom effects on MESSAGES and STREAMING."
  (let* ((count (length messages))
         (last-message (car (last messages)))
         (id (and last-message (benedict-vui-turn-list--message-id last-message)))
         (content (and last-message
                       (and (benedict-message-p last-message)
                            (benedict-message-text last-message))))
         (content-length (and (stringp content) (length content)))
         (streaming-content (plist-get streaming :content))
         (streaming-tool-count (length (plist-get streaming :tool-calls))))
    (list count id content-length streaming-content streaming-tool-count)))

(defun benedict-vui-turn-list--scroll-to-bottom ()
  "Scroll the current buffer to the bottom when possible."
  (cond
   ((fboundp 'vui-scroll-to-bottom) (vui-scroll-to-bottom))
   ((fboundp 'vui-scroll-to-end) (vui-scroll-to-end))
   (t (when-let ((window (get-buffer-window (current-buffer) t)))
        (with-selected-window window
          (goto-char (point-max)))))))

(defun benedict-vui-turn-list--render-turn (turn collapsed-blocks on-toggle-block)
  "Return a Vui node for TURN using COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK."
  (vui-component 'benedict-vui-turn
   :turn turn
   :collapsed-blocks collapsed-blocks
   :on-toggle-block on-toggle-block))

(vui-defcomponent benedict-vui-turn-list (conversation streaming collapsed-blocks on-toggle-block)
  :render
  (let* ((normalized-messages (benedict-vui-turn-list--normalize-messages
                               conversation))
         (turns (benedict-vui-turn-list--derive-turns normalized-messages streaming)))
     (vui-use-effect ((benedict-vui-turn-list--scroll-deps normalized-messages streaming))
       (benedict-vui-turn-list--scroll-to-bottom)
       nil)
     (vui-list turns
               (lambda (turn &optional index)
                 (benedict-vui-turn-list--render-turn
                  turn collapsed-blocks on-toggle-block))
               (lambda (turn &optional index)
                 (benedict-vui-turn-list--turn-id turn index)))))

(defalias 'benedict-vui-turn-list--render
  (lambda (props)
    (let* ((messages (benedict-vui-turn-list--normalize-messages
                      (plist-get props :conversation)))
            (streaming (plist-get props :streaming))
            (turns (benedict-vui-turn-list--derive-turns messages streaming))
            (collapsed-blocks (plist-get props :collapsed-blocks))
            (on-toggle-block (plist-get props :on-toggle-block)))
       (vui-use-effect ((benedict-vui-turn-list--scroll-deps messages streaming))
         (benedict-vui-turn-list--scroll-to-bottom)
         nil)
       (vui-list turns
                 (lambda (turn &optional index)
                   (benedict-vui-turn-list--render-turn
                    turn collapsed-blocks on-toggle-block))
                 (lambda (turn &optional index)
                   (benedict-vui-turn-list--turn-id turn index))))))

(provide 'benedict-vui-turn-list)
;;; benedict-vui-turn-list.el ends here
