;;; benedict-chat-profiles.el --- Profile and configuration resolution -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Resolves profile, provider, model, and tool configuration for chat requests.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'benedict)
(require 'benedict-tools)

(defvar benedict-provider)
(defvar benedict-chat-profile)
(defvar benedict-chat--provider-override)
(defvar benedict-chat--compose-model-override)
(defvar benedict-provider-openrouter-default-model)
(defvar benedict-provider-fake-default-model)

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
  `benedict-chat-profiles-capability-tool-map'.
- :autonomy — plist with keys :max-turns, :max-time, :max-tokens.
  Overrides global safeguards if stricter (lower).
- :verbosity — hint about response length/structure."
  :type '(alist :key-type symbol :value-type plist)
  :group 'benedict)

(defcustom benedict-chat-profiles-default-profile 'coding
  "Default profile applied when opening a chat buffer."
  :type 'symbol
  :group 'benedict)

(defcustom benedict-chat-profiles-project-default-profiles nil
  "Alist mapping project roots (strings) to default profile symbols."
  :type '(alist :key-type string :value-type symbol)
  :group 'benedict)

(defcustom benedict-chat-profiles-base-system-prompt
  "You are Benedict, an expert AI engineering agent integrated into Emacs.
Your goal is to help the user build high-quality software efficiently.
You have access to the user's editor state (buffers, project files) and should use this context to provide precise, relevant assistance.
Always be concise, direct, and professional."
  "Base system prompt applied to every request before profile-specific text."
  :type 'string
  :group 'benedict)

(defcustom benedict-chat-profiles-capability-tool-map nil
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

(defconst benedict-chat-profiles--anchor-guidance
  "The user may refer to context slices using Org-style notation. Each context block is labeled with an anchor like <<foo>>. Inside the user's instructions, [[foo]] refers to that same context slice. When reasoning about their request, resolve [[foo]] to the corresponding <<foo>> block in the Context section above."
  "System guidance explaining how to resolve [[handle]] links to context anchors.")

(defun benedict-chat-profiles--project-root ()
  "Return the current project root or expanded `default-directory'."
  (or (when (fboundp 'project-current)
        (when-let* ((project (project-current nil default-directory))
                    (roots (project-roots project)))
          (expand-file-name (car roots))))
      (when default-directory (expand-file-name default-directory))))

(defun benedict-chat-profiles--profile-entry (profile)
  "Return the profile plist entry for PROFILE."
  (assoc profile benedict-chat-profiles))

(defun benedict-chat-profiles--profile-label (profile)
  "Return human-readable label for PROFILE."
  (or (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :label)
      (when profile (capitalize (symbol-name profile)))
      "Default"))

(defun benedict-chat-profiles--profile-provider (profile)
  "Return provider symbol supplied by PROFILE entry, if any."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :provider))

(defun benedict-chat-profiles--profile-model (profile)
  "Return model string supplied by PROFILE entry, if any."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :model))

(defun benedict-chat-profiles--profile-preamble (profile)
  "Return preamble string for PROFILE or nil."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :preamble))

(defun benedict-chat-profiles--profile-tool-allowlist (profile)
  "Return tool allowlist for PROFILE."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :tool-allowlist))

(defun benedict-chat-profiles--profile-tool-denylist (profile)
  "Return tool denylist for PROFILE."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :tool-denylist))

(defun benedict-chat-profiles--profile-capabilities (profile)
  "Return capability list for PROFILE."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :capabilities))

(defun benedict-chat-profiles--profile-autonomy (profile)
  "Return autonomy plist for PROFILE."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :autonomy))

(defun benedict-chat-profiles--effective-limit (key global-val)
  "Return the stricter of the profile's autonomy limit KEY and GLOBAL-VAL.
NIL represents infinity (no limit). Uses `benedict-chat-profile`."
  (let* ((autonomy (benedict-chat-profiles--profile-autonomy benedict-chat-profile))
         (profile-limit (plist-get autonomy key)))
    (cond
     ((and (null global-val) (null profile-limit)) nil)
     ((null global-val) profile-limit)
     ((null profile-limit) global-val)
     (t (min global-val profile-limit)))))

(defun benedict-chat-profiles--profile-verbosity (profile)
  "Return verbosity hint for PROFILE."
  (plist-get (cdr (benedict-chat-profiles--profile-entry profile)) :verbosity))

(defun benedict-chat-profiles--default-profile ()
  "Return default profile for the current context."
  (let* ((root (benedict-chat-profiles--project-root))
         (match (cl-find-if (lambda (entry)
                              (and root (file-equal-p root (car entry))))
                            benedict-chat-profiles-project-default-profiles)))
    (or (cdr match) benedict-chat-profiles-default-profile)))

(defun benedict-chat-profiles--effective-profile ()
  "Return the active profile for the current chat buffer."
  (or benedict-chat-profile (benedict-chat-profiles--default-profile)))

