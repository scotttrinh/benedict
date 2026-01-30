;;; benedict-vui-root.el --- Vui root component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Root component owning all shared application state.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict-session)
(require 'benedict-vui-chat-header)
(require 'benedict-vui-conversation-view)
(require 'benedict-vui-input-area)
(require 'benedict-vui-status-bar)

(vui-defcomponent benedict-vui-root (props state)
  "Root component owning all shared application state."
  :state ((conversation nil)
          (streaming nil)
          (provider 'openrouter)
          (model "claude-3-5-sonnet-20241022")
          (collapsed-blocks nil)
          (error nil))
  :on-mount
  (when-let ((session (plist-get props :session)))
    (let ((subscription (benedict-vui-root--subscribe-to-session session)))
      (lambda ()
        (benedict-vui-root--unsubscribe-from-session subscription))))
  :render
  (let* ((current-conversation (plist-get state :conversation))
         (current-streaming (plist-get state :streaming))
         (current-provider (plist-get state :provider))
         (current-model (plist-get state :model))
         (current-collapsed-blocks (plist-get state :collapsed-blocks))
         (current-error (plist-get state :error))
         (slices (plist-get props :slices))
         (input-text (plist-get props :input-text))
         (on-input-change (plist-get props :on-input-change))
         (on-submit (plist-get props :on-submit))
         (on-slice-remove (plist-get props :on-slice-remove))
         (on-provider-click (plist-get props :on-provider-click))
         (usage (plist-get props :usage))
         (on-toggle-block (plist-get props :on-toggle-block)))
    (vui-vstack
      (benedict-vui-chat-header
        :provider current-provider
        :model current-model
        :status (when (plist-get current-streaming :status)
                  (plist-get current-streaming :status))
        :title "Chat"
        :on-click on-provider-click)
      (benedict-vui-conversation-view
        :conversation current-conversation
        :streaming current-streaming
        :collapsed-blocks current-collapsed-blocks)
      (benedict-vui-input-area
        :slices slices
        :input-text input-text
        :on-input-change on-input-change
        :on-submit on-submit
        :on-slice-remove on-slice-remove
        :placeholder "Ask Benedict..."
        :size 5
        :field-key 'root-input)
      (benedict-vui-status-bar
        :usage usage
        :error current-error))))

;;; Session event subscription

(defvar-local benedict-vui-root--session-subscription nil
  "Subscription function for session events.")

(defun benedict-vui-root--subscribe-to-session (session)
  "Subscribe to SESSION events.
Returns a function that when called unsubscribes from events."
  (let ((handler (lambda (sess event-type payload)
                  (when (eq sess session)
                    (benedict-vui-root--handle-session-event event-type payload)))))
    (add-hook 'benedict-session-event-hook handler)
    (lambda ()
      (remove-hook 'benedict-session-event-hook handler))))

(defun benedict-vui-root--unsubscribe-from-session (subscription)
  "Unsubscribe from session events using SUBSCRIPTION function."
  (when subscription
    (funcall subscription)))

(defun benedict-vui-root--handle-session-event (event-type payload)
  "Handle session EVENT-TYPE with PAYLOAD, updating component state."
  (pcase event-type
    ('message-added
     (vui-with-async-context
       (let ((message (plist-get payload :message)))
         (when message
           (vui-set-state :conversation
             (lambda (conv)
               (append conv (list message))))))))
    ('draft-started
     (vui-with-async-context
       (vui-set-state :streaming
         (lambda ()
           (list :status 'active
                 :content ""
                 :tool-calls nil)))))
    ('draft-updated
     (vui-with-async-context
       (let ((delta (plist-get payload :delta))
             (tool-call (plist-get payload :tool-call)))
         (if delta
             (vui-set-state :streaming
               (lambda (s)
                 (list :status (plist-get s :status)
                       :content (concat (plist-get s :content) delta)
                       :tool-calls (plist-get s :tool-calls))))
           (when tool-call
             (vui-set-state :streaming
               (lambda (s)
                 (list :status (plist-get s :status)
                       :content (plist-get s :content)
                       :tool-calls (append (plist-get s :tool-calls)
                                           (list tool-call))))))))))
    ('draft-finalized
     (vui-with-async-context
       (if (plist-get payload :discarded)
           (vui-set-state :streaming nil)
         (vui-batch
           (vui-set-state :streaming nil)
           (vui-set-state :conversation
             (lambda (conv)
               (let ((last-msg (and (consp conv) (car (last conv)))))
                 (if (and last-msg (eq (plist-get last-msg :role) 'assistant))
                     conv
                   (append conv (list (list :role 'assistant)))))))))))
    ('state-changed
     (vui-with-async-context
       (let ((old-state (plist-get payload :old))
             (new-state (plist-get payload :new)))
         (when (eq new-state 'error)
           (vui-set-state :error (format "Session error: %s -> %s" old-state new-state)))
         (when (and (memq old-state '(streaming running))
                    (eq new-state 'idle))
           (vui-set-state :error nil)))))
    ('request-completed
     (vui-with-async-context
       (let ((success (plist-get payload :success))
             (error-payload (plist-get payload :error))
             (result (plist-get payload :result)))
         (when success
           (when-let ((provider (plist-get result :provider)))
             (vui-set-state :provider provider))
           (when-let ((model (plist-get result :model)))
             (vui-set-state :model model))
           (vui-set-state :error nil))
         (when (and (not success) error-payload)
           (let ((error-message (cond
                               ((plist-get error-payload :message)
                                (plist-get error-payload :message))
                               (t (format "Request failed: %S" error-payload)))))
             (vui-set-state :error error-message))))))
    (_ nil)))

(provide 'benedict-vui-root)
;;; benedict-vui-root.el ends here
