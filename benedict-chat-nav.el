;;; benedict-chat-nav.el --- Navigation commands for Benedict chat -*- lexical-binding: t; -*-

;;; Commentary:
;; Navigation helpers for chat buffers rendered with vui.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict-session)

;; Declare functions and variables from benedict-chat.el
(defvar benedict-chat--session)
(declare-function benedict-chat--ensure-chat-buffer "benedict-chat")
(declare-function benedict-chat--vui-call "benedict-chat")

(defvar-local benedict-chat-nav--last-index nil
  "Most recently navigated message index for chat navigation.")

(defun benedict-chat-nav--normalize-role (role)
  "Normalize ROLE into a symbol."
  (cond
   ((keywordp role) (intern (substring (symbol-name role) 1)))
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t nil)))

(defun benedict-chat-nav--messages ()
  "Return session messages in chronological order."
  (when benedict-chat--session
    (benedict-session-messages-chronological benedict-chat--session)))

(defun benedict-chat-nav--message-text (message)
  "Return display text for MESSAGE when available."
  (or (plist-get message :display-content)
      (plist-get message :content)
      (plist-get message :text)))

(defun benedict-chat-nav--assistant-message-p (message)
  "Return non-nil when MESSAGE represents an assistant response."
  (eq (benedict-chat-nav--normalize-role (plist-get message :role)) 'assistant))

(defun benedict-chat-nav--assistant-with-tools-p (message)
  "Return non-nil when MESSAGE is an assistant message with tool call data."
  (and (benedict-chat-nav--assistant-message-p message)
       (plist-get message :tool-calls)))

(defun benedict-chat-nav--tool-message-p (message)
  "Return non-nil when MESSAGE represents a tool result."
  (eq (benedict-chat-nav--normalize-role (plist-get message :role)) 'tool))

(defun benedict-chat-nav--tool-failure-message-p (message)
  "Return non-nil when MESSAGE represents a failed tool result."
  (and (benedict-chat-nav--tool-message-p message)
       (let ((status (plist-get (plist-get message :metadata) :status)))
         (memq status '(failure error)))))

(defun benedict-chat-nav--error-message-p (message)
  "Return non-nil when MESSAGE captures an error state."
  (let ((metadata (plist-get message :metadata)))
    (or (plist-get metadata :error)
        (eq (plist-get metadata :status) 'failure)
        (eq (plist-get metadata :status) 'error))))

(defun benedict-chat-nav--message-index (message messages)
  "Return MESSAGE index within MESSAGES, or nil."
  (when (and message messages)
    (cl-position message messages :test #'eq)))

(defun benedict-chat-nav--message-key (message messages)
  "Return a navigation key for MESSAGE within MESSAGES.

Prefer stable IDs when available; fall back to MESSAGE index."
  (or (plist-get message :id)
      (plist-get message :message-id)
      (plist-get message :turn-id)
      (plist-get message :uuid)
      (benedict-chat-nav--message-index message messages)))

(defun benedict-chat-nav--goto-message-by-property (message-key direction)
  "Move point to MESSAGE-KEY using text properties in DIRECTION.

Return non-nil on success."
  (when (and message-key
             (fboundp 'text-property-search-forward)
             (fboundp 'text-property-search-backward))
    (let ((match (if (eq direction 'backward)
                     (text-property-search-backward 'benedict-message-key message-key t)
                   (text-property-search-forward 'benedict-message-key message-key t))))
      (when match
        (goto-char (if (fboundp 'prop-match-beginning)
                       (prop-match-beginning match)
                     (car match)))
        t))))

(defun benedict-chat-nav--seek-message (predicate direction)
  "Return next message matching PREDICATE in DIRECTION.
DIRECTION is either 'forward or 'backward."
  (let* ((messages (benedict-chat-nav--messages))
         (count (length messages))
         (current (if (and (numberp benedict-chat-nav--last-index)
                           (< benedict-chat-nav--last-index count))
                      benedict-chat-nav--last-index
                    (if (eq direction 'forward) -1 count)))
         (indices (if (eq direction 'forward)
                      (number-sequence (1+ current) (1- count))
                    (number-sequence (1- current) 0 -1))))
    (when messages
      (cl-loop for idx in indices
               for candidate = (nth idx messages)
               when (and candidate (funcall predicate candidate))
               return (list candidate idx)))))

(defun benedict-chat-nav--goto-message (message &optional direction)
  "Move point to MESSAGE content when possible.
DIRECTION controls search direction when locating text."
  (let* ((messages (benedict-chat-nav--messages))
          (content (benedict-chat-nav--message-text message))
          (message-key (benedict-chat-nav--message-key message messages))
          (search-backward (eq direction 'backward))
          (start (if search-backward (point-max) (point-min))))
    (goto-char start)
    (unless (benedict-chat-nav--goto-message-by-property message-key direction)
      (if (and (stringp content) (not (string-empty-p content)))
          (if (if search-backward
                  (search-backward content nil t)
                (search-forward content nil t))
              (goto-char (match-beginning 0))
            (goto-char (if search-backward (point-min) (point-max))))
        (goto-char (if search-backward (point-min) (point-max)))))
    (setq benedict-chat-nav--last-index
          (benedict-chat-nav--message-index message messages))
    message))

(defun benedict-chat-nav--navigate (predicate direction label)
  "Move to message matching PREDICATE in DIRECTION or echo LABEL when missing."
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((result (benedict-chat-nav--seek-message predicate direction)))
          (benedict-chat-nav--goto-message (car result) direction)
        (message "Benedict: no %s %s" label (if (eq direction 'forward) "ahead" "behind"))
        nil))))

(defun benedict-chat-nav--last-assistant-item ()
  "Return the most recent assistant message, or nil."
  (when-let ((messages (benedict-chat-nav--messages)))
    (cl-find-if #'benedict-chat-nav--assistant-message-p (reverse messages))))

(defun benedict-chat-nav--find-last-assistant (&optional include-errors)
  "Return the most recent assistant message from session.
When INCLUDE-ERRORS is nil, skip entries flagged with :error metadata."
  (when-let ((messages (benedict-chat-nav--messages)))
    (cl-find-if
     (lambda (message)
       (and (benedict-chat-nav--assistant-message-p message)
            (or include-errors
                (not (plist-get (plist-get message :metadata) :error)))))
     (reverse messages))))

(defun benedict-chat-nav--item-at-point ()
  "Return the last navigated message, or nil."
  (let ((messages (benedict-chat-nav--messages)))
    (when (and messages (numberp benedict-chat-nav--last-index))
      (nth benedict-chat-nav--last-index messages))))

(defun benedict-chat-nav-jump-to-latest ()
  "Jump to the newest chat item in the buffer."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if (fboundp 'vui-scroll-to-bottom)
          (vui-scroll-to-bottom)
        (goto-char (point-max)))
      (message "Benedict: at latest message"))))

(defun benedict-chat-nav-jump-to-last-assistant ()
  "Jump to the most recent assistant message in the chat buffer."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((message (benedict-chat-nav--last-assistant-item)))
          (benedict-chat-nav--goto-message message 'backward)
        (message "Benedict: no assistant messages yet")
        nil))))

(defun benedict-chat-nav-jump-to-last-assistant-with-tools ()
  "Jump to the most recent assistant message that has tool call data."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((message (cl-find-if
                         #'benedict-chat-nav--assistant-with-tools-p
                         (reverse (benedict-chat-nav--messages)))))
          (benedict-chat-nav--goto-message message 'backward)
        (message "Benedict: no assistant messages with tools yet")
        nil))))

(defun benedict-chat-nav-next-tool ()
  "Move point to the next tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-message-p 'forward "tool blocks"))

(defun benedict-chat-nav-previous-tool ()
  "Move point to the previous tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-message-p 'backward "tool blocks"))

(defun benedict-chat-nav-next-tool-failure ()
  "Move point to the next failed tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-failure-message-p 'forward "failed tool blocks"))

(defun benedict-chat-nav-previous-tool-failure ()
  "Move point to the previous failed tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-failure-message-p 'backward "failed tool blocks"))

(defun benedict-chat-nav-next-error ()
  "Move point to the next error block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--error-message-p 'forward "errors"))

(defun benedict-chat-nav-previous-error ()
  "Move point to the previous error block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--error-message-p 'backward "errors"))

(defun benedict-chat-nav-next-thinking ()
  "Move point to the next thinking block."
  (interactive)
  (benedict-chat-nav--navigate
   (lambda (message) (plist-get message :thinking))
   'forward "thinking blocks"))

(defun benedict-chat-nav-previous-thinking ()
  "Move point to the previous thinking block."
  (interactive)
  (benedict-chat-nav--navigate
   (lambda (message) (plist-get message :thinking))
   'backward "thinking blocks"))

(defun benedict-chat-nav-toggle-thinking ()
  "Toggle thinking block visibility.
For the vui.el UI this toggles the block at point when possible."
  (interactive)
  (let ((kind (get-text-property (point) 'benedict-region-kind))
        (block-id (get-text-property (point) 'benedict-block-id)))
    (if (and (eq kind 'thinking) block-id)
        (progn
          (benedict-chat--vui-call :toggle-block block-id)
          (message "Benedict: toggled thinking"))
      (message "Benedict: no thinking block at point"))))

(defun benedict-chat-nav-retry-last ()
  "Retry the last assistant response by re-sending the prior user message."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (let ((messages (benedict-chat-nav--messages))
            (last-user nil))
        (dolist (msg (reverse messages))
          (when (and (eq (benedict-chat-nav--normalize-role (plist-get msg :role)) 'user)
                     (not last-user))
            (setq last-user msg)))
        (if last-user
            (benedict-chat--send-text (benedict-chat-nav--message-text last-user) chat)
          (message "Benedict: no user messages to retry"))))))

(defun benedict-chat-nav-copy-last-response ()
  "Copy the last assistant response to the kill ring."
  (interactive)
  (if-let ((message (benedict-chat-nav--last-assistant-item)))
      (let ((content (or (benedict-chat-nav--message-text message) "")))
        (kill-new content)
        (message "Benedict: copied last response"))
    (message "Benedict: no assistant messages to copy")))

(provide 'benedict-chat-nav)
;;; benedict-chat-nav.el ends here
