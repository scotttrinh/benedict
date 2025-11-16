;;; benedict-chat.el --- Chat buffers and commands -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provider-backed chat buffer for Phase 2. Renders role-tagged messages,
;; tracks history for retry/copy actions, and dispatches requests through
;; the active Benedict provider (OpenRouter by default).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict)

(defvar-local benedict-chat--messages nil
  "List of chat message plists (newest first).
Each entry includes :role, :content, :time, and optional :metadata.")

(defvar-local benedict-chat--pending-request nil
  "Opaque handle representing an in-flight provider request.")

(defvar-local benedict-chat--last-dispatch nil
  "Plist describing the most recent provider request (for retries).")

(defvar benedict-chat-buffer-name "*Benedict Chat*"
  "Default chat buffer name.")

(defun benedict-chat--provider-label ()
  "Return a short label for the active provider."
  (condition-case nil
      (let ((provider (benedict-provider-current)))
        (or (benedict-provider-name provider)
            (symbol-name (benedict-provider-id provider))))
    (error "unknown provider")))

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

(defun benedict-chat--record-message (message)
  "Persist MESSAGE in buffer history and render it."
  (push message benedict-chat--messages)
  (benedict-chat--insert message))

(defun benedict-chat--message-history ()
  "Return messages in chronological order."
  (reverse benedict-chat--messages))

(defun benedict-chat--insert (message)
  "Insert MESSAGE into the current buffer."
  (let* ((role (benedict-chat--normalize-role (plist-get message :role)))
         (content (or (plist-get message :content) ""))
         (metadata (plist-get message :metadata))
         (face (benedict-chat--face-for-role role metadata))
         (label (capitalize (symbol-name role))))
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (propertize (format "%s: " label) 'face face))
      (insert content)
      (insert "\n")
      (let ((meta-line (benedict-chat--format-metadata-line metadata)))
        (when meta-line
          (insert (propertize meta-line 'face 'benedict-chat-system))
          (insert "\n"))))))

(defun benedict-chat--format-metadata-line (metadata)
  "Return a user-facing line for METADATA plist."
  (when metadata
    (let (parts)
      (when-let ((provider (plist-get metadata :provider)))
        (push (format "provider %s" provider) parts))
      (when-let ((model (plist-get metadata :model)))
        (push model parts))
      (when-let ((latency (plist-get metadata :latency)))
        (push (format "%.2fs" latency) parts))
      (when-let ((usage (plist-get metadata :usage)))
        (let ((prompt (benedict-chat--usage-value usage "prompt_tokens"))
              (completion (benedict-chat--usage-value usage "completion_tokens")))
          (when (or prompt completion)
            (push (format "tokens p:%s / c:%s"
                          (or prompt "?")
                          (or completion "?"))
                  parts))))
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
        (concat "  " (string-join (nreverse parts) " · "))))))

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
  (list :role (plist-get message :role)
        :content (or (plist-get message :content) "")))

(defun benedict-chat--build-request ()
  "Build a provider request plist from buffer state."
  (list :messages (mapcar #'benedict-chat--message->provider
                          (benedict-chat--message-history))))

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

(defun benedict-chat--handle-provider-success (result)
  "Handle RESULT returned from the provider."
  (setq benedict-chat--pending-request nil)
  (let* ((message (plist-get result :message))
         (role (benedict-chat--normalize-role (plist-get message :role)))
         (content (or (plist-get message :content) ""))
         (metadata (benedict-chat--metadata
                    :provider (plist-get result :provider)
                    :model (plist-get result :model)
                    :latency (plist-get result :latency)
                    :usage (plist-get result :usage))))
    (benedict-chat--record-message
     (list :role role :content content :time (current-time) :metadata metadata))
    (message "Benedict: %s replied via %s"
             (if (plist-get metadata :model)
                 (plist-get metadata :model)
               "provider")
             (benedict-chat--provider-label))))

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
  (let ((content (benedict-chat--format-error-content payload))
        (metadata (benedict-chat--metadata
                   :provider (or (plist-get payload :provider) benedict-provider)
                   :error t
                   :status (plist-get payload :status)
                   :code (plist-get payload :code)
                   :retryable (plist-get payload :retryable))))
    (benedict-chat--record-message
     (list :role 'assistant :content content :time (current-time) :metadata metadata))
    (message "Benedict provider error: %s" content)))

(defun benedict-chat--start-dispatch (request &optional retry)
  "Send REQUEST through the provider. RETRY notes when replaying."
  (let ((buffer (current-buffer))
        (provider-label (benedict-chat--provider-label)))
    (setq benedict-chat--last-dispatch
          (list :request request :timestamp (current-time) :retry retry))
    (message "Benedict: contacting %s%s..."
             provider-label (if retry " (retry)" ""))
    (condition-case err
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
                               (benedict-chat--handle-provider-error payload)))) ))
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
  (unless (derived-mode-p 'benedict-chat-mode)
    (user-error "Not in a Benedict chat buffer"))
  (when (string-blank-p text)
    (user-error "Prompt is empty"))
  (benedict-chat--ensure-not-busy)
  (benedict-chat--record-message
   (list :role 'user :content text :time (current-time)))
  (benedict-chat--start-dispatch (benedict-chat--build-request)))

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
    m)
  "Keymap for `benedict-chat-mode'.")

(define-derived-mode benedict-chat-mode special-mode "Benedict-Chat"
  "Major mode for Benedict chat buffers backed by network providers."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines t)
  (setq-local benedict-chat--messages nil)
  (setq-local benedict-chat--pending-request nil)
  (setq-local benedict-chat--last-dispatch nil)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize
             (format "Benedict Chat — provider: %s (non-streaming)\n"
                     (benedict-chat--provider-label))
             'face 'benedict-chat-system))
    (insert (propertize
             "Commands: C-c C-s send · g r retry-last · w copy-last\n"
             'face 'benedict-chat-system))
    (insert "\n")))

;;;###autoload
(defun benedict-chat ()
  "Open or switch to the Benedict chat buffer."
  (interactive)
  (let ((buf (get-buffer-create benedict-chat-buffer-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'benedict-chat-mode)
      (benedict-chat-mode)))
  (message "Type C-c C-s to send a prompt; g r retries; w copies last response."))

(provide 'benedict-chat)
;;; benedict-chat.el ends here
