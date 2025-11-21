;;; benedict-chat-render.el --- Rendering logic for Benedict chat -*- lexical-binding: t; -*-

;; Author: Benedict maintainers

;;; Commentary:
;; Handles buffer insertion and face application for Benedict chat.
;; Manages the 'benedict-region-kind text property to distinguish
;; message bodies from metadata and UI elements.

;;; Code:

(require 'subr-x)

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
:content-start, :content-end, and :end."
  (let ((start (point-marker))
        (inhibit-read-only t))
    (set-marker-insertion-type start t)
    (insert (propertize (concat (make-string 60 ?-) "\n") 'benedict-region-kind 'header))
    
    (let ((header-start (point-marker)))
      (set-marker-insertion-type header-start t)
      (insert (propertize (concat header "\n") 'face face 'benedict-region-kind 'header))
      (plist-put item :header-start header-start)
      (plist-put item :header-end (point-marker)))
    
    (let ((content-start (point-marker)))
      (set-marker-insertion-type content-start t)
      (insert (propertize (or (plist-get item :content) "") 'benedict-region-kind 'tool-ui))
      (insert (propertize "\n" 'benedict-region-kind 'tool-ui))
      (plist-put item :content-start content-start)
      (plist-put item :content-end (point-marker)))
    
    (insert (propertize (concat (make-string 60 ?-) "\n") 'benedict-region-kind 'header))
    (plist-put item :start start)
    (plist-put item :end (point-marker))))

(defun benedict-chat--write-message-item-content (item content)
  "Replace ITEM's content region with CONTENT."
  (let ((start (plist-get item :content-start))
        (end (plist-get item :content-end)))
    (when (and start end (marker-position start) (marker-position end))
      (with-current-buffer (marker-buffer start)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char start)
            (delete-region start end)
            (insert (propertize (or content "") 'benedict-region-kind 'tool-ui))
            (insert (propertize "\n" 'benedict-region-kind 'tool-ui))))))))

(provide 'benedict-chat-render)
;;; benedict-chat-render.el ends here
