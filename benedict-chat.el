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
(require 'magit-section)
(require 'markdown-mode)
(require 'benedict)
(require 'benedict-context)
(require 'benedict-tools)
(require 'benedict-flywire)
(require 'benedict-session)
(require 'benedict-chat-render)
(require 'benedict-chat-sections)
(require 'benedict-chat-profiles)
(require 'benedict-chat-status)
(require 'benedict-chat-stream)
(require 'benedict-chat-tool-ui)
(require 'benedict-chat-thinking)
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

;;; Section Classes and UI Helpers

(defvar-local benedict-chat--conversation-section nil
  "Conversation root section for the current chat buffer.

All UI sections are inserted under this stable parent to avoid ad-hoc
root sections when streaming inserts append later.")

(defvar-local benedict-chat--current-turn-section nil
  "Most recent turn section in the current chat buffer.

Turn sections group user and assistant blocks for stable navigation and
folding semantics in the UI renderer.")

;;;###autoload
(define-derived-mode benedict-chat-mode magit-section-mode "Benedict-Chat"
  "Major mode for Benedict chat buffers."
  (benedict-chat--setup-common-buffer))

(defvar-local benedict-chat--buffer nil
  "Stable reference to the chat buffer.")

(defvar-local benedict-chat--items nil
  "Ordered list of rendered chat items (oldest first).")

(defvar-local benedict-chat--item-counter 0
  "Monotonic counter used to generate unique item identifiers.")

(defvar-local benedict-chat--thinking-items nil
  "Hash table mapping reasoning/think identifiers to chat items.")

(defvar-local benedict-chat--streaming-message nil
  "Plist describing the in-progress streaming assistant message.")

(defvar-local benedict-chat--thinking-temp-counter 0
  "Per-request counter for synthesizing thinking identifiers when absent.")

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
   (benedict-chat-status--status-refresh)
   (benedict-chat-compose--refresh-header))
  (message "Benedict provider set to %s" (or (benedict-provider-display-name (cdr (assoc choice candidates)))
                                            (symbol-name (cdr (assoc choice candidates)))))))

;; -------------------------------------------------------------------
;; Internal helpers for block items

(defun benedict-chat--next-item-id ()
  "Return a fresh identifier for chat items."
  (setq benedict-chat--item-counter (1+ benedict-chat--item-counter)))

(defun benedict-chat--make-item (kind &rest properties)
  "Create a new chat item plist of KIND with PROPERTIES."
  (let ((item (list :id (benedict-chat--next-item-id)
                    :kind kind
                    :section nil)))
    (while properties
      (let ((key (pop properties))
            (value (pop properties)))
        (setq item (plist-put item key value))))
    item))

(defun benedict-chat--ensure-message-kind (message)
  "Ensure MESSAGE plist carries a :kind field (defaults to `message')."
  (cond
   ((null message) nil)
   ((plist-member message :kind) message)
   (t (plist-put message :kind 'message))))

(defun benedict-chat--track-item (item)
  "Append ITEM to `benedict-chat--items' maintaining chronological order."
  (setq benedict-chat--items (append benedict-chat--items (list item)))
  item)

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
      (benedict-chat-status--status-refresh)
      (benedict-chat-compose--refresh-header))
    (if (string-empty-p selection)
        (message "Benedict: cleared compose model override")
      (message "Benedict: model override set to %s" selection))))

;; -------------------------------------------------------------------
;; Message Rendering

(defun benedict-chat--refresh-message-header (item)
  "Refresh ITEM's header text based on current message metadata."
  (when-let ((message (plist-get item :message)))
    (let ((in-flight (and (benedict-chat-status--status-active-p)
                          benedict-chat--streaming-message
                          (eq (plist-get benedict-chat--streaming-message :message) message))))
      (save-excursion
        (benedict-chat--update-message-header
         item
         (benedict-chat-render--message-header-string message nil)))
      (when-let ((end (plist-get item :content-end)))
        (when (markerp end)
          (goto-char (marker-position end)))))))

(defun benedict-chat--replace-message-content (buffer message content)
  "Replace MESSAGE content in BUFFER with CONTENT."
  (with-current-buffer buffer
    (when-let ((item (plist-get message :item)))
      (benedict-chat-render--set-item-content item content 'body))))

(defvar-local benedict-chat--has-rendered-block nil
  "Non-nil once a message/tool block has been rendered in this chat buffer.")

(defun benedict-chat--maybe-insert-item-gap (buffer &optional pos)
  "Insert a blank line in BUFFER before rendering the next chat block.

This keeps message/tool blocks visually separated while remaining compatible
with marker-backed streaming inserts."
  (with-current-buffer buffer
    (when benedict-chat--has-rendered-block
      (let ((inhibit-read-only t))
        (goto-char (or pos (point-max)))
        ;; Ensure the conversation root's end marker advances when we insert the gap
        (when-let ((root benedict-chat--conversation-section))
          (when-let ((root-end (ignore-errors (oref root end))))
            (when (markerp root-end)
              (set-marker-insertion-type root-end t))))
        (let* ((end (point))
               (start (save-excursion
                        (skip-chars-backward "\n")
                        (point)))
               (trailing-newlines (- end start))
               (needed (max 0 (- 2 trailing-newlines))))
          (when (> needed 0)
            (insert (propertize (make-string needed ?\n) 'benedict-region-kind 'header))))))))

(defun benedict-chat--metadata (&rest pairs)
  "Build a metadata plist from PAIRS ignoring nil values."
  (let (metadata)
    (while pairs
      (let ((key (pop pairs))
            (value (pop pairs)))
        (when value
          (setq metadata (plist-put metadata key value)))))
    metadata))

(defun benedict-chat--record-message (buffer message)
  "Persist MESSAGE in session and render it.
For user messages, adds to session (observer renders via message-added event).
For assistant messages during streaming, renders directly (streaming UI)."
  (with-current-buffer buffer
    (setq message (benedict-chat--ensure-message-kind message))
    (let ((role (plist-get message :role))
          (streaming-p (and benedict-chat--session
                            (eq (benedict-session-state benedict-chat--session) 'streaming)))
          (added-to-session nil))
      ;; For user messages (and non-streaming assistant), add to session.
      ;; The session-event observer will render them.
      (when benedict-chat--session
        (unless (and (memq role '(assistant Assistant)) streaming-p)
          (benedict-session-add-message benedict-chat--session message)
          (setq added-to-session t)))
      ;; For streaming assistant messages, render directly here.
      ;; These are not added to session (draft handles it).
      (unless added-to-session
        (benedict-chat--render-message buffer message))))
  message)

(defun benedict-chat--render-message (buffer message)
  "Render MESSAGE into BUFFER.
Assistant messages are rendered as marker-backed items."
  (with-current-buffer buffer
    (setq message (benedict-chat--ensure-message-kind message))
    (let* ((role (benedict-chat-render--normalize-role (plist-get message :role)))
           (metadata (plist-get message :metadata))
           (content (or (plist-get message :display-content)
                        (plist-get message :content)
                        ""))
           (inhibit-read-only t))
      (goto-char (point-max))
      (benedict-chat--maybe-insert-item-gap buffer)
      (pcase role
        ('assistant
         (let* ((item (benedict-chat--make-item
                       'message
                       :role role
                       :metadata metadata
                       :message message)))
           (plist-put message :item item)
           (benedict-chat--track-item item)
           (benedict-chat-sections--with item
             (benedict-chat--render-message-item
              buffer
              item
              (benedict-chat-render--message-header-string message nil)
              content))
           (setq benedict-chat--has-rendered-block t)
           item))
        (_
         (when (eq role 'user)
           (benedict-chat-sections--begin-turn))
         (benedict-chat-sections--with message
           (benedict-chat--insert-message message))
         (setq benedict-chat--has-rendered-block t)
         nil)))))

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
  "Render RESULT metadata that is not represented in session messages."
  (with-current-buffer buffer
    (let* ((session benedict-chat--session)
           (message (and session (benedict-chat-nav--find-last-assistant)))
           (message-metadata (and message (plist-get message :metadata)))
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
      (when (and empty-response message)
        (let* ((content (or (plist-get message :content) ""))
               (display (if thinking
                            "Response finished with reasoning only; no assistant message."
                          "Response finished without assistant text."))
               (updated (plist-put (copy-sequence metadata) :empty-response t)))
          (when (string-empty-p content)
            (plist-put message :display-content display)
            (plist-put message :metadata updated)
            (when-let ((item (plist-get message :item)))
              (plist-put item :metadata updated)
              (benedict-chat--replace-message-content buffer message display)
              (benedict-chat--refresh-message-header item))))
      (when-let ((details (benedict-chat-thinking--normalize-payload thinking)))
        (let ((first-id (benedict-chat-thinking--stream-id)))
          (dolist (detail details)
            (let ((detail (copy-sequence detail)))
              (when (and first-id (not (plist-get detail :id)))
                (plist-put detail :id first-id)
                (setq first-id nil))
              (benedict-chat-thinking--display-detail
               buffer detail (or metadata (list)))))))))))

(defun benedict-chat-send-prompt (text)
  "Send TEXT to the provider and insert the assistant reply."
  (interactive (list (read-string "Prompt: ")))
  (benedict-chat--send-text text))

(defun benedict-chat--send-text (text &optional buffer)
  "Send TEXT to provider via SESSION."
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
        ;; Reset UI state
        (setq benedict-chat--thinking-temp-counter 0)
        (benedict-chat-stream--reset chat)
        (benedict-chat-status--status-reset)
        (benedict-chat-status--status-start-timer)
        ;; Add user message to session
        (benedict-session-add-message session
                                      (list :role 'user :content text :time (current-time)))
        ;; Configure and run session
        (benedict-chat--configure-session)
        (benedict-session-run session)))))

(defun benedict-chat--ensure-chat-buffer ()
  "Return the active Benedict chat buffer, creating one if needed."
  (or (and (derived-mode-p 'benedict-chat-mode)
           (current-buffer))
      (get-buffer benedict-chat-buffer-name)
      (progn
        (benedict-chat)
        (get-buffer benedict-chat-buffer-name))
      (user-error "Not in a Benedict chat buffer")))

(defvar benedict-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m magit-section-mode-map)
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
    ('request-started
     (benedict-chat-status--status-reset)
     (benedict-chat-status--status-start-timer)
     (benedict-chat-status--status-refresh))
    ('message-added
     (benedict-chat--observe-message-added (plist-get payload :message)))
    ('draft-started
     (benedict-chat--observe-draft-started))
    ('draft-updated
     (benedict-chat--observe-draft-updated payload))
    ('draft-finalized
     (benedict-chat--observe-draft-finalized payload))
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
    ('tool-started
     (when-let ((session benedict-chat--session)
                (tool-call (plist-get payload :tool-call)))
       (let* ((tool-id (benedict-chat-tool-ui--normalize-id
                        (or (plist-get payload :tool-id)
                            (plist-get tool-call :name)
                            (plist-get tool-call :tool))))
              (normalized (plist-put (copy-sequence tool-call) :name tool-id))
              (metadata (benedict-chat-tool-ui--call-metadata
                         tool-id normalized 'in-progress
                         (list :provider (benedict-session-provider session)
                               :model (benedict-session-model session)))))
         (benedict-chat-tool-ui--record-block (current-buffer) normalized metadata))))
    ('tool-completed
     (when-let ((session benedict-chat--session)
                (tool-call (plist-get payload :tool-call)))
       (let* ((tool-id (benedict-chat-tool-ui--normalize-id
                        (or (plist-get payload :tool-id)
                            (plist-get tool-call :name)
                            (plist-get tool-call :tool))))
              (normalized (plist-put (copy-sequence tool-call) :name tool-id))
              (status (plist-get payload :status))
              (error-info (plist-get payload :error))
              (raw-output (plist-get payload :output))
              (output (if (and error-info (null raw-output))
                          (format "Tool error: %s" (plist-get error-info :message))
                        raw-output))
              (normalized-output (benedict-chat-tool-ui--normalize-output output))
              (text (plist-get normalized-output :text))
              (ui (plist-get normalized-output :ui))
              (raw (plist-get normalized-output :raw))
              (metadata (benedict-chat-tool-ui--call-metadata
                         tool-id normalized status
                         (list :provider (benedict-session-provider session)
                               :model (benedict-session-model session))))
              (call-id (plist-get normalized :id))
              (item (benedict-chat-tool-ui--find-item call-id)))
         (when (and (memq status '(failure error)) error-info)
           (plist-put metadata :error error-info))
         (when raw
           (plist-put metadata :raw raw))
         (if item
             (benedict-chat-tool-ui--update-block
              (current-buffer) item metadata ui
              (benedict-chat-tool-ui--result-content normalized text))
           (let ((new-item (benedict-chat-tool-ui--record-block
                            (current-buffer) normalized metadata ui)))
             (when new-item
               (benedict-chat-tool-ui--update-block
                (current-buffer) new-item metadata ui
                (benedict-chat-tool-ui--result-content normalized text))))))))
    ('request-completed
     (benedict-chat--observe-request-completed payload))
    ('loop-stopped
     (message "Benedict: loop stopped (%s)" (plist-get payload :reason)))
    ('dispatch-needed
     (benedict-chat-status--status-stop-timer)
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

(defun benedict-chat--draft-payload (session)
  "Return a payload plist for rendering SESSION's draft."
  (list :provider (benedict-session-provider session)
        :model (benedict-session-model session)))

(defun benedict-chat--apply-draft-snapshot (session draft)
  "Render DRAFT snapshot for SESSION into the current buffer."
  (let ((payload (benedict-chat--draft-payload session)))
    (benedict-chat-stream--reset (current-buffer))
    (benedict-chat-stream--ensure-message (current-buffer) payload)
    (let ((content (or (plist-get draft :content) "")))
      (unless (string-empty-p content)
        (benedict-chat-stream--append-text (current-buffer) payload content)))))

(defun benedict-chat--finalize-streaming-from-message (buffer message)
  "Finalize streaming state in BUFFER using MESSAGE data."
  (with-current-buffer buffer
    (when-let ((state benedict-chat--streaming-message)
               (record (plist-get state :message)))
      (let* ((content (or (plist-get message :content) ""))
             (display (or (plist-get message :display-content) content))
             (metadata (plist-get message :metadata)))
        (plist-put record :content content)
        (plist-put record :display-content (plist-get message :display-content))
        (plist-put record :metadata metadata)
        (when (plist-member message :tool-calls)
          (plist-put record :tool-calls (plist-get message :tool-calls)))
        (when (plist-member message :time)
          (plist-put record :time (plist-get message :time)))
        (benedict-chat--replace-message-content buffer record display)
        (when-let ((item (plist-get record :item)))
          (plist-put item :metadata metadata)
          (benedict-chat--refresh-message-header item)))
      (benedict-chat-stream--reset buffer))))

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

(defun benedict-chat--observe-message-added (message)
  "Handle new MESSAGE added to session.
Renders the message unless it's the finalization of a streaming response
that was already rendered by the direct buffer handlers."
  (let ((msg-role (plist-get message :role)))
    (cond
     ;; If we have a streaming placeholder, finalize it from the session message.
     ((and (memq msg-role '(assistant Assistant))
           benedict-chat--streaming-message)
      (benedict-chat--finalize-streaming-from-message (current-buffer) message))
     (t
      (benedict-chat--render-message (current-buffer) message)))))

(defun benedict-chat--observe-draft-started ()
  "Handle streaming draft started."
  (when-let ((session benedict-chat--session)
             (draft (benedict-session-draft session)))
    (benedict-chat--apply-draft-snapshot session draft)))

(defun benedict-chat--observe-draft-updated (payload)
  "Handle draft update with PAYLOAD (:delta or :tool-call)."
  (when-let ((session benedict-chat--session))
    (when-let ((data (plist-get payload :payload)))
      (let ((stream-payload (benedict-chat--draft-payload session)))
        (benedict-chat-stream--handle-provider-delta
         (current-buffer)
         (append stream-payload data))))
    (when-let ((delta (plist-get payload :delta)))
      (let ((stream-payload (benedict-chat--draft-payload session)))
        (benedict-chat-stream--handle-provider-delta
         (current-buffer)
         (append stream-payload (list :kind 'content-delta :text delta)))))
    (when (plist-get payload :tool-call)
      ;; Tool-call streaming UI is handled on finalization.
      nil)))

(defun benedict-chat--observe-draft-finalized (payload)
  "Handle draft finalized (PAYLOAD may have :discarded t)."
  (when (plist-get payload :discarded)
    (benedict-chat-stream--reset (current-buffer))))

(defun benedict-chat--observe-request-completed (payload)
  "Handle request completion using PAYLOAD."
  (if (plist-get payload :success)
      (when-let ((result (plist-get payload :result)))
        (benedict-chat--apply-request-result-extras (current-buffer) result))
    (when-let ((error-payload (plist-get payload :error)))
      (benedict-chat-stream--handle-provider-error (current-buffer) error-payload))))

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

(defun benedict-chat--init-buffer ()
  "Initialize buffer-local state for Benedict chat."
  (setq benedict-session-tool-invoke-fn #'benedict-tool-invoke)
  (setq-local benedict-chat--buffer (current-buffer))
  (setq-local benedict-chat--items nil)
  (setq-local benedict-chat--item-counter 0)
  (setq-local benedict-chat--has-rendered-block nil)
  (setq-local benedict-chat--thinking-items (make-hash-table :test 'equal))
  (setq-local benedict-chat--thinking-temp-counter 0)
  (setq-local benedict-chat--context-slices nil)
  (setq-local benedict-chat--compose-buffer nil)
  (setq-local benedict-chat--provider-override nil)
  (setq-local benedict-chat--flywire-session nil)
  (setq-local benedict-chat--flywire-event-unsubscribe nil)
  (setq-local benedict-chat-profile (or benedict-chat-profile
                                        (benedict-chat-profiles--default-profile)))
  (let* ((profile benedict-chat-profile)
         (provider (benedict-chat-profiles--resolve-provider profile))
         (model (benedict-chat-profiles--resolve-model
                 provider profile benedict-chat--compose-model-override)))
    ;; Create and attach session
    (setq-local benedict-chat--session
                (benedict-session-create
                 :title (buffer-name)
                 :profile profile
                 :provider provider
                 :model model
                 :root (when (project-current)
                         (project-root (project-current)))))
    (benedict-chat--configure-session))
  (benedict-session--add-frontend benedict-chat--session (current-buffer))
  ;; Subscribe to session events
  (setq-local benedict-chat--session-subscription
              (benedict-chat--subscribe-to-session benedict-chat--session))
  (add-hook 'benedict-session-event-hook
            benedict-chat--session-subscription)
  (setq-local header-line-format '(:eval (benedict-chat-status--header-line-status)))
  (visual-line-mode 1)
  (benedict-chat-status--status-reset)
  (add-hook 'kill-buffer-hook #'benedict-chat-status--status-stop-timer nil t)
  (add-hook 'kill-buffer-hook #'benedict-chat--flywire-teardown-session nil t)
  (add-hook 'kill-buffer-hook #'benedict-chat--detach-session nil t)
  (add-hook 'kill-buffer-hook
            (lambda () (when (buffer-live-p benedict-chat--compose-buffer) (kill-buffer benedict-chat--compose-buffer)))
            nil t)
  (setq-local benedict-chat--conversation-section nil)
  (setq-local benedict-chat--current-turn-section nil)
  (setq-local magit-root-section nil)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize
             (format "Benedict Chat — provider: %s\n"
                     (benedict-chat-profiles--provider-label
                      (benedict-chat-profiles--resolve-provider)))
             'face 'benedict-chat-system
             'benedict-region-kind 'system))
    (insert (propertize
             "Commands: C-c C-s send · g r retry-last · w copy-last · benedict-chat-ask-{region,defun,buffer,project,git-context} open compose (C-c C-c to send)\n"
             'face 'benedict-chat-system
             'benedict-region-kind 'system))
    (insert "\n"))
  (benedict-chat-sections--ensure-root))

(defun benedict-chat--session-annotation (session)
  "Return annotation string for SESSION completion.
Includes title, state, and message count."
  (let ((title (or (benedict-session-title session) "Untitled"))
        (state (benedict-session-state session))
        (msg-count (length (benedict-session-messages session))))
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
             (buf-name (format "*Benedict Chat [%s]*"
                               (substring session-id 0 (min 12 (length session-id)))))
             (buf (get-buffer-create buf-name)))
        (with-current-buffer buf
          (unless (derived-mode-p 'benedict-chat-mode)
            (let ((mode (or benedict-chat-major-mode #'benedict-chat-mode)))
              (unless (fboundp mode)
                (setq mode #'benedict-chat-mode))
              (funcall mode)
              ;; Don't create new session - attach to existing one
              (benedict-chat--init-buffer))))
        ;; Now attach to the passed session instead of creating a new one
        (with-current-buffer buf
          (when (bound-and-true-p benedict-chat--session)
            ;; A session was created by init-buffer, remove it
            ;; First unsubscribe from old session's events
            (benedict-chat--unsubscribe-from-session)
            (benedict-session-destroy benedict-chat--session))
          (setq-local benedict-chat--session session)
          (benedict-session--add-frontend session (current-buffer))
          ;; Subscribe to the correct session's events
          (setq-local benedict-chat--session-subscription
                      (benedict-chat--subscribe-to-session session))
          (add-hook 'benedict-session-event-hook
                    benedict-chat--session-subscription)
          (benedict-chat--sync-from-session session))
        buf))))

(defun benedict-chat--sync-from-session (session)
  "Synchronize buffer state from SESSION.
Renders messages and current streaming draft."
  (when (benedict-session-p session)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq benedict-chat--items nil
            benedict-chat--item-counter 0
            benedict-chat--has-rendered-block nil
            benedict-chat--thinking-items (make-hash-table :test 'equal)
            benedict-chat--conversation-section nil
            benedict-chat--current-turn-section nil
            magit-root-section nil)
      (benedict-chat-status--status-reset)
      (benedict-chat-stream--reset (current-buffer))
      (insert (propertize
               (format "Benedict Chat — provider: %s\n"
                       (benedict-chat-profiles--provider-label
                        (or (benedict-session-provider session)
                            (benedict-chat-profiles--resolve-provider))))
               'face 'benedict-chat-system
               'benedict-region-kind 'system))
      (insert (propertize
               "Commands: C-c C-s send · g r retry-last · w copy-last · benedict-chat-ask-{region,defun,buffer,project,git-context} open compose (C-c C-c to send)\n"
               'face 'benedict-chat-system
               'benedict-region-kind 'system))
      (insert "\n")
      (benedict-chat-sections--ensure-root)
      (dolist (msg (benedict-session-messages-chronological session))
        (benedict-chat--render-message (current-buffer) msg))
      (when (eq (benedict-session-state session) 'streaming)
        (when-let ((draft (benedict-session-draft session)))
          (benedict-chat--apply-draft-snapshot session draft)))
      (if (eq (benedict-session-state session) 'streaming)
          (benedict-chat-status--status-start-timer)
        (benedict-chat-status--status-stop-timer))
      (goto-char (point-max)))))

(defun benedict-chat--render-session-history (session)
  "Render SESSION's message history into current buffer.
Assumes buffer is already in benedict-chat-mode with session attached."
  (benedict-chat--sync-from-session session))

;;;###autoload
(defun benedict-chat (&optional prefix)
  "Open or switch to Benedict chat buffer.
With PREFIX argument (C-u), always create a new session.
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
  (message "Type C-c C-s to send a prompt; g r retries; w copies last response.")))

(provide 'benedict-chat)
;;; benedict-chat.el ends here
