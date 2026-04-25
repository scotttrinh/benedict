;;; benedict-chat-status.el --- Status line UI for Benedict chat -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Status line rendering, timer management, and usage formatting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict-session)
(require 'benedict-chat-profiles)

(declare-function benedict-chat-flywire-active-p "benedict-chat" ())

(defvar benedict-chat--session)
(defvar benedict-chat--status-spinner-index)
(defvar benedict-chat--status-timer)
(defvar benedict-chat--compose-model-override)
(defvar benedict-chat--model-button-map)

(defcustom benedict-chat-status-token-display 'prompt+completion
  "Control how token usage appears in chat status lines.
Values:
- prompt+completion: show prompt and completion counts (e.g., \"186p+126c\").
- total: show a single total token count (e.g., \"312 tok\").
- none: hide token usage entirely."
  :type '(choice
          (const :tag "Prompt + completion" prompt+completion)
          (const :tag "Total tokens only" total)
          (const :tag "Hide token usage" none))
  :group 'benedict)

(defconst benedict-chat-status--spinner-frames ["◐" "◓" "◑" "◒"]
  "Spinner frames used while a provider request is active.")

(defun benedict-chat-status--status-reset ()
  "Reset status UI state for the current buffer."
  (setq benedict-chat--status-spinner-index 0))

(defun benedict-chat-status--status-phase ()
  "Return the current session phase for status display."
  (let ((session benedict-chat--session))
    (cond
     ((null session) 'idle)
     ((eq (benedict-session-state session) 'streaming) 'streaming)
     ((eq (benedict-session-run-state session) 'error) 'error)
     ((eq (benedict-session-run-state session) 'cancelled) 'canceled)
     ((benedict-session-outstanding-yields session) 'waiting)
     ((benedict-session-request-active-p session) 'sending)
     ((eq (benedict-session-run-state session) 'running) 'running)
     (t 'idle))))

(defun benedict-chat-status--status-request-started-at ()
  "Return the time value when the current request started, if any."
  (when-let* ((session benedict-chat--session)
              (inflight (benedict-session-inflight session)))
    (plist-get inflight :started-at)))

(defun benedict-chat-status--status-request-started-at-float ()
  "Return the current request start time as float seconds, if any."
  (when-let ((started (benedict-chat-status--status-request-started-at)))
    (if (numberp started) started (float-time started))))

(defun benedict-chat-status--status-elapsed ()
  "Return elapsed seconds for the current session request."
  (when-let ((started (benedict-chat-status--status-request-started-at)))
    (if (numberp started)
        (- (float-time) started)
      (float-time (time-subtract (current-time) started)))))

(defun benedict-chat-status--status-active-p ()
  "Return non-nil when session indicates an active provider call."
  (let ((phase (benedict-chat-status--status-phase)))
    (memq phase '(sending streaming running))))

(defun benedict-chat-status--status-stop-timer ()
  "Cancel the status timer if present."
  (when (timerp benedict-chat--status-timer)
    (cancel-timer benedict-chat--status-timer))
  (setq benedict-chat--status-timer nil))

(defun benedict-chat-status--status-refresh ()
  "Force status lines to update."
  (force-mode-line-update t))

(defun benedict-chat-status--status-tick (buffer)
  "Advance spinner/elapsed for BUFFER and refresh status."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (benedict-chat-status--status-active-p)
          (progn
            (setq benedict-chat--status-spinner-index
                  (1+ benedict-chat--status-spinner-index))
            (benedict-chat-status--status-refresh))
        (benedict-chat-status--status-stop-timer)))))

(defun benedict-chat-status--status-start-timer ()
  "Ensure the spinner/elapsed timer is running for the current buffer."
  (unless (timerp benedict-chat--status-timer)
    (setq benedict-chat--status-timer
          (run-with-timer 0.2 0.2 #'benedict-chat-status--status-tick (current-buffer)))))

(defun benedict-chat-status--status-usage-string (usage)
  "Format USAGE according to `benedict-chat-status-token-display', including cost."
  (let (parts)
    (pcase benedict-chat-status-token-display
      ('none nil)
      ('total
       (let ((total (or (plist-get usage :total)
                        (benedict-session--usage-value usage "total_tokens")
                        (benedict-session--usage-value usage "tokens"))))
         (when total
           (push (format "%s tok" total) parts))))
      ('prompt+completion
       (let ((prompt (or (plist-get usage :prompt)
                         (benedict-session--usage-value usage "prompt_tokens")
                         (benedict-session--usage-value usage "prompt"))))
         (let ((completion (or (plist-get usage :completion)
                               (benedict-session--usage-value usage "completion_tokens")
                               (benedict-session--usage-value usage "completion"))))
           (cond
            ((and prompt completion)
             (push (format "%sp+%sc tok" prompt completion) parts))
            (prompt (push (format "%sp tok" prompt) parts))
            (completion (push (format "%sc tok" completion) parts)))))))
    (when-let ((cost (or (plist-get usage :cost)
                         (benedict-session--usage-cost-number usage))))
      (push (format "cost:$%.4f" cost) parts))
    (when parts
      (string-join (nreverse parts) " / "))))

(defun benedict-chat-status--status-indicator (phase last-phase)
  "Return the indicator glyph for PHASE using LAST-PHASE as a hint."
  (pcase phase
    ((or 'sending 'streaming 'running)
     (let* ((frames benedict-chat-status--spinner-frames)
            (len (length frames))
            (index (mod (or benedict-chat--status-spinner-index 0) len)))
       (aref frames index)))
    ('complete "✔")
    ('error "✖")
    ('canceled "⨯")
    (_ (pcase last-phase
         ('complete "✔")
         ('error "✖")
         ('canceled "⨯")
         (_ "·")))))

(defun benedict-chat-status--status-phase-label (phase)
  "Return a human-readable label for PHASE."
  (pcase phase
    ('sending "contacting")
    ('streaming "streaming")
    ('running "running")
    ('waiting "waiting")
    ('complete "completed")
    ('error "error")
    ('canceled "canceled")
    (_ "idle")))

(defun benedict-chat-status--status-provider-label (&optional clickable)
  "Return provider/model label for the status line.
When CLICKABLE is non-nil, attach button properties that run
`benedict-chat-choose-model'."
  (let* ((session benedict-chat--session)
         (provider (or (and session (benedict-session-provider session))
                       (benedict-chat-profiles--resolve-provider)))
         (model (or (and session (benedict-session-model session))
                    (benedict-chat-profiles--resolve-model
                     provider
                     (benedict-chat-profiles--effective-profile)
                     benedict-chat--compose-model-override)))
         (label (if model
                    (format "%s:%s" (benedict-chat-profiles--provider-label provider) model)
                  (format "%s" (benedict-chat-profiles--provider-label provider)))))
    (if clickable
        (propertize label
                    'mouse-face 'mode-line-highlight
                    'help-echo "Choose a model for this chat/compose buffer"
                    'local-map benedict-chat--model-button-map)
      label)))

(defun benedict-chat-status--status-agent-indicator ()
  "Return an indicator if a flywire agent session is active."
  (when (benedict-chat-flywire-active-p)
    (propertize "🤖" 'help-echo "Agent frame active")))

(defun benedict-chat-status--status-string (&optional rich)
  "Return the formatted status string for the current buffer.
When RICH is non-nil, include header-friendly hints.
Handles errors related to killed buffers gracefully."
  (condition-case err
      (let* ((session benedict-chat--session)
             (phase (benedict-chat-status--status-phase))
             (last-phase (and session (benedict-session-last-phase session)))
             (active (memq phase '(sending streaming running)))
             (elapsed (or (and active (benedict-chat-status--status-elapsed))
                          (and session (benedict-session-last-elapsed session))))
             (usage (and session (benedict-session-accumulated-usage session)))
             (session-seconds (and session (benedict-session-accumulated-seconds session)))
             (indicator (benedict-chat-status--status-indicator phase last-phase))
             (label (benedict-chat-status--status-phase-label phase))
             (provider (benedict-chat-status--status-provider-label rich))
             (usage-str (benedict-chat-status--status-usage-string usage))
             (elapsed-str (when (and elapsed (or (not rich) active))
                            (format "%.0fs" elapsed)))
             (session-str (when (and rich session-seconds (> session-seconds 0))
                            (format "Σ%.0fs" session-seconds)))
             (agent-indicator (benedict-chat-status--status-agent-indicator))
             (hint (and rich active "ESC to cancel")))
        (string-join
         (delq nil
               (list (format "%s %s" indicator label)
                     provider
                     elapsed-str
                     session-str
                     usage-str
                     agent-indicator
                     hint))
         " · "))
    ;; Handle errors from killed buffers or other issues during cleanup
    ((buffer-read-only error) "")))

(defun benedict-chat-status--mode-line-status ()
  "Compact status string for the mode line."
  (benedict-chat-status--status-string nil))

(defun benedict-chat-status--header-line-status ()
  "Richer status string for the header line."
  (benedict-chat-status--status-string t))

(provide 'benedict-chat-status)
;;; benedict-chat-status.el ends here
