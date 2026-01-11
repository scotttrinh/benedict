;;; benedict-chat-context-capture.el --- Context capture commands -*- lexical-binding: t; -*--

(require 'cl-lib)
(require 'benedict-context)
(require 'benedict-chat-compose)
(require 'benedict-chat-profiles) ;; for benedict-chat-profiles--project-root

(defun benedict-chat-context-capture--slice-with-handle-default (slice handle)
  "Return SLICE tagged with a default HANDLE suggestion."
  (plist-put slice :handle-default (benedict-chat-compose--preferred-handle handle)))

(defun benedict-chat-context-capture--buffer-label (&optional buffer)
  "Return a short label for BUFFER (defaults to current buffer)."
  (with-current-buffer (or buffer (current-buffer))
    (or (and buffer-file-name (file-name-nondirectory buffer-file-name))
        (buffer-name))))

(defun benedict-chat-context-capture--slice-from-region (start end)
  "Return a context slice covering region START to END."
  (let* ((text (buffer-substring-no-properties start end))
         (label (format "%s: lines %d-%d"
                        (benedict-chat-context-capture--buffer-label)
                        (line-number-at-pos start)
                        (line-number-at-pos end)))
         (origin (or buffer-file-name (buffer-name)))
         (default-handle (format "%s:%d-%d"
                                 (benedict-chat-context-capture--buffer-label)
                                 (line-number-at-pos start)
                                 (line-number-at-pos end)))
         (slice (benedict-context-make-slice
                 :kind 'region :label label :origin origin :content text)))
    (benedict-chat-context-capture--slice-with-handle-default slice default-handle)))

(defun benedict-chat-context-capture--current-defun-name ()
  "Return a best-effort defun name at point, or nil."
  (or (when (fboundp 'add-log-current-defun)
        (ignore-errors (add-log-current-defun)))
      (when (fboundp 'which-function)
        (ignore-errors
          (let ((value (which-function)))
            (cond
             ((stringp value) value)
             ((and (listp value) (stringp (car value))) (car value))))))))

(defun benedict-chat-context-capture--slice-from-defun ()
  "Return a context slice for the current defun."
  (let ((bounds (bounds-of-thing-at-point 'defun)))
    (unless bounds
      (user-error "No defun at point"))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (text (buffer-substring-no-properties start end))
           (label (format "%s: defun at line %d"
                          (benedict-chat-context-capture--buffer-label)
                          (line-number-at-pos start)))
           (origin (or buffer-file-name (buffer-name)))
           (line (line-number-at-pos start))
           (base (or (benedict-chat-context-capture--current-defun-name)
                     (benedict-chat-context-capture--buffer-label)))
           (default-handle (format "%s:%d" base line))
           (slice (benedict-context-make-slice
                   :kind 'defun :label label :origin origin :content text)))
      (benedict-chat-context-capture--slice-with-handle-default
       slice default-handle))))

(defun benedict-chat-context-capture--slice-from-buffer ()
  "Return a context slice for the entire current buffer."
  (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
         (label (format "%s buffer" (benedict-chat-context-capture--buffer-label)))
         (origin (or buffer-file-name (buffer-name)))
         (default-handle (format "%s-buffer" (benedict-chat-context-capture--buffer-label)))
         (slice (benedict-context-make-slice
                 :kind 'buffer :label label :origin origin :content text)))
    (benedict-chat-context-capture--slice-with-handle-default slice default-handle)))

(defun benedict-chat-context-capture--slice-from-project ()
  "Return a context slice describing the current project."
  (let* ((root (or (benedict-chat-profiles--project-root) default-directory))
         (label "Project overview")
         (content (format "Project root: %s" root))
         (slice (benedict-context-make-slice
                 :kind 'project :label label :origin root :content content)))
    (benedict-chat-context-capture--slice-with-handle-default slice "project")))

(defun benedict-chat-context-capture--git-run (root &rest args)
  "Run git ARGS inside ROOT directory and return trimmed string or nil."
  (when (and root (executable-find "git"))
    (ignore-errors
      (with-temp-buffer
        (let ((default-directory root))
          (when (eq 0 (apply #'process-file "git" nil (current-buffer) nil args))
            (string-trim (buffer-string))))))))

(defun benedict-chat-context-capture--slice-from-git ()
  "Return a context slice with basic Git info, or nil when unavailable."
  (let* ((root (or (when (fboundp 'magit-toplevel)
                     (ignore-errors (magit-toplevel)))
                   (ignore-errors (vc-root-dir))
                   (benedict-chat-profiles--project-root)))
         (branch (or (and (fboundp 'magit-get-current-branch)
                          (ignore-errors (magit-get-current-branch)))
                     (benedict-chat-context-capture--git-run root "rev-parse" "--abbrev-ref" "HEAD")))
         (status (or (and (fboundp 'magit-git-string)
                          (ignore-errors (magit-git-string "status" "--short")))
                     (benedict-chat-context-capture--git-run root "status" "--short")))
         (diff (or (and (fboundp 'magit-git-string)
                        (ignore-errors (magit-git-string "diff" "--stat")))
                   (benedict-chat-context-capture--git-run root "diff" "--stat"))))
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
        (benedict-chat-context-capture--slice-with-handle-default slice "git-status")))))

;;;###autoload
(defun benedict-chat-ask-region (start end)
  "Add the active region START END to the Benedict compose context."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (let ((slice (benedict-chat-context-capture--slice-from-region start end)))
    (benedict-chat-compose--deliver-context-slices (list slice))
    (message "Added region to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-defun ()
  "Add the defun at point to the Benedict compose context."
  (interactive)
  (let ((slice (benedict-chat-context-capture--slice-from-defun)))
    (benedict-chat-compose--deliver-context-slices (list slice))
    (message "Added defun to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-buffer ()
  "Add the entire buffer to the Benedict compose context."
  (interactive)
  (let ((slice (benedict-chat-context-capture--slice-from-buffer)))
    (benedict-chat-compose--deliver-context-slices (list slice))
    (message "Added buffer to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-project ()
  "Add basic project information to the compose context."
  (interactive)
  (let ((slice (benedict-chat-context-capture--slice-from-project)))
    (benedict-chat-compose--deliver-context-slices (list slice))
    (message "Added project context to Benedict compose buffer")))

;;;###autoload
(defun benedict-chat-ask-git-context ()
  "Add simple Git status/diff information to the compose context."
  (interactive)
  (if-let ((slice (benedict-chat-context-capture--slice-from-git)))
      (progn
        (benedict-chat-compose--deliver-context-slices (list slice))
        (message "Added Git context to Benedict compose buffer"))
    (user-error "No Git context available here")))

(provide 'benedict-chat-context-capture)
;;; benedict-chat-context-capture.el ends here
