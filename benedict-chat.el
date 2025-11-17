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
(require 'benedict)

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

(defconst benedict-chat--block-divider-line
  (concat (make-string 60 ?-) "\n")
  "Divider line inserted before and after block sections.")

(defconst benedict-chat--empty-response-placeholder
  "Response finished without assistant text."
  "Displayed when providers return no assistant message.")

(defconst benedict-chat--empty-response-thinking-placeholder
  "Response finished with reasoning only; no assistant message."
  "Displayed when providers stream thinking without a final reply.")

(defun benedict-chat--empty-response-text (thinking)
  "Return placeholder text for empty responses.
THINKING is non-nil when reasoning blocks accompanied the response."
  (if thinking
      benedict-chat--empty-response-thinking-placeholder
    benedict-chat--empty-response-placeholder))

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
  (let* ((display (or (plist-get message :display-content)
                      (plist-get message :content)
                      ""))
         (item (apply #'benedict-chat--make-item
                      'message
                      (list :role (plist-get message :role)
                            :content display
                            :metadata (plist-get message :metadata))))
         (message (plist-put message :item item)))
    (benedict-chat--track-item item)
    (benedict-chat--render-item item)
    message))

(defun benedict-chat--record-thinking (content metadata &rest properties)
  "Record a thinking block with CONTENT and METADATA.
This does not affect provider message history."
  (let* ((item (apply #'benedict-chat--make-item
                      'thinking
                      :role 'thinking
                      :content content
                      :metadata metadata
                      properties)))
    (benedict-chat--track-item item)
    (benedict-chat--render-item item)
    item))

(defun benedict-chat--message-history ()
  "Return messages in chronological order."
  (reverse benedict-chat--messages))

