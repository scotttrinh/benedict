;;; benedict-chat-render.el --- Rendering logic for Benedict chat -*- lexical-binding: t; -*-

;; Author: Benedict maintainers

;;; Commentary:
;; Handles buffer insertion and face application for Benedict chat.
;; Manages the 'benedict-region-kind text property to distinguish
;; message bodies from metadata and UI elements.

;;; Code:

(require 'subr-x)
(require 'json)
(require 'benedict)
(require 'benedict-chat-fold)

(defvar benedict-chat-tool-toggle-map
   (let ((map (make-sparse-keymap)))
     (define-key map [mouse-1] #'benedict-chat-tool-toggle)
     (define-key map (kbd "RET") #'benedict-chat-tool-toggle)
     map)
   "Keymap for tool toggle buttons.")

(defvar benedict-chat-tool-action-map
   (let ((map (make-sparse-keymap)))
     (define-key map [mouse-1] #'benedict-chat-tool-action-invoke)
     (define-key map (kbd "RET") #'benedict-chat-tool-action-invoke)
     map)
   "Keymap for tool action buttons.")

(defun benedict-chat-tool-toggle (&optional event)
   "Toggle tool details visibility at point. EVENT is the mouse event that triggered the command."
   (interactive (list last-nonmenu-event))
   (when event (goto-char (posn-point (event-start event))))
   (let* ((item (get-text-property (point) 'benedict-chat-item)))
     (when item
       (let ((folded (plist-get item :tool-folded)))
         (plist-put item :tool-folded (not folded))
         (benedict-chat--update-tool-header item)
         (benedict-chat--update-tool-visibility item)))))

(defun benedict-chat-tool-action-invoke (&optional event)
   "Invoke the action handler at point. EVENT is the mouse event that triggered the command."
   (interactive (list last-nonmenu-event))
   (when event (goto-char (posn-point (event-start event))))
   (let* ((handler (get-text-property (point) 'benedict-chat-action)))
     (when (and handler (functionp handler))
       (funcall handler))))

(defun benedict-chat--insert-message (message)
  "Insert MESSAGE (plist) into chat buffer at point.
MESSAGE must contain :role and :content."
  (let ((role (plist-get message :role))
        (content (plist-get message :content))
        (inhibit-read-only t))
    (goto-char (point-max))
    ;; Insert role tag as a non-body region
    (insert (propertize (format "[%s]\n" (upcase (symbol-name role)))
                        'face 'benedict-chat-role
                        'benedict-region-kind 'header))
    ;; Insert content (markdown-mode will fontify body regions)
    (insert (propertize (or content "")
                        'face nil
                        'benedict-region-kind 'body))
    (insert (propertize "\n" 'benedict-region-kind 'header))))

(defun benedict-chat--render-message-item (item header content)
  "Render chat message ITEM with HEADER and CONTENT at point.
Sets markers in ITEM for :start, :header-start, :header-end,
:content-start, :content-end, and :end.

HEADER should be a single line string without a trailing newline.
CONTENT may include newlines and will be marked as a body region."
  (let ((start (point-marker))
        (inhibit-read-only t))
    ;; Header
    (let ((header-start (point-marker)))
      (let ((header-beg (point)))
        (insert header)
        (add-text-properties header-beg (point)
                             (list 'benedict-region-kind 'header
                                   'benedict-chat-item item)))
      (insert (propertize "\n" 'benedict-region-kind 'header))
      (set-marker-insertion-type header-start t)
      (plist-put item :header-start header-start)
      (plist-put item :header-end (copy-marker (1- (point)) t)))

    ;; Body
    (let ((content-start (point-marker)))
      (insert (propertize (or content "")
                          'face nil
                          'benedict-region-kind 'body))
      (insert (propertize "\n" 'benedict-region-kind 'header))
      (set-marker-insertion-type content-start nil)
      (plist-put item :content-start content-start)
      ;; End marker sits before the sentinel newline, enabling stream appends.
      (plist-put item :content-end (copy-marker (1- (point)) t)))

    (set-marker-insertion-type start t)
    (plist-put item :start start)
    (plist-put item :end (copy-marker (1- (point)) t))))

(defun benedict-chat--update-message-header (item header)
  "Refresh ITEM header text to HEADER."
  (let ((start (plist-get item :header-start))
        (end (plist-get item :header-end)))
    (when (and start end (marker-position start))
      (with-current-buffer (marker-buffer start)
        (let* ((inhibit-read-only t)
               (start-type (marker-insertion-type start)))
          (set-marker-insertion-type start nil)
          ;; Delete header text, leaving its sentinel newline in place so body
          ;; markers (which start after the newline) don't collapse onto START.
          (delete-region start end)
          (goto-char start)
          (let ((header-beg (point)))
            (insert header)
            (add-text-properties header-beg (point)
                                 (list 'benedict-region-kind 'header
                                       'benedict-chat-item item)))
          ;; `end' already points at the existing sentinel newline and will move
          ;; forward as we insert the new header.
          (set-marker-insertion-type start start-type))))))

(defun benedict-chat-render--set-item-content (item content &optional kind)
  "Replace ITEM content region with CONTENT and refontify when appropriate.

KIND is the value to use for the `benedict-region-kind' text property.
When KIND is `body', also runs `font-lock-flush' and `font-lock-ensure' on
the affected region."
  (let* ((kind (or kind 'body))
         (start (plist-get item :content-start))
         (end (plist-get item :content-end)))
    (when (and start end (marker-position start) (marker-position end))
      (with-current-buffer (marker-buffer start)
        (let* ((inhibit-read-only t)
               (start-type (marker-insertion-type start))
               (start-pos (min (marker-position start) (marker-position end)))
               (end-pos (max (marker-position start) (marker-position end))))
          (save-excursion
            (set-marker-insertion-type start nil)
            (goto-char start-pos)
            (delete-region start-pos end-pos)
            (insert (propertize (or content "")
                                'face nil
                                'benedict-region-kind kind))
            (set-marker end (point))
            (set-marker-insertion-type start start-type)
            (when (eq kind 'body)
              (font-lock-flush start end)
              (font-lock-ensure start end))))))))

(defun benedict-chat-render--append-item-content (item text &optional kind)
  "Append TEXT to ITEM content region and refontify when appropriate.

KIND is the value to use for the `benedict-region-kind' text property on
the inserted text.  When KIND is `body', also runs `font-lock-flush' and
`font-lock-ensure' on the affected region."
  (let* ((kind (or kind 'body))
         (end (plist-get item :content-end)))
    (when (and (stringp text)
               (not (string-empty-p text))
               end
               (marker-position end))
      (with-current-buffer (marker-buffer end)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (marker-position end))
            (insert (propertize text
                                'face nil
                                'benedict-region-kind kind))
            (set-marker end (point))
            (when (eq kind 'body)
              (when-let ((start (plist-get item :content-start)))
                (when (and (markerp start)
                           (marker-buffer start)
                           (marker-position start))
                  (font-lock-flush start end)
                  (font-lock-ensure start end))))))))))

(defun benedict-chat--write-message-item-body (item content)
  "Replace ITEM body region with CONTENT.

Deprecated internal helper. Prefer `benedict-chat-render--set-item-content'."
  (benedict-chat-render--set-item-content item content 'body))

(defun benedict-chat--render-block (item header face)
  "Render a block ITEM with HEADER and FACE at point.
Sets markers in ITEM for :start, :header-start, :header-end,
:content-start, :content-end, and :end.
Uses the 'Sentinel Pattern': regions exclude the trailing newline to allow
insert-after markers to work without swallowing subsequent blocks."
  (let ((start (point-marker))
        (inhibit-read-only t))
    (set-marker-insertion-type start t)
    (insert (propertize (concat (make-string 60 ?-) "\n")
                        'face 'benedict-chat-block-divider
                        'benedict-region-kind 'header))
    
    (let ((header-start (point-marker)))
      (set-marker-insertion-type header-start t)
      (insert (propertize header 'face face 'benedict-region-kind 'header))
      ;; Sentinel newline for header
      (insert (propertize "\n" 'face face 'benedict-region-kind 'header))
      (plist-put item :header-start header-start)
      ;; End marker excludes sentinel
      (plist-put item :header-end (copy-marker (1- (point)) t)))
    
    (let ((content-start (point-marker)))
      (set-marker-insertion-type content-start t)
      (insert (propertize (or (plist-get item :content) "") 'benedict-region-kind 'tool-ui))
      ;; Sentinel newline for content
      (insert (propertize "\n" 'benedict-region-kind 'tool-ui))
      (plist-put item :content-start content-start)
      ;; End marker excludes sentinel
      (plist-put item :content-end (copy-marker (1- (point)) t)))
    
    (insert (propertize (concat (make-string 60 ?-) "\n")
                        'face 'benedict-chat-block-divider
                        'benedict-region-kind 'header))
    (plist-put item :start start)
    ;; End marker at the very end (excluding potential future insertions?)
    ;; For the block itself, we might want to include the footer.
    ;; But to prevent stacking, we should ideally have a sentinel after the block too.
    ;; Currently blocks are separated by the chat loop?
    ;; Let's make the block end marker exclude the final newline of the footer.
    (plist-put item :end (copy-marker (1- (point)) t))))

(defun benedict-chat--tool-status-icon (status)
  "Return icon string for STATUS."
  (pcase status
    ('success "✓")
    ('failure "✗")
    ('running "◒")
    (_ "?")))

(defun benedict-chat--tool-status-face (status)
  "Return face for STATUS."
  (pcase status
    ('success 'benedict-chat-tool-success)
    ('failure 'benedict-chat-tool-error)
    ('running 'benedict-chat-tool-running)
    (_ 'benedict-chat-tool-indicator)))

(defun benedict-chat--format-tool-header (item)
  "Return formatted header string for tool ITEM."
  (let* ((metadata (plist-get item :metadata))
         (status (plist-get metadata :status))
         (call (plist-get item :tool-call))
         (name (or (plist-get call :name) "unknown"))
         (ui (plist-get item :ui))
         (ui-header (and ui (plist-get ui :header)))
         (folded (plist-get item :tool-folded))
         (icon (benedict-chat--tool-status-icon status))
         (arrow (if folded "▶" "▼"))
         (label (cond
                 ((and ui-header (not (string-empty-p ui-header)))
                  ui-header)
                 ((eq status 'running)
                  (let ((args (plist-get call :arguments)))
                    (if args
                        (format "%s %s..." name (json-encode args))
                      (format "%s..." name))))
                 (t name)))
         (label-str (format "%s" label)))
    (concat (propertize arrow 'face 'benedict-chat-tool-indicator)
            (propertize " " 'face 'benedict-chat-tool-indicator)
            (propertize icon 'face (benedict-chat--tool-status-face status))
            (propertize " " 'face 'benedict-chat-tool-indicator)
            (propertize label-str 'face 'benedict-chat-tool-label))))

(defun benedict-chat--render-tool-actions (item)
   "Insert action buttons for ITEM's tool call.
 Buttons are inserted after the header text, separated by spaces."
   (let ((ui (plist-get item :ui))
         (inhibit-read-only t))
     (when ui
       (let ((actions (plist-get ui :actions)))
         (when actions
           (dolist (action actions)
             (insert " ")
             (let ((label (plist-get action :label))
                   (handler (plist-get action :handler)))
               (insert-text-button label
                                   'face 'benedict-chat-button
                                   'mouse-face 'highlight
                                   'keymap benedict-chat-tool-action-map
                                   'benedict-chat-action handler
                                   'follow-link t))))))))

(defun benedict-chat--render-tool-item (item)
   "Render tool ITEM at point.
 Uses the 'Sentinel Pattern': regions exclude the trailing newline to allow
 insert-after markers to work without swallowing subsequent blocks."
  (let ((start (point-marker))
        (inhibit-read-only t))
    ;; start marker stays type nil during insertion, will be set to t at end
     
     ;; Header
     (let ((header-start (point-marker))
           (header-text (benedict-chat--format-tool-header item)))
       (let ((header-beg (point)))
         (insert header-text)
         (add-text-properties header-beg (point)
                              (list 'benedict-region-kind 'header
                                    'benedict-chat-item item
                                    'keymap benedict-chat-tool-toggle-map
                                    'mouse-face 'highlight)))
       ;; Render action buttons on the same line as header
       (benedict-chat--render-tool-actions item)
       ;; Sentinel newline
       (insert (propertize "\n" 'benedict-region-kind 'header))

       (set-marker-insertion-type header-start t)
       (plist-put item :header-start header-start)
       
       ;; Header end excludes sentinel
       (plist-put item :header-end (copy-marker (1- (point)) t)))
     
     ;; Body
    (let ((content-start (point-marker)))
      (set-marker-insertion-type content-start nil)
       (insert (propertize (or (plist-get item :content) "")
                           'benedict-region-kind 'tool-ui))
       ;; Sentinel newline
       (insert (propertize "\n" 'benedict-region-kind 'tool-ui))
       
       (plist-put item :content-start content-start)
       
       ;; Content end excludes sentinel
       (plist-put item :content-end (copy-marker (1- (point)) t)))
     
     (set-marker-insertion-type start t)
     (plist-put item :start start)
     
     ;; Item end excludes sentinel (which is the content's sentinel here)
     (plist-put item :end (copy-marker (1- (point)) t))
     
     ;; Initial visibility
     (benedict-chat-fold-ensure-tool item)
     (benedict-chat--update-tool-visibility item)))

(defun benedict-chat--update-tool-header (item)
   "Refresh the header text for ITEM."
  (let ((start (plist-get item :header-start))
        (end (plist-get item :header-end)))
    (when (and start end (marker-position start))
      (with-current-buffer (marker-buffer start)
        (let* ((inhibit-read-only t)
               (text (benedict-chat--format-tool-header item))
               (start-type (marker-insertion-type start)))
          (save-excursion
            ;; Keep start anchored at the beginning while we rewrite.
            (set-marker-insertion-type start nil)
            ;; Delete header text only; keep the sentinel newline so the tool
            ;; body markers (which start after the newline) remain stable.
            (delete-region start end)
            (goto-char start)
            ;; Re-insert header with same structure as render.
            (let ((header-beg (point)))
              (insert text)
              (add-text-properties header-beg (point)
                                   (list 'benedict-region-kind 'header
                                         'benedict-chat-item item
                                         'keymap benedict-chat-tool-toggle-map
                                         'mouse-face 'highlight)))
            ;; Re-render action buttons on same line.
            (benedict-chat--render-tool-actions item)
            (set-marker-insertion-type start start-type)))))))

(defun benedict-chat--update-tool-visibility (item)
  "Update body visibility for ITEM."
  (benedict-chat-fold-set-tool-folded item (plist-get item :tool-folded)))

(defun benedict-chat--write-message-item-content (item content)
  "Replace ITEM's content region with CONTENT.
Does NOT append a newline, as the region is expected to be followed by a sentinel."
  (benedict-chat-render--set-item-content item content 'tool-ui))

(provide 'benedict-chat-render)
;;; benedict-chat-render.el ends here
