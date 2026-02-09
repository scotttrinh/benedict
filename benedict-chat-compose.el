;;; benedict-chat-compose.el --- Compose buffer for Benedict chat -*- lexical-binding: t; -*-

;;; Commentary:
;; Compose buffer support for Benedict chat prompts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict-context)
(require 'benedict-chat-profiles)
(require 'benedict-chat-status)

;;; External Variables

(defvar benedict-chat--buffer)
(defvar benedict-chat--session)
(defvar benedict-chat--context-slices)
(defvar benedict-chat--compose-buffer)
(defvar benedict-chat--compose-model-override)
(defvar benedict-chat-profile)
(defvar benedict-chat--provider-override)

;;; External Functions

(declare-function benedict-chat--ensure-chat-buffer "benedict-chat")
(declare-function benedict-chat--send-text "benedict-chat")
(declare-function benedict-chat--configure-session "benedict-chat")
(declare-function benedict-chat-status--status-refresh "benedict-chat-status")
(declare-function benedict-chat-choose-profile "benedict-chat")
(declare-function benedict-chat-choose-provider "benedict-chat")
(declare-function benedict-chat-choose-model "benedict-chat")
(declare-function benedict-chat--set-context-slices "benedict-chat")

;;; Configuration

(defcustom benedict-chat-compose-buffer-name-format "*Benedict Compose: %s*"
  "Format string used to name compose buffers for chat threads.
The chat buffer name is substituted into the single %s placeholder."
  :type 'string
  :group 'benedict)

(defcustom benedict-chat-context-retain-after-send nil
  "When non-nil, keep pending context slices after sending from compose."
  :type 'boolean
  :group 'benedict)

(defcustom benedict-chat-compose-window-height 0.33
  "Fractional height for compose windows shown below chat buffers."
  :type 'float
  :group 'benedict)

(defconst benedict-chat-compose--separator "----\n"
  "Separator line between compose header and body.")

(defconst benedict-chat-compose--handle-regexp "^[A-Za-z0-9._:-]+$"
  "Valid pattern for context handles referenced via [[handle]].")

(defconst benedict-chat-compose--anchor-guidance
  "The user may refer to context slices using Org-style notation. Each context block is labeled with an anchor like <<foo>>. Inside the user's instructions, [[foo]] refers to that same context slice. When reasoning about their request, resolve [[foo]] to the corresponding <<foo>> block in the Context section above."
  "System guidance explaining how to resolve [[handle]] links to context anchors.")

;;; Keymaps

(defvar benedict-chat-compose--profile-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'benedict-chat-choose-profile)
    (define-key map [down-mouse-1] #'benedict-chat-choose-profile)
    (define-key map (kbd "RET") #'benedict-chat-choose-profile)
    map)
  "Keymap for interacting with the profile display in compose headers.")

(defvar benedict-chat-compose--provider-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'benedict-chat-choose-provider)
    (define-key map [down-mouse-1] #'benedict-chat-choose-provider)
    (define-key map (kbd "RET") #'benedict-chat-choose-provider)
    map)
  "Keymap for interacting with the provider display in compose headers.")

(defvar benedict-chat-compose-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'benedict-chat-compose-send)
    (define-key m (kbd "C-c C-k") #'benedict-chat-compose-cancel)
    m)
  "Keymap for `benedict-chat-compose-mode'.")

;;; Mode

(defvar-local benedict-chat-compose--chat-buffer nil
  "Parent chat buffer associated with this compose buffer.")

(defvar-local benedict-chat-compose--body-start nil
  "Marker pointing to the start of the editable body in compose buffers.")

(define-derived-mode benedict-chat-compose-mode text-mode "Benedict-Compose"
  "Major mode for composing Benedict prompts with context."
  (setq-local benedict-chat-compose--chat-buffer nil)
  (setq-local benedict-chat-compose--body-start (make-marker))
  (setq-local mode-line-process nil)
  (setq-local header-line-format nil)
  (visual-line-mode 1))

;;; Functions

(defun benedict-chat-compose--buffer-name (chat-buffer)
  "Return a compose buffer name for CHAT-BUFFER."
  (format benedict-chat-compose-buffer-name-format (buffer-name chat-buffer)))

(defun benedict-chat-compose--header-text (chat-buffer)
  "Return header text for CHAT-BUFFER's compose buffer."
  (with-current-buffer chat-buffer
    (let* ((profile (benedict-chat-profiles--effective-profile))
           (profile-label (propertize (benedict-chat-profiles--profile-label profile)
                                      'mouse-face 'mode-line-highlight
                                      'help-echo "Choose a Benedict profile (click)"
                                      'local-map benedict-chat-compose--profile-button-map))
           (provider (benedict-chat-profiles--resolve-provider profile))
           (provider-label (propertize (benedict-chat-profiles--provider-label provider)
                                       'mouse-face 'mode-line-highlight
                                       'help-echo "Choose a Benedict provider (click)"
                                       'local-map benedict-chat-compose--provider-button-map))
           (model (benedict-chat-profiles--resolve-model
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
           (project (or (benedict-chat-profiles--project-root) "n/a"))
           (summary (or (benedict-context-summary (or benedict-chat--context-slices nil))
                        "n/a")))
      (format "Profile: %s    Provider: %s    Model: %s    Project: %s    Context: %s\n"
              profile-label provider-label model-label project summary))))

(defun benedict-chat-compose--sanitize-handle (handle)
  "Return HANDLE trimmed and with unsafe characters replaced."
  (let* ((trimmed (string-trim (or handle "")))
         (spaced (replace-regexp-in-string "[[:space:]]+" "-" trimmed))
         (clean (replace-regexp-in-string "[^A-Za-z0-9._:-]" "-" spaced)))
    (replace-regexp-in-string "-+" "-" clean)))

(defun benedict-chat-compose--valid-handle-p (handle)
  "Return non-nil when HANDLE matches `benedict-chat-compose--handle-regexp'."
  (and (stringp handle)
       (string-match-p benedict-chat-compose--handle-regexp handle)))

(defun benedict-chat-compose--preferred-handle (candidate)
  "Return a sanitized HANDLE string derived from CANDIDATE or fallback."
  (let* ((sanitized (benedict-chat-compose--sanitize-handle candidate))
         (fallback (benedict-chat-compose--sanitize-handle "context")))
    (or (and (benedict-chat-compose--valid-handle-p sanitized) sanitized)
        fallback)))

(defun benedict-chat-compose--context-handles (slices)
  "Return a list of handles present in SLICES."
  (delq nil (mapcar (lambda (slice) (plist-get slice :handle)) slices)))

(defun benedict-chat-compose--prepare-context-slice (slice existing-handles)
  "Prompt for a handle for SLICE, respecting EXISTING-HANDLES.
Return a plist with :slice and :replacing entries; :slice carries the final handle."
  (let* ((default (or (plist-get slice :handle-default)
                      (plist-get slice :handle)
                      (plist-get slice :label)
                      "context"))
         (proposal (benedict-chat-compose--preferred-handle default))
         (handles (cl-remove-if-not #'identity existing-handles))
         (final-handle nil))
    (if noninteractive
        (setq final-handle proposal)
      (while (not final-handle)
        (let* ((input (string-trim (read-string
                                    (format "Context handle (default %s): " proposal)
                                    nil nil proposal)))
               (candidate (if (string-empty-p input) proposal input))
               (sanitized (benedict-chat-compose--sanitize-handle candidate)))
          (cond
           ((not (benedict-chat-compose--valid-handle-p sanitized))
            (message "Handle must match %s" benedict-chat-compose--handle-regexp))
           ((and (member sanitized handles)
                  (not (yes-or-no-p (format "Handle %s already in use.  Replace it? "
                                            sanitized))))
            (setq proposal sanitized))
           (t (setq final-handle sanitized))))))
    (let* ((handle final-handle)
           (replacing (member handle handles))
           (final-slice (plist-put (copy-sequence slice) :handle handle)))
      (list :slice final-slice :replacing replacing))))

(defun benedict-chat-compose--upsert-context-slice (slices slice)
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

(defun benedict-chat-compose--insert-handle-link (handle)
  "Insert [[HANDLE]] at point inside the compose body."
  (insert (format "[[%s]]" handle)))

(defun benedict-chat-compose--extract-handle-links (text)
  "Return a list of handle names referenced as [[handle]] in TEXT."
  (let (result (start 0))
    (while (string-match "\[\[\([A-Za-z0-9._:-]+\)\]\]" text start)
      (push (match-string 1 text) result)
      (setq start (match-end 0)))
    (nreverse (cl-delete-duplicates result :test #'string=))))

(defun benedict-chat-compose--warn-unknown-handles (body-handles slices)
  "Warn when BODY-HANDLES are not present in SLICES."
  (let* ((known (benedict-chat-compose--context-handles slices))
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
                     (benedict-chat-compose--header-text chat)
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
    (insert header benedict-chat-compose--separator)
    (when context-preview
      (insert context-preview benedict-chat-compose--separator))
    (setq benedict-chat-compose--body-start (copy-marker (point)))
    (set-marker-insertion-type benedict-chat-compose--body-start nil)
    (add-text-properties (point-min) benedict-chat-compose--body-start
                         '(read-only t front-sticky t rear-nonsticky t))
    (insert body)
    (goto-char (min (point-max)
                    (+ (marker-position benedict-chat-compose--body-start)
                       (or body-point (length body)))))))

(defun benedict-chat-compose--refresh-header ()
  "Refresh compose buffer header for the current chat."
  (when (and benedict-chat--compose-buffer
             (buffer-live-p benedict-chat--compose-buffer))
    (with-current-buffer benedict-chat--compose-buffer
      (benedict-chat-compose--render-header))))

(defun benedict-chat-compose--ensure-buffer ()
  "Return the compose buffer for the current chat, creating it if needed."
  (let ((chat (current-buffer)))
    (unless (derived-mode-p 'benedict-chat-mode)
      (user-error "Compose buffers are only available from Benedict chat"))
    (unless (and benedict-chat--compose-buffer
                 (buffer-live-p benedict-chat--compose-buffer))
      (let ((buffer (get-buffer-create (benedict-chat-compose--buffer-name chat))))
        (setq benedict-chat--compose-buffer buffer)
        (with-current-buffer buffer
          (benedict-chat-compose-mode)
          (setq-local benedict-chat-compose--chat-buffer chat)
          (benedict-chat-compose--render-header))))
    benedict-chat--compose-buffer))

(defun benedict-chat-compose--display-buffer (buffer)
  "Display compose BUFFER in a window below the selected one."
  (pop-to-buffer
   buffer
   '((display-buffer-reuse-window display-buffer-in-direction)
     (direction . below)
     (window-height . benedict-chat-compose-window-height))))

(defun benedict-chat-compose--close-windows (compose-buffer chat-buffer)
  "Close windows showing COMPOSE-BUFFER and focus CHAT-BUFFER."
  (dolist (window (get-buffer-window-list compose-buffer nil t))
    (when (window-live-p window)
      (with-selected-window window
        (if (one-window-p t)
            (when (buffer-live-p chat-buffer)
              (switch-to-buffer chat-buffer))
          (delete-window window)))))
  (when (buffer-live-p chat-buffer)
    (if-let ((chat-window (get-buffer-window chat-buffer t)))
        (select-window chat-window)
      (pop-to-buffer chat-buffer))))

(defun benedict-chat-compose-open ()
  "Open or focus the compose buffer for the current chat."
  (interactive)
  (let* ((chat (benedict-chat--ensure-chat-buffer))
         (compose (with-current-buffer chat
                     (benedict-chat-compose--ensure-buffer))))
    (benedict-chat-compose--display-buffer compose)
    (goto-char (point-max))
    (message "Compose buffer ready. C-c C-c to send; C-c C-k to cancel.")))

(defun benedict-chat-compose--body-text ()
  "Return the editable body text from the current compose buffer."
  (buffer-substring-no-properties
   (or (marker-position benedict-chat-compose--body-start) (point-min))
   (point-max)))

(defun benedict-chat-compose--assemble-message-text (prompt slices)
  "Return final user message text combining PROMPT and SLICES."
  (let* ((context (benedict-context-format-for-send slices))
         (body (string-trim prompt)))
    (string-join (delq nil (list context body)) "\n\n")))

(defun benedict-chat-compose--clear-state ()
  "Clear compose buffer reference for the current chat."
  (when (and benedict-chat--compose-buffer
             (buffer-live-p benedict-chat--compose-buffer))
    (kill-buffer benedict-chat--compose-buffer))
  (setq benedict-chat--compose-model-override nil)
  (setq benedict-chat--compose-buffer nil)
  (benedict-chat--configure-session)
  (benedict-chat-status--status-refresh))

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
           (stable-chat (with-current-buffer chat
                           (or benedict-chat--buffer chat)))
           (slices (with-current-buffer stable-chat
                      benedict-chat--context-slices))
           (body-handles (benedict-chat-compose--extract-handle-links prompt))
           (text (benedict-chat-compose--assemble-message-text prompt slices)))
      (benedict-chat-compose--warn-unknown-handles body-handles slices)
      (benedict-chat-compose--close-windows compose stable-chat)
      (with-current-buffer stable-chat
        (benedict-chat--send-text text stable-chat t)
        (unless benedict-chat-context-retain-after-send
          (benedict-chat--set-context-slices nil))
        (benedict-chat-compose--clear-state))
      (message "Benedict: sent prompt with context"))))

(defun benedict-chat-compose-cancel ()
  "Cancel composition and discard pending context."
  (interactive)
  (unless (derived-mode-p 'benedict-chat-compose-mode)
    (user-error "Not in a Benedict compose buffer"))
  (let ((chat benedict-chat-compose--chat-buffer)
        (compose (current-buffer)))
    (when (buffer-live-p chat)
      (benedict-chat-compose--close-windows compose chat)
      (with-current-buffer chat
        (benedict-chat--set-context-slices nil)
        (benedict-chat-compose--clear-state))))
  (message "Benedict: canceled compose buffer"))

(defun benedict-chat-compose--deliver-context-slices (slices)
  "Attach SLICES to the compose buffer for the current chat."
  (let* ((chat (benedict-chat--ensure-chat-buffer))
         (compose (with-current-buffer chat
                    (benedict-chat-compose--ensure-buffer)))
         (prepared nil))
    (with-current-buffer chat
      (let ((existing (benedict-chat-compose--context-handles benedict-chat--context-slices)))
        (dolist (slice slices)
          (let* ((entry (benedict-chat-compose--prepare-context-slice slice existing))
                 (final (plist-get entry :slice)))
            (push entry prepared)
            (setq benedict-chat--context-slices
                  (benedict-chat-compose--upsert-context-slice benedict-chat--context-slices final))
            (setq existing (benedict-chat-compose--context-handles benedict-chat--context-slices)))))
      (setq prepared (nreverse prepared)))
    (with-current-buffer chat
      (benedict-chat--set-context-slices benedict-chat--context-slices))
    (when (buffer-live-p compose)
      (with-current-buffer compose
        (benedict-chat-compose--render-header)
        (when (and benedict-chat-compose--body-start
                   (< (point) (marker-position benedict-chat-compose--body-start)))
          (goto-char (marker-position benedict-chat-compose--body-start)))
        (dolist (entry prepared)
          (let ((handle (plist-get (plist-get entry :slice) :handle)))
            (when (and handle (not (plist-get entry :replacing)))
              (benedict-chat-compose--insert-handle-link handle))))))
    (benedict-chat-compose--display-buffer compose)))

(provide 'benedict-chat-compose)
;;; benedict-chat-compose.el ends here
