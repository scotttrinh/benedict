;;; benedict-retry.el --- Visible retries as separate session runs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;;; Commentary:

;; Optional retry policy above the session state machine.  A failed attempt is
;; already a terminal transcript entry; this extension schedules a new run from
;; that head instead of hiding another request inside the transport.

;;; Code:

(require 'cl-lib)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-core)

(defgroup benedict-retry nil
  "Visible retries of failed Benedict model attempts."
  :group 'benedict)

(defcustom benedict-retry-limit 2
  "Maximum automatic retries after one failed model attempt."
  :type 'natnum
  :group 'benedict-retry)

(defcustom benedict-retry-base-seconds 0.5
  "Base seconds for the first automatic retry's jittered backoff."
  :type 'number
  :group 'benedict-retry)

(defcustom benedict-retry-max-seconds 20
  "Maximum seconds an automatic retry waits."
  :type 'number
  :group 'benedict-retry)

(defun benedict-retry-default-policy (_session entry attempt)
  "Return a retry delay for ENTRY at zero-based ATTEMPT, or nil.

The terminal entry must carry `:error-data' with a
`(:benedict-retry (:transient t ...))' classification.  A numeric `:delay'
there is honored up to `benedict-retry-max-seconds'; otherwise return jittered
exponential backoff.  SESSION is accepted for replaceable policies."
  (let* ((error-data (benedict-entry-meta-get entry :error-data))
         (classification (plist-get error-data :benedict-retry)))
    (when (and (< attempt benedict-retry-limit)
               (plist-get classification :transient))
      (min benedict-retry-max-seconds
           (or (and (numberp (plist-get classification :delay))
                    (max 0 (plist-get classification :delay)))
               (let ((interval
                      (min benedict-retry-max-seconds
                           (* benedict-retry-base-seconds (expt 2 attempt)))))
                 (+ (/ interval 2.0)
                    (* (/ (random 1000) 1000.0) (/ interval 2.0)))))))))

(defcustom benedict-retry-policy-function #'benedict-retry-default-policy
  "Function deciding whether and when to retry a failed attempt.

Called with (SESSION ENTRY ATTEMPT), where ATTEMPT is zero for the first
automatic retry in the current budget.  Return a non-negative delay in seconds
or nil."
  :type 'function
  :group 'benedict-retry)

(defvar benedict-retry--states (make-hash-table :test 'eq :weakness 'key)
  "Weak map from sessions to retry bookkeeping plists.")

(defvar benedict-retry--installed nil
  "Non-nil while the retry observation hooks are installed.")

(defvar benedict-retry--starting nil
  "Session whose run is currently being started by this extension.")

(defun benedict-retry--head-entry (session)
  "Return SESSION's current head entry, or nil."
  (when-let* ((id (benedict-session-head session)))
    (benedict-session-entry session id)))

(defun benedict-retry-eligible-p (session)
  "Return non-nil when SESSION can be retried explicitly now.

SESSION must be idle at an assistant head whose `:stop-reason' is `error'.
Aborted entries and earlier failed entries away from head are ineligible."
  (let ((entry (benedict-retry--head-entry session)))
    (and (eq (benedict-session-state session) 'idle)
         entry
         (benedict-entry-assistant-p entry)
         (eq (benedict-entry-meta-get entry :stop-reason) 'error))))

(defun benedict-retry-pending-p (session)
  "Return non-nil when SESSION has an automatic retry timer pending."
  (and (plist-get (gethash session benedict-retry--states) :timer) t))

(defun benedict-retry--cancel (session &optional forget)
  "Cancel SESSION's pending timer; when FORGET, discard its budget too."
  (when-let* ((state (gethash session benedict-retry--states))
              (timer (plist-get state :timer)))
    (cancel-timer timer)
    (setq state (plist-put state :timer nil))
    (puthash session state benedict-retry--states))
  (when forget
    (remhash session benedict-retry--states)))

(defun benedict-retry--timer-fired (session timer entry-id model)
  "Retry SESSION if TIMER still belongs to ENTRY-ID under MODEL."
  (let ((state (gethash session benedict-retry--states)))
    (when (eq timer (plist-get state :timer))
      (setq state (plist-put state :timer nil))
      (puthash session state benedict-retry--states)
      (when (and (eq (benedict-session-state session) 'idle)
                 (equal (benedict-session-head session) entry-id)
                 (equal (benedict-session-model session) model)
                 (benedict-retry-eligible-p session))
        (setq state (plist-put state :attempt (1+ (plist-get state :attempt))))
        (puthash session state benedict-retry--states)
        (let ((benedict-retry--starting session))
          (benedict-session-submit session nil))))))

(defun benedict-retry--schedule (session entry delay)
  "Schedule SESSION after failed ENTRY for DELAY seconds."
  (benedict-retry--cancel session)
  (let* ((state (or (gethash session benedict-retry--states)
                    (list :attempt 0)))
         (entry-id (benedict-entry-id entry))
         (model (benedict-session-model session))
         timer)
    (setq timer
          (run-at-time delay nil
                       (lambda ()
                         (benedict-retry--timer-fired
                          session timer entry-id model))))
    (setq state (plist-put state :timer timer))
    (setq state (plist-put state :entry-id entry-id))
    (setq state (plist-put state :model model))
    (puthash session state benedict-retry--states)))

(defun benedict-retry--on-run-start (session)
  "Cancel stale retry state before a non-retry run for SESSION."
  (unless (eq session benedict-retry--starting)
    (benedict-retry--cancel session t)))

(defun benedict-retry--on-head-change (session _old-id _new-id)
  "Cancel SESSION's pending retry after a move to another branch head."
  (benedict-retry--cancel session t))

(defun benedict-retry--on-run-end (session)
  "Schedule SESSION when its terminal assistant entry satisfies policy."
  (if (benedict-retry-eligible-p session)
      (let* ((entry (benedict-retry--head-entry session))
             (state (or (gethash session benedict-retry--states)
                        (list :attempt 0)))
             (attempt (or (plist-get state :attempt) 0))
             (delay (funcall benedict-retry-policy-function
                             session entry attempt)))
        (puthash session state benedict-retry--states)
        (if (and (numberp delay) (>= delay 0))
            (benedict-retry--schedule session entry delay)
          (benedict-retry--cancel session)))
    (benedict-retry--cancel session t)))

(defun benedict-retry-now (session)
  "Retry SESSION immediately from its failed assistant head.

Cancels any pending automatic retry and starts a fresh automatic-attempt budget.
The new run is submitted with nil input.  Signal `user-error' when SESSION is
active or its head is not a failed assistant attempt."
  (unless (eq (benedict-session-state session) 'idle)
    (user-error "Cannot retry while the Benedict session is active"))
  (unless (benedict-retry-eligible-p session)
    (user-error "The Benedict session head is not a failed assistant attempt"))
  (benedict-retry--cancel session t)
  (puthash session (list :attempt 0) benedict-retry--states)
  (let ((benedict-retry--starting session))
    (benedict-session-submit session nil)))

(defun benedict-retry-install ()
  "Install visible automatic retry observation hooks idempotently."
  (unless benedict-retry--installed
    (add-hook 'benedict-run-start-functions #'benedict-retry--on-run-start)
    (add-hook 'benedict-run-end-functions #'benedict-retry--on-run-end)
    (add-hook 'benedict-head-change-functions #'benedict-retry--on-head-change)
    (setq benedict-retry--installed t))
  t)

(defun benedict-retry-uninstall ()
  "Uninstall retry hooks and cancel every pending automatic retry idempotently."
  (when benedict-retry--installed
    (remove-hook 'benedict-run-start-functions #'benedict-retry--on-run-start)
    (remove-hook 'benedict-run-end-functions #'benedict-retry--on-run-end)
    (remove-hook 'benedict-head-change-functions #'benedict-retry--on-head-change)
    (setq benedict-retry--installed nil))
  (maphash (lambda (session _state) (benedict-retry--cancel session))
           benedict-retry--states)
  (clrhash benedict-retry--states)
  t)

(provide 'benedict-retry)
;;; benedict-retry.el ends here
