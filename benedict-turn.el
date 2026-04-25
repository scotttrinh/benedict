;;; benedict-turn.el --- First-class model-turn execution context -*- lexical-binding: t; -*-

;;; Commentary:
;; A turn represents one logical unit of work from user input through final
;; assistant response, policy stop, cancellation, or error. It owns transient
;; inner state: control-owner/turn-state, message IDs that belong to the turn,
;; prompt and outcome message IDs, outstanding turn yields, request/draft linkage,
;; usage and timing telemetry, phase, and turn-local metadata.

;;; Code:

(require 'cl-lib)

(defvar benedict-turn--seq 0
  "Sequence number for turn IDs.")

(cl-defstruct (benedict-turn (:constructor benedict-turn--create))
  "A single logical unit of work from input to final outcome."
  id session-id created-at updated-at completed-at
  (state 'idle) phase
  prompt-message-id outcome-message-id
  (message-ids nil)
  (outstanding-yields nil)
  request-id draft-message-id
  usage elapsed metadata)

(defun benedict-turn-create (session-id &rest plist)
  "Create a new turn for SESSION-ID with PLIST."
  (let* ((now (current-time))
         (id (format "turn-%s-%03d"
                     (format-time-string "%Y%m%d%H%M%S" now)
                     (cl-incf benedict-turn--seq)))
         (turn (benedict-turn--create
                :id id
                :session-id session-id
                :created-at now
                :updated-at now)))
    (cl-loop for (k v) on plist by #'cddr
             do (pcase k
                  (:state (setf (benedict-turn-state turn) v))
                  (:phase (setf (benedict-turn-phase turn) v))
                  (:prompt-message-id (setf (benedict-turn-prompt-message-id turn) v))
                  (:metadata (setf (benedict-turn-metadata turn) v))))
    turn))

(defun benedict-turn-touch (turn)
  "Update the updated-at timestamp on TURN."
  (setf (benedict-turn-updated-at turn) (current-time)))

(defun benedict-turn-set-state (turn state)
  "Set inner loop STATE on TURN."
  (setf (benedict-turn-state turn) state)
  (benedict-turn-touch turn))

(defun benedict-turn-add-message-id (turn message-id)
  "Add MESSAGE-ID to the list of messages in TURN."
  (when message-id
    (unless (member message-id (benedict-turn-message-ids turn))
      (setf (benedict-turn-message-ids turn)
            (append (benedict-turn-message-ids turn) (list message-id)))
      (benedict-turn-touch turn))))

(defun benedict-turn-add-yield (turn yield)
  "Add YIELD to TURN's outstanding yields."
  (setf (benedict-turn-outstanding-yields turn)
        (append (benedict-turn-outstanding-yields turn) (list yield)))
  (benedict-turn-touch turn))

(defun benedict-turn-remove-yield (turn yield-id)
  "Remove yield with YIELD-ID from TURN and return it."
  (let ((removed nil)
        (kept nil))
    (dolist (yield (benedict-turn-outstanding-yields turn))
      (if (and (not removed) (equal (plist-get yield :id) yield-id))
          (setq removed yield)
        (push yield kept)))
    (setf (benedict-turn-outstanding-yields turn) (nreverse kept))
    (when removed (benedict-turn-touch turn))
    removed))

(defun benedict-turn-blocked-p (turn)
  "Return non-nil when TURN has unresolved outstanding yields."
  (not (null (benedict-turn-outstanding-yields turn))))

(defun benedict-turn-complete (turn &optional outcome-message-id)
  "Mark TURN as completed, optionally recording OUTCOME-MESSAGE-ID."
  (when outcome-message-id
    (setf (benedict-turn-outcome-message-id turn) outcome-message-id)
    (benedict-turn-add-message-id turn outcome-message-id))
  (setf (benedict-turn-state turn) 'turn-complete)
  (setf (benedict-turn-completed-at turn) (current-time))
  (setf (benedict-turn-phase turn) 'complete)
  (benedict-turn-touch turn))

(defun benedict-turn-cancel (turn)
  "Mark TURN as cancelled."
  (setf (benedict-turn-state turn) 'turn-complete)
  (setf (benedict-turn-completed-at turn) (current-time))
  (setf (benedict-turn-phase turn) 'canceled)
  (benedict-turn-touch turn))

(defun benedict-turn-fail (turn)
  "Mark TURN as failed."
  (setf (benedict-turn-state turn) 'turn-complete)
  (setf (benedict-turn-completed-at turn) (current-time))
  (setf (benedict-turn-phase turn) 'error)
  (benedict-turn-touch turn))

(defun benedict-turn-projection (turn)
  "Produce display/store projection for TURN."
  (list :id (benedict-turn-id turn)
        :session-id (benedict-turn-session-id turn)
        :created-at (benedict-turn-created-at turn)
        :updated-at (benedict-turn-updated-at turn)
        :completed-at (benedict-turn-completed-at turn)
        :state (benedict-turn-state turn)
        :phase (benedict-turn-phase turn)
        :prompt-message-id (benedict-turn-prompt-message-id turn)
        :outcome-message-id (benedict-turn-outcome-message-id turn)
        :message-ids (benedict-turn-message-ids turn)
        :outstanding-yields (benedict-turn-outstanding-yields turn)
        :request-id (benedict-turn-request-id turn)
        :draft-message-id (benedict-turn-draft-message-id turn)
        :usage (benedict-turn-usage turn)
        :elapsed (benedict-turn-elapsed turn)
        :metadata (benedict-turn-metadata turn)))

(provide 'benedict-turn)
;;; benedict-turn.el ends here
