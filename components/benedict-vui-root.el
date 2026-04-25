;;; benedict-vui-root.el --- Vui root component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Root component owning all shared application state.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict-harness)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-vui-audit-log)
(require 'benedict-vui-approval-block)
(require 'benedict-vui-chat-header)
(require 'benedict-vui-checkpoint-block)
(require 'benedict-vui-conversation-view)
(require 'benedict-vui-session-panel)
(require 'benedict-vui-status-bar)

(defun benedict-vui-root--session-draft (session)
  "Return streaming payload for SESSION draft, or nil."
  (when (and session (eq (benedict-session-state session) 'streaming))
    (when-let ((draft (benedict-session-draft session)))
      (list :status 'active
            :content (or (plist-get draft :content) "")
            :thinking (plist-get draft :thinking)
            :tool-calls (plist-get draft :tool-calls)))))

(defun benedict-vui-root--session-info (session)
  "Return displayable session metadata for SESSION."
  (when session
    (let* ((meta (copy-tree (benedict-session-meta session)))
           (harness (benedict-session-harness session)))
      (list :session-id (benedict-session-id session)
            :title (benedict-session-title session)
            :state (benedict-session-run-state session)
            :turn-state (benedict-session-turn-state session)
            :outstanding-yield-count
            (length (benedict-session-outstanding-yields session))
            :root (benedict-session-root session)
            :instruction-sources (copy-tree (plist-get meta :instruction-sources))
            :store-path (plist-get meta :store-path)
            :last-saved-at (plist-get meta :last-saved-at)
            :audit-count (length (benedict-harness-audit-log harness))
            :updated-at (benedict-session-updated-at session)))))

(defun benedict-vui-root--session-approval (session)
  "Return SESSION's current approval yield, or nil."
  (and session
       (copy-tree
        (cl-find-if
         (lambda (yield)
           (eq (plist-get yield :type) 'approval-request))
         (benedict-session-outstanding-yields session)))))

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

(defun benedict-vui-root--collapsed-p (collapsed-blocks block-id)
  "Return non-nil when BLOCK-ID is collapsed in COLLAPSED-BLOCKS."
  (cond
   ((hash-table-p collapsed-blocks) (gethash block-id collapsed-blocks))
   ((listp collapsed-blocks) (member block-id collapsed-blocks))
   (t nil)))

(vui-defcomponent benedict-vui-root (session register-actions on-provider-click on-continue-checkpoint on-stop-checkpoint on-approve-approval on-deny-approval)
  "Root component owning all shared application state."
  :state ((conversation nil)
          (streaming nil)
          (provider 'openrouter)
          (model "claude-3-5-sonnet-20241022")
          (collapsed-blocks nil)
          (session-info nil)
          (checkpoint nil)
          (approval nil)
          (audit-log nil)
          (error nil)
          (usage nil))
  :on-mount
  (let* ((initial-conversation (and session
                                    (benedict-session-entries-chronological session)))
         (initial-streaming (benedict-vui-root--session-draft session))
         (initial-provider (and session (benedict-session-provider session)))
         (initial-model (and session (benedict-session-model session)))
         (initial-usage (and session (benedict-session-last-usage session)))
         (initial-session-info (benedict-vui-root--session-info session))
         (initial-approval (benedict-vui-root--session-approval session))
         (initial-audit-log (and session
                                 (copy-tree
                                  (benedict-harness-audit-log
                                   (benedict-session-harness session))))))
    (vui-batch
      (when initial-conversation
        (vui-set-state :conversation initial-conversation))
      (when initial-streaming
        (vui-set-state :streaming initial-streaming))
      (when initial-provider
        (vui-set-state :provider initial-provider))
      (when initial-model
        (vui-set-state :model initial-model))
      (when initial-usage
        (vui-set-state :usage initial-usage))
      (when initial-session-info
        (vui-set-state :session-info initial-session-info))
      (when initial-approval
        (vui-set-state :approval initial-approval))
      (when initial-audit-log
        (vui-set-state :audit-log initial-audit-log)))
    (when session
      (let ((subscription (benedict-vui-root--subscribe-to-session session)))
        (lambda ()
          (benedict-vui-root--unsubscribe-from-session subscription)))))
  :render
  (let* ((current-usage (or (plist-get --props-- :usage)
                            usage))
         (toggle-block (vui-use-memo ()
                         (vui-async-callback (block-id &optional next)
                           (vui-set-state :collapsed-blocks
                             (lambda (current)
                               (benedict-vui-root--toggle-collapsed-block
                                current block-id next)))))))
    (vui-use-effect (register-actions toggle-block)
      (when register-actions
        (funcall register-actions
                 (list :toggle-block toggle-block)))
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
     (vui-component 'benedict-vui-session-panel
      :session-info session-info
      :collapsed (benedict-vui-root--collapsed-p collapsed-blocks "session-panel")
      :on-toggle (when toggle-block
                   (lambda (next)
                     (funcall toggle-block "session-panel" next))))
     (vui-component 'benedict-vui-checkpoint-block
      :checkpoint checkpoint
      :on-continue on-continue-checkpoint
      :on-stop on-stop-checkpoint)
      (vui-component 'benedict-vui-approval-block
      :approval approval
      :on-approve on-approve-approval
      :on-deny on-deny-approval)
      (vui-component 'benedict-vui-conversation-view
       :conversation conversation
       :streaming streaming
       :collapsed-blocks collapsed-blocks
       :on-toggle-block toggle-block)
     (vui-component 'benedict-vui-audit-log
      :entries audit-log
      :collapsed (benedict-vui-root--collapsed-p collapsed-blocks "audit-panel")
      :on-toggle (when toggle-block
                   (lambda (next)
                     (funcall toggle-block "audit-panel" next))))
     (vui-component 'benedict-vui-status-bar
      :usage current-usage
      :error error))))

(defun benedict-vui-root--subscribe-to-session (session)
  "Subscribe to SESSION events.
Returns a function that when called unsubscribes from events."
  (let ((handler (vui-async-callback (sess event-type payload)
                   (when (eq sess session)
                     (benedict-vui-root--handle-session-event sess event-type payload)))))
    (add-hook 'benedict-session-event-hook handler)
    (lambda ()
      (remove-hook 'benedict-session-event-hook handler))))

(defun benedict-vui-root--unsubscribe-from-session (subscription)
  "Unsubscribe from session events using SUBSCRIPTION function."
  (when subscription
    (funcall subscription)))

(defun benedict-vui-root--handle-session-event (session event-type payload)
  "Handle SESSION EVENT-TYPE with PAYLOAD, updating component state."
  (pcase event-type
    ('message-added
     (let ((entry (plist-get payload :entry)))
       (when entry
         (vui-set-state :conversation
           (lambda (conv)
             (append conv (list entry))))))
     (vui-set-state :session-info (benedict-vui-root--session-info session)))
    ('message-updated
     (when-let ((entry (plist-get payload :entry)))
       (vui-set-state :conversation
                      (lambda (conv)
                        (cl-loop for message in conv
                                 collect (if (equal (benedict-message-id message)
                                                    (benedict-message-id entry))
                                             entry
                                           message))))))
    ('draft-started
     (vui-set-state :streaming
                    (list :status 'active
                          :content ""
                          :thinking nil
                          :tool-calls nil)))
    ('draft-updated
     (let ((delta (plist-get payload :delta))
           (tool-call (plist-get payload :tool-call))
           (streaming-payload (plist-get payload :payload)))
       (if delta
           (vui-set-state :streaming
             (lambda (s)
               (list :status (plist-get s :status)
                     :content (concat (plist-get s :content) delta)
                     :thinking (plist-get s :thinking)
                     :tool-calls (plist-get s :tool-calls))))
         (if tool-call
           (vui-set-state :streaming
             (lambda (s)
               (list :status (plist-get s :status)
                     :content (plist-get s :content)
                     :thinking (plist-get s :thinking)
                     :tool-calls (append (plist-get s :tool-calls)
                                         (list tool-call)))))
           (when (eq (plist-get streaming-payload :kind) 'thinking-delta)
             (vui-set-state :streaming
               (lambda (s)
                 (list :status (plist-get s :status)
                       :content (plist-get s :content)
                       :thinking (concat (or (plist-get s :thinking) "")
                                         (or (plist-get streaming-payload :text) ""))
                       :tool-calls (plist-get s :tool-calls)))))))))
    ('draft-finalized
     (vui-set-state :streaming nil))
    ('checkpoint-requested
     (vui-set-state :checkpoint
                    (list :reason (plist-get payload :reason)
                          :turn-count (plist-get payload :turn-count)
                          :elapsed (plist-get payload :elapsed)
                          :total-tokens (plist-get payload :total-tokens)
                          :limit (plist-get payload :limit))))
    ('approval-requested
     (vui-set-state :approval
                    (or (copy-tree (plist-get payload :yield))
                        (benedict-vui-root--session-approval session)))
     (vui-set-state :session-info (benedict-vui-root--session-info session)))
    ('approval-resolved
     (vui-set-state :approval (benedict-vui-root--session-approval session))
     (vui-set-state :session-info (benedict-vui-root--session-info session)))
    ('yield-created
     (vui-set-state :approval (benedict-vui-root--session-approval session))
     (vui-set-state :session-info (benedict-vui-root--session-info session)))
    ('yield-resolved
     (vui-set-state :approval (benedict-vui-root--session-approval session))
     (vui-set-state :session-info (benedict-vui-root--session-info session)))
    ('tool-audit
     (when-let ((audit (plist-get payload :audit)))
       (vui-set-state :audit-log
                      (lambda (entries)
                        (append entries (list audit))))))
    ('state-changed
     (let ((old-state (plist-get payload :old))
           (new-state (plist-get payload :new))
           (axis (plist-get payload :axis)))
       (vui-set-state :session-info (benedict-vui-root--session-info session))
       (when (and (eq axis 'run)
                  (eq new-state 'error))
         (vui-set-state :error (format "Session error: %s -> %s" old-state new-state)))
       (when (not (eq new-state 'checkpoint))
         (vui-set-state :checkpoint nil))
       (vui-set-state :approval (benedict-vui-root--session-approval session))
       (when (and (eq axis 'run)
                  (memq old-state '(streaming running))
                  (eq new-state 'idle))
         (vui-set-state :error nil))))
    ('session-saved
     (vui-set-state :session-info (benedict-vui-root--session-info session)))
    ('request-completed
     (let ((success (plist-get payload :success))
           (error-payload (plist-get payload :error))
           (result (plist-get payload :result)))
       (vui-set-state :session-info (benedict-vui-root--session-info session))
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
           (vui-set-state :error error-message)))))
    (_ nil)))

(provide 'benedict-vui-root)
;;; benedict-vui-root.el ends here
