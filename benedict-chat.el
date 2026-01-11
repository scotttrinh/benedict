;;; benedict-chat.el --- Chat buffers and commands -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders role-tagged messages, tracks history for retry/copy actions, and
;; dispatches requests through the active Benedict provider (OpenRouter by
;; default).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'project)
(require 'magit-section)
(require 'markdown-mode)
(require 'svg-lib nil t)
(require 'benedict)
(require 'benedict-context)
(require 'benedict-tools)
(require 'benedict-flywire)
(require 'benedict-chat-render)
(require 'benedict-chat-sections)
(require 'benedict-chat-stream)
(require 'benedict-chat-thinking)
(require 'benedict-chat-tool-ui)
(require 'benedict-chat-compose)
(require 'benedict-chat-context-capture)
(require 'benedict-chat-nav)
(require 'benedict-chat-profiles)
(require 'benedict-session)

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

(defun benedict-chat--svg-supported-p ()
  "Return non-nil when SVG badges can be rendered."
  (and (display-graphic-p)
       (featurep 'svg)
       (require 'svg-lib nil t)
       (fboundp 'svg-lib-tag)))

(defun benedict-chat--badge-face (face)
  "Return FACE coerced to a single face symbol."
  (cond
   ((and (symbolp face) (facep face)) face)
   ((listp face)
    (or (cl-some (lambda (candidate)
                   (and (symbolp candidate) (facep candidate)))
                 face)
        'benedict-chat-header))
   (t 'benedict-chat-header)))

(defun benedict-chat--badge (label face)
  "Render LABEL as a badge using FACE.
Falls back to a propertized text badge when SVG is unavailable."
  (let* ((label (format "%s" label))
         (face (benedict-chat--badge-face face))
         (fg (face-foreground face nil 'default))
         (bg (or (face-background face nil 'default)
                 (face-background 'default nil))))
    (if (benedict-chat--svg-supported-p)
        (let ((image (svg-lib-tag label nil
                                  :stroke 0
                                  :radius 4
                                  :padding 1.0
                                  :foreground fg
                                  :background bg
                                  :font-family "Menlo")))
          (propertize label 'display image 'face face))
      (propertize (format "[%s]" label) 'face face))))

(defun benedict-chat--propertize-region (beg end kind)
  "Apply `benedict-region-kind' KIND to region between BEG and END."
  (put-text-property beg end 'benedict-region-kind kind))

(defun benedict-chat--insert-header-line (text item)
  "Insert TEXT as a header line for ITEM and tag it as non-body.
This only applies text properties; callers handle marker tracking."
  (let ((start (point)))
    (insert text)
    (benedict-chat--propertize-region start (point) 'header)
    (put-text-property start (point) 'benedict-chat-item item)
    (insert "\n")
    (benedict-chat--propertize-region (1- (point)) (point) 'header)))

(defun benedict-chat--insert-body (content &optional kind)
  "Insert CONTENT and tag the region as KIND (defaults to `body')."
  (let* ((kind (or kind 'body))
         (start (point)))
    (insert (or content ""))
    (benedict-chat--propertize-region start (point) kind)
    (insert "\n")
    (benedict-chat--propertize-region (1- (point)) (point) kind)))

;;;###autoload
(define-derived-mode benedict-chat-mode magit-section-mode "Benedict-Chat"
  "Major mode for Benedict chat buffers."
  (benedict-chat--setup-common-buffer))

(defvar-local benedict-chat--buffer nil
  "Stable reference to the chat buffer.")

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

(defvar-local benedict-chat--request-seq 0
  "Monotonic sequence used to tag provider requests.")

(defvar-local benedict-chat--thinking-temp-counter 0
  "Per-request counter for synthesizing thinking identifiers when absent.")

(defvar benedict-chat-buffer-name "*Benedict Chat*"
  "Default chat buffer name.")

(defcustom benedict-chat-major-mode #'benedict-chat-mode
  "Major mode constructor used when creating chat buffers."
  :type 'function
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

(defvar-local benedict-chat--status-spinner-index 0
  "Spinner index for the status line animation.")

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

(defun benedict-chat--empty-response-text (thinking)
  "Return placeholder text for empty responses.
THINKING is non-nil when reasoning blocks accompanied the response."
  (if thinking
      benedict-chat--empty-response-thinking-placeholder
    benedict-chat--empty-response-placeholder))

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
    ('ollama benedict-provider-ollama-default-model)
    ('vercel benedict-provider-vercel-default-model)
    ('gemini benedict-provider-gemini-default-model)
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
                         benedict-chat-compose--anchor-guidance
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
                    (or benedict-chat-profile (benedict-chat--default-profile))))
         (choice (completing-read
                  "Profile: "
                  candidates nil t nil nil (symbol-name current)))
         (profile (cdr (assoc choice candidates))))
    (with-current-buffer chat
      (setq benedict-chat-profile profile)
      (benedict-chat--configure-session)
      (benedict-chat--status-refresh)
      (benedict-chat-compose--refresh-header))
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
   (benedict-chat--configure-session)
   (benedict-chat--status-refresh)
   (benedict-chat-compose--refresh-header))
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

(defun benedict-chat--usage-number (usage key)
  "Return numeric value for KEY (string or symbol) in USAGE."
  (when-let ((val (benedict-session--usage-value usage key)))
    (if (stringp val) (string-to-number val) val)))

(defun benedict-chat--usage-cost-number (usage)
  "Return numeric cost from USAGE if present."
  (or (benedict-chat--usage-number usage "cost")
      (benedict-chat--usage-number usage "total_cost")))

(defun benedict-chat--status-reset ()
  "Reset status UI state for the current buffer."
  (setq benedict-chat--status-spinner-index 0))

(defun benedict-chat--status-phase ()
  "Return the current session phase for status display."
  (let ((session benedict-chat--session))
    (cond
     ((null session) 'idle)
     ((eq (benedict-session-state session) 'streaming) 'streaming)
     ((eq (benedict-session-state session) 'error) 'error)
     ((eq (benedict-session-state session) 'cancelled) 'canceled)
     ((benedict-session-request-active-p session) 'sending)
     (t 'idle))))

(defun benedict-chat--status-request-started-at ()
  "Return the time value when the current request started, if any."
  (when-let* ((session benedict-chat--session)
              (inflight (benedict-session-inflight session)))
    (plist-get inflight :started-at)))

(defun benedict-chat--status-request-started-at-float ()
  "Return the current request start time as float seconds, if any."
  (when-let ((started (benedict-chat--status-request-started-at)))
    (if (numberp started) started (float-time started))))

(defun benedict-chat--status-elapsed ()
  "Return elapsed seconds for the current session request."
  (when-let ((started (benedict-chat--status-request-started-at)))
    (if (numberp started)
        (- (float-time) started)
      (float-time (time-subtract (current-time) started)))))

(defun benedict-chat--status-active-p ()
  "Return non-nil when session indicates an active provider call."
  (let ((phase (benedict-chat--status-phase)))
    (memq phase '(sending streaming))))

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
            (setq benedict-chat--status-spinner-index
                  (1+ benedict-chat--status-spinner-index))
            (when-let* ((state benedict-chat--streaming-message)
                        (message (plist-get state :message))
                        (item (plist-get message :item)))
              (benedict-chat--refresh-message-header item))
            (benedict-chat--status-refresh))
        (benedict-chat--status-stop-timer)))))

(defun benedict-chat--status-start-timer ()
  "Ensure the spinner/elapsed timer is running for the current buffer."
  (unless (timerp benedict-chat--status-timer)
    (setq benedict-chat--status-timer
          (run-with-timer 0.2 0.2 #'benedict-chat--status-tick (current-buffer)))))

(defun benedict-chat--status-usage-string (usage)
  "Format USAGE according to `benedict-chat-token-display', including cost."
  (let (parts)
    (pcase benedict-chat-token-display
      ('none nil)
      ('total
       (let ((total (or (plist-get usage :total)
                        (benedict-session--usage-value usage "total_tokens")
                        (benedict-session--usage-value usage "tokens"))))
         (when total
           (push (format "%s tok" total) parts))))
      ('prompt+completion
       (let ((prompt (or (plist-get usage :prompt)
                         (benedict-session--usage-value usage "prompt_tokens")
                         (benedict-session--usage-value usage "prompt"))))
         (let ((completion (or (plist-get usage :completion)
                               (benedict-session--usage-value usage "completion_tokens")
                               (benedict-session--usage-value usage "completion"))))
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
            (index (mod (or benedict-chat--status-spinner-index 0) len)))
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
  (let* ((session benedict-chat--session)
         (provider (or (and session (benedict-session-provider session))
                       (benedict-chat--resolve-provider)))
         (model (or (and session (benedict-session-model session))
                    (benedict-chat--resolve-model
                     provider
                     (benedict-chat--effective-profile)
                     benedict-chat--compose-model-override)))
         (label (if model
                    (format "%s:%s" (benedict-chat--provider-label provider) model)
                  (format "%s" (benedict-chat--provider-label provider)))))
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
When RICH is non-nil, include header-friendly hints.
Handles errors related to killed buffers gracefully."
  (condition-case err
      (let* ((session benedict-chat--session)
             (phase (benedict-chat--status-phase))
             (last-phase (and session (benedict-session-last-phase session)))
             (active (memq phase '(sending streaming)))
             (elapsed (or (and active (benedict-chat--status-elapsed))
                          (and session (benedict-session-last-elapsed session))))
             (usage (and session (benedict-session-accumulated-usage session)))
             (session-seconds (and session (benedict-session-accumulated-seconds session)))
             (indicator (benedict-chat--status-indicator phase last-phase))
             (label (benedict-chat--status-phase-label phase))
             (provider (benedict-chat--status-provider-label rich))
             (usage-str (benedict-chat--status-usage-string usage))
             (elapsed-str (when (and elapsed (or (not rich) active))
                            (format "%.0fs" elapsed)))
             (session-str (when (and rich session-seconds (> session-seconds 0))
                            (format "Σ%.0fs" session-seconds)))
             (agent-indicator (benedict-chat--status-agent-indicator))
             (hint (and rich active "ESC to cancel")))
        (string-join
         (delq nil
               (list (format "%s %s" indicator label)
                     provider
                     elapsed-str
                     session-str
                     usage-str
                     agent-indicator
                     hint))
         " · "))
    ;; Handle errors from killed buffers or other issues during cleanup
    ((buffer-read-only error) "")))

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
      (benedict-chat--configure-session)
      (benedict-chat--status-refresh)
      (benedict-chat-compose--refresh-header))
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

(defun benedict-chat--message-provider-label (metadata)
  "Return a display label for METADATA :provider."
  (when-let ((provider (plist-get metadata :provider)))
    (cond
     ((stringp provider) provider)
     (t (benedict-chat--provider-label provider)))))

(defun benedict-chat--message-provider-model-fragment (provider model)
  "Return a propertized provider/model fragment for the message header.

PROVIDER and MODEL should be strings (or nil)."
  (let ((provider (and provider (format "%s" provider)))
        (model (and model (format "%s" model))))
    (cond
     ((and provider model)
      (concat (propertize provider 'face 'benedict-chat-header-provider)
              (propertize ":" 'face 'benedict-chat-header-separator)
              (propertize model 'face 'benedict-chat-header-model)))
     (provider (propertize provider 'face 'benedict-chat-header-provider))
     (model (propertize model 'face 'benedict-chat-header-model)))))

(defun benedict-chat--badge-face (face)
  "Return FACE coerced to a single face symbol for badges."
  (cond
   ((and (symbolp face) (facep face)) face)
   ((listp face)
    (or (cl-find-if (lambda (candidate)
                      (and (symbolp candidate) (facep candidate)))
                    face)
        'benedict-chat-header))
   ((facep face) face)
   (t 'benedict-chat-header)))

(defun benedict-chat--header-badge (label face)
  "Return a badge for LABEL using FACE with a text fallback."
  (when label
    (let ((label (format "%s" label))
          (face (benedict-chat--badge-face face)))
      (if (fboundp 'benedict-chat--badge)
          (benedict-chat--badge label face)
        (propertize (format "[%s]" label) 'face face)))))

(defun benedict-chat--message-header-string (message &optional in-flight)
  "Return the message header line for MESSAGE.
When IN-FLIGHT is non-nil, include a live elapsed hint when possible.

The returned string may carry text properties (notably faces) suitable for
insertion into a chat buffer."
  (let* ((role (benedict-chat--normalize-role (plist-get message :role)))
         (metadata (plist-get message :metadata))
         (item (plist-get message :item))
         (tag-face (benedict-chat--badge-face
                    (or (benedict-chat--face-for-role role metadata)
                        'benedict-chat-role)))
         (role-badge (benedict-chat--header-badge (upcase (symbol-name role)) tag-face))
         (provider (plist-get metadata :provider))
         (provider-label (cond
                          ((stringp provider) provider)
                          (provider (benedict-chat--provider-label provider))))
         (model (and metadata (plist-get metadata :model)))
         (provider-model-label (cond
                                ((and provider-label model) (format "%s:%s" provider-label model))
                                (provider-label provider-label)
                                (model model)))
         (provider-badge (when provider-model-label
                           (benedict-chat--header-badge provider-model-label 'benedict-chat-header-model)))
         (usage (and metadata (plist-get metadata :usage)))
         (usage-str (and usage (benedict-chat--status-usage-string usage)))
         (latency (and metadata (plist-get metadata :latency)))
         (empty-response (and metadata (plist-get metadata :empty-response)))
         (time-str (cond
                    ((and in-flight item (plist-get item :started-at))
                     (format "%.1fs…" (- (float-time) (plist-get item :started-at))))
                    (latency (format "%.2fs" latency))))
         (state-badge (cond
                       ((plist-get metadata :error)
                        (benedict-chat--header-badge "ERROR" 'benedict-chat-header-error))
                       (in-flight
                        (benedict-chat--header-badge "STREAMING" 'benedict-chat-header-time))
                       (empty-response
                        (benedict-chat--header-badge "EMPTY" 'benedict-chat-header-separator))
                       (t nil)))
         (time-badge (and time-str (benedict-chat--header-badge time-str 'benedict-chat-header-time)))
         (usage-badge (and usage-str (benedict-chat--header-badge usage-str 'benedict-chat-header-usage)))
         (left (benedict-chat-render--join-badges
                (list role-badge state-badge provider-badge)))
         (right (benedict-chat-render--join-badges
                 (list time-badge usage-badge))))
    (or (benedict-chat-render--align-header left right)
        left
        right
        "")))

(defun benedict-chat--refresh-message-header (item)
  "Refresh ITEM's header text based on current message metadata."
  (when-let ((message (plist-get item :message)))
    (let ((in-flight (and (benedict-chat--status-active-p)
                          benedict-chat--streaming-message
                          (eq (plist-get benedict-chat--streaming-message :message) message))))
      (save-excursion
        (benedict-chat--update-message-header
         item
         (benedict-chat--message-header-string message in-flight)))
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
            (insert (propertize (make-string needed ?\n)
                                'benedict-region-kind 'header))))))))

(defun benedict-chat--render-message (buffer message)
  "Render MESSAGE into BUFFER.
Assistant messages are rendered as marker-backed items."
  (with-current-buffer buffer
    (setq message (benedict-chat--ensure-message-kind message))
    (let* ((role (benedict-chat--normalize-role (plist-get message :role)))
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
              (benedict-chat--message-header-string message nil)
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



(defun benedict-chat--message-history ()
  "Return message history for current buffer's session."
  (when benedict-chat--session
    (benedict-session-messages-chronological benedict-chat--session)))

;; Tool UI helpers live in benedict-chat-tool-ui.el.


(defun benedict-chat--configure-session ()
  "Configure the session with current buffer settings."
  (when-let ((session benedict-chat--session))
    (let* ((profile (benedict-chat--effective-profile))
           (provider (benedict-chat--resolve-provider profile))
           (model (benedict-chat--resolve-model
                   provider profile benedict-chat--compose-model-override))
           (tools (benedict-chat--resolve-tools profile))
           (system (benedict-chat--system-messages profile))
           (autonomy (benedict-chat--profile-autonomy profile))
           (verbosity (benedict-chat--profile-verbosity profile))
           (loop-config (list :max-turns (benedict-chat--effective-limit
                                          :max-turns benedict-chat-loop-checkpoint-interval)
                              :max-time (benedict-chat--effective-limit
                                         :max-time benedict-chat-loop-max-time)
                              :max-tokens (benedict-chat--effective-limit
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
             (benedict-session-request-active-p benedict-chat--session))
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

(defun benedict-chat--apply-request-result-extras (buffer result)
  "Render RESULT metadata that is not represented in session messages."
  (with-current-buffer buffer
    (let* ((session benedict-chat--session)
           (message (and session (benedict-chat-nav--find-last-assistant)))
           (message-metadata (and message (plist-get message :metadata)))
           (provider (or (plist-get result :provider)
                         (and session (benedict-session-provider session))
                         (benedict-chat--resolve-provider)))
           (model (or (plist-get result :model)
                      (and session (benedict-session-model session))))
           (metadata (or message-metadata
                         (benedict-chat--metadata
                          :provider provider
                          :model model
                          :latency (plist-get result :latency)
                          :usage (plist-get result :usage))))
           (thinking (plist-get result :thinking))
           (empty-response (plist-get result :empty-response)))
      (when (and empty-response message)
        (let* ((content (or (plist-get message :content) ""))
               (display (benedict-chat--empty-response-text thinking))
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

(defun benedict-chat--start-dispatch (buffer request &optional retry)
  "Send REQUEST through the provider for BUFFER."
  (unless (and buffer (buffer-live-p buffer))
    (user-error "Chat buffer is unavailable"))
  (with-current-buffer buffer
    (let* ((provider-id (or (plist-get request :provider) benedict-provider))
           (provider-label (benedict-chat--provider-label provider-id))
           (session benedict-chat--session))
      (unless session
        (user-error "No session attached to buffer"))
      (benedict-chat--configure-session)
      ;; Reset UI state
      (setq benedict-chat--request-seq (1+ benedict-chat--request-seq))
      (setq benedict-chat--thinking-temp-counter 0)
      (benedict-chat-stream--reset buffer)
      (benedict-chat--status-reset)
      (benedict-chat--status-start-timer)
      (benedict-chat--status-refresh)
      (setq benedict-chat--last-dispatch
            (list :request request :timestamp (current-time) :retry retry))
      (message "Benedict: contacting %s%s..."
               provider-label (if retry " (retry)" ""))
      (condition-case err
          (let ((request-id (benedict-session-dispatch session request)))
            (when benedict-chat--last-dispatch
              (setq benedict-chat--last-dispatch
                    (plist-put benedict-chat--last-dispatch :request-id request-id))))
        (error
         (benedict-chat-stream--handle-provider-error
          buffer
          (list :message (error-message-string err)
                :type 'dispatch
                :provider provider-id
                :retryable nil)))))))

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
        (setq benedict-chat--request-seq (1+ benedict-chat--request-seq))
        (benedict-chat-stream--reset chat)
        (benedict-chat--status-reset)
        (benedict-chat--status-start-timer)
        ;; Add user message to session
        (benedict-session-add-message session
                                      (list :role 'user :content text :time (current-time)))
        ;; Configure and run session
        (benedict-chat--configure-session)
        (setq benedict-chat--last-dispatch
              (list :request (benedict-session--build-request session)
                    :timestamp (current-time)))
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
  (benedict-chat--status-stop-timer)
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

;; benedict-chat-mode is now defined in benedict-chat-mode.el

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
     (benedict-chat--status-reset)
     (benedict-chat--status-start-timer)
     (benedict-chat--status-refresh)
     (when (and benedict-chat--last-dispatch
                (plist-get payload :request-id))
       (setq benedict-chat--last-dispatch
             (plist-put benedict-chat--last-dispatch
                        :request-id
                        (plist-get payload :request-id)))))
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
                         (benedict-chat--metadata
                          :provider (benedict-session-provider session)
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
                         (benedict-chat--metadata
                          :provider (benedict-session-provider session)
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
     (benedict-chat--status-stop-timer)
     (message "Benedict: cannot dispatch - provider or model not configured"))
    ('destroyed
     (benedict-chat--observe-session-destroyed))))

;; Observer functions (placeholders for Phase 3 implementation)

(defun benedict-chat--dispatching-current-request-p (session)
  "Return non-nil when current buffer initiated SESSION's active request."
  (let ((inflight (and session (benedict-session-inflight session))))
    (and inflight
         benedict-chat--last-dispatch
         (or (equal (plist-get inflight :request-id)
                    (plist-get benedict-chat--last-dispatch :request-id))
             (null (plist-get benedict-chat--last-dispatch :request-id))))))

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
     (when (eq old-state 'streaming)
       ;; Request finished - telemetry accumulated by session dispatch
       )
     (benedict-chat--status-reset)
     (benedict-chat--status-stop-timer))
    ('streaming
     (benedict-chat--status-reset)
     (benedict-chat--status-start-timer))
    ('error
     (benedict-chat--status-reset)
     (benedict-chat--status-stop-timer))
    ('cancelled
     (benedict-chat--status-reset)
     (benedict-chat--status-stop-timer)))
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
  (unless (benedict-chat--dispatching-current-request-p benedict-chat--session)
    (when-let ((session benedict-chat--session)
               (draft (benedict-session-draft session)))
      (benedict-chat--apply-draft-snapshot session draft))))

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
  (unless (benedict-chat--dispatching-current-request-p benedict-chat--session)
    (when (plist-get payload :discarded)
      (benedict-chat-stream--reset (current-buffer)))))

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
  (setq-local benedict-chat--request-seq 0)
  (setq-local benedict-chat--thinking-temp-counter 0)
  (setq-local benedict-chat--last-dispatch nil)
  (setq-local benedict-chat--context-slices nil)
  (setq-local benedict-chat--compose-buffer nil)
  (setq-local benedict-chat--provider-override nil)
  (setq-local benedict-chat--flywire-session nil)
  (setq-local benedict-chat--flywire-event-unsubscribe nil)
  (setq-local benedict-chat-profile (or benedict-chat-profile
                                        (benedict-chat--default-profile)))
  (let* ((profile benedict-chat-profile)
         (provider (benedict-chat--resolve-provider profile))
         (model (benedict-chat--resolve-model
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
  (setq-local header-line-format '(:eval (benedict-chat--header-line-status)))
  (visual-line-mode 1)
  (benedict-chat--status-reset)
  (add-hook 'kill-buffer-hook #'benedict-chat--status-stop-timer nil t)
  (add-hook 'kill-buffer-hook #'benedict-chat--flywire-teardown-session nil t)
  (add-hook 'kill-buffer-hook #'benedict-chat--detach-session nil t)
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when (buffer-live-p benedict-chat--compose-buffer)
                (kill-buffer benedict-chat--compose-buffer)))
            nil t)
  (setq-local benedict-chat--conversation-section nil)
  (setq-local benedict-chat--current-turn-section nil)
  (setq-local magit-root-section nil)
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
      (benedict-chat--status-reset)
      (benedict-chat-stream--reset (current-buffer))
      (insert (propertize
               (format "Benedict Chat — provider: %s\n"
                       (benedict-chat--provider-label
                        (or (benedict-session-provider session)
                            (benedict-chat--resolve-provider))))
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
          (benedict-chat--status-start-timer)
        (benedict-chat--status-stop-timer))
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