(defun benedict-chat--render-item (item)
  "Render ITEM according to its :kind."
  (pcase (plist-get item :kind)
    ('message (benedict-chat--render-message item))
    ('thinking (benedict-chat--render-thinking item))
    (_ (benedict-chat--render-message item))))

(defun benedict-chat--render-block (item header face)
  "Render ITEM as a divider block labeled with HEADER using FACE."
  (let* ((content (or (plist-get item :content) ""))
         (metadata (plist-get item :metadata))
         (content-end-marker nil))
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (unless (bobp) (insert "\n"))
      (let ((block-start (point)))
        (insert (propertize benedict-chat--block-divider-line 'face 'benedict-chat-block-divider))
        (let ((header-start (point)))
          (insert (propertize header 'face face) "\n")
          (plist-put item :header-start (copy-marker header-start t))
          (plist-put item :header-end (copy-marker (point) nil)))
        (insert (propertize benedict-chat--block-divider-line 'face 'benedict-chat-block-divider))
        (let ((content-start (point)))
          (insert content)
          (unless (bolp) (insert "\n"))
          (let ((content-end (point)))
            (plist-put item :content-start (copy-marker content-start nil))
            (setq content-end-marker (copy-marker content-end t))
            (set-marker-insertion-type content-end-marker nil)
            (plist-put item :content-end content-end-marker)))
        (insert (propertize benedict-chat--block-divider-line 'face 'benedict-chat-block-divider))
        (insert "\n")
        (plist-put item :start (copy-marker block-start t))
        (plist-put item :end (copy-marker (point) nil))
        (when content-end-marker
          (set-marker-insertion-type content-end-marker t))))
    (benedict-chat--decorate-message item)
    metadata))

(defun benedict-chat--render-message (item)
  "Insert ITEM as a message block in the current buffer."
  (let* ((role (benedict-chat--normalize-role (plist-get item :role)))
         (metadata (plist-get item :metadata))
         (summary (benedict-chat--format-metadata-line metadata " · "))
         (header (string-join (delq nil (list (capitalize (symbol-name role)) summary))
                              ""))
         (face (benedict-chat--face-for-role role metadata)))
    (benedict-chat--render-block item header face)))

(defun benedict-chat--refresh-message-header (item)
  "Update ITEM's header line using current metadata."
  (let ((header-start (plist-get item :header-start))
        (header-end (plist-get item :header-end)))
    (when (and header-start header-end
               (marker-position header-start)
               (marker-position header-end))
      (let* ((role (benedict-chat--normalize-role (plist-get item :role)))
             (metadata (plist-get item :metadata))
             (summary (benedict-chat--format-metadata-line metadata " · "))
             (header (string-join (delq nil (list (capitalize (symbol-name role))
                                                  summary))
                                  ""))
             (face (benedict-chat--face-for-role role metadata))
             (start (marker-position header-start))
             (end (marker-position header-end)))
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char start)
            (delete-region start end)
            (insert (propertize header 'face face))
            (set-marker header-end (point))))))))

(defun benedict-chat--write-message-item-content (item text)
  "Replace ITEM's content block with TEXT."
  (let ((content-start (plist-get item :content-start))
        (content-end (plist-get item :content-end)))
    (when (and content-start content-end
               (marker-position content-start)
               (marker-position content-end))
      (let ((inhibit-read-only t)
            (start (marker-position content-start))
            (end (marker-position content-end)))
        (save-excursion
          (goto-char start)
          (delete-region start end)
          (when (and text (> (length text) 0))
            (insert text))
          (unless (bolp)
            (insert "\n"))
          (set-marker content-end (point))))
      (benedict-chat--decorate-message item))))

(defun benedict-chat--replace-message-content (message text)
  "Replace MESSAGE's rendered content with TEXT."
  (let ((item (plist-get message :item))
        (payload (or text "")))
    (when item
      (benedict-chat--write-message-item-content item payload))
    (plist-put message :content payload)
    (plist-put message :display-content nil)))

(defun benedict-chat--render-thinking (item)
  "Render ITEM as a thinking block."
  (let* ((metadata (plist-get item :metadata))
         (label (plist-get item :thinking-label))
         (header-text (if label
                          (format "Thinking — %s" label)
                        "Thinking"))
         (summary (benedict-chat--format-metadata-line metadata " · "))
         (header (string-join (delq nil (list header-text summary)) ""))
         (face 'benedict-chat-thinking))
    (benedict-chat--render-block item header face)
    (benedict-chat--prepare-thinking-block item)))

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
  (setq benedict-chat--streaming-message nil))

(defun benedict-chat--streaming-merge-metadata (payload)
  "Return merged metadata for PAYLOAD and existing streaming state."
  (let* ((state benedict-chat--streaming-message)
         (current (plist-get state :metadata))
         (provider (or (plist-get payload :provider)
                       (plist-get current :provider)))
         (model (or (plist-get payload :model)
                    (plist-get current :model))))
    (benedict-chat--metadata :provider provider :model model)))

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

(defun benedict-chat--decorate-message (item)
  "Apply markdown-lite decorations for ITEM."
  (let* ((start-marker (plist-get item :content-start))
         (end-marker (plist-get item :content-end))
         (start (and start-marker (marker-position start-marker)))
         (end (and end-marker (marker-position end-marker))))
    (when (and start end (> end start))
      (benedict-chat--clear-block-buttons start-marker end-marker)
      (remove-text-properties start end
                              '(face nil font-lock-face nil benedict-chat-code-language nil))
      (benedict-chat--apply-code-fences start end))))

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
        (let ((prompt (benedict-chat--usage-value usage "prompt_tokens"))
              (completion (benedict-chat--usage-value usage "completion_tokens")))
          (when (or prompt completion)
            (push (format "tokens p:%s / c:%s"
                          (or prompt "?")
                          (or completion "?"))
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
    (goto-char start)
    (let ((case-fold-search nil))
      (while (re-search-forward "^```\\([^ \n\r]*\\)?[ \t]*\n" end t)
        (let* ((language (match-string 1))
               (body-start (point))
               (closing (save-excursion
                          (when (re-search-forward "^```[ \t]*$" end t)
                            (match-beginning 0)))))
          (if (and closing (> closing body-start))
              (let ((button-pos (save-excursion
                                  (goto-char closing)
                                  (forward-line 1)
                                  (point))))
                (benedict-chat--decorate-code-block body-start closing language button-pos)
                (goto-char button-pos))
            (benedict-chat--decorate-code-block body-start end language nil)
            (goto-char end)))))))

(defun benedict-chat--decorate-code-block (body-start body-end language insertion-point)
  "Apply faces to BODY-START → BODY-END and insert buttons near INSERTION-POINT.
LANGUAGE is the identifier included in the fence (may be nil)."
  (when (> body-end body-start)
    (let* ((lang (and language (string-trim language)))
           (target (list :start (copy-marker body-start t)
                         :end (copy-marker body-end nil)
                         :language lang)))
      (add-text-properties body-start body-end
                           (list 'face 'benedict-chat-code-block
                                 'font-lock-face 'benedict-chat-code-block
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

(defun benedict-chat--handle-provider-delta (payload)
  "Handle streaming PAYLOAD updates from the provider."
  (let ((details (benedict-chat--collect-delta-reasoning-details payload)))
    (when details
      (let ((metadata (benedict-chat--metadata
                       :provider (plist-get payload :provider)
                       :model (plist-get payload :model))))
        (dolist (detail details)
          (benedict-chat--display-thinking-detail detail metadata t)))))
  (when-let ((text (benedict-chat--collect-delta-message-content payload)))
    (unless (string-empty-p text)
      (benedict-chat--streaming-append-text payload text))))

(defun benedict-chat--handle-provider-success (result)
  "Handle RESULT returned from the provider."
  (setq benedict-chat--pending-request nil)
  (setq benedict-chat--active-request-id nil)
  (let* ((message (plist-get result :message))
         (stream-state benedict-chat--streaming-message)
         (stream-text (and stream-state (plist-get stream-state :content)))
         (role (benedict-chat--normalize-role (plist-get message :role)))
         (content (or (plist-get message :content) ""))
         (thinking (benedict-chat--normalize-thinking-payload
                    (plist-get result :thinking)))
         (provider (plist-get result :provider))
         (model (plist-get result :model))
         (latency (plist-get result :latency))
         (usage (plist-get result :usage))
         (empty-response (or (plist-get result :empty-response)
                             (string-blank-p content)))
         (display-content (if empty-response
                              (benedict-chat--empty-response-text thinking)
                            content))
         (metadata (benedict-chat--metadata
                    :provider provider
                    :model model
                    :latency latency
                    :usage usage
                    :empty-response empty-response)))
    (when (and stream-text
               (not (string-empty-p stream-text))
               (string-blank-p (or (plist-get message :content) "")))
      (setq content stream-text)
      (setq empty-response nil)
      (setq display-content content)
      (setq metadata (benedict-chat--metadata
                      :provider provider
                      :model model
                      :latency latency
                      :usage usage
                      :empty-response empty-response)))
    (when thinking
      (let ((thinking-metadata (plist-put (copy-sequence metadata) :thinking t)))
        (dolist (detail thinking)
          (benedict-chat--display-thinking-detail detail thinking-metadata nil))))
    (if (plist-get benedict-chat--streaming-message :message)
        (benedict-chat--complete-streaming-message metadata content display-content empty-response)
      (let ((record (list :role role
                          :content content
                          :time (current-time)
                          :metadata metadata
                          :display-content (and empty-response display-content))))
        (benedict-chat--record-message record)))
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
  (setq benedict-chat--active-request-id nil)
  (let ((content (benedict-chat--format-error-content payload))
        (metadata (benedict-chat--metadata
                   :provider (or (plist-get payload :provider) benedict-provider)
                   :error t
                   :status (plist-get payload :status)
                   :code (plist-get payload :code)
                   :retryable (plist-get payload :retryable))))
    (unless (benedict-chat--fail-streaming-message content metadata)
      (benedict-chat--record-message
       (list :role 'assistant :content content :time (current-time) :metadata metadata)))
    (message "Benedict provider error: %s" content)))

(defun benedict-chat--start-dispatch (request &optional retry)
  "Send REQUEST through the provider. RETRY notes when replaying."
  (let ((buffer (current-buffer))
        (provider-label (benedict-chat--provider-label)))
    (setq benedict-chat--request-seq (1+ benedict-chat--request-seq))
    (setq benedict-chat--active-request-id benedict-chat--request-seq)
    (setq benedict-chat--thinking-temp-counter 0)
    (benedict-chat--streaming-reset)
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
               :on-complete (lambda (result)
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer
                                  (benedict-chat--handle-provider-success result))))
               :on-error (lambda (payload)
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (benedict-chat--handle-provider-error payload))))
               :on-delta (lambda (payload)
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (benedict-chat--handle-provider-delta payload)))) ))
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
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (visual-line-mode 1)
  (setq-local benedict-chat--messages nil)
  (setq-local benedict-chat--items nil)
  (setq-local benedict-chat--item-counter 0)
  (setq-local benedict-chat--thinking-items (make-hash-table :test 'equal))
  (setq-local benedict-chat--active-request-id nil)
  (setq-local benedict-chat--request-seq 0)
  (setq-local benedict-chat--thinking-temp-counter 0)
  (setq-local benedict-chat--pending-request nil)
  (setq-local benedict-chat--last-dispatch nil)
  (benedict-chat--ensure-thinking-invisibility)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize
             (format "Benedict Chat — provider: %s (non-streaming)\n"
                     (benedict-chat--provider-label))
             'face 'benedict-chat-system))
    (insert (propertize
             "Commands: C-c C-s send · g r retry-last · w copy-last · code blocks expose Copy/Apply buttons\n"
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
