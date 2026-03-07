;;; benedict-chat.el --- Chat buffers and commands -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders role-tagged messages, tracks history for retry/copy actions, and
;; dispatches requests through the active Benedict provider.
;;
;; This is the core module that orchestrates the chat buffer view.
;; It subscribes to `benedict-session` events and updates the UI reactively.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'project)
(require 'markdown-mode)
(require 'vui)
(require 'benedict)
(require 'benedict-context)
(require 'benedict-message)
(require 'benedict-tools)
(require 'benedict-flywire)
(require 'benedict-session)
(require 'benedict-vui-root)
(require 'benedict-chat-profiles)
(require 'benedict-chat-status)
(require 'benedict-chat-compose)
(require 'benedict-chat-context-capture)
(require 'benedict-chat-nav)

;;; Mode definition and setup

(defun benedict-chat--extend-region-body-only ()
  "Restrict font-lock to only body regions.
Non-body regions are marked with the `benedict-region-kind' text property.
This function is a member of `font-lock-extend-region-functions', so it
takes no arguments and modifies `font-lock-beg' and `font-lock-end' dynamically."
  (save-excursion
    (save-match-data
      (let ((new-start font-lock-beg)
            (new-end font-lock-end)
            (changed nil))
        ;; If we're not in a body region, don't fontify
        (unless (eq (get-text-property new-start 'benedict-region-kind) 'body)
          (setq new-start (point-max)
                new-end (point-max)
                changed t))

        ;; Move START backward to the beginning of the current body run
        (when (eq (get-text-property new-start 'benedict-region-kind) 'body)
          (goto-char new-start)
          (while (and (> (point) (point-min))
                      (eq (get-text-property (1- (point)) 'benedict-region-kind)
                          'body))
            (backward-char))
          (when (< (point) new-start)
            (setq new-start (point))
            (setq changed t)))

        ;; Move END forward to the end of the current body run
        (when (eq (get-text-property new-end 'benedict-region-kind) 'body)
          (goto-char new-end)
          (while (and (< (point) (point-max))
                      (eq (get-text-property (point) 'benedict-region-kind)
                          'body))
            (forward-char))
          (when (> (point) new-end)
            (setq new-end (point))
            (setq changed t)))

        (when changed
          (setq font-lock-beg new-start
                font-lock-end new-end)
          t)))))

(defun benedict-chat--enable-markdown-fontification-in-body ()
  "Enable `markdown-mode` fontification only in regions marked as `'body."
  ;; Borrow markdown-mode's keywords and syntax propertize function
  (setq-local font-lock-defaults `(markdown-mode-font-lock-keywords
                                   nil nil nil nil
                                   (font-lock-multiline . t)
                                   (font-lock-extend-region-functions . (benedict-chat--extend-region-body-only))))

  (setq-local syntax-propertize-function #'markdown-syntax-propertize)

  ;; Enable native code block fontification
  (setq-local markdown-fontify-code-blocks-natively t))

(defun benedict-chat--setup-common-buffer ()
  "Apply shared buffer settings for Benedict chat modes."
  (setq buffer-read-only t)
  (setq-local word-wrap t)
  (setq-local truncate-lines nil)
  (setq-local benedict-region-kind-property 'benedict-region-kind)
  (benedict-chat--enable-markdown-fontification-in-body))

(defcustom benedict-chat-fringe-bars-enabled t
  "When non-nil, draw role/state bars in the fringe for top-level blocks.
No effect on terminals or when fringes are unavailable."
  :type 'boolean
  :group 'benedict-chat)

;;;###autoload
(define-derived-mode benedict-chat-mode vui-mode "Benedict-Chat"
  "Major mode for Benedict chat buffers."
  (benedict-chat--setup-common-buffer))

(defvar-local benedict-chat--buffer nil
  "Stable reference to the chat buffer.")

(defvar benedict-chat-buffer-name "*Benedict Chat*"
  "Default chat buffer name.")

(defcustom benedict-chat-major-mode #'benedict-chat-mode
  "Major mode constructor used when creating chat buffers."
  :type 'function
  :group 'benedict)

(defvar benedict-chat--model-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'benedict-chat-choose-model)
    (define-key map [header-line mouse-1] #'benedict-chat-choose-model)
    (define-key map [down-mouse-1] #'benedict-chat-choose-model)
    (define-key map (kbd "RET") #'benedict-chat-choose-model)
    map)
  "Keymap for clicking the provider/model display in status lines.")

(defvar benedict-chat-model-history nil
  "Minibuffer history for `benedict-chat-choose-model'.")

;; Buffer-local variables for status UI (managed by benedict-chat-status.el but declared here for context)
(defvar-local benedict-chat--status-spinner-index 0)
(defvar-local benedict-chat--status-timer nil)

(defvar-local benedict-chat--context-slices nil
  "Pending context slices staged for the next user message.")

(defvar-local benedict-chat--compose-buffer nil
  "Compose buffer associated with the current chat, if any.")

(defvar-local benedict-chat--compose-model-override nil
  "Transient model override applied to the next compose send.")

(defvar-local benedict-chat--provider-override nil
  "Buffer-local provider override for the current chat.
When non-nil, this symbol takes precedence over profile :provider and global benedict-provider.")

(defvar-local benedict-chat-profile nil
  "Active profile symbol for the current chat, controls prompt preamble.")

(defvar-local benedict-chat--flywire-session nil
  "Active flywire session for agent tool execution, or nil if inactive.")

(defvar-local benedict-chat--flywire-event-unsubscribe nil
  "Function to unsubscribe from flywire session events.")

(defvar-local benedict-chat--session nil
  "Session object managing this chat buffer's conversation state.
See `benedict-session' for the in-memory session data structure.")

(defvar-local benedict-chat--session-subscription nil
  "Function to call to unsubscribe from session events.")

(defvar-local benedict-chat--vui-actions nil
  "Plist of callbacks registered by the VUI root component.")

(defvar-local benedict-chat--vui-mount nil
  "Handle returned by `vui-mount' for this buffer.")

(defun benedict-chat--vui-register-actions (actions)
  "Register VUI ACTIONS for the current buffer."
  (setq benedict-chat--vui-actions actions))

(defun benedict-chat--vui-call (key &rest args)
  "Invoke VUI action KEY with ARGS when available."
  (when-let ((fn (and (listp benedict-chat--vui-actions)
                      (plist-get benedict-chat--vui-actions key))))
    (apply fn args)))

(defun benedict-chat--set-context-slices (slices)
  "Set chat context SLICES."
  (setq benedict-chat--context-slices slices))

(defun benedict-chat--mount-ui ()
  "Mount the VUI root component for the current buffer."
  (when (and benedict-chat--vui-mount
             (fboundp 'vui-unmount))
    (ignore-errors
      (vui-unmount benedict-chat--vui-mount)))
  (let ((inhibit-read-only t))
    (erase-buffer))
  (setq benedict-chat--vui-mount
        (vui-mount
         (vui-component 'benedict-vui-root
           :session benedict-chat--session
           :register-actions #'benedict-chat--vui-register-actions
           :on-provider-click #'benedict-chat-choose-model)
          (buffer-name))))

;; -------------------------------------------------------------------
;; Flywire Session Management

(defun benedict-chat--flywire-handle-event (event)
  "Handle EVENT from the flywire session.
This function is called for each event emitted by the active session."
  (let ((type (plist-get event :type)))
    (pcase type
      (:minibuffer-open
       (let ((prompt (plist-get event :prompt)))
         (when prompt
           (message "Benedict agent: %s" (string-trim prompt)))))
      (:idle
       nil))))

(defun benedict-chat--flywire-ensure-session ()
  "Ensure a flywire session exists for the current chat buffer.
Creates a new session if needed and `benedict-chat-use-agent-frame' is non-nil.
Returns the session or nil if agent frame is disabled."
  (when benedict-chat-use-agent-frame
    (unless benedict-chat--flywire-session
      (let ((session (benedict-flywire-session-create)))
        (setq benedict-chat--flywire-session session)
        (setq benedict-chat--flywire-event-unsubscribe
              (benedict-flywire-session-on-event
               session
               #'benedict-chat--flywire-handle-event))
        (benedict-flywire-session-enable-events session)))
    benedict-chat--flywire-session))

(defun benedict-chat--flywire-teardown-session ()
  "Tear down the flywire session for the current chat buffer."
  (when benedict-chat--flywire-event-unsubscribe
    (funcall benedict-chat--flywire-event-unsubscribe)
    (setq benedict-chat--flywire-event-unsubscribe nil))
  (when benedict-chat--flywire-session
    (benedict-flywire-session-teardown benedict-chat--flywire-session)
    (setq benedict-chat--flywire-session nil)))

(defun benedict-chat-flywire-session ()
  "Return the active flywire session for the current chat, or nil."
  benedict-chat--flywire-session)

(defun benedict-chat-flywire-active-p ()
  "Return non-nil if a flywire session is active for this chat."
  (and benedict-chat--flywire-session t))

;; -------------------------------------------------------------------
;; Profiles and configuration

(defun benedict-chat--resolve-chat-buffer ()
  "Return the active chat buffer associated with the current context."
  (cond
   ((derived-mode-p 'benedict-chat-mode)
    (let ((buffer (or benedict-chat--buffer (current-buffer))))
      (when (buffer-live-p buffer)
        buffer)))
   ((and (boundp 'benedict-chat-compose--chat-buffer)
         (buffer-live-p benedict-chat-compose--chat-buffer))
    (with-current-buffer benedict-chat-compose--chat-buffer
      (let ((buffer (or benedict-chat--buffer benedict-chat-compose--chat-buffer)))
        (when (buffer-live-p buffer)
          buffer))))
   (t nil)))

(defun benedict-chat-choose-profile ()
  "Select an active profile for the current chat."
  (interactive)
  (let* ((chat (or (benedict-chat--resolve-chat-buffer)
                   (user-error "Not in a Benedict chat or compose buffer")))
         (candidates (mapcar (lambda (entry)
                               (cons (symbol-name (car entry)) (car entry)))
                             benedict-chat-profiles))
         (current (with-current-buffer chat
                    (or benedict-chat-profile (benedict-chat-profiles--default-profile))))
         (choice (completing-read
                  "Profile: "
                  candidates nil t nil nil (symbol-name current))))
    (with-current-buffer chat
      (setq benedict-chat-profile (cdr (assoc choice candidates)))
      (benedict-chat--configure-session)
      (benedict-chat--mount-ui)
      (benedict-chat-status--status-refresh)
      (benedict-chat-compose--refresh-header))
    (message "Benedict profile set to %s" (benedict-chat-profiles--profile-label (cdr (assoc choice candidates))))))

(defun benedict-chat-choose-provider ()
 "Select an active provider for the current chat."
 (interactive)
 (let* ((chat (or (benedict-chat--resolve-chat-buffer)
               (user-error "Not in a Benedict chat or compose buffer")))
        (available-ids (benedict-provider-list-ids))
        (candidates (mapcar (lambda (id)
                              (cons (or (benedict-provider-display-name id)
                                      (symbol-name id))
                                    id))
                            available-ids))
        (current (with-current-buffer chat
                   (benedict-chat-profiles--resolve-provider)))
        (current-name (or (benedict-provider-display-name current)
                         (symbol-name current)))
        (choice (completing-read
                 "Provider: "
                 candidates nil t nil nil current-name)))
  (with-current-buffer chat
   (setq benedict-chat--provider-override (cdr (assoc choice candidates)))
   (benedict-chat--configure-session)
   (benedict-chat--mount-ui)
   (benedict-chat-status--status-refresh)
   (benedict-chat-compose--refresh-header))
  (message "Benedict provider set to %s" (or (benedict-provider-display-name (cdr (assoc choice candidates)))
                                            (symbol-name (cdr (assoc choice candidates)))))))

(defun benedict-chat-choose-model ()
  "Prompt for a model override scoped to the current chat compose buffer."
  (interactive)
  (let* ((chat (or (benedict-chat--resolve-chat-buffer)
                   (user-error "Not in a Benedict chat or compose buffer")))
         (profile (with-current-buffer chat (benedict-chat-profiles--effective-profile)))
         (provider (with-current-buffer chat
                     (benedict-chat-profiles--resolve-provider profile)))
         (current (with-current-buffer chat
                    (benedict-chat-profiles--resolve-model
                     provider profile benedict-chat--compose-model-override)))
         (prompt (format "Model for %s (erase to clear override): "
                         (benedict-chat-profiles--provider-label provider)))
         (input (read-string prompt nil 'benedict-chat-model-history current))
         (selection (string-trim input)))
    (with-current-buffer chat
      (setq benedict-chat--compose-model-override
            (unless (string-empty-p selection) selection))
      (benedict-chat--configure-session)
      (benedict-chat--mount-ui)
      (benedict-chat-status--status-refresh)
      (benedict-chat-compose--refresh-header))
    (if (string-empty-p selection)
        (message "Benedict: cleared compose model override")
      (message "Benedict: model override set to %s" selection))))

(defun benedict-chat--configure-session ()
  "Configure the session with current buffer settings."
  (when-let ((session benedict-chat--session))
    (let* ((profile (benedict-chat-profiles--effective-profile))
           (provider (benedict-chat-profiles--resolve-provider profile))
           (model (benedict-chat-profiles--resolve-model
                   provider profile benedict-chat--compose-model-override))
           (tools (benedict-chat-profiles--resolve-tools profile))
           (system (benedict-chat-profiles--system-messages profile))
           (autonomy (benedict-chat-profiles--profile-autonomy profile))
           (verbosity (benedict-chat-profiles--profile-verbosity profile))
           (loop-config (list :max-turns (benedict-chat-profiles--effective-limit
                                          :max-turns benedict-chat-loop-checkpoint-interval)
                              :max-time (benedict-chat-profiles--effective-limit
                                         :max-time benedict-chat-loop-max-time)
                              :max-tokens (benedict-chat-profiles--effective-limit
                                           :max-tokens benedict-chat-loop-max-tokens))))
      (benedict-session-configure session
                                  :provider provider
                                  :model model
                                  :profile profile
                                  :tools tools
                                  :system-prompt system
                                  :autonomy autonomy
                                  :verbosity verbosity
                                  :loop-config loop-config))))

(defun benedict-chat--ensure-not-busy ()
  "Signal an error when a provider request is already running."
  (when (and benedict-chat--session
             (benedict-session-busy-p benedict-chat--session))
    (user-error "A provider request is already in flight")))

(defun benedict-chat--apply-request-result-extras (buffer result)
  "Apply RESULT metadata updates for the current session in BUFFER."
  (with-current-buffer buffer
    (let* ((session benedict-chat--session)
           (message (and session (benedict-chat-nav--find-last-assistant)))
           (message-metadata (and message (benedict-message-metadata message)))
           (provider (or (plist-get result :provider)
                         (and session (benedict-session-provider session))
                         (benedict-chat-profiles--resolve-provider)))
           (model (or (plist-get result :model)
                      (and session (benedict-session-model session))))
           (metadata (or message-metadata
                         (list :provider provider
                               :model model
                               :latency (plist-get result :latency)
                               :usage (plist-get result :usage))))
           (thinking (plist-get result :thinking))
           (empty-response (plist-get result :empty-response)))
      (when message
        (let ((updated (copy-sequence metadata)))
          (when empty-response
            (setq updated (plist-put updated :empty-response t)))
          (let ((updates (list :metadata updated)))
            (when thinking
              (setq updates (plist-put updates :thinking thinking)))
            (when (and empty-response
                       (string-empty-p (or (benedict-message-text message) "")))
              (let ((display (if thinking
                                 "Response finished with reasoning only; no assistant message."
                               "Response finished without assistant text.")))
                (setq updates (plist-put updates :content display))))
            (benedict-session-update-message
             session
             (benedict-message-id message)
             updates)))))))

(defun benedict-chat-send-prompt (text)
  "Send TEXT to the provider and insert the assistant reply."
  (interactive (list (read-string "Prompt: ")))
  (benedict-chat--send-text text))

(defun benedict-chat--send-text (text &optional buffer skip-context)
  "Send TEXT to provider via SESSION using BUFFER when supplied.
When SKIP-CONTEXT is non-nil, do not append context slices."
  (let ((chat (or buffer (benedict-chat--resolve-chat-buffer))))
    (unless (and chat (buffer-live-p chat))
      (user-error "Not in a Benedict chat buffer"))
    (with-current-buffer chat
      (unless (derived-mode-p 'benedict-chat-mode)
        (user-error "Not in a Benedict chat buffer"))
      (when (string-blank-p text)
        (user-error "Prompt is empty"))
      (let ((session benedict-chat--session))
        (unless session
          (user-error "No session attached"))
        (when (benedict-session-busy-p session)
          (user-error "A provider request is already in flight"))
        ;; Add user message to session
        (let* ((final (if (and benedict-chat--context-slices (not skip-context))
                          (benedict-chat-compose--assemble-message-text
                           text benedict-chat--context-slices)
                        text)))
          (benedict-session-add-message session
                                        (benedict-message-user-text final)))
        (when (and benedict-chat--context-slices
                   (not benedict-chat-context-retain-after-send))
          (benedict-chat--set-context-slices nil))
        ;; Configure and run session
        (benedict-chat--configure-session)
        (benedict-session-run session)
        t))))

(defun benedict-chat--ensure-chat-buffer ()
  "Return the active Benedict chat buffer, creating one if needed."
  (or (and (derived-mode-p 'benedict-chat-mode)
           (current-buffer))
      (get-buffer benedict-chat-buffer-name)
      (progn
        (benedict-chat)
        (get-buffer benedict-chat-buffer-name))
      (user-error "Not in a Benedict chat buffer")))

(defvar benedict-chat--base-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'benedict-chat-compose-open)
    (define-key m (kbd "C-c C-s") #'benedict-chat-send-prompt)
    (define-key m (kbd "g l") #'benedict-chat-nav-jump-to-latest)
    (define-key m (kbd "g a") #'benedict-chat-nav-jump-to-last-assistant)
    (define-key m (kbd "g A") #'benedict-chat-nav-jump-to-last-assistant-with-tools)
    (define-key m (kbd "g r") #'benedict-chat-nav-retry-last)
    (define-key m (kbd "w") #'benedict-chat-nav-copy-last-response)
    (define-key m (kbd "] t") #'benedict-chat-nav-next-tool)
    (define-key m (kbd "[ t") #'benedict-chat-nav-previous-tool)
    (define-key m (kbd "] f") #'benedict-chat-nav-next-tool-failure)
    (define-key m (kbd "[ f") #'benedict-chat-nav-previous-tool-failure)
    (define-key m (kbd "] e") #'benedict-chat-nav-next-error)
    (define-key m (kbd "[ e") #'benedict-chat-nav-previous-error)
    (define-key m (kbd "] h") #'benedict-chat-nav-next-thinking)
    (define-key m (kbd "[ h") #'benedict-chat-nav-previous-thinking)
    (define-key m (kbd "s") #'benedict-chat-nav-toggle-thinking)
    (define-key m (kbd "C-c C-k") #'benedict-chat-cancel)
    m)
  "Base keymap for `benedict-chat-mode'.")

(defvar benedict-chat-mode-map
  (make-composed-keymap
   (list benedict-chat--base-mode-map)
   vui-mode-map)
  "Keymap for `benedict-chat-mode'.")

(defun benedict-chat-cancel ()
  "Cancel the current autonomous loop or in-flight request."
  (interactive)
  (benedict-chat-status--status-stop-timer)
  (when (and benedict-chat--session
             (benedict-session-request-active-p benedict-chat--session))
    (let ((handle (plist-get (benedict-session-inflight benedict-chat--session) :request)))
      (when handle
        (benedict-provider-abort handle)))
    (benedict-session-cancel benedict-chat--session))
  (when (and benedict-chat--session
             (memq (benedict-session-state benedict-chat--session)
                   '(running checkpoint)))
    (benedict-session-stop benedict-chat--session))
  (message "Benedict: loop/request canceled by user"))

;;; Session Event Subscription

(defun benedict-chat--subscribe-to-session (session)
  "Subscribe current buffer to SESSION events.
Returns a function suitable for adding to `benedict-session-event-hook'."
  (let ((buffer (current-buffer)))
    (lambda (sess event-type payload)
      (when (and (eq sess session)
                 (buffer-live-p buffer))
        (with-current-buffer buffer
          (benedict-chat--handle-session-event event-type payload))))))

(defun benedict-chat--unsubscribe-from-session ()
  "Unsubscribe current buffer from session events."
  (when benedict-chat--session-subscription
    (remove-hook 'benedict-session-event-hook
                 benedict-chat--session-subscription)
    (setq benedict-chat--session-subscription nil)))

(defun benedict-chat--handle-session-event (event-type payload)
  "Dispatch session EVENT-TYPE with PAYLOAD to appropriate handler."
  (pcase event-type
    ('state-changed
     (benedict-chat--observe-state-changed
      (plist-get payload :old) (plist-get payload :new)))
    ('checkpoint-requested
     (when-let ((session benedict-chat--session))
       (let* ((reason (plist-get payload :reason))
              (prompt (pcase reason
                        ('turn-limit
                         (format "Benedict has run %d autonomous steps. Continue? "
                                 (plist-get payload :turn-count)))
                        ('time-limit
                         (format "Time limit (%.1fs) reached. Continue? "
                                 (plist-get payload :limit)))
                        ('token-limit
                         (format "Token limit (%d) exceeded. Continue? "
                                 (plist-get payload :limit)))
                        (_ "Continue autonomous loop? "))))
         (if (y-or-n-p prompt)
             (benedict-session-continue session)
           (benedict-session-stop session)))))
    ('request-completed
     (benedict-chat--observe-request-completed payload))
    ('loop-stopped
     (message "Benedict: loop stopped (%s)" (plist-get payload :reason)))
    ('dispatch-needed
     (message "Benedict: cannot dispatch - provider or model not configured"))
    ('destroyed
     (benedict-chat--observe-session-destroyed))))

;; Observer functions

(defun benedict-chat--dispatching-current-request-p (session)
  "Return non-nil when current buffer initiated SESSION's active request."
  (let ((inflight (and session (benedict-session-inflight session))))
    ;; With no benedict-chat--last-dispatch, we assume any session update
    ;; is relevant to the view. The view tracks session state directly.
    inflight))

(defun benedict-chat--observe-state-changed (old-state new-state)
  "Handle session state transition from OLD-STATE to NEW-STATE."
  (pcase new-state
    ('idle
     (benedict-chat-status--status-reset)
     (benedict-chat-status--status-stop-timer))
    ('streaming
     (benedict-chat-status--status-reset)
     (benedict-chat-status--status-start-timer))
    ('error
     (benedict-chat-status--status-reset)
     (benedict-chat-status--status-stop-timer))
    ('cancelled
     (benedict-chat-status--status-reset)
     (benedict-chat-status--status-stop-timer)))
  ;; Refresh header line
  (force-mode-line-update))

(defun benedict-chat--observe-request-completed (payload)
  "Handle request completion using PAYLOAD."
  (when (plist-get payload :success)
    (when-let ((result (plist-get payload :result)))
      (benedict-chat--apply-request-result-extras (current-buffer) result))))

(defun benedict-chat--observe-session-destroyed ()
  "Handle session destruction.
When the session is destroyed, the buffer becomes orphaned."
  ;; For now, just detach the session reference.
  ;; The buffer remains open but can no longer interact with the session.
  (setq benedict-chat--session nil))

(defun benedict-chat--detach-session ()
  "Detach the current buffer from its session.
The session persists independently and can be reattached later."
  (when benedict-chat--session
    (benedict-chat--unsubscribe-from-session)
    (benedict-session--remove-frontend benedict-chat--session (current-buffer))))

(defun benedict-chat--init-buffer (&optional session)
  "Initialize buffer-local state for Benedict chat.
When SESSION is non-nil, attach to it instead of creating a new one."
  (setq benedict-session-tool-invoke-fn #'benedict-tool-invoke)
  (setq-local benedict-chat--buffer (current-buffer))
  (setq-local benedict-chat--context-slices nil)
  (setq-local benedict-chat--compose-buffer nil)
  (setq-local benedict-chat--provider-override nil)
  (setq-local benedict-chat--flywire-session nil)
  (setq-local benedict-chat--flywire-event-unsubscribe nil)
  (setq-local benedict-chat--vui-actions nil)
  (setq-local benedict-chat--vui-mount nil)
  (setq-local benedict-chat-profile (or benedict-chat-profile
                                        (benedict-chat-profiles--default-profile)))
  (let* ((profile benedict-chat-profile)
         (provider (benedict-chat-profiles--resolve-provider profile))
         (model (benedict-chat-profiles--resolve-model
                 provider profile benedict-chat--compose-model-override))
         (existing-session (and (benedict-session-p session) session)))
    ;; Create and attach session if needed.
    (setq-local benedict-chat--session
                (or existing-session
                    (benedict-session-create
                     :title (buffer-name)
                     :profile profile
                     :provider provider
                     :model model
                     :root (when (project-current)
                             (project-root (project-current)))))))
  (unless (and session (benedict-session-p session))
    (benedict-chat--configure-session))
  (benedict-session--add-frontend benedict-chat--session (current-buffer))
  ;; Subscribe to session events
  (setq-local benedict-chat--session-subscription
              (benedict-chat--subscribe-to-session benedict-chat--session))
  (add-hook 'benedict-session-event-hook
            benedict-chat--session-subscription)
  (setq-local header-line-format nil)
  (visual-line-mode 1)
  (benedict-chat-status--status-reset)
  (add-hook 'kill-buffer-hook #'benedict-chat--flywire-teardown-session nil t)
  (add-hook 'kill-buffer-hook #'benedict-chat--detach-session nil t)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when (and benedict-chat--vui-mount
                         (fboundp 'vui-unmount))
                (ignore-errors
                  (vui-unmount benedict-chat--vui-mount))))
            nil t)
  (add-hook 'kill-buffer-hook
            (lambda () (when (buffer-live-p benedict-chat--compose-buffer) (kill-buffer benedict-chat--compose-buffer)))
            nil t)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (benedict-chat--mount-ui))

(defun benedict-chat--session-annotation (session)
  "Return annotation string for SESSION completion.
Includes title, state, and message count."
  (let ((title (or (benedict-session-title session) "Untitled"))
        (state (benedict-session-state session))
        (msg-count (length (benedict-session-entries session))))
    (format "%s [%s] - %d messages" title state msg-count)))

(defun benedict-chat--buffer-for-session (session)
  "Return existing buffer for SESSION, or create and initialize one.
Buffers are keyed by session ID in the buffer name."
  (unless (benedict-session-p session)
    (error "Not a valid session: %s" session))
  ;; Check if any existing buffer is already attached to this session
  (let ((existing (cl-find-if (lambda (buf)
                                (and (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (and (bound-and-true-p benedict-chat--session)
                                            (eq benedict-chat--session session)))))
                              (buffer-list))))
    (if existing
        existing
      ;; Create new buffer for this session
       (let* ((session-id (benedict-session-id session))
              (buf-name (format "*Benedict Chat [%s]*" session-id))
              (buf (get-buffer-create buf-name)))
        (with-current-buffer buf
          (unless (derived-mode-p 'benedict-chat-mode)
            (let ((mode (or benedict-chat-major-mode #'benedict-chat-mode)))
              (unless (fboundp mode)
                (setq mode #'benedict-chat-mode))
              (funcall mode)
              (benedict-chat--init-buffer session))))
        buf))))

(defun benedict-chat--sync-from-session (session)
  "Synchronize buffer state from SESSION.
Renders messages and current streaming draft."
  (when (benedict-session-p session)
    (setq benedict-chat--session session)
    (benedict-chat--mount-ui)))

(defun benedict-chat--render-session-history (session)
  "Render SESSION's message history into current buffer.
Assumes buffer is already in benedict-chat-mode with session attached."
  (benedict-chat--sync-from-session session))

;;;###autoload
(defun benedict-chat (&optional prefix)
  "Open or switch to Benedict chat buffer.
With PREFIX argument, always create a new session.
When multiple sessions exist, prompt for which one to open."
  (interactive "P")
  (let ((sessions (benedict-session-list)))
    (cond
     ;; Prefix arg: always create new session
     (prefix
      (let ((buf (get-buffer-create benedict-chat-buffer-name)))
        (pop-to-buffer buf)
        (with-current-buffer buf
          (unless (derived-mode-p 'benedict-chat-mode)
            (let ((mode (or benedict-chat-major-mode #'benedict-chat-mode)))
              (unless (fboundp mode)
                (setq mode #'benedict-chat-mode))
              (funcall mode)
              (benedict-chat--init-buffer))))))

     ;; No sessions: normal initialization (creates session)
     ((null sessions)
      (let ((buf (get-buffer-create benedict-chat-buffer-name)))
        (pop-to-buffer buf)
        (with-current-buffer buf
          (unless (derived-mode-p 'benedict-chat-mode)
            (let ((mode (or benedict-chat-major-mode #'benedict-chat-mode)))
              (unless (fboundp mode)
                (setq mode #'benedict-chat-mode))
              (funcall mode)
              (benedict-chat--init-buffer))))))

     ;; One session: open it directly
     ((= (length sessions) 1)
      (let ((buf (benedict-chat--buffer-for-session (car sessions))))
        (pop-to-buffer buf)))

     ;; Multiple sessions: prompt with completion (or pick most recent in noninteractive)
     (t
      (let* ((session-strings
              (mapcar (lambda (s)
                        (cons (benedict-chat--session-annotation s) s))
                      sessions))
             (selected
              (if noninteractive
                  ;; In noninteractive mode, pick most recent session (first from sorted list)
                  (benedict-chat--session-annotation (car sessions))
                (completing-read "Select session: "
                                 session-strings
                                 nil t nil nil
                                 (benedict-chat--session-annotation (car sessions))))))
        (when-let ((session (cdr (assoc selected session-strings :test #'equal))))
          (let ((buf (benedict-chat--buffer-for-session session)))
            (pop-to-buffer buf))))))
  (message "Type C-c C-c to compose, C-c C-s to prompt, g r retries, w copies last response.")))

(provide 'benedict-chat)
;;; benedict-chat.el ends here
