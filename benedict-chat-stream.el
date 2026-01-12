;;; benedict-chat-stream.el --- Streaming support for Benedict chat -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Manages streaming state, throttling, and delta buffering.
;; Interfaces with benedict-chat-render to update the buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'benedict-chat-render)
(require 'benedict-chat-thinking)
(require 'benedict-session)

(defvar benedict-chat--session)
(defvar benedict-chat--streaming-message)
(declare-function benedict-chat--metadata "benedict-chat")
(declare-function benedict-chat--record-message "benedict-chat")
(declare-function benedict-chat--refresh-message-header "benedict-chat")
(declare-function benedict-chat--replace-message-content "benedict-chat")
(declare-function benedict-chat--render-message "benedict-chat")
(declare-function benedict-chat--resolve-provider "benedict-chat")
(declare-function benedict-chat-status--status-request-started-at-float "benedict-chat-status")

(defcustom benedict-chat-apply-buffer-name "*Benedict Block*"
  "Name of the temporary buffer used by `benedict-chat-stream-apply-block'."
  :type 'string
  :group 'benedict)

(defvar-local benedict-chat-stream--state nil
  "Plist containing streaming state for the current buffer.
Keys: :item, :pending-text.")

(defun benedict-chat-stream--init (buffer &optional item)
  "Initialize streaming state in BUFFER.

ITEM is the marker-backed chat item whose body should receive streaming deltas."
  (with-current-buffer buffer
    (setq benedict-chat-stream--state
          (list :item item
                :pending-text ""))))

(defun benedict-chat-stream--insert-delta (stream text)
  "Buffer TEXT into STREAM for throttled application.
Currently inserts immediately."
  (when-let ((item (plist-get stream :item)))
    (benedict-chat-render--append-item-content item text 'body)))

;; Streaming assistant message helpers

(defun benedict-chat-stream--reset (buffer)
  "Clear any active streaming message state in BUFFER."
  (with-current-buffer buffer
    (setq benedict-chat--streaming-message nil)
    (benedict-chat-stream--init buffer)))

(defun benedict-chat-stream--merge-metadata (payload)
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

(defun benedict-chat-stream--apply-metadata (payload)
  "Update streaming metadata and header for PAYLOAD."
  (when-let ((message (plist-get benedict-chat--streaming-message :message)))
    (let* ((metadata (benedict-chat-stream--merge-metadata payload))
           (state (plist-put benedict-chat--streaming-message :metadata metadata)))
      (setq benedict-chat--streaming-message state)
      (plist-put message :metadata metadata)
      (when-let ((item (plist-get message :item)))
        (plist-put item :metadata metadata)
        (benedict-chat--refresh-message-header item)))))

(defun benedict-chat-stream--ensure-message (buffer payload)
  "Ensure a placeholder assistant message exists for PAYLOAD in BUFFER."
  (with-current-buffer buffer
    (unless (plist-get benedict-chat--streaming-message :message)
      (let* ((metadata (benedict-chat--metadata
                        :provider (plist-get payload :provider)
                        :model (plist-get payload :model)))
             (record (list :role 'assistant
                           :content ""
                           :display-content nil
                           :time (current-time)
                           :metadata metadata)))
        (setq record (benedict-chat--record-message buffer record))
        (setq benedict-chat--streaming-message
              (list :message record
                    :content ""
                    :metadata metadata))
        (when-let ((item (plist-get record :item)))
          (benedict-chat-stream--init buffer item))))
    (benedict-chat-stream--apply-metadata payload)
    (plist-get benedict-chat--streaming-message :message)))

(defun benedict-chat-stream--append-text (buffer payload text)
  "Append TEXT for PAYLOAD to the streaming assistant message in BUFFER."
  (when (and text (> (length text) 0))
    (when-let ((message (benedict-chat-stream--ensure-message buffer payload)))
      (let* ((state benedict-chat--streaming-message)
             (current (or (plist-get state :content) ""))
             (updated (concat current text)))
        (setq state (plist-put state :content updated))
        (setq benedict-chat--streaming-message state)
        (benedict-chat--replace-message-content buffer message updated)))))

(defun benedict-chat-stream--complete-message (buffer metadata content display-content empty-response)
  "Finalize the streaming assistant message in BUFFER with METADATA and CONTENT.
DISPLAY-CONTENT replaces the visible text when EMPTY-RESPONSE is non-nil."
  (with-current-buffer buffer
    (when-let ((message (plist-get benedict-chat--streaming-message :message)))
      (let* ((state benedict-chat--streaming-message)
             (fallback (or (plist-get state :content) ""))
             (actual (or content fallback ""))
             (visible (if empty-response
                          (or display-content actual)
                        actual)))
        (benedict-chat--replace-message-content buffer message visible)
        (plist-put message :content actual)
        (if empty-response
            (plist-put message :display-content visible)
          (plist-put message :display-content nil))
        (plist-put message :metadata metadata)
        (plist-put message :time (current-time))
        (when-let ((item (plist-get message :item)))
          (plist-put item :metadata metadata)
          (benedict-chat--refresh-message-header item)))))
  (benedict-chat-stream--reset buffer))

(defun benedict-chat-stream--fail-message (buffer content metadata)
  "Replace the streaming message in BUFFER with error CONTENT and METADATA.
Returns non-nil when an active streaming entry handled the error."
  (with-current-buffer buffer
    (let ((handled nil))
      (when-let ((message (plist-get benedict-chat--streaming-message :message)))
        (setq handled t)
        (benedict-chat--replace-message-content buffer message content)
        (plist-put message :content content)
        (plist-put message :display-content nil)
        (plist-put message :metadata metadata)
        (plist-put message :time (current-time))
        (when-let ((item (plist-get message :item)))
          (plist-put item :metadata metadata)
          (benedict-chat--refresh-message-header item)))
      (benedict-chat-stream--reset buffer)
      handled)))

(defun benedict-chat-stream--format-metadata-line (metadata &optional prefix)
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
        (let* ((prompt (benedict-session--usage-value usage "prompt_tokens"))
               (completion (benedict-session--usage-value usage "completion_tokens"))
               (total (or (benedict-session--usage-value usage "total_tokens")
                          (and prompt completion (+ prompt completion))))
               (cost (or (benedict-session--usage-value usage "cost")
                         (benedict-session--usage-value usage "total_cost"))))
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

(defun benedict-chat-stream--clear-block-buttons (start-marker end-marker)
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

(defun benedict-chat-stream--insert-action-button (label action target)
  "Insert button with LABEL to run ACTION on TARGET."
  (insert-text-button
   label
   'face 'benedict-chat-button
   'follow-link t
   'help-echo (format "%s (code block)" label)
   'action action
   'benedict-chat-target target))

(defun benedict-chat-stream--block-target-string (target)
  "Return the code block contents described by TARGET plist."
  (let* ((start-marker (plist-get target :start))
         (end-marker (plist-get target :end))
         (start (and start-marker (marker-position start-marker)))
         (end (and end-marker (marker-position end-marker))))
    (unless (and start end (> end start))
      (user-error "Code block region is unavailable"))
    (buffer-substring-no-properties start end)))

(defun benedict-chat-stream-copy-block (button)
  "Copy the code block associated with BUTTON to the kill ring."
  (interactive (list (or (button-at (point))
                         (user-error "No code block button at point"))))
  (let* ((target (and button (button-get button 'benedict-chat-target)))
         (text (benedict-chat-stream--block-target-string target)))
    (kill-new text)
    (message "Benedict: copied code block to kill ring")
    text))

(defun benedict-chat-stream-apply-block (button)
  "Insert the code block for BUTTON into `benedict-chat-apply-buffer-name'."
  (interactive (list (or (button-at (point))
                         (user-error "No code block button at point"))))
  (let* ((target (and button (button-get button 'benedict-chat-target)))
         (text (benedict-chat-stream--block-target-string target))
         (buffer (get-buffer-create benedict-chat-apply-buffer-name)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert text)
      (goto-char (point-min)))
    (message "Benedict: inserted block into %s" benedict-chat-apply-buffer-name)
    buffer))

(defun benedict-chat-stream--ensure-streaming-message (buffer payload)
  "Ensure a streaming assistant message exists in BUFFER for PAYLOAD."
  (with-current-buffer buffer
    (unless benedict-chat--streaming-message
      (let* ((metadata (benedict-chat--metadata
                        :provider (plist-get payload :provider)
                        :model (plist-get payload :model)
                        :usage (plist-get payload :usage)))
             (record (list :role 'assistant
                           :content ""
                           :time (current-time)
                           :metadata metadata)))
        ;; Note: Session draft is started by session dispatch, not here.
        ;; Insert header and register item in history (buffer-local only)
        (setq record (benedict-chat--record-message buffer record))
        (when-let ((item (plist-get record :item)))
          (plist-put item :request-id (benedict-chat-thinking--current-request-id))
          (plist-put item :started-at (or (benedict-chat-status--status-request-started-at-float)
                                          (float-time)))
          (benedict-chat--refresh-message-header item)
          (benedict-chat-stream--init buffer item))

        (setq benedict-chat--streaming-message
              (list :message record
                    :content ""
                    :metadata metadata))))))

(defun benedict-chat-stream--handle-provider-delta (buffer payload)
  "Handle structured PAYLOAD update from the provider in BUFFER."
  (with-current-buffer buffer
    (when-let* ((state benedict-chat--streaming-message)
                (message (plist-get state :message)))
      (let* ((current (plist-get message :metadata))
             (metadata (benedict-chat--metadata
                        :provider (or (plist-get payload :provider)
                                      (and current (plist-get current :provider)))
                        :model (or (plist-get payload :model)
                                   (and current (plist-get current :model)))
                        :usage (or (plist-get payload :usage)
                                   (and current (plist-get current :usage))))))
        (plist-put message :metadata metadata)
        (setq benedict-chat--streaming-message
              (plist-put state :metadata metadata))
        (when-let ((item (plist-get message :item)))
          (plist-put item :metadata metadata)
          (benedict-chat--refresh-message-header item))))
    ;; Note: Session state is updated by session dispatch, not here.
    ;; This handler only updates buffer UI.
    (let ((kind (plist-get payload :kind))
          (text (plist-get payload :text)))
      (pcase kind
        ('content-delta
         (benedict-chat-stream--ensure-streaming-message buffer payload)
         (benedict-chat-stream--insert-delta benedict-chat-stream--state text))
        ('thinking-delta
         (when (and text (not (string-empty-p text)))
           (let* ((metadata (benedict-chat-stream--merge-metadata payload))
                  (id (or (and benedict-chat--streaming-message
                               (plist-get benedict-chat--streaming-message :thinking-id))
                          (benedict-chat-thinking--stream-id payload)))
                  (detail (list :id id
                                :type "reasoning.text"
                                :text text)))
             (when benedict-chat--streaming-message
               (plist-put benedict-chat--streaming-message :thinking-id id))
             (benedict-chat-thinking--display-detail buffer detail metadata t))))))))

(defun benedict-chat-stream--format-error-content (payload)
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

(defun benedict-chat-stream--handle-provider-error (buffer payload)
  "Render PAYLOAD returned from provider failure in BUFFER."
  (with-current-buffer buffer
    ;; Note: Session state is updated by session dispatch, not here.
    ;; This handler only updates buffer UI.
    (let* ((provider (or (plist-get payload :provider)
                         (and benedict-chat--session
                              (benedict-session-provider benedict-chat--session))
                         (benedict-chat--resolve-provider)))
           (content (benedict-chat-stream--format-error-content payload))
           (metadata (benedict-chat--metadata
                      :provider provider
                      :error t
                      :status (plist-get payload :status)
                      :code (plist-get payload :code)
                      :retryable (plist-get payload :retryable))))
      (unless (benedict-chat-stream--fail-message buffer content metadata)
        (benedict-chat--render-message
         buffer
         (list :role 'assistant :content content :time (current-time) :metadata metadata)))
      (message "Benedict provider error: %s" content))))

(provide 'benedict-chat-stream)
;;; benedict-chat-stream.el ends here
