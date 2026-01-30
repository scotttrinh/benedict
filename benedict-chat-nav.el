;;; benedict-chat-nav.el --- Navigation commands for Benedict chat -*- lexical-binding: t; -*-

;;; Commentary:
;; Navigation helpers for chat buffers and magit sections.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'benedict-chat-thinking) ; for benedict-chat-thinking--item-p
(require 'benedict-session)
(require 'benedict-chat-render)

;; Declare functions and variables from benedict-chat.el
(defvar benedict-chat--items)
(defvar benedict-chat--session)
(defvar benedict-chat--buffer)
(declare-function benedict-chat-render--normalize-role "benedict-chat-render")
(declare-function benedict-chat--ensure-chat-buffer "benedict-chat")
(declare-function benedict-chat--ensure-not-busy "benedict-chat")
(declare-function benedict-chat--sync-from-session "benedict-chat" (session))

(defun benedict-chat-nav--assistant-message-item-p (item)
  "Return non-nil when ITEM represents an assistant message."
  (and (eq (plist-get item :kind) 'message)
       (eq (benedict-chat-render--normalize-role (plist-get item :role)) 'assistant)))

(defun benedict-chat-nav--last-assistant-item ()
  "Return the most recently rendered assistant message item, or nil."
  (cl-loop for item in (reverse benedict-chat--items)
           when (benedict-chat-nav--assistant-message-item-p item)
           return item))

(defun benedict-chat-nav--current-assistant-section ()
  "Return the magit-section for the most recent assistant message, or nil."
  (when-let ((item (benedict-chat-nav--last-assistant-item)))
    (plist-get item :section)))

(defun benedict-chat-nav--find-last-assistant (&optional include-errors)
  "Return the most recent assistant message from session.
When INCLUDE-ERRORS is nil, skip entries flagged with :error metadata."
  (when benedict-chat--session
    (cl-find-if
     (lambda (message)
       (and (eq (benedict-chat-render--normalize-role (plist-get message :role)) 'assistant)
            (or include-errors
                (not (plist-get (plist-get message :metadata) :error)))))
     (benedict-session-messages benedict-chat--session))))

(defun benedict-chat-nav--item-at-point ()
  "Return the chat item covering point, or nil.
Checks both the item's start/end range and header markers to handle
navigation that lands on item headers."
  (or ;; First try: find item whose start/end range contains point
   (cl-find-if
    (lambda (item)
      (let ((start (plist-get item :start))
            (end (plist-get item :end)))
        (and (markerp start) (markerp end)
             (marker-position start) (marker-position end)
             (<= (marker-position start) (point))
             (<= (point) (marker-position end)))))
    benedict-chat--items)
   ;; Second try: find item whose header contains point
   ;; (for navigation that lands on header markers)
   (cl-find-if
    (lambda (item)
      (let ((header-start (plist-get item :header-start))
            (header-end (plist-get item :header-end)))
        (and (markerp header-start) (markerp header-end)
             (marker-position header-start) (marker-position header-end)
             (<= (marker-position header-start) (point))
             (<= (point) (marker-position header-end)))))
    benedict-chat--items)))

(defun benedict-chat-nav--item-index (item)
  "Return ITEM index within `benedict-chat--items', or nil."
  (when item
    (cl-position item benedict-chat--items :test #'eq)))

(defun benedict-chat-nav--seek-item (predicate direction)
  "Return next item matching PREDICATE in DIRECTION.
DIRECTION is either 'forward or 'backward."
  (let* ((items benedict-chat--items)
         (current-index (or (benedict-chat-nav--item-index (benedict-chat-nav--item-at-point)) -1))
         (indices (if (eq direction 'forward)
                      (number-sequence (1+ current-index) (1- (length items)))
                    (number-sequence (1- current-index) 0 -1))))
    (cl-loop for idx in indices
             for candidate = (nth idx items)
             when (and candidate (funcall predicate candidate))
             return candidate)))

(defun benedict-chat-nav--goto-item (item)
  "Move point to ITEM header.
Uses magit-section-goto when section exists, then ensures point lands
on the header marker for tests that verify exact positions."
  (if-let ((section (plist-get item :section)))
      (progn
        (magit-section-goto section)
        ;; After magit-section-goto, ensure we're on the header marker
        ;; for tests that verify exact point positions
        (when-let ((header-start (plist-get item :header-start)))
          (when (and (markerp header-start)
                     (marker-buffer header-start)
                     (marker-position header-start))
            (goto-char (marker-position header-start)))))
    (when-let ((pos (or (plist-get item :header-start)
                       (plist-get item :start))))
      (when (and (markerp pos)
                 (marker-buffer pos)
                 (marker-position pos))
        (goto-char (marker-position pos)))))
  item)

(defun benedict-chat-nav--navigate (predicate direction label)
  "Move to item matching PREDICATE in DIRECTION or echo LABEL when missing."
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((target (benedict-chat-nav--seek-item predicate direction)))
          (benedict-chat-nav--goto-item target)
        (message "Benedict: no %s %s" label (if (eq direction 'forward) "ahead" "behind"))
        nil))))

(defun benedict-chat-nav--tool-item-p (item)
  "Return non-nil when ITEM represents a tool block."
  (eq (plist-get item :kind) 'tool))

(defun benedict-chat-nav--assistant-item-for-tool (tool-item)
  "Return the assistant message item associated with TOOL-ITEM, or nil."
  (let ((items benedict-chat--items)
        (parent (plist-get tool-item :parent-section)))
    (or (and parent
             (cl-find-if (lambda (item)
                           (and (benedict-chat-nav--assistant-message-item-p item)
                                (eq (plist-get item :section) parent)))
                         items))
        (let ((index (benedict-chat-nav--item-index tool-item)))
          (when index
            (cl-loop for idx downfrom (1- index) to 0
                     for candidate = (nth idx items)
                     when (benedict-chat-nav--assistant-message-item-p candidate)
                     return candidate))))))

(defun benedict-chat-nav--last-assistant-with-tools-item ()
  "Return the most recent assistant message that has tool blocks, or nil."
  (cl-loop for item in (reverse benedict-chat--items)
           when (benedict-chat-nav--tool-item-p item)
           do (when-let ((assistant (benedict-chat-nav--assistant-item-for-tool item)))
                (cl-return assistant))))

(defun benedict-chat-nav--tool-failure-item-p (item)
  "Return non-nil when ITEM represents a failed tool block."
  (and (benedict-chat-nav--tool-item-p item)
       (let ((status (plist-get (plist-get item :metadata) :status)))
         (memq status '(failure error)))))

(defun benedict-chat-nav--error-item-p (item)
  "Return non-nil when ITEM captures an error."
  (let ((metadata (plist-get item :metadata)))
    (or (plist-get metadata :error)
        (eq (plist-get metadata :status) 'failure)
        (eq (plist-get metadata :status) 'error))))

(defun benedict-chat-nav-jump-to-latest ()
  "Jump to the newest chat item in the buffer."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if benedict-chat--items
          (benedict-chat-nav--goto-item (car (last benedict-chat--items)))
        (goto-char (point-max))
        (message "Benedict: no chat items yet")))))

(defun benedict-chat-nav-jump-to-last-assistant ()
  "Jump to the most recent assistant message in the chat buffer."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((item (benedict-chat-nav--last-assistant-item)))
          (benedict-chat-nav--goto-item item)
        (message "Benedict: no assistant messages yet")
        nil))))

(defun benedict-chat-nav-jump-to-last-assistant-with-tools ()
  "Jump to the most recent assistant message that has tool blocks."
  (interactive)
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (if-let ((item (benedict-chat-nav--last-assistant-with-tools-item)))
          (benedict-chat-nav--goto-item item)
        (message "Benedict: no assistant messages with tools yet")
        nil))))

(defun benedict-chat-nav-next-tool ()
  "Move point to the next tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-item-p 'forward "tool blocks"))

(defun benedict-chat-nav-previous-tool ()
  "Move point to the previous tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-item-p 'backward "tool blocks"))

(defun benedict-chat-nav-next-tool-failure ()
  "Move point to the next failed tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-failure-item-p 'forward "failed tool blocks"))

(defun benedict-chat-nav-previous-tool-failure ()
  "Move point to the previous failed tool block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--tool-failure-item-p 'backward "failed tool blocks"))

(defun benedict-chat-nav-next-error ()
  "Move point to the next error block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--error-item-p 'forward "errors"))

(defun benedict-chat-nav-previous-error ()
  "Move point to the previous error block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-nav--error-item-p 'backward "errors"))

(defun benedict-chat-nav-next-thinking ()
  "Move point to the next thinking block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-thinking--item-p 'forward "thinking blocks"))

(defun benedict-chat-nav-previous-thinking ()
  "Move point to the previous thinking block."
  (interactive)
  (benedict-chat-nav--navigate #'benedict-chat-thinking--item-p 'backward "thinking blocks"))

(defun benedict-chat-nav-toggle-thinking (&optional all)
  "Toggle thinking blocks at point.

When ALL is non-nil (interactive prefix argument), toggle all thinking
blocks in the current chat buffer.

When point is inside an assistant message/tool block, this toggles all
thinking blocks nested under that assistant section."
  (interactive "P")
  (let ((chat (benedict-chat--ensure-chat-buffer)))
    (unless (eq (current-buffer) chat)
      (pop-to-buffer-same-window chat))
    (with-current-buffer chat
      (let* ((item (benedict-chat-nav--item-at-point))
             (assistant-section (cond
                                 ((benedict-chat-nav--assistant-message-item-p item)
                                  (plist-get item :section))
                                 (t
                                  (plist-get item :parent-section))))
             (candidates
              (cond
               (all
                (cl-remove-if-not #'benedict-chat-thinking--item-p benedict-chat--items))
               ((benedict-chat-thinking--item-p item) (list item))
               (assistant-section
                (cl-remove-if-not
                 (lambda (candidate)
                   (and (benedict-chat-thinking--item-p candidate)
                        (eq (plist-get candidate :parent-section) assistant-section)))
                 benedict-chat--items))
               (t nil))))
        (cond
         ((null candidates)
          (message "Benedict: no thinking blocks here")
          nil)
         ((and (= (length candidates) 1)
               (benedict-chat-thinking--item-p (car candidates)))
          (let ((candidate (car candidates)))
            (benedict-chat-thinking--set-folded candidate
                                                (not (plist-get candidate :thinking-folded)))))
         (t
          (let ((folded (cl-every (lambda (candidate)
                                    (plist-get candidate :thinking-folded))
                                  candidates)))
            (dolist (candidate candidates)
              (benedict-chat-thinking--set-folded candidate (not folded))))))))))

(defun benedict-chat-nav-copy-last-response ()
  "Copy the most recent assistant response (non-error) to the kill ring."
  (interactive)
  (let ((message (benedict-chat-nav--find-last-assistant)))
    (unless message
      (user-error "No assistant responses to copy"))
    (kill-new (plist-get message :content))
    (message "Benedict: copied last response to kill ring")))

(defun benedict-chat-nav-retry-last ()
  "Retry the most recent provider request.
Removes the last assistant message from the session (if any) and runs the
agent loop again."
  (interactive)
  (benedict-chat--ensure-not-busy)
  (let* ((session benedict-chat--session)
         (messages (benedict-session-messages session))
         (last-msg (car messages)))
    (when (and last-msg (memq (plist-get last-msg :role) '(assistant Assistant)))
      (pop (benedict-session-messages session))
      ;; Sync UI to reflect removal
      (benedict-chat--sync-from-session session))
    (message "Benedict: retrying...")
    (benedict-session-run session)))

(provide 'benedict-chat-nav)
;;; benedict-chat-nav.el ends here
