;;; benedict-chat-tool-ui.el --- Tool block UI for Benedict chat -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Tool block rendering and UI helpers for Benedict chat buffers.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'benedict-chat-blocks)
(require 'benedict-chat-render)
(require 'benedict-chat-sections)

(declare-function benedict-chat--make-item "benedict-chat")
(declare-function benedict-chat--track-item "benedict-chat")
(declare-function benedict-chat-nav--current-assistant-section "benedict-chat-nav")
(declare-function benedict-chat-nav--last-assistant-item "benedict-chat-nav")
(declare-function benedict-chat--maybe-insert-item-gap "benedict-chat")
(declare-function benedict-chat--metadata "benedict-chat")
(declare-function benedict-chat-nav--tool-item-p "benedict-chat-nav")

(defvar benedict-chat--items)
(defvar benedict-chat--has-rendered-block)

(defvar benedict-chat-tool-toggle-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'benedict-chat-tool-ui-toggle)
    (define-key map (kbd "RET") #'benedict-chat-tool-ui-toggle)
    map)
  "Keymap for tool toggle buttons.")

(defvar benedict-chat-tool-action-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'benedict-chat-tool-ui-action-invoke)
    (define-key map (kbd "RET") #'benedict-chat-tool-ui-action-invoke)
    map)
  "Keymap for tool action buttons.")

(defun benedict-chat-tool-ui-toggle (&optional event)
  "Toggle tool details visibility at point. EVENT is the mouse event that triggered the command."
  (interactive (list last-nonmenu-event))
  (when event (goto-char (posn-point (event-start event))))
  (let ((item (get-text-property (point) 'benedict-chat-item)))
    (when item
      (benedict-chat-blocks--toggle item :tool-folded)
      (benedict-chat-tool-ui--update-header item))))

(defun benedict-chat-tool-ui-action-invoke (&optional event)
  "Invoke the action handler at point. EVENT is the mouse event that triggered the command."
  (interactive (list last-nonmenu-event))
  (when event (goto-char (posn-point (event-start event))))
  (let ((handler (get-text-property (point) 'benedict-chat-action)))
    (when (and handler (functionp handler))
      (funcall handler))))

(defalias 'benedict-chat-tool-toggle #'benedict-chat-tool-ui-toggle)
(defalias 'benedict-chat-tool-action-invoke #'benedict-chat-tool-ui-action-invoke)

(defun benedict-chat-tool-ui--name-string (name)
  "Return a human-readable string for tool NAME."
  (cond
   ((symbolp name) (symbol-name name))
   ((stringp name) name)
   (t (format "%s" name))))

(defun benedict-chat-tool-ui--value-string (value)
  "Return VALUE formatted for tool argument/result display."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (with-temp-buffer
        (let ((print-level nil)
              (print-length nil))
          (prin1 value (current-buffer))
          (string-trim-right (buffer-string)))))))

(defun benedict-chat-tool-ui--arguments-string (arguments)
  "Format tool ARGUMENTS plist for display."
  (if arguments
      (benedict-chat-tool-ui--value-string arguments)
    "None"))

(defconst benedict-chat-tool-ui--error-arg-preview-limit 400
  "Maximum length of the argument preview captured for tool errors.")

(defconst benedict-chat-tool-ui--error-data-preview-limit 400
  "Maximum length of the error data preview captured for tool errors.")

(defconst benedict-chat-tool-ui--error-backtrace-limit 1600
  "Maximum length of the backtrace string captured for tool errors.")

(defun benedict-chat-tool-ui--truncate-string (text limit)
  "Return TEXT truncated to LIMIT characters with an explicit marker."
  (if (and text limit (> (length text) limit))
      (concat (substring text 0 limit) "... [truncated]")
    text))

(defun benedict-chat-tool-ui--error-stringify (value limit)
  "Return VALUE printed safely and truncated to LIMIT characters."
  (when value
    (with-temp-buffer
      (let ((print-circle t)
            (print-level 6)
            (print-length 20))
        (condition-case err
            (prin1 value (current-buffer))
          (error
           (insert (format "#<unprintable: %s>" (error-message-string err))))))
      (benedict-chat-tool-ui--truncate-string
       (string-trim-right (buffer-string)) limit))))

(defun benedict-chat-tool-ui--error-backtrace ()
  "Return a trimmed backtrace string for a tool error handler."
  (condition-case _err
      (let ((text (with-output-to-string (backtrace))))
        (benedict-chat-tool-ui--truncate-string
         (string-trim-right text)
         benedict-chat-tool-ui--error-backtrace-limit))
    (error nil)))

(defun benedict-chat-tool-ui--error-details (tool-id call arguments err)
  "Return a plist describing ERR for TOOL-ID CALL with ARGUMENTS."
  (let* ((symbol (car-safe err))
         (data (and (consp err) (cdr err)))
         (message (error-message-string err)))
    (delq nil
          (list :type "tool_error"
                :tool (benedict-chat-tool-ui--name-string tool-id)
                :call-id (when (plist-get call :id)
                           (format "%s" (plist-get call :id)))
                :message message
                :symbol (when (symbolp symbol) (symbol-name symbol))
                :data (benedict-chat-tool-ui--error-stringify
                       data benedict-chat-tool-ui--error-data-preview-limit)
                :arguments (benedict-chat-tool-ui--error-stringify
                            arguments benedict-chat-tool-ui--error-arg-preview-limit)
                :backtrace (benedict-chat-tool-ui--error-backtrace)))))

(defun benedict-chat-tool-ui--error-json (details)
  "Return DETAILS plist encoded as compact JSON."
  (let (alist)
    (while details
      (let ((key (pop details))
            (val (pop details)))
        (when (and val (keywordp key))
          (push (cons (substring (symbol-name key) 1) val) alist))))
    (json-encode (nreverse alist))))

(defun benedict-chat-tool-ui--error-summary (tool-id details)
  "Return a concise summary string for a tool failure."
  (format "Tool %s failed: %s"
          (benedict-chat-tool-ui--name-string tool-id)
          (or (plist-get details :message) "unknown error")))

(defun benedict-chat-tool-ui--error-ui-body (summary details)
  "Return a human-friendly UI body for SUMMARY and DETAILS."
  (let ((symbol (or (plist-get details :symbol) "unknown"))
        (args (plist-get details :arguments))
        (data (plist-get details :data))
        (backtrace (plist-get details :backtrace))
        (json (benedict-chat-tool-ui--error-json details)))
    (string-join
     (delq nil
           (list summary
                 ""
                 (format "Symbol: %s" symbol)
                 (when args (format "Arguments: %s" args))
                 (when data (format "Data: %s" data))
                 (when backtrace (format "Backtrace:\n%s" backtrace))
                 (format "JSON payload sent to model:\n%s" json)))
     "\n")))

(defun benedict-chat-tool-ui--status-label (status)
  "Return STATUS normalized into a user-facing string."
  (if status
      (capitalize (replace-regexp-in-string "-" " " (format "%s" status)))
    ""))

(defun benedict-chat-tool-ui--default-header (call)
  "Return a generic header label for CALL."
  (format "Tool — %s" (benedict-chat-tool-ui--name-string (plist-get call :name))))

(defun benedict-chat-tool-ui--normalize-state (state)
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

(defun benedict-chat-tool-ui--stringify-body (value fallback)
  "Return VALUE formatted as a string for tool UI, or FALLBACK."
  (cond
   ((and (stringp value) (not (string-empty-p value))) value)
   ((null value) (or fallback ""))
   ((listp value) (string-join (mapcar #'benedict-chat-tool-ui--value-string value) "\n"))
   (t (benedict-chat-tool-ui--value-string value))))

(defun benedict-chat-tool-ui--format-diff-body (diff &optional lang)
  "Format DIFF string for display with syntax highlighting.
LANG is optional language hint (defaults to 'diff').
Returns the formatted diff wrapped in a markdown code block."
  (let* ((language (or lang "diff"))
         (formatted (concat "```" language "\n" diff "\n```")))
    formatted))

(defun benedict-chat-tool-ui--validate-action (action)
  "Validate that ACTION is a plist with :label and :handler.
Returns the action plist or signals an error."
  (unless (listp action)
    (signal 'wrong-type-argument (list 'listp action)))
  (unless (plist-member action :label)
    (signal 'benedict-error "Action must have :label"))
  (let ((label (plist-get action :label)))
    (unless (stringp label)
      (signal 'wrong-type-argument (list 'stringp label))))
  (unless (plist-member action :handler)
    (signal 'benedict-error "Action must have :handler"))
  (let ((handler (plist-get action :handler)))
    (unless (functionp handler)
      (signal 'wrong-type-argument (list 'functionp handler))))
  action)

(defun benedict-chat-tool-ui--normalize-actions (actions)
  "Normalize ACTIONS list, validating each action.
Returns a list of validated action plists, or nil if ACTIONS is null/empty."
  (when actions
    (unless (listp actions)
      (signal 'wrong-type-argument (list 'listp actions)))
    (let ((result (mapcar #'benedict-chat-tool-ui--validate-action actions)))
      result)))

(defun benedict-chat-tool-ui--normalize-ui (call state ui fallback-body)
  "Return CALL UI plist normalized with STATE and FALLBACK-BODY.
Also validates and normalizes :actions if present."
  (let* ((state (benedict-chat-tool-ui--normalize-state state))
         (normalized (if (listp ui) (copy-sequence ui) nil)))
    (setq normalized (or normalized (list)))
    (if (plist-member normalized :state)
        (setq normalized (plist-put normalized :state
                                    (benedict-chat-tool-ui--normalize-state
                                     (plist-get normalized :state))))
      (setq normalized (plist-put normalized :state state)))
    ;; Removed default header setting to allow render logic to handle it
    (let ((body (if (plist-member normalized :body)
                    (plist-get normalized :body)
                  nil)))
      (setq body (benedict-chat-tool-ui--stringify-body body fallback-body))
      (setq normalized (plist-put normalized :body body)))
    ;; Validate and normalize actions if present
    (when (plist-member normalized :actions)
      (let ((actions (plist-get normalized :actions)))
        (setq normalized (plist-put normalized :actions
                                    (benedict-chat-tool-ui--normalize-actions actions)))))
    normalized))

(defun benedict-chat-tool-ui--body-string (ui)
  "Return the body text for UI."
  (or (plist-get ui :body) ""))

(defun benedict-chat-tool-ui--status-icon (status)
  "Return icon string for STATUS."
  (pcase status
    ('success "✓")
    ('failure "✗")
    ('running "◒")
    (_ "?")))

(defun benedict-chat-tool-ui--status-face (status)
  "Return face for STATUS."
  (pcase status
    ('success 'benedict-chat-tool-success)
    ('failure 'benedict-chat-tool-error)
    ('running 'benedict-chat-tool-running)
    (_ 'benedict-chat-tool-indicator)))

(defun benedict-chat-tool-ui--header-label (item)
  "Return header label for tool ITEM."
  (let* ((metadata (plist-get item :metadata))
         (status (plist-get metadata :status))
         (call (plist-get item :tool-call))
         (name (or (plist-get call :name) "unknown"))
         (ui (plist-get item :ui))
         (ui-header (and ui (plist-get ui :header))))
    (cond
     ((and ui-header (not (string-empty-p ui-header))) ui-header)
     ((eq status 'running)
      (let ((args (plist-get call :arguments)))
        (if args
            (format "%s %s..." name (json-encode args))
          (format "%s..." name))))
     (t name))))

(defun benedict-chat-tool-ui--header-badges (item)
  "Return badge strings for tool ITEM."
  (let* ((metadata (plist-get item :metadata))
         (status (plist-get metadata :status))
         (label (benedict-chat-tool-ui--header-label item))
         (label-str (format "%s" label))
         (status-badge (benedict-chat-render--badge
                        (upcase (or (and status (symbol-name status)) "RUNNING"))
                        (benedict-chat-tool-ui--status-face status)))
         (name-badge (benedict-chat-render--badge label-str 'benedict-chat-tool-label)))
    (list status-badge name-badge)))

(defun benedict-chat-tool-ui--header-text (item)
  "Return formatted header text for tool ITEM."
  (benedict-chat-blocks--header-text
   (plist-get item :tool-folded)
   (benedict-chat-tool-ui--header-badges item)))

(defun benedict-chat-tool-ui--header-props ()
  "Return text properties for tool headers."
  (list 'keymap benedict-chat-tool-toggle-map
        'mouse-face 'highlight))

(defun benedict-chat-tool-ui--render-actions (item)
  "Insert action buttons for ITEM's tool call."
  (let ((ui (plist-get item :ui))
        (inhibit-read-only t))
    (when ui
      (let ((actions (plist-get ui :actions)))
        (benedict-chat-blocks--insert-actions actions benedict-chat-tool-action-map)))))

(defun benedict-chat-tool-ui--render-item (buffer item)
  "Render tool ITEM in BUFFER.
Uses the 'Sentinel Pattern': regions exclude the trailing newline to allow
insert-after markers to work without swallowing subsequent blocks."
  (with-current-buffer buffer
    (unless (plist-member item :tool-folded)
      (plist-put item :tool-folded nil))
    (let ((start (point-marker))
          (inhibit-read-only t))
      (benedict-chat-blocks--render-header
       item
       (benedict-chat-tool-ui--header-badges item)
       nil
       (plist-get (plist-get item :ui) :actions)
       (benedict-chat-tool-ui--header-props))
      ;; Body
      (let ((content-start (point-marker)))
        (set-marker-insertion-type content-start nil)
        (insert (propertize (or (plist-get item :content) "")
                            'benedict-region-kind 'tool-ui))
        ;; Sentinel newline
        (insert (propertize "\n" 'benedict-region-kind 'tool-ui))
        (plist-put item :content-start content-start)
        ;; Content end excludes sentinel
        (plist-put item :content-end (copy-marker (1- (point)) t))
        (set-marker-insertion-type start t)
        (plist-put item :start start)
        ;; Item end excludes sentinel (which is the content's sentinel here)
        (plist-put item :end (copy-marker (1- (point)) t))
        (benedict-chat-tool-ui--update-visibility item)))))

(defun benedict-chat-tool-ui--update-header (item)
  "Refresh the header text for ITEM.
Guards against operations on killed buffers."
  (benedict-chat-blocks--update-header
   item
   #'benedict-chat-tool-ui--header-text
   (plist-get (plist-get item :ui) :actions)
   (benedict-chat-tool-ui--header-props)))

(defun benedict-chat-tool-ui--update-visibility (item)
  "Update body visibility for ITEM using magit-section."
  (benedict-chat-blocks--set-folded item (plist-get item :tool-folded) :tool-folded))

(defun benedict-chat-tool-ui--write-item-content (item content)
  "Replace ITEM's content region with CONTENT.
Does NOT append a newline, as the region is expected to be followed by a sentinel."
  (benedict-chat-render--set-item-content item content 'tool-ui))

(defun benedict-chat-tool-ui--refresh-block (buffer item)
  "Refresh ITEM header and content in BUFFER when UI or metadata change."
  (with-current-buffer buffer
    (let ((ui (plist-get item :ui)))
      (condition-case content-err
          (let ((body-str (benedict-chat-tool-ui--body-string ui)))
            (condition-case write-err
                (benedict-chat-render--set-item-content item body-str 'tool-ui)
              (error
               (error "Failed to write message content: %s" (error-message-string write-err)))))
        (error
         (error "Failed to build tool UI body: %s" (error-message-string content-err))))
      (condition-case nil
          (benedict-chat-tool-ui--update-header item)
        (error))
      (condition-case nil
          (benedict-chat-tool-ui--update-visibility item)
        (error)))))

(defun benedict-chat-tool-ui--call-content (call)
  "Return a formatted string describing CALL arguments."
  (let ((call-id (or (plist-get call :id) "n/a"))
        (args (benedict-chat-tool-ui--arguments-string (plist-get call :arguments))))
    (string-join
     (delq nil
           (list (format "Call ID: %s" call-id)
                 ""
                 "Arguments:"
                 args))
     "\n")))

(defun benedict-chat-tool-ui--result-content (call output)
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

(defun benedict-chat-tool-ui--record-block (buffer call metadata &optional ui)
  "Insert a tool block for CALL using METADATA and optional UI in BUFFER."
  (with-current-buffer buffer
    (let* ((initial-ui (benedict-chat-tool-ui--normalize-ui
                        call
                        (plist-get metadata :status)
                        ui
                        (benedict-chat-tool-ui--call-content call)))
           (item (benedict-chat--make-item 'tool
                                           :tool-call call
                                           :metadata metadata
                                           :ui initial-ui
                                           :content (benedict-chat-tool-ui--body-string initial-ui)
                                           :tool-folded t)))
      (benedict-chat--track-item item)
      (let ((parent (benedict-chat-nav--current-assistant-section)))
        (when parent
          (plist-put item :parent-section parent))
        (let ((inhibit-read-only t))
          (if parent
              (let ((end-pos (benedict-chat-sections--end-position parent)))
                ;; Ensure the parent's end marker advances when we insert the gap and tool block
                (when-let ((parent-end (ignore-errors (oref parent end))))
                  (when (markerp parent-end)
                    (set-marker-insertion-type parent-end t)))
                (benedict-chat--maybe-insert-item-gap buffer end-pos)
                (benedict-chat-sections--with-parent parent item
                  (benedict-chat-tool-ui--render-item buffer item)))
            (goto-char (point-max))
            (benedict-chat--maybe-insert-item-gap buffer)
            (benedict-chat-sections--with item
              (benedict-chat-tool-ui--render-item buffer item)))))
      (setq benedict-chat--has-rendered-block t)
      item)))

(defun benedict-chat-tool-ui--update-block (buffer item metadata ui fallback)
  "Update ITEM with METADATA and UI in BUFFER; FALLBACK is used for missing body text."
  (with-current-buffer buffer
    (let* ((call (plist-get item :tool-call))
           (status (plist-get metadata :status)))
      (condition-case norm-err
          (let ((normalized (benedict-chat-tool-ui--normalize-ui
                             call
                             status
                             ui
                             fallback)))
            (plist-put item :metadata metadata)
            (plist-put item :ui normalized)
            (let ((body-str (benedict-chat-tool-ui--body-string normalized)))
              (plist-put item :content body-str))
            (benedict-chat-tool-ui--refresh-block buffer item))
        (error
         (error "Failed to update tool block: %s" (error-message-string norm-err)))))))

(defun benedict-chat-tool-ui--normalize-id (tool-id)
  "Return TOOL-ID coerced into a symbol."
  (cond
   ((symbolp tool-id) tool-id)
   ((stringp tool-id)
    (let* ((normalized (replace-regexp-in-string "_" "-" (downcase tool-id))))
      (intern normalized)))
   (t (intern (format "%s" tool-id)))))

(defun benedict-chat-tool-ui--call-metadata (tool-id call status base-metadata)
  "Return metadata plist for TOOL-ID CALL with STATUS and BASE-METADATA."
  (apply #'benedict-chat--metadata
         (append (list :tool tool-id
                       :tool-call-id (plist-get call :id)
                       :status status)
                 (when base-metadata
                   (list :provider (plist-get base-metadata :provider)
                         :model (plist-get base-metadata :model))))))

(defun benedict-chat-tool-ui--normalize-output (value)
  "Return VALUE normalized into a plist with :text, :ui, and :raw."
  (let* ((ui (and (listp value)
                  (plist-member value :ui)
                  (plist-get value :ui)))
         (raw (if (and (listp value) (plist-member value :raw))
                  (plist-get value :raw)
                value))
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
           (t (benedict-chat-tool-ui--value-string value)))))
    (setq text (or text "Tool returned no output."))
    (list :text text :ui ui :raw raw)))

(defun benedict-chat-tool-ui--result-history-entry (tool-id call text metadata &optional raw)
  "Return history entry for TOOL-ID CALL result TEXT and METADATA.
RAW, when non-nil, is attached for debugging/forwarding."
  (let ((entry (list :role 'tool
                     :name (benedict-chat-tool-ui--name-string tool-id)
                     :tool-call-id (plist-get call :id)
                     :content text
                     :time (current-time)
                     :metadata metadata)))
    (when raw
      (plist-put entry :raw raw))
    entry))

(defun benedict-chat-tool-ui--find-item (call-id)
  "Return tool item matching CALL-ID, or nil."
  (when call-id
    (cl-find-if
     (lambda (item)
       (and (benedict-chat-nav--tool-item-p item)
            (let* ((call (plist-get item :tool-call))
                   (item-id (plist-get call :id)))
              (and item-id (equal item-id call-id)))))
     benedict-chat--items)))

(provide 'benedict-chat-tool-ui)
;;; benedict-chat-tool-ui.el ends here
