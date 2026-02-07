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
  (if (benedict-vui-root--streaming-message streaming)
      (append conversation (list (benedict-vui-root--streaming-message streaming)))
    conversation))

(defun benedict-vui-root--toggle-collapsed-block (collapsed-blocks block-id &optional next)
  "Return COLLAPSED-BLOCKS updated for BLOCK-ID.

When NEXT is non-nil, it forces the collapsed state.  When NEXT is nil,
toggle based on current membership.  COLLAPSED-BLOCKS may be a list or hash table."
  (cond
   ((null block-id) collapsed-blocks)
   ((hash-table-p collapsed-blocks)
    (let* ((table (copy-hash-table collapsed-blocks))
           (present (gethash block-id table))
           (collapse (if (null next) (not present) next)))
      (if collapse
          (puthash block-id t table)
        (remhash block-id table))
      table))
   (t
    (let* ((current (if (listp collapsed-blocks)
                        (copy-sequence collapsed-blocks)
                      nil))
           (present (member block-id current))
           (collapse (if (null next) (not present) next)))
      (if collapse
          (if present current (cons block-id current))
        (cl-remove block-id current :test #'equal))))))

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

(vui-defcomponent benedict-vui-root (session initial-slices initial-input retain-context register-actions on-slices-change on-provider-click on-submit)
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
  (let* ((initial-conversation (and session
                                    (benedict-session-messages-chronological session)))
         (initial-streaming (benedict-vui-root--session-draft session))
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
      (let ((subscription (benedict-vui-root--subscribe-to-session session)))
        (lambda ()
          (benedict-vui-root--unsubscribe-from-session subscription)))))
  :render
  (let* ((current-usage (or (plist-get --props-- :usage)
                            usage))
         (current-slices (or (plist-get --props-- :slices)
                             slices))
         (render-conversation (benedict-vui-root--append-streaming
                               conversation streaming))
         (set-input (vui-use-memo ()
                      (vui-async-callback (value)
                        (vui-set-state :input-text value))))
         (set-slices (vui-use-memo ()
                       (vui-async-callback (slices-val)
                         (vui-set-state :slices slices-val))))
         (submit-handler (vui-use-memo (on-submit retain-context)
                           (lambda (value)
                             (benedict-vui-root--submit
                              value on-submit retain-context))))
         (toggle-block (vui-use-memo ()
                         (vui-async-callback (block-id &optional next)
                           (vui-set-state :collapsed-blocks
                             (lambda (current)
                               (benedict-vui-root--toggle-collapsed-block
                                current block-id next))))))
         (slice-remove (vui-use-memo (current-slices on-slices-change)
                         (lambda (slice-id)
                           (let ((updated (cl-remove-if
                                           (lambda (slice)
                                             (equal (plist-get slice :id) slice-id))
                                           current-slices)))
                             (vui-set-state :slices updated)
                             (when on-slices-change
                               (funcall on-slices-change updated))))))
         (input-change (vui-use-memo ()
                         (lambda (value)
                           (vui-set-state :input-text value)))))
     (vui-use-effect (register-actions set-input set-slices toggle-block)
       (when register-actions
         (funcall register-actions
                 (list :set-input set-input
                       :set-slices set-slices
                       :toggle-block toggle-block)))
       (lambda ()
         (when register-actions
           (funcall register-actions nil))))
    (vui-vstack
     (vui-component 'benedict-vui-chat-header
       :provider provider
       :model model
       :status (when (plist-get streaming :status)
                 (plist-get streaming :status))
       :title "Chat"
       :on-provider-click on-provider-click)
      (vui-component 'benedict-vui-conversation-view
       :conversation render-conversation
       :streaming streaming
       :collapsed-blocks collapsed-blocks
       :on-toggle-block toggle-block)
     (vui-component 'benedict-vui-input-area
      :slices current-slices
      :input-text input-text
      :on-input-change input-change
      :on-submit submit-handler
      :on-slice-remove slice-remove
      :history history
      :placeholder "Ask Benedict..."
      :size 5
      :field-key 'root-input)
     (vui-component 'benedict-vui-status-bar
      :usage current-usage
      :error error))))

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
           (vui-set-state 'conversation
             (lambda (conv)
               (append conv (list message))))))))
    ('draft-started
     (vui-with-async-context
       (vui-set-state 'streaming
         (lambda ()
           (list :status 'active
                 :content ""
                 :tool-calls nil)))))
    ('draft-updated
     (vui-with-async-context
       (let ((delta (plist-get payload :delta))
             (tool-call (plist-get payload :tool-call)))
         (if delta
             (vui-set-state 'streaming
               (lambda (s)
                 (list :status (plist-get s :status)
                       :content (concat (plist-get s :content) delta)
                       :tool-calls (plist-get s :tool-calls))))
           (when tool-call
             (vui-set-state 'streaming
               (lambda (s)
                 (list :status (plist-get s :status)
                       :content (plist-get s :content)
                       :tool-calls (append (plist-get s :tool-calls)
                                           (list tool-call))))))))))
    ('draft-finalized
     (vui-with-async-context
       (vui-set-state 'streaming nil)))
    ('state-changed
     (vui-with-async-context
       (let ((old-state (plist-get payload :old))
             (new-state (plist-get payload :new)))
         (when (eq new-state 'error)
           (vui-set-state 'error (format "Session error: %s -> %s" old-state new-state)))
         (when (and (memq old-state '(streaming running))
                    (eq new-state 'idle))
           (vui-set-state 'error nil)))))
    ('request-completed
     (vui-with-async-context
       (let ((success (plist-get payload :success))
             (error-payload (plist-get payload :error))
             (result (plist-get payload :result)))
         (when success
           (when-let ((provider (plist-get result :provider)))
             (vui-set-state 'provider provider))
           (when-let ((model (plist-get result :model)))
             (vui-set-state 'model model))
           (when-let ((usage (plist-get result :usage)))
             (vui-set-state 'usage usage))
           (vui-set-state 'error nil))
         (when (and (not success) error-payload)
           (let ((error-message (cond
                               ((plist-get error-payload :message)
                                (plist-get error-payload :message))
                               (t (format "Request failed: %S" error-payload)))))
             (vui-set-state 'error error-message))))))
    (_ nil)))

(provide 'benedict-vui-root)
;;; benedict-vui-root.el ends here
