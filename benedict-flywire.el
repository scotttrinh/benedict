;;; benedict-flywire.el --- Agent frame and session management  -*- lexical-binding: t; -*-
;; Author: Benedict maintainers
;; Version: 0.1.0-pre
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;;; Commentary:
;; Provides agent-frame isolation for tool execution using flywire.
;; Key architectural principle: tools (in benedict-tools.el) define the
;; interface and orchestration; this module provides the execution environment.
;;
;; Main entry points:
;;   - `benedict-flywire-session-create' — create a new session with agent frame
;;   - `benedict-flywire-session-teardown' — clean up frame and resources
;;   - `benedict-flywire-env-create-headless' — create headless env for testing

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'flywire)
(require 'flywire-session)
(require 'flywire-snapshot)

(defgroup benedict-flywire nil
  "Flywire integration for Benedict agent execution."
  :group 'benedict
  :prefix "benedict-flywire-")

(defcustom benedict-flywire-frame-visible nil
  "When non-nil, the agent frame is visible for debugging."
  :type 'boolean
  :group 'benedict-flywire)

(defcustom benedict-flywire-snapshot-profile 'default
  "Snapshot profile used when capturing agent frame state.
One of `minimal', `default', or `rich'."
  :type '(choice (const minimal) (const default) (const rich))
  :group 'benedict-flywire)

(defcustom benedict-flywire-idle-delay 0.5
  "Seconds of idle time before emitting an :idle event."
  :type 'number
  :group 'benedict-flywire)

(defcustom benedict-flywire-allowed-commands
  '(;; Navigation
    forward-char backward-char forward-word backward-word
    next-line previous-line move-end-of-line move-beginning-of-line
    beginning-of-buffer end-of-buffer
    goto-char goto-line forward-line
    scroll-up-command scroll-down-command
    recenter-top-bottom
    ;; Basic editing
    self-insert-command newline newline-and-indent indent-for-tab-command
    delete-char delete-backward-char kill-line kill-word backward-kill-word
    kill-region yank yank-pop
    undo undo-redo
    ;; Selection
    set-mark-command exchange-point-and-mark
    ;; Search (non-destructive)
    isearch-forward isearch-backward
    ;; File operations
    find-file find-file-noselect save-buffer write-file
    ;; Buffer operations
    switch-to-buffer set-buffer kill-buffer
    ;; Window operations
    split-window-right split-window-below delete-window delete-other-windows
    other-window select-window
    ;; Eval (controlled)
    eval-expression eval-last-sexp)
  "List of commands allowed in agent sessions.
Commands not in this list will be blocked by the safety policy."
  :type '(repeat symbol)
  :group 'benedict-flywire)

;;; Internal variables

(defvar benedict-flywire--agent-frame nil
  "The dedicated frame for agent operations, or nil if none exists.")

(defvar benedict-flywire--sessions nil
  "List of active flywire sessions.")

(defvar benedict-flywire--event-state (make-hash-table :test 'eq)
  "Per-session event wiring state.
Keys are sessions; values are plists with event handlers.")

(defvar benedict-flywire--session-callbacks (make-hash-table :test 'eq)
  "Per-session event callbacks.
Keys are sessions; values are lists of callback functions.")

(defvar benedict-flywire--session-policies (make-hash-table :test 'eq)
  "Per-session safety policies.
Keys are sessions; values are policy functions or nil for default.")

;;; Safety policy

(defun benedict-flywire-command-allowed-p (command &optional session)
  "Return non-nil if COMMAND is allowed.
If SESSION is provided and has a custom policy, uses that.
Otherwise uses the global `benedict-flywire-allowed-commands' list."
  (let ((policy (and session (gethash session benedict-flywire--session-policies))))
    (if (functionp policy)
        (funcall policy command)
      (memq command benedict-flywire-allowed-commands))))

(defun benedict-flywire-session-set-policy (session policy)
  "Set the safety POLICY for SESSION.
POLICY should be a function that takes a command symbol and returns
non-nil if the command is allowed, or nil to use the default policy."
  (if policy
      (puthash session policy benedict-flywire--session-policies)
    (remhash session benedict-flywire--session-policies)))

(defun benedict-flywire--make-policy-predicate (session)
  "Return a predicate function for checking commands in SESSION."
  (lambda (command)
    (benedict-flywire-command-allowed-p command session)))

