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

(defun benedict-vui-root--session-draft (session)
  "Return streaming payload for SESSION draft, or nil."
  (when (and session (eq (benedict-session-state session) 'streaming))
    (when-let ((draft (benedict-session-draft session)))
      (list :status 'active
            :content (or (plist-get draft :content) "")
            :tool-calls (plist-get draft :tool-calls)))))

(defun benedict-vui-root--streaming-message (streaming)
  "Return a synthetic message for STREAMING payload."
  (when (and (listp streaming)
             (eq (plist-get streaming :status) 'active))
    (list :role 'assistant
          :content (plist-get streaming :content)
          :tool-calls (plist-get streaming :tool-calls))))

(defun benedict-vui-root--append-streaming (conversation streaming)
  "Return CONVERSATION with STREAMING appended when active."
  (if (vui-component 'benedict-vui-root--streaming-message streaming)
      (append conversation (list (vui-component 'benedict-vui-root--streaming-message streaming)))
    conversation))

(defun benedict-vui-root--submit (value on-submit retain-context)
  "Submit VALUE via ON-SUBMIT, returning non-nil on success.
Clears input and context when RETAIN-CONTEXT is nil."
  (when on-submit
    (let ((result (funcall on-submit value)))
      (when result
        (vui-batch
          (vui-set-state :history (lambda (history)
                                    (append history (list value))))
          (vui-set-state :input-text "")
          (when (not retain-context)
            (vui-set-state :slices nil))))
      result)))

(vui-defcomponent benedict-vui-root (props state)
  "Root component owning all shared application state."
  :state ((conversation nil)
          (streaming nil)
          (provider 'openrouter)
          (model "claude-3-5-sonnet-20241022")
          (collapsed-blocks nil)
          (error nil)
          (usage nil)
          (input-text "")
          (slices nil)
          (history nil))
  :on-mount
  (let* ((session (plist-get props :session))
         (initial-slices (plist-get props :initial-slices))
         (initial-input (plist-get props :initial-input))
         (initial-conversation (and session
                                    (benedict-session-messages-chronological session)))
         (initial-streaming (vui-component 'benedict-vui-root--session-draft session))
         (initial-provider (and session (benedict-session-provider session)))
         (initial-model (and session (benedict-session-model session)))
         (initial-usage (and session (benedict-session-last-usage session))))
    (vui-batch
      (when initial-slices
        (vui-set-state :slices initial-slices))
      (when initial-input
        (vui-set-state :input-text initial-input))
      (when initial-conversation
        (vui-set-state :conversation initial-conversation))
      (when initial-streaming
        (vui-set-state :streaming initial-streaming))
      (when initial-provider
        (vui-set-state :provider initial-provider))
      (when initial-model
        (vui-set-state :model initial-model))
      (when initial-usage
        (vui-set-state :usage initial-usage)))
    (when session
      (let ((subscription (vui-component 'benedict-vui-root--subscribe-to-session session)))
        (lambda ()
          (vui-component 'benedict-vui-root--unsubscribe-from-session subscription)))))
  :render
  (let* ((current-conversation (plist-get state :conversation))
         (current-streaming (plist-get state :streaming))
         (current-provider (plist-get state :provider))
         (current-model (plist-get state :model))
         (current-collapsed-blocks (plist-get state :collapsed-blocks))
         (current-error (plist-get state :error))
         (current-usage (or (plist-get props :usage)
                            (plist-get state :usage)))
         (current-input (plist-get state :input-text))
         (current-slices (or (plist-get props :slices)
                             (plist-get state :slices)))
         (current-history (plist-get state :history))
         (render-conversation (vui-component 'benedict-vui-root--append-streaming
                               current-conversation current-streaming))
         (retain-context (plist-get props :retain-context))
         (register-actions (plist-get props :register-actions))
         (on-slices-change (plist-get props :on-slices-change))
         (on-provider-click (plist-get props :on-provider-click))
         (on-submit (plist-get props :on-submit))
         (set-input (vui-use-callback ()
                      (lambda (value)
                        (vui-set-state :input-text value))))
         (set-slices (vui-use-callback ()
                      (lambda (slices)
                        (vui-set-state :slices slices))))
         (submit-handler (vui-use-callback (on-submit retain-context)
                           (lambda (value)
                             (vui-component 'benedict-vui-root--submit
                              value on-submit retain-context))))
         (slice-remove (vui-use-callback (current-slices on-slices-change)
                         (lambda (slice-id)
                           (let ((updated (cl-remove-if
                                           (lambda (slice)
                                             (equal (plist-get slice :id) slice-id))
                                           current-slices)))
                             (vui-set-state :slices updated)
                             (when on-slices-change
                               (funcall on-slices-change updated))))))
         (input-change (vui-use-callback ()
                         (lambda (value)
                           (vui-set-state :input-text value)))))
    (vui-use-effect (register-actions set-input set-slices)
      (when register-actions
        (funcall register-actions
                 (list :set-input set-input
                       :set-slices set-slices)))
      (lambda ()
        (when register-actions
          (funcall register-actions nil))))
    (vui-vstack
     (vui-component 'benedict-vui-chat-header
       :provider current-provider
       :model current-model
       :status (when (plist-get current-streaming :status)
                 (plist-get current-streaming :status))
       :title "Chat"
       :on-provider-click on-provider-click)
     (vui-component 'benedict-vui-conversation-view
      :conversation render-conversation
      :streaming current-streaming
      :collapsed-blocks current-collapsed-blocks)
     (vui-component 'benedict-vui-input-area
      :slices current-slices
      :input-text current-input
      :on-input-change input-change
      :on-submit submit-handler
      :on-slice-remove slice-remove
      :history current-history
      :placeholder "Ask Benedict..."
      :size 5
      :field-key 'root-input)
     (vui-component 'benedict-vui-status-bar
      :usage current-usage
      :error current-error))))

;;; Session event subscription

(defvar-local benedict-vui-root--session-subscription nil
  "Subscription function for session events.")

(defun benedict-vui-root--subscribe-to-session (session)
  "Subscribe to SESSION events.
Returns a function that when called unsubscribes from events."
  (let ((handler (lambda (sess event-type payload)
                  (when (eq sess session)
                    (vui-component 'benedict-vui-root--handle-session-event event-type payload)))))
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
       (vui-set-state :streaming nil)))
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
           (when-let ((usage (plist-get result :usage)))
             (vui-set-state :usage usage))
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
