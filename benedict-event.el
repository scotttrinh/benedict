;;; benedict-event.el --- Stable runtime events for Benedict -*- lexical-binding: t; -*-

;;; Commentary:
;; Canonical event payloads shared between the runtime, UI, and tests.

;;; Code:

(require 'cl-lib)

(cl-defstruct (benedict-event (:constructor benedict-event-create))
  "Stable runtime event emitted by a Benedict session."
  type session-id timestamp payload)

(defun benedict-event-to-plist (event)
  "Convert EVENT to a plain plist."
  (list :type (benedict-event-type event)
        :session-id (benedict-event-session-id event)
        :timestamp (benedict-event-timestamp event)
        :payload (benedict-event-payload event)))

(provide 'benedict-event)
;;; benedict-event.el ends here
