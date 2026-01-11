;;; benedict-chat-thinking.el --- Thinking block UI for Benedict chat -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Thinking block rendering, fold state, and streaming helpers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict-chat-blocks)
(require 'benedict-chat-render)
(require 'benedict-chat-sections)
(require 'benedict-session)

(declare-function benedict-chat--make-item "benedict-chat")
(declare-function benedict-chat--track-item "benedict-chat")
(declare-function benedict-chat--current-assistant-section "benedict-chat")
(declare-function benedict-chat--maybe-insert-item-gap "benedict-chat")

(defvar benedict-chat--thinking-items)
(defvar benedict-chat--thinking-temp-counter)
(defvar benedict-chat--request-seq)
(defvar benedict-chat--session)
(defvar benedict-chat--has-rendered-block)

(defun benedict-chat-thinking--item-p (item)
  "Return non-nil when ITEM represents a thinking block."
  (eq (plist-get item :kind) 'thinking))

(defun benedict-chat-thinking--header-badges (item)
  "Return badge strings for thinking ITEM."
  (let ((label (or (plist-get item :thinking-label) "Thinking")))
    (list (benedict-chat-render--badge label 'benedict-chat-thinking))))

(defun benedict-chat-thinking--header-text (item)
  "Return formatted header text for thinking ITEM."
  (benedict-chat-blocks--header-text
   (plist-get item :thinking-folded)
   (benedict-chat-thinking--header-badges item)))

(defun benedict-chat-thinking--header-props ()
  "Return text properties for thinking headers."
  (list 'face 'benedict-chat-header))

(defun benedict-chat-thinking--render-item (buffer item)
  "Render thinking ITEM in BUFFER."
  (with-current-buffer buffer
    (unless (plist-member item :thinking-folded)
      (plist-put item :thinking-folded t))
    (let ((start (point-marker))
          (inhibit-read-only t))
      (benedict-chat-blocks--render-header
       item
       (benedict-chat-thinking--header-badges item)
       nil
       nil
       (benedict-chat-thinking--header-props))
      (let ((content-start (point-marker)))
        (set-marker-insertion-type content-start nil)
        (let ((body-beg (point)))
          (insert (propertize (or (plist-get item :content) "")
                              'benedict-region-kind 'thinking
                              'benedict-chat-item item
                              'face 'benedict-chat-thinking))
          (insert (propertize "\n" 'benedict-region-kind 'thinking))
          (add-text-properties body-beg (1- (point))
                               '(benedict-region-kind thinking)))
        (plist-put item :content-start content-start)
        (plist-put item :content-end (copy-marker (1- (point)) t)))
      (set-marker-insertion-type start t)
      (plist-put item :start start)
      (plist-put item :end (copy-marker (1- (point)) t))
      (benedict-chat-thinking--update-visibility item))))

(defun benedict-chat-thinking--update-header (item)
  "Refresh the header text for thinking ITEM."
  (benedict-chat-blocks--update-header
   item
   #'benedict-chat-thinking--header-text
   nil
   (benedict-chat-thinking--header-props)))

(defun benedict-chat-thinking--update-visibility (item)
  "Apply ITEM thinking folded state using magit-section."
  (benedict-chat-blocks--set-folded item (plist-get item :thinking-folded) :thinking-folded))

(defun benedict-chat-thinking--set-folded (item folded)
  "Set ITEM's folding state to FOLDED."
  (benedict-chat-blocks--set-folded item folded :thinking-folded)
  (benedict-chat-thinking--update-header item))

(defun benedict-chat-thinking--record-block (buffer content metadata &rest properties)
  "Record a thinking block with CONTENT and METADATA in BUFFER.
PROPERTIES describe additional block hints. This does not affect provider
message history."
  (with-current-buffer buffer
    (let* ((item (apply #'benedict-chat--make-item
                        'thinking
                        :metadata metadata
                        :content (or content "")
                        properties)))
      (unless (plist-member item :thinking-folded)
        (plist-put item :thinking-folded t))
      (benedict-chat--track-item item)
      (let ((parent (benedict-chat--current-assistant-section)))
        (when parent
          (plist-put item :parent-section parent))
        (let ((inhibit-read-only t))
          (if parent
              (let ((end-pos (benedict-chat-sections--end-position parent)))
                (benedict-chat--maybe-insert-item-gap buffer end-pos)
                (benedict-chat-sections--with-parent parent item
                  (benedict-chat-thinking--render-item buffer item)))
            (goto-char (point-max))
            (benedict-chat--maybe-insert-item-gap buffer)
            (benedict-chat-sections--with item
              (benedict-chat-thinking--render-item buffer item)))))
      (setq benedict-chat--has-rendered-block t)
      item)))

;; -------------------------------------------------------------------
;; Thinking detail helpers

(defun benedict-chat-thinking--normalize-seq (value)
  "Return VALUE coerced into a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((vectorp value) (append value nil))
   (t (list value))))

(defun benedict-chat-thinking--alist-to-plist (alist)
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

(defun benedict-chat-thinking--current-request-id ()
  "Return the current request ID from session, or request-seq as fallback."
  (or (and benedict-chat--session
           (plist-get (benedict-session-inflight benedict-chat--session) :request-id))
      benedict-chat--request-seq
      0))

(defun benedict-chat-thinking--next-temp-id ()
  "Return a generated identifier for thinking blocks."
  (setq benedict-chat--thinking-temp-counter (1+ benedict-chat--thinking-temp-counter))
  (format "benedict-thinking-%s-%d"
          (benedict-chat-thinking--current-request-id)
          benedict-chat--thinking-temp-counter))

(defun benedict-chat-thinking--stream-id (&optional payload)
  "Return a stable identifier for streaming thinking PAYLOAD."
  (let ((request (or (plist-get payload :message-id)
                     (benedict-chat-thinking--current-request-id))))
    (format "benedict-thinking-%s-stream" request)))

(defun benedict-chat-thinking--register-item (id item)
  "Register ITEM under identifier ID so streaming state can update later."
  (when id
    (unless (hash-table-p benedict-chat--thinking-items)
      (setq benedict-chat--thinking-items (make-hash-table :test 'equal)))
    (puthash id item benedict-chat--thinking-items)))

(defun benedict-chat-thinking--lookup-item (id)
  "Return thinking item registered under ID, or nil."
  (when (and id (hash-table-p benedict-chat--thinking-items))
    (gethash id benedict-chat--thinking-items)))

(defun benedict-chat-thinking--label-from-type (type)
  "Return a user-facing label for reasoning TYPE."
  (let ((type-name (and type (downcase (format "%s" type)))))
    (cond
     ((member type-name '("reasoning.summary" "summary")) "Summary")
     ((member type-name '("reasoning.encrypted" "encrypted")) "Encrypted")
     (t nil))))

(defun benedict-chat-thinking--detail-text (detail)
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

(defun benedict-chat-thinking--normalize-entry (entry)
  "Normalize a single thinking ENTRY into a plist."
  (cond
   ((null entry) nil)
   ((stringp entry)
    (list :id (benedict-chat-thinking--next-temp-id)
          :type "reasoning.text"
          :text entry
          :format "anthropic-claude-v1"))
   ((listp entry)
    (let* ((plist (if (and (consp (car entry))
                           (not (keywordp (caar entry))))
                      (benedict-chat-thinking--alist-to-plist entry)
                    entry))
           (result (copy-sequence plist)))
      (plist-put result :type (or (plist-get result :type) "reasoning.text"))
      (plist-put result :id (or (plist-get result :id)
                                (benedict-chat-thinking--next-temp-id)))
      (plist-put result :format (or (plist-get result :format)
                                    "anthropic-claude-v1"))
      (when-let ((chunks (plist-get result :chunks)))
        (plist-put result :text (mapconcat #'identity (benedict-chat-thinking--normalize-seq chunks) "")))
      result))
   (t nil)))

(defun benedict-chat-thinking--normalize-payload (thinking)
  "Normalize THINKING payloads into a list of detail plists."
  (cond
   ((null thinking) nil)
   ((stringp thinking)
    (list (benedict-chat-thinking--normalize-entry thinking)))
   ((vectorp thinking)
    (benedict-chat-thinking--normalize-payload (append thinking nil)))
   ((and (listp thinking)
         (cl-every #'stringp thinking))
    (list (benedict-chat-thinking--normalize-entry
           (string-join thinking "\n\n"))))
   ((listp thinking)
    (delq nil (mapcar #'benedict-chat-thinking--normalize-entry thinking)))
   (t nil)))

(defun benedict-chat-thinking--ensure-item (buffer detail metadata)
  "Return the thinking item associated with DETAIL and METADATA in BUFFER."
  (let* ((id (or (plist-get detail :id)
                 (benedict-chat-thinking--next-temp-id)))
         (item (benedict-chat-thinking--lookup-item id)))
    (unless item
      (let ((label (benedict-chat-thinking--label-from-type (plist-get detail :type)))
            (meta (plist-put (copy-sequence metadata) :thinking t)))
        (setq item (benedict-chat-thinking--record-block buffer "" meta
                                                         :thinking-id id
                                                         :thinking-label label
                                                         :thinking-type (plist-get detail :type)))
        (benedict-chat-thinking--register-item id item)))
    item))

(defun benedict-chat-thinking--write-content (buffer item text replace)
  "Insert TEXT into ITEM's content region in BUFFER.
When REPLACE is non-nil, replace the entire block contents."
  (with-current-buffer buffer
    (let ((payload (or text "")))
      (cond
       (replace
        (benedict-chat-render--set-item-content item payload 'thinking))
       ((and payload (not (string-empty-p payload)))
        (benedict-chat-render--append-item-content item payload 'thinking)))
      (when-let ((start (plist-get item :content-start))
                 (end (plist-get item :content-end)))
        (when (and (markerp start) (markerp end)
                   (marker-buffer start) (marker-buffer end)
                   (marker-position start) (marker-position end))
          (with-current-buffer (marker-buffer start)
            (let ((inhibit-read-only t)
                  (start-pos (marker-position start))
                  (end-pos (marker-position end)))
              (add-text-properties start-pos end-pos
                                   '(face benedict-chat-thinking))
              (plist-put item :content
                         (buffer-substring-no-properties start-pos end-pos))))))
      (benedict-chat-thinking--update-visibility item))))

(defun benedict-chat-thinking--append-content (buffer item text)
  "Append TEXT to ITEM's content in BUFFER."
  (when (and text (not (string-empty-p text)))
    (benedict-chat-thinking--write-content buffer item text nil)))

(defun benedict-chat-thinking--replace-content (buffer item text)
  "Replace ITEM content with TEXT in BUFFER."
  (benedict-chat-thinking--write-content buffer item text t))

(defun benedict-chat-thinking--display-detail (buffer detail metadata &optional append)
  "Render DETAIL using METADATA in BUFFER. APPEND when streaming, replace otherwise."
  (let* ((normalized (benedict-chat-thinking--normalize-entry detail))
         (item (and normalized
                    (benedict-chat-thinking--ensure-item buffer normalized metadata)))
         (text (and normalized (benedict-chat-thinking--detail-text normalized))))
    (when item
      (if append
          (benedict-chat-thinking--append-content buffer item text)
        (benedict-chat-thinking--replace-content buffer item text)))))

(defun benedict-chat-thinking--collect-delta-details (payload)
  "Extract reasoning details from streaming PAYLOAD."
  (let (details)
    (dolist (choice (benedict-chat-thinking--normalize-seq (plist-get payload :choices)))
      (let ((delta (plist-get choice :delta)))
        (dolist (detail (benedict-chat-thinking--normalize-seq
                         (and delta (plist-get delta :reasoning_details))))
          (when-let ((normalized (benedict-chat-thinking--normalize-entry detail)))
            (push normalized details)))))
    (nreverse details)))

(defun benedict-chat-thinking--delta-choice-text (choice)
  "Return flattened user-visible text for CHOICE delta."
  (or (plist-get choice :text)
      (let ((delta (plist-get choice :delta)))
        (when delta
          (benedict-chat-thinking--delta-text-from-delta delta)))))

(defun benedict-chat-thinking--delta-text-from-delta (delta)
  "Extract string content from DELTA plist."
  (cond
   ((plist-member delta :content)
    (let ((content (plist-get delta :content)))
      (cond
       ((stringp content) content)
       (content
        (mapconcat #'benedict-chat-thinking--delta-content-entry-text
                   (benedict-chat-thinking--normalize-seq content)
                   "")))))
   ((plist-member delta :text)
    (plist-get delta :text))
   (t nil)))

(defun benedict-chat-thinking--delta-content-entry-text (entry)
  "Return the visible text stored within ENTRY."
  (cond
   ((stringp entry) entry)
   ((listp entry)
    (or (plist-get entry :text)
        (plist-get entry :content)
        ""))
   (t "")))

(defun benedict-chat-thinking--collect-delta-message-content (payload)
  "Return concatenated assistant message text contained in PAYLOAD."
  (let (chunks)
    (dolist (choice (benedict-chat-thinking--normalize-seq (plist-get payload :choices)))
      (let ((text (benedict-chat-thinking--delta-choice-text choice)))
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

(provide 'benedict-chat-thinking)
;;; benedict-chat-thinking.el ends here
