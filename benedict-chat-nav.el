;;; benedict-chat-nav.el --- Navigation commands for Benedict chat -*- lexical-binding: t; -*-

;;; Commentary:
;; Navigation helpers for chat buffers rendered with vui.el.

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'subr-x)
(require 'widget)
(require 'benedict-message)
(require 'benedict-session)

;; Declare functions and variables from benedict-chat.el
(defvar benedict-chat--session)
(declare-function benedict-chat--ensure-chat-buffer "benedict-chat")
(declare-function benedict-chat--vui-call "benedict-chat")

(defvar-local benedict-chat-nav--last-index nil
  "Most recently navigated message index for chat navigation.")

(defconst benedict-chat-nav--prompt-target 'prompt
  "Turn target used for prompt headers.")

(defconst benedict-chat-nav--outcome-target 'outcome
  "Turn target used for completed turn outcomes.")

(defconst benedict-chat-nav--execution-summary-target 'execution-summary
  "Turn target used for completed turn execution summaries.")

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
  (benedict-message-text message))

(defun benedict-chat-nav--assistant-message-p (message)
  "Return non-nil when MESSAGE represents an assistant response."
  (eq (benedict-chat-nav--normalize-role (benedict-message-role message)) 'assistant))

(defun benedict-chat-nav--assistant-with-tools-p (message)
  "Return non-nil when MESSAGE is an assistant message with tool call data."
  (and (benedict-chat-nav--assistant-message-p message)
       (benedict-message-tool-calls message)))

(defun benedict-chat-nav--tool-message-p (message)
  "Return non-nil when MESSAGE represents a tool result."
  (eq (benedict-chat-nav--normalize-role (benedict-message-role message)) 'tool))

(defun benedict-chat-nav--tool-failure-message-p (message)
  "Return non-nil when MESSAGE represents a failed tool result."
  (and (benedict-chat-nav--tool-message-p message)
       (let ((status (benedict-message-status message)))
         (memq status '(failure error)))))

(defun benedict-chat-nav--error-message-p (message)
  "Return non-nil when MESSAGE captures an error state."
  (or (benedict-message-metadata-value message :error)
      (eq (benedict-message-status message) 'failure)
      (eq (benedict-message-status message) 'error)))

(defun benedict-chat-nav--message-index (message messages)
  "Return MESSAGE index within MESSAGES, or nil."
  (when (and message messages)
    (cl-position message messages :test #'eq)))

(defun benedict-chat-nav--message-key (message messages)
  "Return a navigation key for MESSAGE within MESSAGES.

Prefer stable IDs when available; fall back to MESSAGE index."
  (or (benedict-message-id message)
      (benedict-chat-nav--message-index message messages)))

(defun benedict-chat-nav--group-turns (messages)
  "Return MESSAGES grouped into user-led turn groups."
  (let (turns current)
    (dolist (message messages)
      (if (eq (benedict-chat-nav--normalize-role (benedict-message-role message)) 'user)
          (progn
            (when current
              (push (nreverse current) turns))
            (setq current (list message)))
        (if current
            (push message current)
          (setq current (list message)))))
    (when current
      (push (nreverse current) turns))
    (nreverse turns)))

(defun benedict-chat-nav--turn-id (turn index messages)
  "Return a stable turn identifier for TURN at INDEX within MESSAGES."
  (let* ((prompt (cl-find-if
                  (lambda (message)
                    (eq (benedict-chat-nav--normalize-role (benedict-message-role message))
                        'user))
                  turn))
         (outcome (car (last (cl-remove-if-not #'benedict-chat-nav--assistant-message-p turn)))))
    (or (and prompt (benedict-chat-nav--message-key prompt messages))
        (and outcome (benedict-chat-nav--message-key outcome messages))
        (format "turn-%s" index))))

(defun benedict-chat-nav--turn-id-for-message-key (message-key)
  "Return the turn identifier containing MESSAGE-KEY, or nil."
  (when-let ((messages (benedict-chat-nav--messages)))
    (let ((turns (benedict-chat-nav--group-turns messages))
          (index 0)
          found)
      (while (and turns (not found))
        (let ((turn (car turns)))
          (when (cl-some (lambda (message)
                           (equal (benedict-chat-nav--message-key message messages)
                                  message-key))
                         turn)
            (setq found (benedict-chat-nav--turn-id turn index messages))))
        (setq turns (cdr turns)
              index (1+ index)))
      found)))

(defun benedict-chat-nav--turn-id-at-point ()
  "Return the current turn identifier from point context, or nil."
  (or (get-text-property (point) 'benedict-turn-id)
      (when-let ((message-key (get-text-property (point) 'benedict-message-key)))
        (benedict-chat-nav--turn-id-for-message-key message-key))
      (when-let ((message (benedict-chat-nav--item-at-point))
                 (messages (benedict-chat-nav--messages)))
        (benedict-chat-nav--turn-id-for-message-key
         (benedict-chat-nav--message-key message messages)))))

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

(defun benedict-chat-nav--property-positions (property value &optional predicate)
  "Return run start positions where PROPERTY equals VALUE and PREDICATE accepts the position."
  (let ((probe (point-min))
        positions)
    (while (< probe (point-max))
      (when (and (equal (get-text-property probe property) value)
                 (or (null predicate)
                     (funcall predicate probe)))
        (push probe positions))
      (setq probe (or (next-single-property-change probe property nil (point-max))
                      (point-max))))
    (nreverse positions)))

(defun benedict-chat-nav--goto-property-match (property value direction &optional predicate)
  "Move point to PROPERTY VALUE in DIRECTION when PREDICATE accepts the match."
  (let* ((positions (benedict-chat-nav--property-positions property value predicate))
         (match (if (eq direction 'backward)
                    (car (last (cl-remove-if-not (lambda (pos) (< pos (point))) positions)))
                  (cl-find-if (lambda (pos) (> pos (point))) positions))))
    (when match
      (goto-char match)
      t)))

(defun benedict-chat-nav--goto-turn-target (turn-id target &optional direction)
  "Move point to TARGET within TURN-ID, searching in DIRECTION."
  (when turn-id
    (benedict-chat-nav--goto-property-match
     'benedict-turn-target target (or direction 'forward)
     (lambda (pos)
       (equal (get-text-property pos 'benedict-turn-id) turn-id)))))

(defun benedict-chat-nav--goto-turn-target-anywhere (turn-id target)
  "Move point to TARGET within TURN-ID, searching the full buffer."
  (when-let ((match (car (benedict-chat-nav--property-positions
                          'benedict-turn-target target
                          (lambda (pos)
                            (equal (get-text-property pos 'benedict-turn-id) turn-id))))))
    (goto-char match)
    t))

(defun benedict-chat-nav--move-past-current-target-run (direction)
  "Move point past the current turn target run in DIRECTION."
  (when-let ((target (get-text-property (point) 'benedict-turn-target)))
    (let ((boundary (if (eq direction 'backward)
                        (previous-single-property-change
                         (point) 'benedict-turn-target nil (point-min))
                      (next-single-property-change
                       (point) 'benedict-turn-target nil (point-max)))))
      (goto-char (if (eq direction 'backward)
                     (max (point-min) (1- (or boundary (point-min))))
                   (min (point-max) (or boundary (point-max))))))))

(defun benedict-chat-nav--button-at-or-after-point (&optional limit)
  "Return the first widget or button between point and LIMIT."
  (let ((end (or limit (line-end-position))))
    (save-excursion
      (or (let ((button-pos (next-button (point) t)))
            (when (and button-pos (<= button-pos (min end (point-max))))
              (or (button-at button-pos)
                  (widget-at button-pos))))
          (cl-loop for pos from (point) to (min end (point-max))
                   for widget = (widget-at pos)
                   when widget
                   return widget)
          (cl-loop for pos from (point) to (min end (point-max))
                   for button = (button-at pos)
                   when button
                   return button)))))

(defun benedict-chat-nav--activate-widget-or-button (control)
  "Activate CONTROL returned by `widget-at' or `button-at'."
  (cond
   ((and control (widgetp control))
    (let ((action (widget-get control :action)))
      (when action
        (funcall action control)
        t)))
   ((buttonp control)
    (button-activate control)
    t)
   (t nil)))

(defun benedict-chat-nav--activate-current-turn-execution-toggle (turn-id)
  "Activate the execution summary toggle button for TURN-ID."
  (when turn-id
    (let ((start (point)))
      (when (benedict-chat-nav--goto-turn-target-anywhere
             turn-id benedict-chat-nav--execution-summary-target)
        (let* ((limit (min (+ (point) 512) (point-max)))
               (control (benedict-chat-nav--button-at-or-after-point limit)))
          (unless control
            (goto-char start))
          (benedict-chat-nav--activate-widget-or-button control))))))

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
                (not (benedict-message-metadata-value message :error)))))
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

(defun benedict-chat-nav-next-prompt ()
  "Move point to the next turn prompt header."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (benedict-chat-nav--move-past-current-target-run 'forward)
      (unless (benedict-chat-nav--goto-property-match
               'benedict-turn-target benedict-chat-nav--prompt-target 'forward)
        (goto-char (point-max))
        (message "Benedict: no later prompts")
        nil))))

(defun benedict-chat-nav-previous-prompt ()
  "Move point to the previous turn prompt header."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (benedict-chat-nav--move-past-current-target-run 'backward)
      (unless (benedict-chat-nav--goto-property-match
               'benedict-turn-target benedict-chat-nav--prompt-target 'backward)
        (goto-char (point-min))
        (message "Benedict: no earlier prompts")
        nil))))

(defun benedict-chat-nav-jump-to-current-turn-outcome ()
  "Move point to the current turn's outcome, falling back to the draft section."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((turn-id (benedict-chat-nav--turn-id-at-point)))
          (unless (or (benedict-chat-nav--goto-turn-target-anywhere
                       turn-id benedict-chat-nav--outcome-target)
                      (benedict-chat-nav--goto-turn-target-anywhere turn-id 'draft))
            (message "Benedict: no turn outcome here")
            nil)
        (message "Benedict: no turn at point")
        nil))))

(defun benedict-chat-nav-toggle-current-turn-execution ()
  "Toggle execution detail for the current completed turn."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((turn-id (benedict-chat-nav--turn-id-at-point)))
          (unless (benedict-chat-nav--activate-current-turn-execution-toggle turn-id)
            (message "Benedict: no execution summary on this turn")
            nil)
        (message "Benedict: no turn at point")
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
   (lambda (message) (benedict-message-thinking message))
   'forward "thinking blocks"))

(defun benedict-chat-nav-previous-thinking ()
  "Move point to the previous thinking block."
  (interactive)
  (benedict-chat-nav--navigate
   (lambda (message) (benedict-message-thinking message))
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
          (when (and (eq (benedict-chat-nav--normalize-role (benedict-message-role msg)) 'user)
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
