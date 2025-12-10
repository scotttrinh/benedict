;;; benedict-chat-render.el --- Rendering logic for Benedict chat -*- lexical-binding: t; -*-

;; Author: Benedict maintainers

;;; Commentary:
;; Handles buffer insertion and face application for Benedict chat.
;; Manages the 'benedict-region-kind text property to distinguish
;; message bodies from metadata and UI elements.

;;; Code:

(require 'subr-x)
(require 'benedict-chat-fold)

(defgroup benedict-chat-faces nil
  "Faces for Benedict Chat."
  :group 'benedict)

(defface benedict-chat-role
  '((t :weight bold :inherit font-lock-keyword-face))
  "Face for role labels (User, Assistant, System)."
  :group 'benedict-chat-faces)

(defface benedict-chat-header
  '((t :inherit shadow))
  "Face for message headers/metadata."
  :group 'benedict-chat-faces)

(defface benedict-chat-system
  '((t :inherit italic))
  "Face for system messages."
  :group 'benedict-chat-faces)

(defface benedict-chat-tool-header
  '((t :inherit benedict-chat-header))
  "Face for tool call headers."
  :group 'benedict-chat-faces)

(defface benedict-chat-tool-success
  '((t :inherit success))
  "Face for successful tool calls."
  :group 'benedict-chat-faces)

(defface benedict-chat-tool-error
  '((t :inherit error))
  "Face for failed tool calls."
  :group 'benedict-chat-faces)

(defface benedict-chat-tool-running
  '((t :inherit warning))
  "Face for running tool calls."
  :group 'benedict-chat-faces)

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

(defun benedict-chat--render-block (item header face)
  "Render a block ITEM with HEADER and FACE at point.
Sets markers in ITEM for :start, :header-start, :header-end,
:content-start, :content-end, and :end.
Uses the 'Sentinel Pattern': regions exclude the trailing newline to allow
insert-after markers to work without swallowing subsequent blocks."
  (let ((start (point-marker))
        (inhibit-read-only t))
    (set-marker-insertion-type start t)
    (insert (propertize (concat (make-string 60 ?-) "\n") 'benedict-region-kind 'header))
    
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
    
    (insert (propertize (concat (make-string 60 ?-) "\n") 'benedict-region-kind 'header))
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
    (_ 'benedict-chat-header)))

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
                 (t name))))
    (format "%s %s %s" arrow icon label)))

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
                                   'face 'button
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
       (insert (propertize header-text
                           'face 'benedict-chat-tool-header
                           'benedict-region-kind 'header
                           'benedict-chat-item item
                           'keymap benedict-chat-tool-toggle-map
                           'mouse-face 'highlight))
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
               (start-type (marker-insertion-type start))
               (body-start (plist-get item :content-start))
               (body-end (plist-get item :content-end))
               (body-start-pos (and body-start (marker-position body-start)))
               (body-end-pos (and body-end (marker-position body-end))))
           ;; Keep start anchored at the beginning while we rewrite.
           (set-marker-insertion-type start nil)
           ;; Delete header text and its sentinel newline
           (delete-region start (1+ end))
           (goto-char start)
            ;; Re-insert header with same structure as render
            (insert (propertize text
                               'face 'benedict-chat-tool-header
                               'benedict-region-kind 'header
                               'benedict-chat-item item
                               'keymap benedict-chat-tool-toggle-map
                               'mouse-face 'highlight))
            ;; Re-render action buttons on same line
            (benedict-chat--render-tool-actions item)
            ;; Sentinel newline
            (insert (propertize "\n" 'benedict-region-kind 'header))
            ;; Restore start marker insertion type and update header-end
            (set-marker-insertion-type start start-type)
            (plist-put item :header-end (copy-marker (1- (point)) t))
            ;; Restore body markers to their original positions
            (when (and body-start-pos body-start)
              (set-marker body-start body-start-pos))
            (when (and body-end-pos body-end)
              (set-marker body-end body-end-pos)))))))

(defun benedict-chat--update-tool-visibility (item)
  "Update body visibility for ITEM."
  (benedict-chat-fold-set-tool-folded item (plist-get item :tool-folded)))

(defun benedict-chat--write-message-item-content (item content)
  "Replace ITEM's content region with CONTENT.
Does NOT append a newline, as the region is expected to be followed by a sentinel."
  (let ((start (plist-get item :content-start))
        (end (plist-get item :content-end)))
    (when (and start end (marker-position start) (marker-position end))
      (with-current-buffer (marker-buffer start)
        (let ((inhibit-read-only t)
              (start-type (marker-insertion-type start))
              (start-pos (min (marker-position start) (marker-position end)))
              (end-pos (max (marker-position start) (marker-position end))))
          (save-excursion
            ;; Lock start marker so it stays before the inserted content
            (set-marker-insertion-type start nil)
            (goto-char start-pos)
            (delete-region start-pos end-pos)
            (insert (propertize (or content "") 'benedict-region-kind 'tool-ui))
            (set-marker end (point))
            ;; Restore start marker type (usually t)
            (set-marker-insertion-type start start-type)))))))

(provide 'benedict-chat-render)
;;; benedict-chat-render.el ends here
