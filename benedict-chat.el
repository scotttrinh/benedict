;;; benedict-chat.el --- Chat buffers and commands -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provider-backed chat buffer for Phase 2. Renders role-tagged messages,
;; tracks history for retry/copy actions, and dispatches requests through
;; the active Benedict provider (OpenRouter by default).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'project)
(require 'benedict)
(require 'benedict-context)
(require 'benedict-tools)
(require 'benedict-flywire)
(require 'benedict-chat-mode)
(require 'benedict-chat-render)
(require 'benedict-chat-stream)

(defvar-local benedict-chat--messages nil
  "List of chat message plists (newest first).
Each entry includes :role, :content, :time, optional :metadata, and UI state.")

(defvar-local benedict-chat--pending-request nil
  "Opaque handle representing an in-flight provider request.")

(defvar-local benedict-chat--last-dispatch nil
  "Plist describing the most recent provider request (for retries).")

(defvar-local benedict-chat--items nil
  "Ordered list of rendered chat items (oldest first).")

(defvar-local benedict-chat--item-counter 0
  "Monotonic counter used to generate unique item identifiers.")

(defvar-local benedict-chat--thinking-items nil
  "Hash table mapping reasoning/think identifiers to chat items.")

(defvar-local benedict-chat--streaming-message nil
  "Plist describing the in-progress streaming assistant message.")

(defvar-local benedict-chat--active-request-id nil
  "Identifier for the in-flight provider request, if any.")

(defvar-local benedict-chat--request-seq 0
  "Monotonic sequence used to tag provider requests.")

(defvar-local benedict-chat--thinking-temp-counter 0
  "Per-request counter for synthesizing thinking identifiers when absent.")

(defvar benedict-chat-buffer-name "*Benedict Chat*"
  "Default chat buffer name.")

(defcustom benedict-chat-apply-buffer-name "*Benedict Block*"
  "Name of the temporary buffer used by `benedict-chat-apply-block'."
  :type 'string
  :group 'benedict)

(defcustom benedict-chat-token-display 'prompt+completion
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

(defcustom benedict-chat-compose-buffer-name-format "*Benedict Compose: %s*"
  "Format string used to name compose buffers for chat threads.
The chat buffer name is substituted into the single %s placeholder."
  :type 'string
  :group 'benedict)

(defcustom benedict-chat-profiles
  '((planning
     :label "Planning"
     :preamble "You are Benedict, an expert engineering lead helping to plan complex tasks.

# Goal
Create actionable, high-quality plans that address the user's goals.

# Process
1. **Analyze**: Understand the request. Ask clarifying questions if ambiguous.
2. **Draft**: Propose a detailed, step-by-step plan.
3. **Iterate**: Present options as ordered lists. Incorporate feedback.

# Output
- Structured Markdown with clear headers.
- Tasks should be broken down into manageable chunks.")
    (coding
     :label "Coding"
     :preamble "You are Benedict, an expert AI coding agent built to run inside Emacs.

# Agency
- Take initiative to resolve requests but ask if ambiguous.
- Balance proactivity with safety.

# Communication
- Be concise and direct. No fluff (\"Great question\", \"Here is the code\").
- Use GitHub-flavored Markdown.
- Never apologize for limitations; state them clearly.

# Code
- Mimic existing code style and conventions.
- Do not suppress errors unless asked.
- Do not add comments unless complex or requested.

# Context
- You are in Emacs. Use this to your advantage.")
    (writing
     :label "Writing"
     :preamble "You are Benedict, an expert technical writer and editor.

# Goal
Draft and edit prose for clarity, brevity, and impact.

# Style
- **Voice**: Active, professional, and direct.
- **Tone**: Objective and confident.
- **Format**: Clean Markdown.

# Instructions
- Improve flow and structure.
- Fix grammar and spelling errors.
- Remove redundancy.
- Preserve the original intent and meaning.")
    (review
     :label "Review"
     :preamble "You are Benedict, a senior code reviewer.

# Goal
Identify bugs, security risks, and architectural issues in code.

# Instructions
1. **Prioritize**: Lead with critical findings (bugs, security risks).
2. **Analyze**: Check for logic errors, edge cases, and race conditions.
3. **Improve**: Suggest readability, performance, and style improvements.
4. **Summarize**: Conclude with a brief summary of the code quality.

# Tone
- Constructive, objective, and specific.
- Avoid nitpicking unless it affects correctness or maintainability."))
  "Profile definitions keyed by symbol.
Each entry includes :label and :preamble plus optional :provider and :model
defaults applied when composing chat requests.

Additional optional keys (all are ignored when absent):
- :tool-allowlist — list of tool IDs allowed for this profile (preferred gate).
- :tool-denylist — list of tool IDs to exclude.
- :capabilities — high-level tags mapped to tools via
  `benedict-chat-capability-tool-map'.
- :autonomy — plist with keys :max-turns, :max-time, :max-tokens.
  Overrides global safeguards if stricter (lower).
- :verbosity — hint about response length/structure."
  :type '(alist :key-type symbol :value-type plist)
  :group 'benedict)

(defcustom benedict-chat-default-profile 'coding
  "Default profile applied when opening a chat buffer."
  :type 'symbol
  :group 'benedict)

(defcustom benedict-chat-project-default-profiles nil
  "Alist mapping project roots (strings) to default profile symbols."
  :type '(alist :key-type string :value-type symbol)
  :group 'benedict)

(defcustom benedict-chat-context-retain-after-send nil
  "When non-nil, keep pending context slices after sending from compose."
  :type 'boolean
  :group 'benedict)

(defcustom benedict-chat-base-system-prompt
  "You are Benedict, an expert AI engineering agent integrated into Emacs.
Your goal is to help the user build high-quality software efficiently.
You have access to the user's editor state (buffers, project files) and should use this context to provide precise, relevant assistance.
Always be concise, direct, and professional."
  "Base system prompt applied to every request before profile-specific text."
  :type 'string
  :group 'benedict)

(defcustom benedict-chat-capability-tool-map nil
  "Alist mapping capability keywords to tool ID lists.
For example: '((:plan update-plan) (:read-files read-file list-files))."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'benedict)

(defcustom benedict-chat-loop-checkpoint-interval 5
  "Number of autonomous turns before pausing to ask for user confirmation.
Set to nil to disable turn-based checkpoints."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'benedict)

(defcustom benedict-chat-loop-max-time 60.0
  "Maximum duration (in seconds) for an autonomous loop before pausing.
Set to nil to disable time limits."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'benedict)

(defcustom benedict-chat-loop-max-tokens nil
  "Maximum total tokens consumed in a loop session before pausing.
Set to nil to disable token limits."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'benedict)

(defcustom benedict-chat-use-agent-frame nil
  "When non-nil, use a dedicated agent frame for tool execution.
The agent frame provides isolation for flywire-backed tools."
  :type 'boolean
  :group 'benedict)

(defconst benedict-chat--block-divider-line
  (concat (make-string 60 ?-) "\n")
  "Divider line inserted before and after block sections.")

(defconst benedict-chat--empty-response-placeholder
  "Response finished without assistant text."
  "Displayed when providers return no assistant message.")

(defconst benedict-chat--empty-response-thinking-placeholder
  "Response finished with reasoning only; no assistant message."
  "Displayed when providers stream thinking without a final reply.")

(defconst benedict-chat--spinner-frames ["◐" "◓" "◑" "◒"]
  "Spinner frames used while a provider request is active.")

(defvar benedict-chat--profile-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'benedict-chat-choose-profile)
    (define-key map [down-mouse-1] #'benedict-chat-choose-profile)
    (define-key map (kbd "RET") #'benedict-chat-choose-profile)
    map)
  "Keymap for interacting with the profile display in compose headers.")

(defvar benedict-chat--model-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'benedict-chat-choose-model)
    (define-key map [header-line mouse-1] #'benedict-chat-choose-model)
    (define-key map [down-mouse-1] #'benedict-chat-choose-model)
    (define-key map (kbd "RET") #'benedict-chat-choose-model)
    map)
  "Keymap for clicking the provider/model display in status lines.")

(defvar benedict-chat--provider-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'benedict-chat-choose-provider)
    (define-key map [down-mouse-1] #'benedict-chat-choose-provider)
    (define-key map (kbd "RET") #'benedict-chat-choose-provider)
    map)
  "Keymap for interacting with the provider display in compose headers.")

(defvar benedict-chat-model-history nil
  "Minibuffer history for `benedict-chat-choose-model'.")

(defvar-local benedict-chat--telemetry nil
  "Buffer-local telemetry for modeline/header-line status.")

(defvar-local benedict-chat--status-timer nil
  "Timer driving spinner/elapsed updates for the status line.")

(defvar-local benedict-chat--context-slices nil
  "Pending context slices staged for the next user message.")

(defvar-local benedict-chat--compose-buffer nil
  "Compose buffer associated with the current chat, if any.")

(defvar-local benedict-chat--compose-model-override nil
  "Transient model override applied to the next compose send.")

(defvar-local benedict-chat--provider-override nil
  "Buffer-local provider override for the current chat.
When non-nil, this symbol takes precedence over profile :provider and global benedict-provider.")

(defvar-local benedict-chat--loop-start-time nil
  "Float time marking the start of the current autonomous loop.")

(defvar-local benedict-chat--loop-turn-count 0
  "Number of turns executed in the current autonomous loop.")

(defvar-local benedict-chat--loop-canceled nil
  "Non-nil when the user has requested the current loop to stop.")

(defvar-local benedict-chat-profile nil
  "Active profile symbol for the current chat, controls prompt preamble.")

(defvar-local benedict-chat--flywire-session nil
  "Active flywire session for agent tool execution, or nil if inactive.")

(defvar-local benedict-chat--flywire-event-unsubscribe nil
  "Function to unsubscribe from flywire session events.")

(defconst benedict-chat--compose-separator "----\n"
  "Separator line between compose header and body.")

(defconst benedict-chat--handle-regexp "^[A-Za-z0-9._:-]+$"
  "Valid pattern for context handles referenced via [[handle]].")

(defconst benedict-chat--anchor-guidance
  "The user may refer to context slices using Org-style notation. Each context block is labeled with an anchor like <<foo>>. Inside the user's instructions, [[foo]] refers to that same context slice. When reasoning about their request, resolve [[foo]] to the corresponding <<foo>> block in the Context section above."
  "System guidance explaining how to resolve [[handle]] links to context anchors.")

(defun benedict-chat--empty-response-text (thinking)
  "Return placeholder text for empty responses.
THINKING is non-nil when reasoning blocks accompanied the response."
  (if thinking
      benedict-chat--empty-response-thinking-placeholder
    benedict-chat--empty-response-placeholder))

;; -------------------------------------------------------------------
;; Loop Constraints and Safeguards

(defun benedict-chat--check-loop-constraints ()
  "Check loop safeguards (checkpoints, time, tokens).
Returns t if the loop should continue, or nil if it should stop.
Prompts the user to authorize extensions when limits are reached."
  (if benedict-chat--loop-canceled
      nil
    (let ((continue t)
          (limit-turns (benedict-chat--effective-limit :max-turns benedict-chat-loop-checkpoint-interval))
          (limit-time (benedict-chat--effective-limit :max-time benedict-chat-loop-max-time))
          (limit-tokens (benedict-chat--effective-limit :max-tokens benedict-chat-loop-max-tokens)))
      ;; 1. Turn Checkpoint
      (when (and limit-turns
                 (> benedict-chat--loop-turn-count 0)
                 (= 0 (mod benedict-chat--loop-turn-count
                           limit-turns)))
        (unless (y-or-n-p (format "Benedict has run %d autonomous steps. Continue? "
                                  benedict-chat--loop-turn-count))
          (setq continue nil)))
      
      ;; 2. Time Limit
      (when (and continue
                 limit-time
                 benedict-chat--loop-start-time
                 (> (float-time (time-since benedict-chat--loop-start-time))
                    limit-time))
        (unless (y-or-n-p (format "Time limit (%.1fs) reached. Continue? "
                                  limit-time))
          (setq continue nil)
          ;; If continued, reset the timer to avoid prompting immediately again?
          ;; Or just extend? For now, we update start time to give another full window.
          (when continue
            (setq benedict-chat--loop-start-time (float-time)))))
      
      ;; 3. Token Limit (Best effort based on session telemetry)
      (when (and continue
                 limit-tokens)
        (let* ((usage (plist-get benedict-chat--telemetry :session-usage))
               (total (or (plist-get usage :total) 0)))
          (when (> total limit-tokens)
            (unless (y-or-n-p (format "Token limit (%d) exceeded (current: %d). Continue? "
                                      limit-tokens total))
              (setq continue nil)))))
      
      continue)))

(defun benedict-chat--check-repetition-guard (current-tool-calls history)
  "Return non-nil if CURRENT-TOOL-CALLS match the previous assistant message in HISTORY."
  (let* ((assistants (cl-remove-if-not 
                      (lambda (m) (eq (benedict-chat--normalize-role (plist-get m :role)) 'assistant))
                      history))
         ;; assistants is (current prev ...) because we are called after recording
         (previous (cadr assistants)))
    (when previous
      (equal current-tool-calls (plist-get previous :tool-calls)))))

(defun benedict-chat--loop-step (assistant-message)
  "Decide whether to continue the autonomous loop after ASSISTANT-MESSAGE."
  (let ((tool-calls (plist-get assistant-message :tool-calls)))
    (when tool-calls
      ;; Check for repetition
      (if (benedict-chat--check-repetition-guard tool-calls benedict-chat--messages)
          (message "Benedict: loop stopped (repetition detected)")
        ;; Check constraints
        (when (benedict-chat--check-loop-constraints)
          (setq benedict-chat--loop-turn-count (1+ benedict-chat--loop-turn-count))
          (benedict-chat--start-dispatch (benedict-chat--build-request)))))))

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
;; Profiles and project helpers

(defun benedict-chat--project-root ()
  "Return the current project root or expanded `default-directory'."
  (or (when (fboundp 'project-current)
        (when-let* ((project (project-current nil default-directory))
                    (roots (project-roots project)))
          (expand-file-name (car roots))))
      (when default-directory (expand-file-name default-directory))))

(defun benedict-chat--profile-entry (profile)
  "Return the profile plist entry for PROFILE."
  (assoc profile benedict-chat-profiles))

(defun benedict-chat--profile-label (profile)
  "Return human-readable label for PROFILE."
  (or (plist-get (cdr (benedict-chat--profile-entry profile)) :label)
      (when profile (capitalize (symbol-name profile)))
      "Default"))

(defun benedict-chat--profile-provider (profile)
  "Return provider symbol supplied by PROFILE entry, if any."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :provider))

(defun benedict-chat--profile-model (profile)
  "Return model string supplied by PROFILE entry, if any."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :model))

(defun benedict-chat--profile-preamble (profile)
  "Return preamble string for PROFILE or nil."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :preamble))

(defun benedict-chat--profile-tool-allowlist (profile)
  "Return tool allowlist for PROFILE."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :tool-allowlist))

(defun benedict-chat--profile-tool-denylist (profile)
  "Return tool denylist for PROFILE."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :tool-denylist))

(defun benedict-chat--profile-capabilities (profile)
  "Return capability list for PROFILE."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :capabilities))

(defun benedict-chat--profile-autonomy (profile)
  "Return autonomy plist for PROFILE."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :autonomy))

(defun benedict-chat--effective-limit (key global-val)
  "Return the stricter of the profile's autonomy limit KEY and GLOBAL-VAL.
NIL represents infinity (no limit). Uses `benedict-chat-profile`."
  (let* ((autonomy (benedict-chat--profile-autonomy benedict-chat-profile))
         (profile-limit (plist-get autonomy key)))
    (cond
     ((and (null global-val) (null profile-limit)) nil)
     ((null global-val) profile-limit)
     ((null profile-limit) global-val)
     (t (min global-val profile-limit)))))

(defun benedict-chat--profile-verbosity (profile)
  "Return verbosity hint for PROFILE."
  (plist-get (cdr (benedict-chat--profile-entry profile)) :verbosity))

(defun benedict-chat--default-profile ()
  "Return default profile for the current context."
  (let* ((root (benedict-chat--project-root))
         (match (cl-find-if (lambda (entry)
                              (and root (file-equal-p root (car entry))))
                            benedict-chat-project-default-profiles)))
    (or (cdr match) benedict-chat-default-profile)))

(defun benedict-chat--effective-profile ()
  "Return the active profile for the current chat buffer."
  (or benedict-chat-profile (benedict-chat--default-profile)))

(defun benedict-chat--provider-default-model (provider)
  "Return the default model string for PROVIDER."
  (pcase provider
    ('openrouter benedict-provider-openrouter-default-model)
    ('fake benedict-provider-fake-default-model)
    (_ nil)))

(defun benedict-chat--resolve-provider (&optional profile)
  "Resolve provider using PROFILE or the buffer's effective profile.
Resolution order: buffer override → profile :provider → global `benedict-provider'."
  (or benedict-chat--provider-override
      (benedict-chat--profile-provider (or profile (benedict-chat--effective-profile)))
      benedict-provider))

(defun benedict-chat--resolve-model (&optional provider profile override)
  "Resolve model using PROVIDER/PROFILE with optional OVERRIDE."
  (let* ((profile (or profile (benedict-chat--effective-profile)))
         (provider (or provider (benedict-chat--resolve-provider profile)))
         (override (or override benedict-chat--compose-model-override)))
    (or (and (stringp override) (not (string-empty-p override)) override)
        (benedict-chat--profile-model profile)
        (benedict-chat--provider-default-model provider))))

(defun benedict-chat--system-content (&optional profile)
  "Return combined system content for PROFILE."
  (let ((parts nil))
    (dolist (piece (list benedict-chat-base-system-prompt
                         benedict-chat--anchor-guidance
                         (benedict-chat--profile-preamble profile)))
      (when (and piece (stringp piece)
                 (not (string-empty-p (string-trim piece))))
        (push (string-trim piece) parts)))
    (when parts
      (string-join (nreverse parts) "\n\n"))))

(defun benedict-chat--system-messages (&optional profile)
  "Return a list of system messages for PROFILE."
  (when-let ((content (benedict-chat--system-content profile)))
    (list (list :role 'system :content content))))

(defun benedict-chat--registered-tool-ids ()
  "Return tool IDs registered in `benedict-tools-list'."
  (mapcar (lambda (tool) (plist-get tool :id))
          (benedict-tools-list)))

(defun benedict-chat--normalize-capabilities (capabilities)
  "Normalize CAPABILITIES into a list."
  (cond
   ((null capabilities) nil)
   ((listp capabilities) capabilities)
   (t (list capabilities))))

(defun benedict-chat--tools-for-capabilities (capabilities)
  "Return tool IDs derived from CAPABILITIES via `benedict-chat-capability-tool-map'."
  (let ((caps (benedict-chat--normalize-capabilities capabilities))
        (acc nil))
    (dolist (cap caps)
      (let ((tools (alist-get cap benedict-chat-capability-tool-map nil nil #'eq)))
        (when tools
          (setq acc (nconc acc (copy-sequence tools))))))
    (delete-dups acc)))

(defun benedict-chat--effective-tool-ids (profile)
  "Return effective tool IDs for PROFILE respecting allow/deny/capabilities."
  (let* ((allow (benedict-chat--profile-tool-allowlist profile))
         (deny (benedict-chat--profile-tool-denylist profile))
         (caps (benedict-chat--profile-capabilities profile))
         (cap-tools (benedict-chat--tools-for-capabilities caps))
         (registered (benedict-chat--registered-tool-ids))
         (baseline (cond
                    (allow (copy-sequence allow))
                    (cap-tools cap-tools)
                    (t registered)))
         (with-deny (if deny
                        (cl-set-difference baseline deny :test #'eq)
                      baseline)))
    (cl-intersection with-deny registered :test #'eq)))

(defun benedict-chat--resolve-tools (profile)
  "Return hydrated tool specs allowed for PROFILE."
  (let ((ids (benedict-chat--effective-tool-ids profile))
        (result nil))
    (dolist (spec (benedict-tools-list))
      (when (memq (plist-get spec :id) ids)
        (push (copy-tree spec) result)))
    (nreverse result)))

(defun benedict-chat--resolve-chat-buffer ()
  "Return the active chat buffer associated with the current context."
  (cond
   ((derived-mode-p 'benedict-chat-mode) (current-buffer))
   ((and (boundp 'benedict-chat-compose--chat-buffer)
         (buffer-live-p benedict-chat-compose--chat-buffer))
    benedict-chat-compose--chat-buffer)
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
                    (or benedict-chat-profile (benedict-chat--default-profile))))
         (choice (completing-read
                  "Profile: "
                  candidates nil t nil nil (symbol-name current)))
         (profile (cdr (assoc choice candidates))))
    (with-current-buffer chat
      (setq benedict-chat-profile profile)
      (let* ((provider (benedict-chat--resolve-provider profile))
             (model (benedict-chat--resolve-model
                     provider profile benedict-chat--compose-model-override)))
        (benedict-chat--telemetry-update
         :provider (benedict-chat--provider-label provider)
         :model model))
      (benedict-chat--refresh-compose-header))
    (message "Benedict profile set to %s" (benedict-chat--profile-label profile))))

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
                   (benedict-chat--resolve-provider)))
        (current-name (or (benedict-provider-display-name current)
                         (symbol-name current)))
        (choice (completing-read
                 "Provider: "
                 candidates nil t nil nil current-name))
        (provider (cdr (assoc choice candidates))))
    (with-current-buffer chat
     (setq benedict-chat--provider-override provider)
     (let* ((model (benedict-chat--resolve-model
                    provider (benedict-chat--effective-profile) 
                    benedict-chat--compose-model-override)))
       (benedict-chat--telemetry-update
        :provider (benedict-chat--provider-label provider)
        :model model))
     (benedict-chat--refresh-compose-header))
    (message "Benedict provider set to %s" (or (benedict-provider-display-name provider)
                                              (symbol-name provider)))))

    ;; -------------------------------------------------------------------
    ;; Internal helpers for block items

(defun benedict-chat--next-item-id ()
  "Return a fresh identifier for chat items."
  (setq benedict-chat--item-counter (1+ benedict-chat--item-counter)))

(defun benedict-chat--make-item (kind &rest properties)
  "Create a new chat item plist of KIND with PROPERTIES."
  (let ((item (list :id (benedict-chat--next-item-id)
                    :kind kind)))
    (while properties
      (let ((key (pop properties))
            (value (pop properties)))
        (setq item (plist-put item key value))))
    item))

(defun benedict-chat--track-item (item)
  "Append ITEM to `benedict-chat--items' maintaining chronological order."
  (setq benedict-chat--items (append benedict-chat--items (list item)))
  item)

(defun benedict-chat--provider-label (&optional provider-id)
  "Return a short label for PROVIDER-ID (or the active provider)."
  (let* ((provider (or (and provider-id (benedict-provider-lookup provider-id))
                       (ignore-errors (benedict-provider-current))))
         (name (and provider (benedict-provider-name provider)))
         (id (and provider (benedict-provider-id provider))))
    (or name
        (and id (symbol-name id))
        (and provider-id (format "%s" provider-id))
        "unknown provider")))

(defun benedict-chat--telemetry-reset ()
  "Initialize telemetry for the current chat buffer."
  (let* ((profile (benedict-chat--effective-profile))
         (provider (benedict-chat--resolve-provider profile)))
    (setq benedict-chat--telemetry
          (list :phase 'idle
                :provider (benedict-chat--provider-label provider)
                :model (benedict-chat--resolve-model
                        provider profile benedict-chat--compose-model-override)
                :started-at nil
                :last-phase nil
                :last-usage nil
                :last-elapsed nil
                :session-usage nil
                :spinner-index 0))))

(defun benedict-chat--telemetry-update (&rest pairs)
  "Merge PAIRS into the buffer-local telemetry plist."
  (while pairs
    (let ((key (pop pairs))
          (value (pop pairs)))
      (setq benedict-chat--telemetry
            (plist-put benedict-chat--telemetry key value)))))

(defun benedict-chat--telemetry-apply-metadata (metadata)
  "Update telemetry with METADATA such as provider/model/usage."
  (let* ((provider (plist-get metadata :provider))
         (provider-label (cond
                          ((stringp provider) provider)
                          (provider (benedict-chat--provider-label provider))
                          (t nil)))
         (model (plist-get metadata :model))
         (usage (plist-get metadata :usage)))
    (benedict-chat--telemetry-update
     :provider (or provider-label (plist-get benedict-chat--telemetry :provider))
     :model (or model (plist-get benedict-chat--telemetry :model))
     :usage (or usage (plist-get benedict-chat--telemetry :usage)))))

(defun benedict-chat--usage-number (usage key)
  "Return numeric value for KEY (string or symbol) in USAGE."
  (when-let ((val (benedict-chat--usage-value usage key)))
    (if (stringp val) (string-to-number val) val)))

(defun benedict-chat--usage-cost-number (usage)
  "Return numeric cost from USAGE if present."
  (or (benedict-chat--usage-number usage "cost")
      (benedict-chat--usage-number usage "total_cost")))

(defun benedict-chat--usage-accumulate (session usage)
  "Return SESSION usage totals merged with USAGE numbers."
  (let* ((prompt-old (or (plist-get session :prompt) 0))
         (completion-old (or (plist-get session :completion) 0))
         (total-old (or (plist-get session :total) 0))
         (cost-old (or (plist-get session :cost) 0))
         (prompt (or (benedict-chat--usage-number usage "prompt_tokens")
                     (benedict-chat--usage-number usage "prompt")
                     0))
         (completion (or (benedict-chat--usage-number usage "completion_tokens")
                         (benedict-chat--usage-number usage "completion")
                         0))
         (total (or (benedict-chat--usage-number usage "total_tokens")
                    (benedict-chat--usage-number usage "tokens")
                    (+ prompt completion)))
         (cost (or (benedict-chat--usage-cost-number usage) 0)))
    (list :prompt (+ prompt-old prompt)
          :completion (+ completion-old completion)
          :total (+ total-old total)
          :cost (+ cost-old cost))))

(defun benedict-chat--telemetry-accumulate-session (usage)
  "Merge USAGE into session totals."
  (when usage
    (let ((session (plist-get benedict-chat--telemetry :session-usage)))
      (benedict-chat--telemetry-update
       :session-usage (benedict-chat--usage-accumulate session usage)))))

(defun benedict-chat--telemetry-begin (request)
  "Mark telemetry as sending REQUEST."
  (benedict-chat--telemetry-update
   :phase 'sending
   :started-at (float-time)
   :spinner-index 0
   :usage nil)
  (when-let* ((provider (plist-get request :provider)))
    (benedict-chat--telemetry-update
     :provider (benedict-chat--provider-label provider)))
  (when-let ((model (plist-get request :model)))
    (benedict-chat--telemetry-update :model model))
  (benedict-chat--status-start-timer)
  (benedict-chat--status-refresh))

(defun benedict-chat--telemetry-streaming (payload)
  "Mark telemetry as streaming using PAYLOAD metadata."
  (benedict-chat--telemetry-apply-metadata payload)
  (benedict-chat--telemetry-update :phase 'streaming)
  (benedict-chat--status-start-timer)
  (benedict-chat--status-refresh))

(defun benedict-chat--telemetry-finish (kind metadata)
  "Mark telemetry as idle after KIND with METADATA.
KIND is one of 'complete, 'error, or 'canceled."
  (benedict-chat--telemetry-apply-metadata metadata)
  (let* ((elapsed (or (benedict-chat--status-elapsed)
                      (plist-get benedict-chat--telemetry :last-elapsed)))
         (usage (or (plist-get metadata :usage)
                    (plist-get benedict-chat--telemetry :usage))))
    (benedict-chat--telemetry-accumulate-session usage)
    (benedict-chat--telemetry-update
     :phase 'idle
     :started-at nil
     :usage nil
     :spinner-index 0
     :last-phase kind
     :last-elapsed elapsed
     :last-usage usage))
  (benedict-chat--status-stop-timer)
  (benedict-chat--status-refresh))

(defun benedict-chat--status-active-p ()
  "Return non-nil when telemetry indicates an active provider call."
  (memq (plist-get benedict-chat--telemetry :phase) '(sending streaming)))

(defun benedict-chat--status-stop-timer ()
  "Cancel the status timer if present."
  (when (timerp benedict-chat--status-timer)
    (cancel-timer benedict-chat--status-timer))
  (setq benedict-chat--status-timer nil))

(defun benedict-chat--status-refresh ()
  "Force status lines to update."
  (force-mode-line-update t))

(defun benedict-chat--status-tick (buffer)
  "Advance spinner/elapsed for BUFFER and refresh status."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (benedict-chat--status-active-p)
          (progn
            (let* ((index (or (plist-get benedict-chat--telemetry :spinner-index) 0))
                   (next (1+ index)))
              (benedict-chat--telemetry-update :spinner-index next))
            (benedict-chat--status-refresh))
        (benedict-chat--status-stop-timer)))))

(defun benedict-chat--status-start-timer ()
  "Ensure the spinner/elapsed timer is running for the current buffer."
  (unless (timerp benedict-chat--status-timer)
    (setq benedict-chat--status-timer
          (run-with-timer 0.2 0.2 #'benedict-chat--status-tick (current-buffer)))))

(defun benedict-chat--status-elapsed ()
  "Return elapsed seconds for the current telemetry."
  (let ((started (plist-get benedict-chat--telemetry :started-at)))
    (when started
      (- (float-time) started))))

(defun benedict-chat--status-usage-string (usage)
  "Format USAGE according to `benedict-chat-token-display', including cost."
  (let (parts)
    (pcase benedict-chat-token-display
      ('none nil)
      ('total
       (let ((total (or (plist-get usage :total)
                        (benedict-chat--usage-value usage "total_tokens")
                        (benedict-chat--usage-value usage "tokens"))))
         (when total
           (push (format "%s tok" total) parts))))
      ('prompt+completion
       (let ((prompt (or (plist-get usage :prompt)
                         (benedict-chat--usage-value usage "prompt_tokens")
                         (benedict-chat--usage-value usage "prompt"))))
         (let ((completion (or (plist-get usage :completion)
                               (benedict-chat--usage-value usage "completion_tokens")
                               (benedict-chat--usage-value usage "completion"))))
           (cond
            ((and prompt completion)
             (push (format "%sp+%sc tok" prompt completion) parts))
            (prompt (push (format "%sp tok" prompt) parts))
            (completion (push (format "%sc tok" completion) parts)))))))
    (when-let ((cost (or (plist-get usage :cost)
                         (benedict-chat--usage-cost-number usage))))
      (push (format "cost:$%.4f" cost) parts))
    (when parts
      (string-join (nreverse parts) " / "))))

(defun benedict-chat--status-indicator (phase last-phase)
  "Return the indicator glyph for PHASE using LAST-PHASE as a hint."
  (pcase phase
    ((or 'sending 'streaming)
     (let* ((frames benedict-chat--spinner-frames)
            (len (length frames))
            (index (mod (or (plist-get benedict-chat--telemetry :spinner-index) 0) len)))
       (aref frames index)))
    ('complete "✔")
    ('error "✖")
    ('canceled "⨯")
    (_ (pcase last-phase
         ('complete "✔")
         ('error "✖")
         ('canceled "⨯")
         (_ "·")))))

(defun benedict-chat--status-phase-label (phase)
  "Return a human-readable label for PHASE."
  (pcase phase
    ('sending "contacting")
    ('streaming "streaming")
    ('complete "completed")
    ('error "error")
    ('canceled "canceled")
    (_ "idle")))

(defun benedict-chat--status-provider-label (&optional clickable)
  "Return provider/model label for the status line.
When CLICKABLE is non-nil, attach button properties that run
`benedict-chat-choose-model'."
  (let* ((provider (or (plist-get benedict-chat--telemetry :provider)
                       (benedict-chat--provider-label
                        (benedict-chat--resolve-provider))))
         (model (plist-get benedict-chat--telemetry :model))
         (label (if model
                    (format "%s:%s" provider model)
                  (format "%s" provider))))
    (if clickable
        (propertize label
                    'mouse-face 'mode-line-highlight
                    'help-echo "Choose a model for this chat/compose buffer"
                    'local-map benedict-chat--model-button-map)
      label)))

(defun benedict-chat--status-agent-indicator ()
  "Return an indicator if a flywire agent session is active."
  (when (benedict-chat-flywire-active-p)
    (propertize "🤖" 'help-echo "Agent frame active")))

(defun benedict-chat--status-string (&optional rich)
  "Return the formatted status string for the current buffer.
When RICH is non-nil, include header-friendly hints."
  (let* ((phase (or (plist-get benedict-chat--telemetry :phase) 'idle))
         (last-phase (plist-get benedict-chat--telemetry :last-phase))
         (active (memq phase '(sending streaming)))
         (elapsed (or (and active (benedict-chat--status-elapsed))
                      (plist-get benedict-chat--telemetry :last-elapsed)))
         (usage (plist-get benedict-chat--telemetry :session-usage))
         (indicator (benedict-chat--status-indicator phase last-phase))
         (label (benedict-chat--status-phase-label phase))
         (provider (benedict-chat--status-provider-label rich))
         (usage-str (benedict-chat--status-usage-string usage))
         (elapsed-str (when elapsed (format "%.0fs" elapsed)))
         (agent-indicator (benedict-chat--status-agent-indicator))
         (hint (and rich active "ESC to cancel")))
    (string-join
     (delq nil
           (list (format "%s %s" indicator label)
                 provider
                 elapsed-str
                 usage-str
                 agent-indicator
                 hint))
     " · ")))

(defun benedict-chat--mode-line-status ()
  "Compact status string for the mode line."
  (benedict-chat--status-string nil))

(defun benedict-chat--header-line-status ()
  "Richer status string for the header line."
  (benedict-chat--status-string t))

(defun benedict-chat-choose-model ()
  "Prompt for a model override scoped to the current chat compose buffer."
  (interactive)
  (let* ((chat (or (benedict-chat--resolve-chat-buffer)
                   (user-error "Not in a Benedict chat or compose buffer")))
         (profile (with-current-buffer chat (benedict-chat--effective-profile)))
         (provider (with-current-buffer chat
                     (benedict-chat--resolve-provider profile)))
         (current (with-current-buffer chat
                    (benedict-chat--resolve-model
                     provider profile benedict-chat--compose-model-override)))
         (prompt (format "Model for %s (erase to clear override): "
                         (benedict-chat--provider-label provider)))
         (input (read-string prompt nil 'benedict-chat-model-history current))
         (selection (string-trim input)))
    (with-current-buffer chat
      (setq benedict-chat--compose-model-override
            (unless (string-empty-p selection) selection))
      (benedict-chat--telemetry-update
       :model (benedict-chat--resolve-model provider profile benedict-chat--compose-model-override))
      (benedict-chat--refresh-compose-header))
    (if (string-empty-p selection)
        (message "Benedict: cleared compose model override")
      (message "Benedict: model override set to %s" selection))))

(defun benedict-chat--normalize-role (role)
  "Normalize ROLE into a symbol."
  (cond
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t 'assistant)))

(defun benedict-chat--face-for-role (role metadata)
  "Return a face for ROLE considering METADATA."
  (cond
   ((plist-get metadata :error) 'benedict-chat-error)
   ((eq role 'user) 'benedict-chat-user)
   ((eq role 'assistant) 'benedict-chat-assistant)
   (t 'benedict-chat-system)))

(defun benedict-chat--history-store (message)
  "Persist MESSAGE in buffer history without rendering."
  (push message benedict-chat--messages)
  message)

(defun benedict-chat--record-message (message)
  "Persist MESSAGE in buffer history and render it."
  (benedict-chat--history-store message)
  (benedict-chat--insert-message message)
  message)

(defun benedict-chat--record-thinking (content metadata &rest properties)
  "Record a thinking block with CONTENT and METADATA.
This does not affect provider message history."
  ;; TODO: Implement thinking block rendering in benedict-chat-render
  nil)

(defun benedict-chat--message-history ()
  "Return messages in chronological order."
  (reverse benedict-chat--messages))

;; Old rendering functions removed.

(defun benedict-chat--tool-name-string (name)
  "Return a human-readable string for tool NAME."
  (cond
   ((symbolp name) (symbol-name name))
   ((stringp name) name)
   (t (format "%s" name))))

(defun benedict-chat--tool-value-string (value)
  "Return VALUE formatted for tool argument/result display."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (with-temp-buffer
        (let ((print-level nil)
              (print-length nil))
          (prin1 value (current-buffer))
          (string-trim-right (buffer-string)))))))

(defun benedict-chat--tool-arguments-string (arguments)
  "Format tool ARGUMENTS plist for display."
  (if arguments
      (benedict-chat--tool-value-string arguments)
    "None"))

(defun benedict-chat--tool-status-label (status)
  "Return STATUS normalized into a user-facing string."
  (if status
      (capitalize (replace-regexp-in-string "-" " " (format "%s" status)))
    ""))

(defun benedict-chat--tool-default-header (call)
  "Return a generic header label for CALL."
  (format "Tool — %s" (benedict-chat--tool-name-string (plist-get call :name))))

(defun benedict-chat--normalize-tool-state (state)
  "Return STATE coerced into a canonical symbol."
  (cond
   ((keywordp state) (intern (substring (symbol-name state) 1)))
   ((symbolp state)
    (pcase state
      ('ok 'success)
      ('error 'failure)
      (_ state)))
   ((stringp state)
    (let ((normalized (replace-regexp-in-string "[[:space:]]+" "-" (downcase state))))
      (intern normalized)))
   ((null state) 'in-progress)
   (t 'in-progress)))

(defun benedict-chat--tool-ui--stringify-body (value fallback)
   "Return VALUE formatted as a string for tool UI, or FALLBACK."
   (cond
    ((and (stringp value) (not (string-empty-p value))) value)
    ((null value) (or fallback ""))
    ((listp value) (string-join (mapcar #'benedict-chat--tool-value-string value) "\n"))
    (t (benedict-chat--tool-value-string value))))

(defun benedict-chat--format-diff-body (diff &optional lang)
   "Format DIFF string for display with syntax highlighting.
LANG is optional language hint (defaults to 'diff').
Returns the formatted diff wrapped in a markdown code block."
   (let* ((language (or lang "diff"))
          (formatted (concat "```" language "\n" diff "\n```")))
     formatted))

(defun benedict-chat--validate-action (action)
  "Validate that ACTION is a plist with :label and :handler.
Returns the action plist or signals an error."
  (message "[Benedict--validate-action] Validating: %S" (type-of action))
  (unless (listp action)
    (message "[Benedict--validate-action] ERROR: not a list: %S" (type-of action))
    (signal 'wrong-type-argument (list 'listp action)))
  (unless (plist-member action :label)
    (message "[Benedict--validate-action] ERROR: missing :label in %S" action)
    (signal 'benedict-error "Action must have :label"))
  (let ((label (plist-get action :label)))
    (unless (stringp label)
      (message "[Benedict--validate-action] ERROR: :label not string: %S" (type-of label))
      (signal 'wrong-type-argument (list 'stringp label))))
  (unless (plist-member action :handler)
    (message "[Benedict--validate-action] ERROR: missing :handler in %S" action)
    (signal 'benedict-error "Action must have :handler"))
  (let ((handler (plist-get action :handler)))
    (unless (functionp handler)
      (message "[Benedict--validate-action] ERROR: :handler not functionp: %S" (type-of handler))
      (signal 'wrong-type-argument (list 'functionp handler))))
  (message "[Benedict--validate-action] VALID: action with label=%s" (plist-get action :label))
  action)

(defun benedict-chat--normalize-actions (actions)
  "Normalize ACTIONS list, validating each action.
Returns a list of validated action plists, or nil if ACTIONS is null/empty."
  (message "[Benedict--normalize-actions] Processing: %S (count: %d)" 
           (type-of actions) (if (listp actions) (length actions) 0))
  (when actions
    (unless (listp actions)
      (message "[Benedict--normalize-actions] ERROR: actions not a list: %S" (type-of actions))
      (signal 'wrong-type-argument (list 'listp actions)))
    (let ((result (mapcar #'benedict-chat--validate-action actions)))
      (message "[Benedict--normalize-actions] DONE: %d actions validated" (length result))
      result)))

(defun benedict-chat--normalize-tool-ui (call state ui fallback-body)
  "Return CALL UI plist normalized with STATE and FALLBACK-BODY.
Also validates and normalizes :actions if present."
  (message "[Benedict--normalize-tool-ui] START: state=%s, ui=%S, fallback=%S" 
           state (type-of ui) (type-of fallback-body))
  (let* ((state (benedict-chat--normalize-tool-state state))
         (normalized (if (listp ui) (copy-sequence ui) nil)))
    (message "[Benedict--normalize-tool-ui] After normalize-state: state=%s, normalized=%S"
             state (type-of normalized))
    (setq normalized (or normalized (list)))
    (if (plist-member normalized :state)
        (setq normalized (plist-put normalized :state
                                    (benedict-chat--normalize-tool-state
                                     (plist-get normalized :state))))
      (setq normalized (plist-put normalized :state state)))
    ;; Removed default header setting to allow render logic to handle it
    (let ((body (if (plist-member normalized :body)
                    (plist-get normalized :body)
                  nil)))
      (message "[Benedict--normalize-tool-ui] Body before stringify: %S" (type-of body))
      (setq body (benedict-chat--tool-ui--stringify-body body fallback-body))
      (message "[Benedict--normalize-tool-ui] Body after stringify: %S" (type-of body))
      (setq normalized (plist-put normalized :body body)))
    ;; Validate and normalize actions if present
    (when (plist-member normalized :actions)
      (let ((actions (plist-get normalized :actions)))
        (message "[Benedict--normalize-tool-ui] Normalizing actions: %S" (type-of actions))
        (setq normalized (plist-put normalized :actions
                                    (benedict-chat--normalize-actions actions)))))
    (message "[Benedict--normalize-tool-ui] DONE: normalized=%S" (type-of normalized))
    normalized))

(defun benedict-chat--tool-ui-body-string (ui)
  "Return the body text for UI."
  (or (plist-get ui :body) ""))

(declare-function backtrace-to-string "backtrace" (&optional frames))
(declare-function current-backtrace "backtrace" ())

(defun benedict-chat--refresh-tool-block (item)
  "Refresh ITEM header and content after UI or metadata changes."
  (let ((ui (plist-get item :ui)))
    (message "[Benedict] Refreshing tool block (ui=%S)" (type-of ui))
    (condition-case content-err
        (let ((body-str (benedict-chat--tool-ui-body-string ui)))
          (message "[Benedict] Tool UI body string resolved: %S" (type-of body-str))
          (condition-case write-err
              (benedict-chat--write-message-item-content item body-str)
            (error
             (message "[Benedict] ERROR writing message content: %S" write-err)
             (message "[Benedict] Backtrace: %s" (backtrace-to-string (current-backtrace)))
             (error "Failed to write message content: %s" (error-message-string write-err)))))
      (error
       (message "[Benedict] ERROR building tool UI body: %S" content-err)
       (message "[Benedict] Backtrace: %s" (backtrace-to-string (current-backtrace)))
       (error "Failed to build tool UI body: %s" (error-message-string content-err))))
    (message "[Benedict] Updating tool header")
    (condition-case header-err
        (benedict-chat--update-tool-header item)
      (error
       (message "[Benedict] ERROR updating tool header: %S" header-err)
       (message "[Benedict] Backtrace: %s" (backtrace-to-string (current-backtrace)))))
    (message "[Benedict] Updating tool visibility")
    (condition-case vis-err
        (benedict-chat--update-tool-visibility item)
      (error
       (message "[Benedict] ERROR updating tool visibility: %S" vis-err)
       (message "[Benedict] Backtrace: %s" (backtrace-to-string (current-backtrace)))))))

(defun benedict-chat--prepare-thinking-block (item)
  "Install folding controls and overlays for thinking ITEM."
  (unless (plist-member item :thinking-folded)
    (plist-put item :thinking-folded t))
  (benedict-chat--ensure-thinking-overlay item)
  (benedict-chat--ensure-thinking-toggle item)
  (benedict-chat--apply-thinking-fold item))

(defun benedict-chat--ensure-thinking-invisibility ()
  "Ensure the buffer invisibility spec knows about thinking folds."
  (unless (listp buffer-invisibility-spec)
    (setq buffer-invisibility-spec
          (if buffer-invisibility-spec
              (list buffer-invisibility-spec)
            nil)))
  (unless (assoc 'benedict-chat-thinking buffer-invisibility-spec)
    (add-to-invisibility-spec 'benedict-chat-thinking)))

(defun benedict-chat--ensure-thinking-overlay (item)
  "Create or refresh the overlay hiding ITEM's content."
  (let* ((start-marker (plist-get item :content-start))
         (end-marker (plist-get item :content-end))
         (start (and start-marker (marker-position start-marker)))
         (end (and end-marker (marker-position end-marker))))
    (when (and start end)
      (let ((overlay-start (min start end))
            (overlay-end (max start end))
            (overlay (plist-get item :thinking-overlay)))
        (unless (overlayp overlay)
          (setq overlay (make-overlay overlay-start overlay-end))
          (overlay-put overlay 'evaporate t)
          (overlay-put overlay 'benedict-chat-thinking-overlay t)
          (plist-put item :thinking-overlay overlay))
        (move-overlay overlay overlay-start overlay-end)
        (benedict-chat--ensure-thinking-invisibility)))))

(defun benedict-chat--apply-thinking-fold (item)
  "Apply ITEM's folding state to its overlay and toggle."
  (let* ((overlay (plist-get item :thinking-overlay))
         (folded (plist-get item :thinking-folded)))
    (when (overlayp overlay)
      (overlay-put overlay 'invisible (and folded 'benedict-chat-thinking)))
    (benedict-chat--refresh-thinking-toggle item)))

(defun benedict-chat--thinking-toggle-label (item)
  "Return the label used for ITEM's toggle button."
  (if (plist-get item :thinking-folded)
      "Show thinking"
    "Hide thinking"))

(defun benedict-chat--insert-thinking-toggle (item)
  "Insert ITEM's toggle button at point and record markers."
  (let ((start (point)))
    (insert-text-button (benedict-chat--thinking-toggle-label item)
                        'face 'benedict-chat-button
                        'follow-link t
                        'help-echo "Toggle hidden reasoning"
                        'action #'benedict-chat--thinking-toggle-action
                        'benedict-chat-thinking-item item)
    (plist-put item :thinking-button-start (copy-marker start t))
    (plist-put item :thinking-button-end (copy-marker (point) nil))))

(defun benedict-chat--thinking-toggle-valid-p (item)
  "Return non-nil when ITEM already has a live toggle button."
  (let ((start (plist-get item :thinking-button-start))
        (end (plist-get item :thinking-button-end)))
    (and start end
         (marker-buffer start)
         (marker-buffer end)
         (marker-position start)
         (marker-position end))))

(defun benedict-chat--ensure-thinking-toggle (item)
  "Create a toggle button for ITEM or refresh the existing one."
  (if (benedict-chat--thinking-toggle-valid-p item)
      (benedict-chat--refresh-thinking-toggle item)
    (let ((header-end (plist-get item :header-end)))
      (when-let ((pos (and header-end (marker-position header-end))))
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char pos)
            (when (> (point) (point-min))
              (backward-char 1)
              (when (eq (char-after) ?\n)
                (unless (memq (char-before) '(?\s ?\t))
                  (insert " "))
                (benedict-chat--insert-thinking-toggle item)))))))))

(defun benedict-chat--refresh-thinking-toggle (item)
  "Update ITEM's toggle label to match its folding state."
  (let ((start (plist-get item :thinking-button-start))
        (end (plist-get item :thinking-button-end)))
    (when (and start end
               (marker-position start) (marker-position end))
      (let ((inhibit-read-only t)
            (start-pos (marker-position start))
            (end-pos (marker-position end)))
        (save-excursion
          (goto-char start-pos)
          (delete-region start-pos end-pos)
          (benedict-chat--insert-thinking-toggle item))))))

(defun benedict-chat--thinking-toggle-action (button)
  "Toggle the thinking block referenced by BUTTON."
  (let ((item (button-get button 'benedict-chat-thinking-item)))
    (when item
      (benedict-chat--set-thinking-folded item
                                          (not (plist-get item :thinking-folded))))))

(defun benedict-chat--set-thinking-folded (item folded)
  "Set ITEM's folding state to FOLDED."
  (plist-put item :thinking-folded folded)
  (benedict-chat--ensure-thinking-overlay item)
  (benedict-chat--apply-thinking-fold item))

(defun benedict-chat--update-thinking-overlay (item)
  "Refresh ITEM overlay boundaries after content changes."
  (let ((overlay (plist-get item :thinking-overlay)))
    (when (overlayp overlay)
      (let ((start-marker (plist-get item :content-start))
            (end-marker (plist-get item :content-end)))
        (when (and start-marker end-marker
                   (marker-position start-marker)
                   (marker-position end-marker))
          (let ((start (marker-position start-marker))
                (end (marker-position end-marker)))
            (move-overlay overlay
                          (min start end)
                          (max start end)))
          (benedict-chat--apply-thinking-fold item))))))

;; -------------------------------------------------------------------
;; Tool call helpers

(defun benedict-chat--tool-call-content (call)
  "Return a formatted string describing CALL arguments."
  (let ((call-id (or (plist-get call :id) "n/a"))
        (args (benedict-chat--tool-arguments-string (plist-get call :arguments))))
    (string-join
     (delq nil
           (list (format "Call ID: %s" call-id)
                 ""
                 "Arguments:"
                 args))
     "\n")))

(defun benedict-chat--tool-result-content (call output)
  "Return a formatted string for CALL result OUTPUT."
  (let ((call-id (or (plist-get call :id) "n/a"))
        (payload (if (and output (not (string-empty-p output)))
                     output
                   "Tool returned no output.")))
    (string-join
     (delq nil
           (list (format "Call ID: %s" call-id)
                 ""
                 payload))
     "\n")))

(defun benedict-chat--record-tool-block (call metadata &optional ui)
  "Insert a tool block for CALL using METADATA and optional UI."
  (let* ((initial-ui (benedict-chat--normalize-tool-ui
                      call
                      (plist-get metadata :status)
                      ui
                      (benedict-chat--tool-call-content call)))
         (item (benedict-chat--make-item 'tool
                                         :tool-call call
                                         :metadata metadata
                                         :ui initial-ui
                                         :content (benedict-chat--tool-ui-body-string initial-ui)
                                         :tool-folded t)))
    (benedict-chat--track-item item)
    (benedict-chat--render-tool-item item)
    item))

(defun benedict-chat--update-tool-block (item metadata ui fallback)
  "Update ITEM with METADATA and UI; FALLBACK is used for missing body text."
  (let* ((call (plist-get item :tool-call))
         (status (plist-get metadata :status)))
    (message "[Benedict] Updating tool block: status=%s, ui=%S, fallback=%S" 
             status (type-of ui) (type-of fallback))
    (condition-case norm-err
        (let ((normalized (benedict-chat--normalize-tool-ui
                           call
                           status
                           ui
                           fallback)))
          (message "[Benedict] Normalized UI: %S" (type-of normalized))
          (plist-put item :metadata metadata)
          (plist-put item :ui normalized)
          (let ((body-str (benedict-chat--tool-ui-body-string normalized)))
            (message "[Benedict] Tool body string: %S" (type-of body-str))
            (plist-put item :content body-str))
          (message "[Benedict] Calling refresh-tool-block")
          (benedict-chat--refresh-tool-block item))
      (error
       (message "[Benedict] ERROR normalizing tool UI: %S" norm-err)
       (message "[Benedict] Backtrace: %s" (backtrace-to-string (current-backtrace)))
       (error "Failed to update tool block: %s" (error-message-string norm-err))))))

(defun benedict-chat--normalize-tool-id (tool-id)
  "Return TOOL-ID coerced into a symbol."
  (cond
   ((symbolp tool-id) tool-id)
   ((stringp tool-id)
    (let* ((normalized (replace-regexp-in-string "_" "-" (downcase tool-id))))
      (intern normalized)))
   (t (intern (format "%s" tool-id)))))

(defun benedict-chat--tool-call-metadata (tool-id call status base-metadata)
  "Return metadata plist for TOOL-ID CALL with STATUS and BASE-METADATA."
  (apply #'benedict-chat--metadata
         (append (list :tool tool-id
                       :tool-call-id (plist-get call :id)
                       :status status)
                 (when base-metadata
                   (list :provider (plist-get base-metadata :provider)
                         :model (plist-get base-metadata :model))))))

(defun benedict-chat--normalize-tool-output (value)
  "Return VALUE normalized into a plist with :text, :ui, and :raw."
  (let* ((ui (and (listp value)
                  (plist-member value :ui)
                  (plist-get value :ui)))
         (text
          (cond
           ((and (listp value) (plist-member value :content))
            (plist-get value :content))
           ((and (listp value) (plist-member value :message))
            (plist-get value :message))
           ((and (listp value) (plist-member value :text))
            (plist-get value :text))
           ((stringp value) value)
           ((null value) "Tool returned no output.")
           (t (benedict-chat--tool-value-string value)))))
    (setq text (or text "Tool returned no output."))
    (list :text text :ui ui :raw value)))

(defun benedict-chat--tool-result-history-entry (tool-id call text metadata)
  "Return history entry for TOOL-ID CALL result TEXT and METADATA."
  (list :role 'tool
        :name (benedict-chat--tool-name-string tool-id)
        :tool-call-id (plist-get call :id)
        :content text
        :time (current-time)
        :metadata metadata))

(defun benedict-chat--invoke-tool-call (call metadata item)
  "Execute CALL (plist) using METADATA and update ITEM."
  (let* ((tool-id (benedict-chat--normalize-tool-id
                   (or (plist-get call :name) (plist-get call :tool))))
         (arguments (or (plist-get call :arguments) nil))
         (status 'success)
         (output nil))
    (message "[Benedict] Invoking tool: %s with args: %S" tool-id arguments)
    (condition-case err
        (progn
          (message "[Benedict] Tool invocation started for %s" tool-id)
          (setq output (benedict-tool-invoke tool-id arguments))
          (message "[Benedict] Tool %s returned successfully: %S" tool-id (type-of output)))
      (error
       (setq status 'failure)
       (message "[Benedict] Tool %s failed with error: %S (type: %s)" 
                tool-id err (type-of err))
       (message "[Benedict] Error details: %s" (error-message-string err))
       (message "[Benedict] Full backtrace: %s" (backtrace-to-string (current-backtrace)))
       (setq output (format "Tool error: %s" (error-message-string err)))))
    (message "[Benedict] Normalizing tool output for %s" tool-id)
    (let* ((normalized-output (benedict-chat--normalize-tool-output output))
           (text (plist-get normalized-output :text))
           (ui (plist-get normalized-output :ui))
           (result-metadata (benedict-chat--tool-call-metadata tool-id call status metadata)))
      (message "[Benedict] Normalized output: text=%s, ui=%S" (type-of text) (type-of ui))
      (when item
        (message "[Benedict] Updating tool block for %s" tool-id)
        (condition-case block-err
            (benedict-chat--update-tool-block
             item result-metadata ui
             (benedict-chat--tool-result-content call text))
          (error
           (message "[Benedict] ERROR updating tool block: %S" block-err)
           (message "[Benedict] Backtrace: %s" (backtrace-to-string (current-backtrace))))))
      (message "[Benedict] Storing tool result for %s" tool-id)
      (condition-case hist-err
          (benedict-chat--history-store
           (benedict-chat--tool-result-history-entry tool-id call text result-metadata))
        (error
         (message "[Benedict] ERROR storing tool result: %S" hist-err)
         (message "[Benedict] Backtrace: %s" (backtrace-to-string (current-backtrace))))))))

(defun benedict-chat--process-tool-calls (message tool-calls metadata)
  "Render TOOL-CALLS for MESSAGE and execute each tool using METADATA."
  (let (normalized-calls)
    (dolist (call tool-calls)
      (let* ((tool-id (benedict-chat--normalize-tool-id (or (plist-get call :name)
                                                            (plist-get call :tool))))
             (normalized (plist-put (copy-sequence call) :name tool-id))
             (call-metadata (benedict-chat--tool-call-metadata tool-id normalized 'in-progress metadata))
             (item (benedict-chat--record-tool-block normalized call-metadata)))
        (push normalized normalized-calls)
        (benedict-chat--invoke-tool-call normalized metadata item)))
    (plist-put message :tool-calls (nreverse normalized-calls))))

;; -------------------------------------------------------------------
;; Thinking detail helpers

(defun benedict-chat--normalize-seq (value)
  "Return VALUE coerced into a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((vectorp value) (append value nil))
   (t (list value))))

(defun benedict-chat--alist-to-plist (alist)
  "Convert ALIST into a plist with keyword keys."
  (let (plist)
    (dolist (pair alist plist)
      (let* ((key (car pair))
             (keyword (cond
                       ((keywordp key) key)
                       ((symbolp key) (intern (format ":%s" (symbol-name key))))
                       ((stringp key) (intern (concat ":" (downcase key))))
                       (t nil))))
        (when keyword
          (setq plist (plist-put plist keyword (cdr pair))))))))

(defun benedict-chat--next-thinking-temp-id ()
  "Return a generated identifier for thinking blocks."
  (setq benedict-chat--thinking-temp-counter (1+ benedict-chat--thinking-temp-counter))
  (format "benedict-thinking-%s-%d"
          (or benedict-chat--active-request-id
              benedict-chat--request-seq
              0)
          benedict-chat--thinking-temp-counter))

(defun benedict-chat--register-thinking-item (id item)
  "Register ITEM under identifier ID for later streaming updates."
  (when id
    (unless (hash-table-p benedict-chat--thinking-items)
      (setq benedict-chat--thinking-items (make-hash-table :test 'equal)))
    (puthash id item benedict-chat--thinking-items)))

(defun benedict-chat--lookup-thinking-item (id)
  "Return thinking item registered under ID, or nil."
  (when (and id (hash-table-p benedict-chat--thinking-items))
    (gethash id benedict-chat--thinking-items)))

(defun benedict-chat--thinking-label-from-type (type)
  "Return a user-facing label for reasoning TYPE."
  (let ((type-name (and type (downcase (format "%s" type)))))
    (cond
     ((member type-name '("reasoning.summary" "summary")) "Summary")
     ((member type-name '("reasoning.encrypted" "encrypted")) "Encrypted")
     (t nil))))

(defun benedict-chat--thinking-detail-text (detail)
  "Return display text for DETAIL plist."
  (cond
   ((plist-get detail :text) (plist-get detail :text))
   ((plist-get detail :summary) (plist-get detail :summary))
   ((plist-get detail :data)
    (let ((data (plist-get detail :data)))
      (if (and (stringp data) (not (string-empty-p data)))
          (format "[Encrypted reasoning block]\n%s" data)
        "[Encrypted reasoning block]")))
   (t nil)))

(defun benedict-chat--normalize-thinking-entry (entry)
  "Normalize a single thinking ENTRY into a plist."
  (cond
   ((null entry) nil)
   ((stringp entry)
    (list :id (benedict-chat--next-thinking-temp-id)
          :type "reasoning.text"
          :text entry
          :format "anthropic-claude-v1"))
   ((listp entry)
    (let* ((plist (if (and (consp (car entry))
                           (not (keywordp (caar entry))))
                      (benedict-chat--alist-to-plist entry)
                    entry))
           (result (copy-sequence plist)))
      (plist-put result :type (or (plist-get result :type) "reasoning.text"))
      (plist-put result :id (or (plist-get result :id)
                                (benedict-chat--next-thinking-temp-id)))
      (plist-put result :format (or (plist-get result :format)
                                    "anthropic-claude-v1"))
      (when-let ((chunks (plist-get result :chunks)))
        (plist-put result :text (mapconcat #'identity (benedict-chat--normalize-seq chunks) "")))
      result))
   (t nil)))

(defun benedict-chat--normalize-thinking-payload (thinking)
  "Normalize THINKING payloads into a list of detail plists."
  (cond
   ((null thinking) nil)
   ((stringp thinking)
    (list (benedict-chat--normalize-thinking-entry thinking)))
   ((vectorp thinking)
    (benedict-chat--normalize-thinking-payload (append thinking nil)))
   ((and (listp thinking)
         (cl-every #'stringp thinking))
    (list (benedict-chat--normalize-thinking-entry
           (string-join thinking "\n\n"))))
   ((listp thinking)
    (delq nil (mapcar #'benedict-chat--normalize-thinking-entry thinking)))
   (t nil)))

(defun benedict-chat--ensure-thinking-item (detail metadata)
  "Return the thinking item associated with DETAIL, creating it if needed."
  (let* ((id (or (plist-get detail :id)
                 (benedict-chat--next-thinking-temp-id)))
         (item (benedict-chat--lookup-thinking-item id)))
    (unless item
      (let ((label (benedict-chat--thinking-label-from-type (plist-get detail :type)))
            (meta (plist-put (copy-sequence metadata) :thinking t)))
        (setq item (benedict-chat--record-thinking "" meta
                                                   :thinking-id id
                                                   :thinking-label label
                                                   :thinking-type (plist-get detail :type)))
        (benedict-chat--register-thinking-item id item)))
    item))

(defun benedict-chat--write-thinking-content (item text replace)
  "Insert TEXT into ITEM's content region.
When REPLACE is non-nil, replace the entire block contents."
  (let ((content-start (plist-get item :content-start))
        (content-end (plist-get item :content-end))
        (block-end (plist-get item :end)))
    (when (and content-start content-end
               (marker-position content-start)
               (marker-position content-end))
      (let* ((start-pos (marker-position content-start))
             (end-pos (marker-position content-end))
             (insert-pos (if replace (min start-pos end-pos) end-pos))
             (delete-start (min start-pos end-pos))
             (delete-end (max start-pos end-pos))
             (inhibit-read-only t))
        (goto-char insert-pos)
        (when replace
          (delete-region delete-start delete-end)
          (goto-char delete-start))
        (let ((payload (or text "")))
          (when (> (length payload) 0)
            (insert payload)
            (unless (string-suffix-p "\n" payload)
              (insert "\n"))))
        (let ((new-end (point)))
          (set-marker content-end new-end)
          (plist-put item :content
                     (buffer-substring-no-properties
                      (marker-position content-start)
                      (marker-position content-end)))
          (when (and block-end (marker-position block-end))
            (set-marker block-end (marker-position block-end)))
          (benedict-chat--update-thinking-overlay item))))))

(defun benedict-chat--append-thinking-content (item text)
  "Append TEXT to ITEM's content."
  (when (and text (not (string-empty-p text)))
    (benedict-chat--write-thinking-content item text nil)))

(defun benedict-chat--replace-thinking-content (item text)
  "Replace ITEM content with TEXT."
  (benedict-chat--write-thinking-content item text t))

(defun benedict-chat--display-thinking-detail (detail metadata &optional append)
  "Render DETAIL using METADATA. APPEND when streaming, replace otherwise."
  (let ((item (benedict-chat--ensure-thinking-item detail metadata))
        (text (benedict-chat--thinking-detail-text detail)))
    (when item
      (if append
          (benedict-chat--append-thinking-content item text)
        (benedict-chat--replace-thinking-content item text)))))

(defun benedict-chat--collect-delta-reasoning-details (payload)
  "Extract reasoning details from streaming PAYLOAD."
  (let (details)
    (dolist (choice (benedict-chat--normalize-seq (plist-get payload :choices)))
      (let ((delta (plist-get choice :delta)))
        (dolist (detail (benedict-chat--normalize-seq
                         (and delta (plist-get delta :reasoning_details))))
          (when-let ((normalized (benedict-chat--normalize-thinking-entry detail)))
            (push normalized details)))))
    (nreverse details)))

(defun benedict-chat--delta-choice-text (choice)
  "Return flattened user-visible text for CHOICE delta."
  (or (plist-get choice :text)
      (let ((delta (plist-get choice :delta)))
        (when delta
          (benedict-chat--delta-text-from-delta delta)))))

(defun benedict-chat--delta-text-from-delta (delta)
  "Extract string content from DELTA plist."
  (cond
   ((plist-member delta :content)
    (let ((content (plist-get delta :content)))
      (cond
       ((stringp content) content)
       (content
        (mapconcat #'benedict-chat--delta-content-entry-text
                   (benedict-chat--normalize-seq content)
                   "")))))
   ((plist-member delta :text)
    (plist-get delta :text))
   (t nil)))

(defun benedict-chat--delta-content-entry-text (entry)
  "Return the visible text stored within ENTRY."
  (cond
   ((stringp entry) entry)
   ((listp entry)
    (or (plist-get entry :text)
        (plist-get entry :content)
        ""))
   (t "")))

(defun benedict-chat--collect-delta-message-content (payload)
  "Return concatenated assistant message text contained in PAYLOAD."
  (let (chunks)
    (dolist (choice (benedict-chat--normalize-seq (plist-get payload :choices)))
      (let ((text (benedict-chat--delta-choice-text choice)))
        (when (and text (> (length text) 0))
          (push text chunks))))
    (when-let ((direct (plist-get payload :content)))
      (cond
       ((stringp direct)
        (when (> (length direct) 0)
          (push direct chunks)))
       ((listp direct)
        (dolist (entry direct)
          (when (and (stringp entry) (> (length entry) 0))
            (push entry chunks))))
       ((vectorp direct)
        (dolist (entry (append direct nil))
          (when (and (stringp entry) (> (length entry) 0))
            (push entry chunks))))))
    (when chunks
      (mapconcat #'identity (nreverse chunks) ""))))

;; -------------------------------------------------------------------
;; Streaming assistant message helpers

(defun benedict-chat--streaming-reset ()
  "Clear any active streaming message state."
  (setq benedict-chat--streaming-message nil)
  (benedict-chat--stream-init (current-buffer)))

(defun benedict-chat--streaming-merge-metadata (payload)
  "Return merged metadata for PAYLOAD and existing streaming state."
  (let* ((state benedict-chat--streaming-message)
         (current (plist-get state :metadata))
         (provider (or (plist-get payload :provider)
                       (plist-get current :provider)))
         (model (or (plist-get payload :model)
                    (plist-get current :model)))
         (usage (or (plist-get payload :usage)
                    (plist-get current :usage))))
    (benedict-chat--metadata :provider provider :model model :usage usage)))

(defun benedict-chat--streaming-apply-metadata (payload)
  "Update streaming metadata and header for PAYLOAD."
  (when-let ((message (plist-get benedict-chat--streaming-message :message)))
    (let* ((metadata (benedict-chat--streaming-merge-metadata payload))
           (state (plist-put benedict-chat--streaming-message :metadata metadata)))
      (setq benedict-chat--streaming-message state)
      (plist-put message :metadata metadata)
      (when-let ((item (plist-get message :item)))
        (plist-put item :metadata metadata)
        (benedict-chat--refresh-message-header item)))))

(defun benedict-chat--streaming-ensure-message (payload)
  "Ensure a placeholder assistant message exists for PAYLOAD."
  (unless (plist-get benedict-chat--streaming-message :message)
    (let* ((metadata (benedict-chat--metadata
                      :provider (plist-get payload :provider)
                      :model (plist-get payload :model)))
           (record (list :role 'assistant
                         :content ""
                         :display-content nil
                         :time (current-time)
                         :metadata metadata)))
      (setq record (benedict-chat--record-message record))
      (setq benedict-chat--streaming-message
            (list :message record
                  :content ""
                  :metadata metadata))))
  (benedict-chat--streaming-apply-metadata payload)
  (plist-get benedict-chat--streaming-message :message))

(defun benedict-chat--streaming-append-text (payload text)
  "Append TEXT for PAYLOAD to the streaming assistant message."
  (when (and text (> (length text) 0))
    (when-let ((message (benedict-chat--streaming-ensure-message payload)))
      (let* ((state benedict-chat--streaming-message)
             (current (or (plist-get state :content) ""))
             (updated (concat current text)))
        (setq state (plist-put state :content updated))
        (setq benedict-chat--streaming-message state)
        (benedict-chat--replace-message-content message updated)))))

(defun benedict-chat--complete-streaming-message (metadata content display-content empty-response)
  "Finalize the streaming assistant message with METADATA and CONTENT.
DISPLAY-CONTENT replaces the visible text when EMPTY-RESPONSE is non-nil."
  (when-let ((message (plist-get benedict-chat--streaming-message :message)))
    (let* ((state benedict-chat--streaming-message)
           (fallback (or (plist-get state :content) ""))
           (actual (or content fallback ""))
           (visible (if empty-response
                        (or display-content actual)
                      actual)))
      (benedict-chat--replace-message-content message visible)
      (plist-put message :content actual)
      (if empty-response
          (plist-put message :display-content visible)
        (plist-put message :display-content nil))
      (plist-put message :metadata metadata)
      (plist-put message :time (current-time))
      (when-let ((item (plist-get message :item)))
        (plist-put item :metadata metadata)
        (benedict-chat--refresh-message-header item))))
  (benedict-chat--streaming-reset))

(defun benedict-chat--fail-streaming-message (content metadata)
  "Replace the streaming message with error CONTENT and METADATA.
Returns non-nil when an active streaming entry handled the error."
  (let ((handled nil))
    (when-let ((message (plist-get benedict-chat--streaming-message :message)))
      (setq handled t)
      (benedict-chat--replace-message-content message content)
      (plist-put message :content content)
      (plist-put message :display-content nil)
      (plist-put message :metadata metadata)
      (plist-put message :time (current-time))
      (when-let ((item (plist-get message :item)))
        (plist-put item :metadata metadata)
        (benedict-chat--refresh-message-header item)))
    (benedict-chat--streaming-reset)
    handled))

(defun benedict-chat--format-metadata-line (metadata &optional prefix)
  "Return a user-facing line for METADATA plist with optional PREFIX."
  (when metadata
    (let (parts)
      (when-let ((provider (plist-get metadata :provider)))
        (push (format "provider %s" provider) parts))
      (when-let ((model (plist-get metadata :model)))
        (push model parts))
      (when-let ((latency (plist-get metadata :latency)))
        (push (format "%.2fs" latency) parts))
      (when-let ((usage (plist-get metadata :usage)))
        (let* ((prompt (benedict-chat--usage-value usage "prompt_tokens"))
               (completion (benedict-chat--usage-value usage "completion_tokens"))
               (total (or (benedict-chat--usage-value usage "total_tokens")
                          (and prompt completion (+ prompt completion))))
               (cost (or (benedict-chat--usage-value usage "cost")
                         (benedict-chat--usage-value usage "total_cost"))))
          (when (or prompt completion total cost)
            (push (format "tokens p:%s / c:%s%s%s"
                          (or prompt "?")
                          (or completion "?")
                          (if total (format " / t:%s" total) "")
                          (if cost (format " / cost:%s" cost) ""))
                  parts))))
      (when (plist-get metadata :empty-response)
        (push "empty response" parts))
      (when (plist-get metadata :error)
        (let ((status (plist-get metadata :status))
              (code (plist-get metadata :code))
              (retryable (plist-get metadata :retryable)))
          (push (format "error%s%s%s"
                        (if code (format " %s" code) "")
                        (if status (format " (HTTP %s)" status) "")
                        (if retryable " — retryable" ""))
                parts)))
      (when parts
        (concat (or prefix "") (string-join (nreverse parts) " · "))))))

(defun benedict-chat--clear-block-buttons (start-marker end-marker)
  "Remove previously inserted code block buttons between START-MARKER and END-MARKER."
  (when (and start-marker end-marker
             (marker-position start-marker)
             (marker-position end-marker))
    (let ((pos (marker-position start-marker)))
      (while (< pos (marker-position end-marker))
        (let ((button-start (text-property-any pos (marker-position end-marker)
                                               'benedict-chat-block-button t)))
          (if (not button-start)
              (setq pos (marker-position end-marker))
            (let ((button-end (or (text-property-not-all button-start (marker-position end-marker)
                                                         'benedict-chat-block-button t)
                                  (marker-position end-marker))))
              (let ((inhibit-read-only t))
                (delete-region button-start button-end))
              (setq pos (marker-position start-marker)))))))))

(defun benedict-chat--apply-code-fences (start end)
  "Highlight code fences between START and END and install block buttons."
  (save-excursion
    (save-match-data
      (goto-char start)
      (let ((case-fold-search nil))
        (while (re-search-forward "^\W*```\\([^ \n\r]*\\)?[ \t]*\n" end t)
          (let* ((language (match-string 1))
                 (body-start (point))
                 (closing (save-excursion
                            (when (re-search-forward "^\W*```[ \t]*$" end t)
                              (match-beginning 0)))))
            (if (and closing (> closing body-start))
                (let ((button-pos (save-excursion
                                    (goto-char closing)
                                    (forward-line 1)
                                    (point))))
                  (benedict-chat--decorate-code-block body-start closing language button-pos)
                  (goto-char button-pos))
              (benedict-chat--decorate-code-block body-start end language nil)
              (goto-char end))))))))

(defun benedict-chat--decorate-code-block (body-start body-end language insertion-point)
  "Apply faces to BODY-START → BODY-END and insert buttons near INSERTION-POINT.
LANGUAGE is the identifier included in the fence (may be nil)."
  (when (> body-end body-start)
    (let* ((lang (and language (string-trim (substring-no-properties language))))
           (target (list :start (copy-marker body-start t)
                         :end (copy-marker body-end nil)
                         :language lang)))
      (remove-text-properties body-start body-end '(face nil font-lock-face nil))
      (add-text-properties body-start body-end
                           (list 'face 'benedict-chat-code-block
                                 'font-lock-face 'benedict-chat-code-block
                                 'benedict-chat-code-block t
                                 'benedict-chat-code-language lang))
      (when insertion-point
        (benedict-chat--insert-code-block-buttons insertion-point target))
      target)))

(defun benedict-chat--insert-code-block-buttons (position target)
  "Insert Copy/Apply buttons at POSITION operating on TARGET."
  (save-excursion
    (goto-char position)
    (let ((inhibit-read-only t))
      (unless (or (bobp) (eq (char-before) ?\n))
        (insert "\n"))
      (let ((line-start (point)))
        (insert "  ")
        (benedict-chat--insert-action-button "Copy block" #'benedict-chat-copy-block target)
        (insert "   ")
        (benedict-chat--insert-action-button "Apply block" #'benedict-chat-apply-block target)
        (insert "\n")
        (add-text-properties line-start (point)
                             '(benedict-chat-block-button t
                               read-only t
                               front-sticky t
                               rear-nonsticky t))))))

(defun benedict-chat--insert-action-button (label action target)
  "Insert button with LABEL that runs ACTION on TARGET."
  (insert-text-button
   label
   'face 'benedict-chat-button
   'follow-link t
   'help-echo (format "%s (code block)" label)
   'action action
   'benedict-chat-target target))

(defun benedict-chat--block-target-string (target)
  "Return the code block contents described by TARGET plist."
  (let* ((start-marker (plist-get target :start))
         (end-marker (plist-get target :end))
         (start (and start-marker (marker-position start-marker)))
         (end (and end-marker (marker-position end-marker))))
    (unless (and start end (> end start))
      (user-error "Code block region is unavailable"))
    (buffer-substring-no-properties start end)))

(defun benedict-chat-copy-block (button)
  "Copy the code block associated with BUTTON to the kill ring."
  (interactive (list (or (button-at (point))
                         (user-error "No code block button at point"))))
  (let* ((target (and button (button-get button 'benedict-chat-target)))
         (text (benedict-chat--block-target-string target)))
    (kill-new text)
    (message "Benedict: copied code block to kill ring")
    text))

(defun benedict-chat-apply-block (button)
  "Insert the code block for BUTTON into `benedict-chat-apply-buffer-name'."
  (interactive (list (or (button-at (point))
                         (user-error "No code block button at point"))))
  (let* ((target (and button (button-get button 'benedict-chat-target)))
         (text (benedict-chat--block-target-string target))
         (buffer (get-buffer-create benedict-chat-apply-buffer-name)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert text)
      (goto-char (point-min)))
    (message "Benedict: inserted block into %s" benedict-chat-apply-buffer-name)
    buffer))

(defun benedict-chat--usage-value (usage key)
  "Fetch KEY from USAGE alist/plist (keys may be strings)."
  (when usage
    (let* ((sym (intern key))
           (keyword (intern (concat ":" key))))
      (or (when (listp usage)
            (cond
             ((and (consp (car usage)) (not (keywordp (caar usage))))
              (or (cdr (assoc-string key usage))
                  (cdr (assq sym usage))
                  (cdr (assq keyword usage))))
             ((keywordp (car usage))
              (plist-get usage keyword))))
          (when (and (listp usage) (keywordp (car usage)))
            (plist-get usage keyword))))))

(defun benedict-chat--message->provider (message)
  "Convert MESSAGE plist into provider payload form."
  (let* ((role (plist-get message :role))
         (content (plist-get message :content))
         (tool-calls (plist-get message :tool-calls))
         (name (plist-get message :name))
         (tool-call-id (plist-get message :tool-call-id))
         (payload (list :role role
                        :content (if (stringp content) content ""))))
    (when tool-calls
      (setq payload (plist-put payload :tool-calls tool-calls)))
    (when (and name (stringp name))
      (setq payload (plist-put payload :name name)))
    (when tool-call-id
      (setq payload (plist-put payload :tool-call-id tool-call-id)))
    payload))

(defun benedict-chat--build-request ()
  "Build a provider request plist from buffer state."
  (let* ((profile (benedict-chat--effective-profile))
         (provider (benedict-chat--resolve-provider profile))
         (model (benedict-chat--resolve-model
                 provider profile benedict-chat--compose-model-override))
         (system (benedict-chat--system-messages profile))
         (history (mapcar #'benedict-chat--message->provider
                          (benedict-chat--message-history)))
         (tools (benedict-chat--resolve-tools profile)))
    (list :provider provider
          :model model
          :profile profile
          :tools tools
          :autonomy (benedict-chat--profile-autonomy profile)
          :verbosity (benedict-chat--profile-verbosity profile)
          :messages (append system history))))

(defun benedict-chat--ensure-not-busy ()
  "Signal an error when a provider request is already running."
  (when benedict-chat--pending-request
    (user-error "A provider request is already in flight")))

(defun benedict-chat--metadata (&rest pairs)
  "Build a metadata plist from PAIRS ignoring nil values."
  (let (metadata)
    (while pairs
      (let ((key (pop pairs))
            (value (pop pairs)))
        (when value
          (setq metadata (plist-put metadata key value)))))
    metadata))

(defun benedict-chat--ensure-streaming-message (payload)
  "Ensure a streaming assistant message exists in the buffer."
  (unless benedict-chat--streaming-message
    (let* ((metadata (benedict-chat--metadata
                      :provider (plist-get payload :provider)
                      :model (plist-get payload :model)
                      :usage (plist-get payload :usage)))
           (record (list :role 'assistant
                         :content ""
                         :time (current-time)
                         :metadata metadata)))
      ;; Insert header and register item in history
      (setq record (benedict-chat--record-message record))
      
      ;; Initialize stream state.
      ;; benedict-chat--insert-message appends a newline at the end.
      ;; We want to stream content *before* that footer newline so it stays inside the block.
      (with-current-buffer (current-buffer)
        (save-excursion
          (goto-char (point-max))
          (when (eq (char-before) ?\n)
            (backward-char 1))
          (benedict-chat--stream-init (current-buffer))))

      (setq benedict-chat--streaming-message
            (list :message record
                  :content ""
                  :metadata metadata)))))

(defun benedict-chat--handle-provider-delta (payload)
  "Handle structured PAYLOAD updates from the provider."
  (benedict-chat--telemetry-streaming payload)
  (let ((kind (plist-get payload :kind))
        (text (plist-get payload :text)))
    (pcase kind
      ('content-delta
       (benedict-chat--ensure-streaming-message payload)
       (benedict-chat--stream-insert-delta benedict-stream-state text)
       (benedict-chat--apply-buffered-faces benedict-stream-state))
      ('thinking-delta
       ;; TODO: Handle thinking deltas
       nil))))

(defun benedict-chat--handle-provider-success (result)
  "Handle RESULT returned from the provider."
  (let* ((streaming-state benedict-chat--streaming-message)
         (streaming-msg (and streaming-state (plist-get streaming-state :message)))
         (request (plist-get benedict-chat--last-dispatch :request))
         (message (plist-get result :message))
         (content (or (plist-get message :content) ""))
         (role (or (plist-get message :role) 'assistant))
         (tool-calls (plist-get message :tool-calls))
         (provider (or (plist-get result :provider)
                       (plist-get request :provider)
                       (benedict-chat--resolve-provider)))
         (model (or (plist-get result :model)
                    (plist-get request :model)))
         (latency (plist-get result :latency))
         (usage (plist-get result :usage))
         (metadata (benedict-chat--metadata
                    :provider provider
                    :model model
                    :latency latency
                    :usage usage)))

    (setq benedict-chat--pending-request nil)
    (setq benedict-chat--active-request-id nil)
    (benedict-chat--streaming-reset)

    (benedict-chat--telemetry-finish 'complete metadata)
    
    (if streaming-msg
        ;; Path A: Update the existing streaming message
        (let ((record streaming-msg))
          ;; Update record fields
          (plist-put record :content content)
          (plist-put record :metadata metadata)
          (when tool-calls (plist-put record :tool-calls tool-calls))

          ;; Note: The record is already in benedict-chat--messages
          ;; and already rendered in the buffer.

          ;; If we have tool calls, we need to render them now.
          (when tool-calls
            (benedict-chat--process-tool-calls record tool-calls metadata)
            (benedict-chat--loop-step record)))
      
      ;; Path B: Insert new message (non-streaming)
      (let ((record (list :role role :content content :time (current-time) :metadata metadata)))
        (when tool-calls (plist-put record :tool-calls tool-calls))
        (push record benedict-chat--messages)
        (benedict-chat--insert-message record)
        
        (when tool-calls
          (benedict-chat--process-tool-calls record tool-calls metadata)
          (benedict-chat--loop-step record))))
    
    (message "Benedict: %s replied via %s" 
             (or model "provider") 
             (benedict-chat--provider-label provider))))

(defun benedict-chat--format-error-content (payload)
  "Return a human-readable string for PAYLOAD."
  (let ((message (or (plist-get payload :message) "Unknown error"))
        (code (plist-get payload :code))
        (status (plist-get payload :status))
        (retryable (plist-get payload :retryable)))
    (string-join
     (delq nil
           (list (when code (format "Error %s" code))
                 (when status (format "HTTP %s" status))
                 message
                 (when retryable "Retry is available.")))
     " — ")))

(defun benedict-chat--handle-provider-error (payload)
  "Render PAYLOAD returned from provider failure."
  (setq benedict-chat--pending-request nil)
  (setq benedict-chat--active-request-id nil)
  (let ((content (benedict-chat--format-error-content payload))
        (metadata (benedict-chat--metadata
                   :provider (or (plist-get payload :provider)
                                 (plist-get (plist-get benedict-chat--last-dispatch :request) :provider)
                                 (benedict-chat--resolve-provider))
                   :error t
                   :status (plist-get payload :status)
                   :code (plist-get payload :code)
                   :retryable (plist-get payload :retryable))))
    (benedict-chat--telemetry-finish 'error metadata)
    (unless (benedict-chat--fail-streaming-message content metadata)
      (benedict-chat--record-message
       (list :role 'assistant :content content :time (current-time) :metadata metadata)))
    (message "Benedict provider error: %s" content)))

(defun benedict-chat--start-dispatch (request &optional retry)
  "Send REQUEST through the provider. RETRY notes when replaying."
  (let* ((buffer (current-buffer))
         (provider-id (or (plist-get request :provider) benedict-provider))
         (provider-label (benedict-chat--provider-label provider-id)))
    (setq benedict-chat--request-seq (1+ benedict-chat--request-seq))
    (setq benedict-chat--active-request-id benedict-chat--request-seq)
    (setq benedict-chat--thinking-temp-counter 0)
    (benedict-chat--streaming-reset)
    (benedict-chat--telemetry-begin request)
    (setq benedict-chat--last-dispatch
          (list :request request :timestamp (current-time) :retry retry))
    (message "Benedict: contacting %s%s..."
             provider-label (if retry " (retry)" ""))
    (condition-case err
        (let ((benedict-provider provider-id))
          (setq benedict-chat--pending-request
                (benedict-provider-dispatch
                 request
                 :on-success (lambda (result)
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (benedict-chat--handle-provider-success result))))
                 :on-error (lambda (payload)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (benedict-chat--handle-provider-error payload))))
                 :on-delta (lambda (&rest payload)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 ;; If payload is wrapped in a list, unwrap it
                                 (let ((data (if (and (listp payload) 
                                                      (not (keywordp (car payload)))
                                                      (listp (car payload)))
                                                 (car payload)
                                               payload)))
                                   (benedict-chat--handle-provider-delta data))))) )))
      (error
       (setq benedict-chat--pending-request nil)
       (let ((payload (list :message (error-message-string err)
                            :type 'dispatch
                            :provider benedict-provider
                            :retryable nil)))
         (benedict-chat--handle-provider-error payload))))))

(defun benedict-chat-send-prompt (text)
  "Send TEXT to the provider and insert the assistant reply."
  (interactive (list (read-string "Prompt: ")))
  (benedict-chat--send-text text))

(defun benedict-chat--send-text (text)
  "Helper implementing the logic behind `benedict-chat-send-prompt'."
  (unless (derived-mode-p 'benedict-chat-mode)
    (user-error "Not in a Benedict chat buffer"))
  (when (string-blank-p text)
    (user-error "Prompt is empty"))
  (benedict-chat--ensure-not-busy)
  (setq benedict-chat--loop-start-time (float-time))
  (setq benedict-chat--loop-turn-count 0)
  (setq benedict-chat--loop-canceled nil)
  (benedict-chat--record-message
   (list :role 'user :content text :time (current-time)))
  (benedict-chat--start-dispatch (benedict-chat--build-request)))

;; -------------------------------------------------------------------
;; Compose buffer flow (context-aware prompts)

(defvar-local benedict-chat-compose--chat-buffer nil
  "Parent chat buffer associated with this compose buffer.")

(defvar-local benedict-chat-compose--body-start nil
  "Marker pointing to the start of the editable body in compose buffers.")

(defvar benedict-chat-compose-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'benedict-chat-compose-send)
    (define-key m (kbd "C-c C-k") #'benedict-chat-compose-cancel)
    m)
  "Keymap for `benedict-chat-compose-mode'.")

(define-derived-mode benedict-chat-compose-mode text-mode "Benedict-Compose"
  "Major mode for composing Benedict prompts with context."
  (setq-local benedict-chat-compose--chat-buffer nil)
  (setq-local benedict-chat-compose--body-start (make-marker))
  (setq-local mode-line-process nil)
  (setq-local header-line-format nil)
  (visual-line-mode 1))

(defun benedict-chat--compose-buffer-name (chat-buffer)
  "Return a compose buffer name for CHAT-BUFFER."
  (format benedict-chat-compose-buffer-name-format (buffer-name chat-buffer)))

(defun benedict-chat--ensure-chat-buffer ()
  "Return the active chat buffer, creating one if necessary."
  (if (derived-mode-p 'benedict-chat-mode)
      (current-buffer)
    (let ((buf (get-buffer-create benedict-chat-buffer-name)))
      (with-current-buffer buf
        (unless (derived-mode-p 'benedict-chat-mode)
          (benedict-chat-mode)))
      buf)))

(defun benedict-chat--compose-header-text (chat-buffer)
  "Return header text for CHAT-BUFFER's compose buffer."
  (with-current-buffer chat-buffer
    (let* ((profile (benedict-chat--effective-profile))
           (profile-label (propertize (benedict-chat--profile-label profile)
                                      'mouse-face 'mode-line-highlight
                                      'help-echo "Choose a Benedict profile (click)"
                                      'local-map benedict-chat--profile-button-map))
           (provider (benedict-chat--resolve-provider profile))
           (provider-label (propertize (benedict-chat--provider-label provider)
                                       'mouse-face 'mode-line-highlight
                                       'help-echo "Choose a Benedict provider (click)"
                                       'local-map benedict-chat--provider-button-map))
           (model (benedict-chat--resolve-model
                   provider profile benedict-chat--compose-model-override))
           (override (and (stringp benedict-chat--compose-model-override)
                          (not (string-empty-p benedict-chat--compose-model-override))))
           (model-label (propertize (or (and override
                                             (format "%s (compose override)"
                                                     benedict-chat--compose-model-override))
                                        (or model "n/a"))
                                    'mouse-face 'mode-line-highlight
                                    'help-echo "Set a per-compose model override (click)"
                                    'local-map benedict-chat--model-button-map))
           (project (or (benedict-chat--project-root) "n/a"))
           (summary (or (benedict-context-summary (or benedict-chat--context-slices nil))
                        "n/a")))
      (format "Profile: %s    Provider: %s    Model: %s    Project: %s    Context: %s\n"
              profile-label provider-label model-label project summary))))

(defun benedict-chat--sanitize-handle (handle)
  "Return HANDLE trimmed and with unsafe characters replaced."
  (let* ((trimmed (string-trim (or handle "")))
         (spaced (replace-regexp-in-string "[[:space:]]+" "-" trimmed))
         (clean (replace-regexp-in-string "[^A-Za-z0-9._:-]" "-" spaced)))
    (replace-regexp-in-string "-+" "-" clean)))

(defun benedict-chat--valid-handle-p (handle)
  "Return non-nil when HANDLE matches `benedict-chat--handle-regexp'."
  (and (stringp handle)
       (string-match-p benedict-chat--handle-regexp handle)))

(defun benedict-chat--preferred-handle (candidate)
  "Return a sanitized HANDLE string derived from CANDIDATE or fallback."
  (let* ((sanitized (benedict-chat--sanitize-handle candidate))
         (fallback (benedict-chat--sanitize-handle "context")))
    (or (and (benedict-chat--valid-handle-p sanitized) sanitized)
        fallback)))

(defun benedict-chat--context-handles (slices)
  "Return a list of handles present in SLICES."
  (delq nil (mapcar (lambda (slice) (plist-get slice :handle)) slices)))

(defun benedict-chat--prepare-context-slice (slice existing-handles)
  "Prompt for a handle for SLICE, respecting EXISTING-HANDLES.
Returns a plist (:slice :replacing) where :slice carries the final handle."
  (let* ((default (or (plist-get slice :handle-default)
                      (plist-get slice :handle)
                      (plist-get slice :label)
                      "context"))
         (proposal (benedict-chat--preferred-handle default))
         (handles (cl-remove-if-not #'identity existing-handles))
         (final-handle nil))
    (if noninteractive
        (setq final-handle proposal)
      (while (not final-handle)
        (let* ((input (string-trim (read-string
                                    (format "Context handle (default %s): " proposal)
                                    nil nil proposal)))
               (candidate (if (string-empty-p input) proposal input))
               (sanitized (benedict-chat--sanitize-handle candidate)))
          (cond
           ((not (benedict-chat--valid-handle-p sanitized))
            (message "Handle must match %s" benedict-chat--handle-regexp))
           ((and (member sanitized handles)
                 (not (yes-or-no-p (format "Handle %s already in use. Replace it? "
                                           sanitized))))
            (setq proposal sanitized))
           (t (setq final-handle sanitized))))))
    (let* ((handle final-handle)
           (replacing (member handle handles))
           (final-slice (plist-put (copy-sequence slice) :handle handle)))
      (list :slice final-slice :replacing replacing))))

(defun benedict-chat--upsert-context-slice (slices slice)
  "Insert or replace SLICE in SLICES keyed by :handle."
  (let* ((handle (plist-get slice :handle))
         (updated nil)
         (result (mapcar (lambda (existing)
                           (if (and handle
                                    (string= handle (plist-get existing :handle)))
                               (progn
                                 (setq updated t)
                                 slice)
                             existing))
                         slices)))
    (if updated
        result
      (append result (list slice)))))

(defun benedict-chat--insert-handle-link (handle)
  "Insert [[HANDLE]] at point inside the compose body."
  (insert (format "[[%s]]" handle)))

(defun benedict-chat--extract-handle-links (text)
  "Return a list of handle names referenced as [[handle]] in TEXT."
  (let (result (start 0))
    (while (string-match "\\[\\[\\([A-Za-z0-9._:-]+\\)\\]\\]" text start)
      (push (match-string 1 text) result)
      (setq start (match-end 0)))
    (nreverse (cl-delete-duplicates result :test #'string=))))

(defun benedict-chat--warn-unknown-handles (body-handles slices)
  "Warn when BODY-HANDLES are not present in SLICES."
  (let* ((known (benedict-chat--context-handles slices))
         (unknown (cl-set-difference body-handles known :test #'string=)))
    (when unknown
      (message "Benedict: unknown context handles: %s" (string-join unknown ", ")))
    unknown))

(defun benedict-chat-compose--render-header ()
  "Render or refresh the compose header for the current buffer."
  (let* ((body-start (or (and benedict-chat-compose--body-start
                              (marker-position benedict-chat-compose--body-start))
                         (point-min)))
         (body-point (let ((pos (point)))
                       (when (>= pos body-start)
                         (- pos body-start))))
         (body (buffer-substring-no-properties body-start (point-max)))
         (chat benedict-chat-compose--chat-buffer)
         (header (if (buffer-live-p chat)
                     (benedict-chat--compose-header-text chat)
                   "Profile: n/a    Project: n/a    Context: n/a\n"))
         (context-preview (when (and chat (buffer-live-p chat))
                            (with-current-buffer chat
                              (when benedict-chat--context-slices
                                (concat "Context (preview):\n"
                                        (benedict-context-format-for-compose
                                         benedict-chat--context-slices)
                                        "\n")))))
         (inhibit-read-only t))
    (erase-buffer)
    (insert header benedict-chat--compose-separator)
    (when context-preview
      (insert context-preview benedict-chat--compose-separator))
    (setq benedict-chat-compose--body-start (copy-marker (point)))
    (set-marker-insertion-type benedict-chat-compose--body-start nil)
    (add-text-properties (point-min) benedict-chat-compose--body-start
                         '(read-only t front-sticky t rear-nonsticky t))
    (insert body)
    (goto-char (min (point-max)
                    (+ (marker-position benedict-chat-compose--body-start)
                       (or body-point (length body)))))))

(defun benedict-chat--refresh-compose-header ()
  "Refresh compose buffer header for the current chat."
  (when (and benedict-chat--compose-buffer
             (buffer-live-p benedict-chat--compose-buffer))
    (with-current-buffer benedict-chat--compose-buffer
      (benedict-chat-compose--render-header))))

(defun benedict-chat--ensure-compose-buffer ()
  "Return the compose buffer for the current chat, creating it if needed."
  (let ((chat (current-buffer)))
    (unless (derived-mode-p 'benedict-chat-mode)
      (user-error "Compose buffers are only available from Benedict chat"))
    (unless (and benedict-chat--compose-buffer
                 (buffer-live-p benedict-chat--compose-buffer))
      (let ((buffer (get-buffer-create (benedict-chat--compose-buffer-name chat))))
        (setq benedict-chat--compose-buffer buffer)
        (with-current-buffer buffer
          (benedict-chat-compose-mode)
          (setq-local benedict-chat-compose--chat-buffer chat)
          (benedict-chat-compose--render-header))))
    benedict-chat--compose-buffer))

(defun benedict-chat-compose-open ()
  "Open or focus the compose buffer for the current chat."
  (interactive)
  (let* ((chat (benedict-chat--ensure-chat-buffer))
         (compose (with-current-buffer chat
                    (benedict-chat--ensure-compose-buffer))))
    (pop-to-buffer compose)
    (goto-char (point-max))
    (message "Compose buffer ready. C-c C-c to send; C-c C-k to cancel.")))

(defun benedict-chat-compose--body-text ()
  "Return the editable body text from the current compose buffer."
  (buffer-substring-no-properties
   (or (marker-position benedict-chat-compose--body-start) (point-min))
   (point-max)))

(defun benedict-chat--assemble-message-text (prompt slices)
  "Return final user message text combining PROMPT and SLICES."
  (let* ((context (benedict-context-format-for-send slices))
         (body (string-trim prompt)))
    (string-join (delq nil (list context body)) "\n\n")))

(defun benedict-chat--clear-compose-state ()
  "Clear compose buffer reference for the current chat."
  (when (and benedict-chat--compose-buffer
             (buffer-live-p benedict-chat--compose-buffer))
    (kill-buffer benedict-chat--compose-buffer))
  (setq benedict-chat--compose-model-override nil)
  (setq benedict-chat--compose-buffer nil)
  (let* ((provider (benedict-chat--resolve-provider))
         (model (benedict-chat--resolve-model
                 provider
                 (benedict-chat--effective-profile)
                 benedict-chat--compose-model-override)))
    (benedict-chat--telemetry-update
     :provider (benedict-chat--provider-label provider)
     :model model)))

(defun benedict-chat-compose-send ()
  "Send the composed prompt to the associated chat buffer."
  (interactive)
  (unless (derived-mode-p 'benedict-chat-compose-mode)
    (user-error "Not in a Benedict compose buffer"))
  (unless (buffer-live-p benedict-chat-compose--chat-buffer)
    (user-error "Parent chat buffer is unavailable"))
  (let* ((compose (current-buffer))
         (prompt (string-trim (benedict-chat-compose--body-text))))
    (when (string-blank-p prompt)
      (user-error "Prompt is empty"))
    (let* ((chat benedict-chat-compose--chat-buffer)
           (slices (with-current-buffer chat benedict-chat--context-slices))
           (body-handles (benedict-chat--extract-handle-links prompt))
           (text (benedict-chat--assemble-message-text prompt slices)))
      (benedict-chat--warn-unknown-handles body-handles slices)
      (with-current-buffer chat
        (benedict-chat--send-text text)
        (unless benedict-chat-context-retain-after-send
          (setq benedict-chat--context-slices nil))
        (benedict-chat--clear-compose-state))
      (when (buffer-live-p chat)
        (pop-to-buffer chat))
      (when (buffer-live-p compose)
        (kill-buffer compose))
      (message "Benedict: sent prompt with context"))))

(defun benedict-chat-compose-cancel ()
  "Cancel composition and discard pending context."
  (interactive)
  (unless (derived-mode-p 'benedict-chat-compose-mode)
    (user-error "Not in a Benedict compose buffer"))
  (let ((chat benedict-chat-compose--chat-buffer))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (setq benedict-chat--context-slices nil)
        (benedict-chat--clear-compose-state))))
  (when (buffer-live-p benedict-chat-compose--chat-buffer)
    (pop-to-buffer benedict-chat-compose--chat-buffer))
  (when (buffer-live-p (current-buffer))
    (kill-buffer (current-buffer)))
  (message "Benedict: canceled compose buffer"))

(defun benedict-chat--deliver-context-slices (slices)
  "Attach SLICES to the compose buffer for the current chat."
  (let* ((chat (benedict-chat--ensure-chat-buffer))
         (compose (with-current-buffer chat
                    (benedict-chat--ensure-compose-buffer)))
         (prepared nil))
    (with-current-buffer chat
      (let ((existing (benedict-chat--context-handles benedict-chat--context-slices)))
        (dolist (slice slices)
          (let* ((entry (benedict-chat--prepare-context-slice slice existing))
                 (final (plist-get entry :slice)))
            (push entry prepared)
            (setq benedict-chat--context-slices
                  (benedict-chat--upsert-context-slice benedict-chat--context-slices final))
            (setq existing (benedict-chat--context-handles benedict-chat--context-slices)))))
      (setq prepared (nreverse prepared)))
    (when (buffer-live-p compose)
      (with-current-buffer compose
        (benedict-chat-compose--render-header)
        (when (and benedict-chat-compose--body-start
                   (< (point) (marker-position benedict-chat-compose--body-start)))
          (goto-char (marker-position benedict-chat-compose--body-start)))
        (dolist (entry prepared)
          (let ((handle (plist-get (plist-get entry :slice) :handle)))
            (when (and handle (not (plist-get entry :replacing)))
              (benedict-chat--insert-handle-link handle))))))
    (pop-to-buffer compose)))

;; -------------------------------------------------------------------
;; Context capture commands

(defun benedict-chat--slice-with-handle-default (slice handle)
  "Return SLICE tagged with a default HANDLE suggestion."
  (plist-put slice :handle-default (benedict-chat--preferred-handle handle)))

(defun benedict-chat--buffer-label (&optional buffer)
  "Return a short label for BUFFER (defaults to current buffer)."
  (with-current-buffer (or buffer (current-buffer))
    (or (and buffer-file-name (file-name-nondirectory buffer-file-name))
        (buffer-name))))

(defun benedict-chat--slice-from-region (start end)
  "Return a context slice covering region START to END."
  (let* ((text (buffer-substring-no-properties start end))
         (label (format "%s: lines %d-%d"
                        (benedict-chat--buffer-label)
                        (line-number-at-pos start)
                        (line-number-at-pos end)))
         (origin (or buffer-file-name (buffer-name)))
         (default-handle (format "%s:%d-%d"
                                 (benedict-chat--buffer-label)
                                 (line-number-at-pos start)
                                 (line-number-at-pos end)))
         (slice (benedict-context-make-slice
                 :kind 'region :label label :origin origin :content text)))
    (benedict-chat--slice-with-handle-default slice default-handle)))

(defun benedict-chat--current-defun-name ()
  "Return a best-effort defun name at point, or nil."
  (or (when (fboundp 'add-log-current-defun)
        (ignore-errors (add-log-current-defun)))
      (when (fboundp 'which-function)
        (ignore-errors
          (let ((value (which-function)))
            (cond
             ((stringp value) value)
             ((and (listp value) (stringp (car value))) (car value))))))))

(defun benedict-chat--slice-from-defun ()
  "Return a context slice for the current defun."
  (let ((bounds (bounds-of-thing-at-point 'defun)))
    (unless bounds
      (user-error "No defun at point"))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (text (buffer-substring-no-properties start end))
           (label (format "%s: defun at line %d"
                          (benedict-chat--buffer-label)
                          (line-number-at-pos start)))
           (origin (or buffer-file-name (buffer-name)))
           (line (line-number-at-pos start))
           (base (or (benedict-chat--current-defun-name)
                     (benedict-chat--buffer-label)))
           (default-handle (format "%s:%d" base line))
           (slice (benedict-context-make-slice
                   :kind 'defun :label label :origin origin :content text)))
      (benedict-chat--slice-with-handle-default
       slice default-handle))))

(defun benedict-chat--slice-from-buffer ()
  "Return a context slice for the entire current buffer."
  (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
         (label (format "%s buffer" (benedict-chat--buffer-label)))
         (origin (or buffer-file-name (buffer-name)))
         (default-handle (format "%s-buffer" (benedict-chat--buffer-label)))
         (slice (benedict-context-make-slice
                 :kind 'buffer :label label :origin origin :content text)))
    (benedict-chat--slice-with-handle-default slice default-handle)))

(defun benedict-chat--slice-from-project ()
  "Return a context slice describing the current project."
  (let* ((root (or (benedict-chat--project-root) default-directory))
         (label "Project overview")
         (content (format "Project root: %s" root))
         (slice (benedict-context-make-slice
                 :kind 'project :label label :origin root :content content)))
    (benedict-chat--slice-with-handle-default slice "project")))

(defun benedict-chat--git-run (root &rest args)
  "Run git ARGS inside ROOT directory and return trimmed string or nil."
  (when (and root (executable-find "git"))
    (ignore-errors
      (with-temp-buffer
        (let ((default-directory root))
          (when (eq 0 (apply #'process-file "git" nil (current-buffer) nil args))
            (string-trim (buffer-string))))))))

(defun benedict-chat--slice-from-git ()
  "Return a context slice with basic Git info, or nil when unavailable."
  (let* ((root (or (when (fboundp 'magit-toplevel)
                     (ignore-errors (magit-toplevel)))
                   (ignore-errors (vc-root-dir))
                   (benedict-chat--project-root)))
         (branch (or (and (fboundp 'magit-get-current-branch)
                          (ignore-errors (magit-get-current-branch)))
                     (benedict-chat--git-run root "rev-parse" "--abbrev-ref" "HEAD")))
         (status (or (and (fboundp 'magit-git-string)
                          (ignore-errors (magit-git-string "status" "--short")))
                     (benedict-chat--git-run root "status" "--short")))
         (diff (or (and (fboundp 'magit-git-string)
                        (ignore-errors (magit-git-string "diff" "--stat")))
                   (benedict-chat--git-run root "diff" "--stat"))))
    (when root
      (let* ((parts (delq nil
                          (list (when branch (format "Branch: %s" branch))
                                (when (and status (not (string-empty-p status)))
                                  (format "Status:\n%s" status))
                                (when (and diff (not (string-empty-p diff)))
                                  (format "Diff:\n%s" diff))
                                (when (and (string-empty-p (or status ""))
                                           (string-empty-p (or diff "")))
                                  "Working tree clean."))))
             (content (string-join parts "\n\n"))
             (slice (benedict-context-make-slice
                     :kind 'git-diff
                     :label "Git status/diff"
                     :origin root
                     :content (or content "Git context unavailable"))))
        (benedict-chat--slice-with-handle-default slice "git-status")))))

;;;###autoload
(defun benedict-chat-ask-region (start end)
  "Add the active region START END to the Benedict compose context."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (let ((slice (benedict-chat--slice-from-region start end)))
    (benedict-chat--deliver-context-slices (list slice))
    (message "Added region to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-defun ()
  "Add the defun at point to the Benedict compose context."
  (interactive)
  (let ((slice (benedict-chat--slice-from-defun)))
    (benedict-chat--deliver-context-slices (list slice))
    (message "Added defun to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-buffer ()
  "Add the entire buffer to the Benedict compose context."
  (interactive)
  (let ((slice (benedict-chat--slice-from-buffer)))
    (benedict-chat--deliver-context-slices (list slice))
    (message "Added buffer to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-project ()
  "Add basic project information to the compose context."
  (interactive)
  (let ((slice (benedict-chat--slice-from-project)))
    (benedict-chat--deliver-context-slices (list slice))
    (message "Added project context to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-git-context ()
  "Add simple Git status/diff information to the compose context."
  (interactive)
  (if-let ((slice (benedict-chat--slice-from-git)))
      (progn
        (benedict-chat--deliver-context-slices (list slice))
        (message "Added Git context to Benedict compose buffer"))
    (user-error "No Git context available here")))

(defun benedict-chat--find-last-assistant (&optional include-errors)
  "Return the most recent assistant message.
When INCLUDE-ERRORS is nil, skip entries flagged with :error metadata."
  (cl-find-if
   (lambda (message)
     (and (eq (benedict-chat--normalize-role (plist-get message :role)) 'assistant)
          (or include-errors
              (not (plist-get (plist-get message :metadata) :error)))))
   benedict-chat--messages))

(defun benedict-chat-copy-last-response ()
  "Copy the most recent assistant response (non-error) to the kill ring."
  (interactive)
  (let ((message (benedict-chat--find-last-assistant)))
    (unless message
      (user-error "No assistant responses to copy"))
    (kill-new (plist-get message :content))
    (message "Benedict: copied last response to kill ring")))

(defun benedict-chat-retry-last ()
  "Retry the most recent provider request."
  (interactive)
  (unless benedict-chat--last-dispatch
    (user-error "No provider request to retry"))
  (benedict-chat--ensure-not-busy)
  (let ((request (plist-get benedict-chat--last-dispatch :request)))
    (unless request
      (user-error "Stored request is unavailable"))
    (benedict-chat--start-dispatch request t)))

(defvar benedict-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-s") #'benedict-chat-send-prompt)
    (define-key m (kbd "g r") #'benedict-chat-retry-last)
    (define-key m (kbd "w") #'benedict-chat-copy-last-response)
    (define-key m (kbd "C-c C-k") #'benedict-chat-cancel)
    m)
  "Keymap for `benedict-chat-mode'.")

(defun benedict-chat-cancel ()
  "Cancel the current autonomous loop or in-flight request."
  (interactive)
  (setq benedict-chat--loop-canceled t)
  (when benedict-chat--pending-request
    (benedict-provider-abort benedict-chat--pending-request)
    (setq benedict-chat--pending-request nil))
  (message "Benedict: loop/request canceled by user"))

;; benedict-chat-mode is now defined in benedict-chat-mode.el

(defun benedict-chat--init-buffer ()
  "Initialize buffer-local state for Benedict chat."
  (setq-local benedict-chat--messages nil)
  (setq-local benedict-chat--items nil)
  (setq-local benedict-chat--item-counter 0)
  (setq-local benedict-chat--thinking-items (make-hash-table :test 'equal))
  (setq-local benedict-chat--active-request-id nil)
  (setq-local benedict-chat--request-seq 0)
  (setq-local benedict-chat--thinking-temp-counter 0)
  (setq-local benedict-chat--pending-request nil)
  (setq-local benedict-chat--last-dispatch nil)
  (setq-local benedict-chat--context-slices nil)
  (setq-local benedict-chat--compose-buffer nil)
  (setq-local benedict-chat--provider-override nil)
  (setq-local benedict-chat--loop-start-time nil)
  (setq-local benedict-chat--loop-turn-count 0)
  (setq-local benedict-chat--loop-canceled nil)
  (setq-local benedict-chat--flywire-session nil)
  (setq-local benedict-chat--flywire-event-unsubscribe nil)
  (setq-local benedict-chat-profile (or benedict-chat-profile
                                        (benedict-chat--default-profile)))
  (setq-local header-line-format '(:eval (benedict-chat--header-line-status)))
  (visual-line-mode 1)
  (benedict-chat--telemetry-reset)
  (add-hook 'kill-buffer-hook #'benedict-chat--status-stop-timer nil t)
  (add-hook 'kill-buffer-hook #'benedict-chat--flywire-teardown-session nil t)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when (buffer-live-p benedict-chat--compose-buffer)
                (kill-buffer benedict-chat--compose-buffer)))
            nil t)
  (benedict-chat--ensure-thinking-invisibility)
  (unless (assoc 'benedict-tool-details buffer-invisibility-spec)
    (add-to-invisibility-spec 'benedict-tool-details))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize
             (format "Benedict Chat — provider: %s\n"
                     (benedict-chat--provider-label
                      (benedict-chat--resolve-provider)))
             'face 'benedict-chat-system
             'benedict-region-kind 'system))
    (insert (propertize
             "Commands: C-c C-s send · g r retry-last · w copy-last · benedict-chat-ask-{region,defun,buffer,project,git-context} open compose (C-c C-c to send)\n"
             'face 'benedict-chat-system
             'benedict-region-kind 'system))
    (insert "\n")))

;;;###autoload
(defun benedict-chat ()
  "Open or switch to the Benedict chat buffer."
  (interactive)
  (let ((buf (get-buffer-create benedict-chat-buffer-name)))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (unless (derived-mode-p 'benedict-chat-mode)
        (benedict-chat-mode)
        (benedict-chat--init-buffer))))
  (message "Type C-c C-s to send a prompt; g r retries; w copies last response."))

(provide 'benedict-chat)
;;; benedict-chat.el ends here
