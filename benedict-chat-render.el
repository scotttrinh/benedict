;;; benedict-chat-render.el --- Rendering logic for Benedict chat -*- lexical-binding: t; -*-

;; Author: Benedict maintainers

;;; Commentary:
;; Handles buffer insertion and face application for Benedict chat.
;; Manages the 'benedict-region-kind text property to distinguish
;; message bodies from metadata and UI elements.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict)
(require 'benedict-chat-sections)
(require 'benedict-chat-profiles)
(require 'benedict-chat-status)
(require 'svg-lib nil t)

(defsubst benedict-chat-render--ui-active-p ()
  "Return non-nil when the section-based chat UI is active."
  (derived-mode-p 'benedict-chat-mode))

(defun benedict-chat-render--svg-supported-p ()
  "Return non-nil when SVG badges can be rendered."
  (and (display-graphic-p)
       (featurep 'svg)
       (require 'svg-lib nil t)
       (fboundp 'svg-lib-tag)))

(defun benedict-chat-render--badge-face (face)
  "Return FACE coerced to a single face symbol for badges."
  (cond
   ((and (symbolp face) (facep face)) face)
   ((listp face)
    (or (cl-find-if (lambda (candidate)
                      (and (symbolp candidate) (facep candidate)))
                    face)
        'benedict-chat-header))
   ((facep face) face)
   (t 'benedict-chat-header)))

(defun benedict-chat-render--badge (label face)
  "Return a badge string for LABEL using FACE with fallback."
  (let* ((label (format "%s" label))
         (face (benedict-chat-render--badge-face face))
         (fg (face-foreground face nil 'default))
         (bg (or (face-background face nil 'default)
                 (face-background 'default nil))))
    (if (benedict-chat-render--svg-supported-p)
        (let ((image (svg-lib-tag label nil
                                  :stroke 0
                                  :radius 4
                                  :padding 1.0
                                  :foreground fg
                                  :background bg
                                  :font-family "Menlo")))
          (propertize label 'display image 'face face))
      (propertize (format "[%s]" label) 'face face))))

(defun benedict-chat-render--badge-separator ()
  "Return a standardized spacer string between badges."
  (propertize " " 'face 'benedict-chat-header
              'display '(space :width 1)))

(defun benedict-chat-render--join-badges (parts)
  "Join badge PARTS with consistent spacing and a header face base.
Ignores nil entries in PARTS."
  (let ((parts (delq nil parts)))
    (when parts
      (let ((text (mapconcat #'identity parts
                             (benedict-chat-render--badge-separator))))
        (add-face-text-property 0 (length text)
                                'benedict-chat-header t text)
        text))))

(defun benedict-chat-render--header-align-space (right &optional gap)
  "Return spacing that aligns RIGHT to the right edge with GAP padding.
RIGHT may be a string (measured with `string-width') or a raw width."
  (let* ((gap (or gap 2))
         (width (cond
                 ((numberp right) right)
                 ((stringp right) (string-width right))
                 (t 0))))
    (when (> width 0)
      (propertize " " 'face 'benedict-chat-header
                  'display `(space :align-to (- right ,(+ width gap)))))))

(defun benedict-chat-render--align-header (left right &optional gap)
  "Compose LEFT and RIGHT header strings with optional GAP alignment."
  (cond
   ((and left right)
    (concat left
            (or (benedict-chat-render--header-align-space right gap)
                (benedict-chat-render--badge-separator))
            right))
   (right right)
   (left left)
   (t "")))

(defun benedict-chat-render--actions-width (actions)
  "Return total display width for ACTIONS button labels."
  (let ((width 0)
        (first t))
    (dolist (action actions width)
      (let ((label (format "%s" (plist-get action :label))))
        (unless first
          (setq width (1+ width)))
        (setq width (+ width (string-width label)))
        (setq first nil)))))

(defun benedict-chat--insert-message (message)
  "Insert MESSAGE (plist) into chat buffer at point.
MESSAGE must contain :role and :content."
  (let ((role (plist-get message :role))
        (content (plist-get message :content))
        (inhibit-read-only t))
    ;; Insert role tag as a non-body region
    (let ((badge (benedict-chat-render--badge (upcase (symbol-name role))
                                              'benedict-chat-role)))
      (insert badge)
      (add-text-properties (- (point) (length badge)) (point)
                           '(benedict-region-kind header)))
    (insert (propertize "\n" 'benedict-region-kind 'header))
    ;; Insert content (markdown-mode will fontify body regions)
    (insert (propertize (or content "")
                        'face nil
                        'benedict-region-kind 'body))
    (insert (propertize "\n" 'benedict-region-kind 'header))))

(defun benedict-chat--render-message-item (buffer item header content)
  "Render chat message ITEM with HEADER and CONTENT in BUFFER.
Sets markers in ITEM for :start, :header-start, :header-end,
:content-start, :content-end, and :end.

HEADER should be a single line string without a trailing newline.
CONTENT may include newlines and will be marked as a body region."
  (with-current-buffer buffer
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
      (plist-put item :end (copy-marker (1- (point)) t)))))

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
the inserted text.  When KIND is `body', also runs `font-lock-flush'
and `font-lock-ensure' on the affected region."
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

(defun benedict-chat-render--normalize-role (role)
  "Normalize ROLE into a symbol."
  (cond
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t 'assistant)))

(defun benedict-chat-render--face-for-role (role metadata)
  "Return a face for ROLE considering METADATA."
  (cond
   ((plist-get metadata :error) 'benedict-chat-error)
   ((eq role 'user) 'benedict-chat-user)
   ((eq role 'assistant) 'benedict-chat-assistant)
   (t 'benedict-chat-system)))

(defun benedict-chat-render--message-provider-label (metadata)
  "Return a display label for METADATA :provider."
  (when-let ((provider (plist-get metadata :provider)))
    (cond
     ((stringp provider) provider)
     (t (benedict-chat-profiles--provider-label provider)))))

(defun benedict-chat-render--header-badge (label face)
  "Return a badge for LABEL using FACE with a text fallback."
  (when label
    (let ((label (format "%s" label))
          (face (benedict-chat-render--badge-face face)))
      (benedict-chat-render--badge label face))))

(defun benedict-chat-render--message-header-string (message &optional in-flight)
  "Return the message header line for MESSAGE.
When IN-FLIGHT is non-nil, include a live elapsed hint when possible.

The returned string may carry text properties (notably faces) suitable for
insertion into a chat buffer."
  (let* ((role (benedict-chat-render--normalize-role (plist-get message :role)))
         (metadata (plist-get message :metadata))
         (item (plist-get message :item))
         (tag-face (benedict-chat-render--badge-face
                    (or (benedict-chat-render--face-for-role role metadata)
                        'benedict-chat-role)))
         (role-badge (benedict-chat-render--header-badge (upcase (symbol-name role)) tag-face))
         (provider (plist-get metadata :provider))
         (provider-label (cond
                          ((stringp provider) provider)
                          (provider (benedict-chat-profiles--provider-label provider))))
         (model (and metadata (plist-get metadata :model)))
         (provider-model-label (cond
                                ((and provider-label model) (format "%s:%s" provider-label model))
                                (provider-label provider-label)
                                (model model)))
         (provider-badge (when provider-model-label
                           (benedict-chat-render--header-badge provider-model-label 'benedict-chat-header-model)))
         (usage (and metadata (plist-get metadata :usage)))
         (usage-str (and usage (benedict-chat-status--status-usage-string usage)))
         (latency (and metadata (plist-get metadata :latency)))
         (empty-response (and metadata (plist-get metadata :empty-response)))
         (time-str (cond
                    ((and in-flight item (plist-get item :started-at))
                     (format "%.1fs…" (- (float-time) (plist-get item :started-at))))
                    (latency (format "%.2fs" latency))))
         (state-badge (cond
                       ((plist-get metadata :error)
                        (benedict-chat-render--header-badge "ERROR" 'benedict-chat-header-error))
                       (in-flight
                        (benedict-chat-render--header-badge "STREAMING" 'benedict-chat-header-time))
                       (empty-response
                        (benedict-chat-render--header-badge "EMPTY" 'benedict-chat-header-separator))
                       (t nil)))
         (time-badge (and time-str (benedict-chat-render--header-badge time-str 'benedict-chat-header-time)))
         (usage-badge (and usage-str (benedict-chat-render--header-badge usage-str 'benedict-chat-header-usage)))
         (left (benedict-chat-render--join-badges
                (list role-badge state-badge provider-badge)))
         (right (benedict-chat-render--join-badges
                 (list time-badge usage-badge))))
    (or (benedict-chat-render--align-header left right)
        left
        right
        "")))

(provide 'benedict-chat-render)
;;; benedict-chat-render.el ends here