;;; Frame management

(defun benedict-flywire--make-frame ()
  "Create or return the dedicated agent frame.
The frame is marked with parameter `benedict-agent-frame' set to t."
  (if (and benedict-flywire--agent-frame
           (frame-live-p benedict-flywire--agent-frame))
      benedict-flywire--agent-frame
    (let ((frame (make-frame `((name . "Benedict Agent")
                               (visibility . ,(if benedict-flywire-frame-visible
                                                  'visible
                                                'nil))
                               (minibuffer . t)
                               (width . 80)
                               (height . 40)
                               (benedict-agent-frame . t)))))
      (setq benedict-flywire--agent-frame frame)
      frame)))

(defun benedict-flywire--ensure-root-buffer (frame)
  "Ensure FRAME has a root buffer displayed.
Creates a *Benedict Agent* scratch buffer if needed."
  (with-selected-frame frame
    (let ((buf (get-buffer-create "*Benedict Agent*")))
      (with-current-buffer buf
        (unless (eq major-mode 'fundamental-mode)
          (fundamental-mode))
        (setq-local buffer-read-only nil))
      (set-window-buffer (frame-selected-window frame) buf)
      buf)))

(defun benedict-flywire--delete-frame ()
  "Delete the agent frame if it exists."
  (when (and benedict-flywire--agent-frame
             (frame-live-p benedict-flywire--agent-frame))
    (delete-frame benedict-flywire--agent-frame t))
  (setq benedict-flywire--agent-frame nil))

;;; Event infrastructure

(defun benedict-flywire--emit-event (session event)
  "Emit EVENT to all callbacks registered for SESSION."
  (when-let ((callbacks (gethash session benedict-flywire--session-callbacks)))
    (dolist (callback callbacks)
      (condition-case err
          (funcall callback event)
        (error
         (message "Benedict flywire event callback error: %S" err))))))

(defun benedict-flywire-session-on-event (session callback)
  "Register CALLBACK to receive events from SESSION.
CALLBACK is called with one argument, an event plist with at least :type.
Returns a function to remove the callback."
  (let ((callbacks (gethash session benedict-flywire--session-callbacks)))
    (puthash session (cons callback callbacks) benedict-flywire--session-callbacks)
    (lambda ()
      (let ((current (gethash session benedict-flywire--session-callbacks)))
        (puthash session (delq callback current) benedict-flywire--session-callbacks)))))

(defun benedict-flywire--enable-events-for-frame (session frame opts)
  "Install minibuffer/idle events for SESSION scoped to FRAME.
OPTS is a plist that may include :idle-delay to override the default."
  (unless (gethash session benedict-flywire--event-state)
    (let* ((idle-delay (or (plist-get opts :idle-delay) benedict-flywire-idle-delay))
           (snapshot-profile (or (plist-get opts :snapshot-profile)
                                 benedict-flywire-snapshot-profile))
           (get-snapshot (lambda ()
                           (when (frame-live-p frame)
                             (with-selected-frame frame
                               (flywire-snapshot-get-snapshot snapshot-profile)))))
           (minibuffer-hook
            (lambda ()
              (when (and (frame-live-p frame)
                         (eq (selected-frame) frame))
                (benedict-flywire--emit-event
                 session
                 (list :type :minibuffer-open
                       :session session
                       :prompt (minibuffer-prompt)
                       :snapshot (funcall get-snapshot))))))
           (idle-handler
            (lambda ()
              (when (frame-live-p frame)
                (benedict-flywire--emit-event
                 session
                 (list :type :idle
                       :session session
                       :snapshot (funcall get-snapshot))))))
           (idle-timer (run-with-idle-timer idle-delay t idle-handler)))
      (add-hook 'minibuffer-setup-hook minibuffer-hook)
      (puthash session
               (list :minibuffer-hook minibuffer-hook
                     :idle-timer idle-timer
                     :frame frame)
               benedict-flywire--event-state))))

(defun benedict-flywire--enable-events-headless (session _opts)
  "Enable events for a headless SESSION (no-op for most events).
Headless sessions don't have a frame for minibuffer/idle events."
  (unless (gethash session benedict-flywire--event-state)
    (puthash session (list :headless t) benedict-flywire--event-state)))

(defun benedict-flywire--teardown-events (session)
  "Remove event wiring for SESSION."
  (when-let ((state (gethash session benedict-flywire--event-state)))
    (when-let ((hook (plist-get state :minibuffer-hook)))
      (remove-hook 'minibuffer-setup-hook hook))
    (when-let ((timer (plist-get state :idle-timer)))
      (cancel-timer timer))
    (remhash session benedict-flywire--event-state)
    (remhash session benedict-flywire--session-callbacks)))

;;; Environment creation

(defun benedict-flywire-env-create ()
  "Create a flywire-session-env for the dedicated agent frame.
The agent frame is created if it doesn't exist."
  (let ((frame (benedict-flywire--make-frame)))
    (benedict-flywire--ensure-root-buffer frame)
    (make-flywire-session-env
     :name "benedict-agent"
     :run (lambda (thunk)
            (with-selected-frame frame
              (funcall thunk)))
     :snapshot (lambda (&optional profile)
                 (with-selected-frame frame
                   (flywire-snapshot-get-snapshot
                    (or profile benedict-flywire-snapshot-profile))))
     :enable-events (lambda (session opts)
                      (benedict-flywire--enable-events-for-frame session frame opts))
     :teardown (lambda (session)
                 (benedict-flywire--teardown-events session)))))

(defun benedict-flywire-env-create-headless ()
  "Create a headless flywire-session-env for testing.
No frame is created; operations run in current context."
  (make-flywire-session-env
   :name "benedict-headless"
   :run #'funcall
   :snapshot (lambda (&optional profile)
               (flywire-snapshot-get-snapshot
                (or profile benedict-flywire-snapshot-profile)))
   :enable-events #'benedict-flywire--enable-events-headless
   :teardown #'benedict-flywire--teardown-events))

;;; Session management

(cl-defun benedict-flywire-session-create (&key headless safety-policy)
  "Create a new flywire session for Benedict tool execution.
HEADLESS: when non-nil, uses a headless environment (for testing).
SAFETY-POLICY: optional function to check if commands are allowed.
  If nil, uses the default `benedict-flywire-allowed-commands' list.
Returns the created session."
  (let* ((env (if headless
                  (benedict-flywire-env-create-headless)
                (benedict-flywire-env-create)))
         (session (flywire-session-create
                   :env env
                   :snapshot-profile benedict-flywire-snapshot-profile
                   :safety-policy (benedict-flywire--make-policy-predicate nil))))
    (push session benedict-flywire--sessions)
    (when safety-policy
      (benedict-flywire-session-set-policy session safety-policy))
    session))

(defun benedict-flywire-session-teardown (session)
  "Clean up SESSION and associated resources.
If this is the last session using the agent frame, deletes the frame."
  (when session
    (let ((env (flywire-session-env session)))
      (funcall (flywire-session-env-teardown env) session))
    (remhash session benedict-flywire--session-policies)
    (setq benedict-flywire--sessions
          (delq session benedict-flywire--sessions))
    (when (null benedict-flywire--sessions)
      (benedict-flywire--delete-frame))))

(defun benedict-flywire-session-enable-events (session &optional opts)
  "Enable event emission for SESSION.
OPTS is a plist that may include:
  :idle-delay - seconds before idle events fire
  :snapshot-profile - profile for event snapshots"
  (let ((env (flywire-session-env session)))
    (funcall (flywire-session-env-enable-events env) session opts)))

(defun benedict-flywire-session-run (session thunk)
  "Execute THUNK within SESSION's environment.
Returns the result of THUNK."
  (let* ((env (flywire-session-env session)))
    (funcall (flywire-session-env-run env) thunk)))

;;; Utility functions

(defun benedict-flywire-show-frame ()
  "Make the agent frame visible for debugging."
  (interactive)
  (when (and benedict-flywire--agent-frame
             (frame-live-p benedict-flywire--agent-frame))
    (make-frame-visible benedict-flywire--agent-frame)
    (raise-frame benedict-flywire--agent-frame)))

(defun benedict-flywire-snapshot (&optional session profile)
  "Get a snapshot of SESSION's state using PROFILE.
If SESSION is nil, uses the agent frame directly.
PROFILE defaults to `benedict-flywire-snapshot-profile'."
  (let ((profile (or profile benedict-flywire-snapshot-profile)))
    (if session
        (let ((env (flywire-session-env session)))
          (funcall (flywire-session-env-snapshot env) profile))
      (when (and benedict-flywire--agent-frame
                 (frame-live-p benedict-flywire--agent-frame))
        (with-selected-frame benedict-flywire--agent-frame
          (flywire-snapshot-get-snapshot profile))))))

;;; File operations

(defun benedict-flywire--format-line-numbered (content start-line)
  "Format CONTENT with line numbers starting from START-LINE.
Each line is prefixed with \"N | \" where N is the line number."
  (let ((lines (split-string content "\n" nil))
        (line-num start-line)
        result)
    (dolist (line lines)
      (push (format "%d | %s" line-num line) result)
      (cl-incf line-num))
    (string-join (nreverse result) "\n")))

(cl-defun benedict-flywire-read-file (session path &key start-line end-line)
  "Read file at PATH within SESSION's environment.
Returns content with line numbers prepended.
START-LINE and END-LINE are 1-based (inclusive).
If START-LINE is nil, starts from line 1.
If END-LINE is nil, reads to end of file."
  (benedict-flywire-session-run session
    (lambda ()
      (unless (and (stringp path) (not (string-empty-p path)))
        (signal 'benedict-error '("Path must be a non-empty string")))
      (unless (file-exists-p path)
        (signal 'benedict-error (list (format "File does not exist: %s" path))))
      (unless (file-readable-p path)
        (signal 'benedict-error (list (format "File is not readable: %s" path))))
      (let* ((start (or start-line 1))
             (end end-line)
             (buf (find-file-noselect path t)))
        (unwind-protect
            (with-current-buffer buf
              (goto-char (point-min))
              (forward-line (1- start))
              (let ((beg (point)))
                (if end
                    (progn
                      (goto-char (point-min))
                      (forward-line end)
                      (let ((content (buffer-substring-no-properties beg (point))))
                        (benedict-flywire--format-line-numbered content start)))
                  (let ((content (buffer-substring-no-properties beg (point-max))))
                    (benedict-flywire--format-line-numbered content start)))))
          (kill-buffer buf))))))

(cl-defun benedict-flywire-update-file (session path &key start-line end-line content)
  "Update file at PATH within SESSION's environment.
Replaces lines from START-LINE to END-LINE (1-based, inclusive) with CONTENT.
If END-LINE is nil, replaces only START-LINE.
Saves the file after modification.
Returns a plist with :success and :message."
  (benedict-flywire-session-run session
    (lambda ()
      (unless (and (stringp path) (not (string-empty-p path)))
        (signal 'benedict-error '("Path must be a non-empty string")))
      (unless (file-exists-p path)
        (signal 'benedict-error (list (format "File does not exist: %s" path))))
      (unless (file-writable-p path)
        (signal 'benedict-error (list (format "File is not writable: %s" path))))
      (unless (and start-line (> start-line 0))
        (signal 'benedict-error '("start-line must be a positive integer")))
      (let* ((start start-line)
             (end (or end-line start-line))
             (new-content (or content ""))
             (buf (find-file-noselect path t)))
        (unwind-protect
            (with-current-buffer buf
              (goto-char (point-min))
              (forward-line (1- start))
              (let ((beg (point)))
                (forward-line (1+ (- end start)))
                (delete-region beg (point))
                (goto-char beg)
                (insert new-content)
                (unless (or (string-empty-p new-content)
                            (string-suffix-p "\n" new-content))
                  (insert "\n"))
                (save-buffer)
                (list :success t
                      :message (format "Updated lines %d-%d in %s"
                                       start end
                                       (file-name-nondirectory path)))))
          (kill-buffer buf))))))

(defun benedict-flywire-exec-elisp (session code)
  "Execute elisp CODE string within SESSION's environment.
Returns a plist with :success, :result (or :error)."
  (benedict-flywire-session-run session
    (lambda ()
      (unless (and (stringp code) (not (string-empty-p code)))
        (signal 'benedict-error '("Code must be a non-empty string")))
      (condition-case err
          (let* ((form (read code))
                 (result (eval form t)))
            (list :success t
                  :result (prin1-to-string result)))
        (error
         (list :success nil
               :error (format "%S" err)))))))

(provide 'benedict-flywire)
;;; benedict-flywire.el ends here