(defun benedict-chat-profiles--provider-default-model (provider)
  "Return the default model string for PROVIDER."
  (pcase provider
    ('openrouter benedict-provider-openrouter-default-model)
    ('ollama benedict-provider-ollama-default-model)
    ('vercel benedict-provider-vercel-default-model)
    ('gemini benedict-provider-gemini-default-model)
    ('fake benedict-provider-fake-default-model)
    (_ nil)))

(defun benedict-chat-profiles--resolve-provider (&optional profile)
  "Resolve provider using PROFILE or the buffer's effective profile.
Resolution order: buffer override → profile :provider → global `benedict-provider'."
  (or benedict-chat--provider-override
      (benedict-chat-profiles--profile-provider
       (or profile (benedict-chat-profiles--effective-profile)))
      benedict-provider))

(defun benedict-chat-profiles--resolve-model (&optional provider profile override)
  "Resolve model using PROVIDER/PROFILE with optional OVERRIDE."
  (let* ((profile (or profile (benedict-chat-profiles--effective-profile)))
         (provider (or provider (benedict-chat-profiles--resolve-provider profile)))
         (override (or override benedict-chat--compose-model-override)))
    (or (and (stringp override) (not (string-empty-p override)) override)
        (benedict-chat-profiles--profile-model profile)
        (benedict-chat-profiles--provider-default-model provider))))

(defun benedict-chat-profiles--system-content (&optional profile)
  "Return combined system content for PROFILE."
  (let ((parts nil))
    (dolist (piece (list benedict-chat-profiles-base-system-prompt
                         benedict-chat-profiles--anchor-guidance
                         (benedict-chat-profiles--profile-preamble profile)))
      (when (and piece (stringp piece)
                 (not (string-empty-p (string-trim piece))))
        (push (string-trim piece) parts)))
    (when parts
      (string-join (nreverse parts) "\n\n"))))

(defun benedict-chat-profiles--system-messages (&optional profile)
  "Return a list of system messages for PROFILE."
  (when-let ((content (benedict-chat-profiles--system-content profile)))
    (list (list :role 'system :content content))))

(defun benedict-chat-profiles--registered-tool-ids ()
  "Return tool IDs registered in `benedict-tools-list'."
  (mapcar (lambda (tool) (plist-get tool :id))
          (benedict-tools-list)))

(defun benedict-chat-profiles--normalize-capabilities (capabilities)
  "Normalize CAPABILITIES into a list."
  (cond
   ((null capabilities) nil)
   ((listp capabilities) capabilities)
   (t (list capabilities))))

(defun benedict-chat-profiles--tools-for-capabilities (capabilities)
  "Return tool IDs derived from CAPABILITIES via `benedict-chat-profiles-capability-tool-map'."
  (let ((caps (benedict-chat-profiles--normalize-capabilities capabilities))
        (acc nil))
    (dolist (cap caps)
      (let ((tools (alist-get cap benedict-chat-profiles-capability-tool-map nil nil #'eq)))
        (when tools
          (setq acc (nconc acc (copy-sequence tools))))))
    (delete-dups acc)))

(defun benedict-chat-profiles--effective-tool-ids (profile)
  "Return effective tool IDs for PROFILE respecting allow/deny/capabilities."
  (let* ((allow (benedict-chat-profiles--profile-tool-allowlist profile))
         (deny (benedict-chat-profiles--profile-tool-denylist profile))
         (caps (benedict-chat-profiles--profile-capabilities profile))
         (cap-tools (benedict-chat-profiles--tools-for-capabilities caps))
         (registered (benedict-chat-profiles--registered-tool-ids))
         (baseline (cond
                    (allow (copy-sequence allow))
                    (cap-tools cap-tools)
                    (t registered)))
         (with-deny (if deny
                        (cl-set-difference baseline deny :test #'eq)
                      baseline)))
    (cl-intersection with-deny registered :test #'eq)))

(defun benedict-chat-profiles--resolve-tools (profile)
  "Return hydrated tool specs allowed for PROFILE."
  (let ((ids (benedict-chat-profiles--effective-tool-ids profile))
        (result nil))
    (dolist (spec (benedict-tools-list))
      (when (memq (plist-get spec :id) ids)
        (push (copy-tree spec) result)))
    (nreverse result)))

(defun benedict-chat-profiles--provider-label (&optional provider-id)
  "Return a short label for PROVIDER-ID (or the active provider)."
  (let* ((provider (or (and provider-id (benedict-provider-lookup provider-id))
                       (ignore-errors (benedict-provider-current))))
         (name (and provider (benedict-provider-name provider)))
         (id (and provider (benedict-provider-id provider))))
    (or name
        (and id (symbol-name id))
        (and provider-id (format "%s" provider-id))
        "unknown provider")))

(provide 'benedict-chat-profiles)
;;; benedict-chat-profiles.el ends here
