;;; benedict-chat-blocks.el --- Collapsible block abstraction -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Shared rendering helpers for collapsible tool/thinking blocks.

;;; Code:

(require 'cl-lib)
(require 'benedict-chat-sections)
(require 'benedict-chat-render)

(defun benedict-chat-blocks--fold-indicator (folded)
  "Return fold indicator arrow for FOLDED state."
  (if folded "▶" "▼"))

(defun benedict-chat-blocks--fold-key (item)
  "Return the folding state key for ITEM."
  (cond
   ((plist-member item :folded) :folded)
   ((plist-member item :tool-folded) :tool-folded)
   ((plist-member item :thinking-folded) :thinking-folded)
   (t :folded)))

(defun benedict-chat-blocks--folded-p (item &optional key)
  "Return ITEM fold state using KEY (or infer from ITEM)."
  (when item
    (plist-get item (or key (benedict-chat-blocks--fold-key item)))))

(defun benedict-chat-blocks--normalize-badges (badge-text badge-face)
  "Return a list of badge strings from BADGE-TEXT and BADGE-FACE."
  (cond
   ((null badge-text) nil)
   ((listp badge-text) badge-text)
   ((and (stringp badge-text) (null badge-face)) (list badge-text))
   (t (list (benedict-chat-render--badge badge-text badge-face)))))

(defun benedict-chat-blocks--header-text (folded badges &optional indicator-face)
  "Return header string for FOLDED state and BADGES list."
  (let ((indicator (propertize (benedict-chat-blocks--fold-indicator folded)
                               'face (or indicator-face
                                         'benedict-chat-tool-indicator))))
    (benedict-chat-render--join-badges (cons indicator badges))))

(defun benedict-chat-blocks--insert-actions (actions &optional keymap)
  "Insert ACTIONS buttons using optional KEYMAP."
  (when (and actions (listp actions))
    (when-let ((align (benedict-chat-render--header-align-space
                       (benedict-chat-render--actions-width actions) 2)))
      (insert align))
    (let ((first t)
          (action-map (or keymap
                          (and (boundp 'benedict-chat-tool-action-map)
                               benedict-chat-tool-action-map))))
      (dolist (action actions)
        (let ((label (plist-get action :label))
              (handler (plist-get action :handler)))
          (when label
            (unless first
              (insert (benedict-chat-render--badge-separator)))
            (setq first nil)
            (insert-text-button (format "%s" label)
                                'face 'benedict-chat-button
                                'mouse-face 'highlight
                                'keymap action-map
                                'benedict-chat-action handler
                                'follow-link t)))))))

(defun benedict-chat-blocks--render-header (item badge-text badge-face &optional actions props)
  "Render collapsible header for ITEM using BADGE-TEXT and BADGE-FACE.
ACTIONS optionally inserts buttons after the header.  PROPS are appended
to the default header text properties."
  (let* ((folded (benedict-chat-blocks--folded-p item))
         (badges (benedict-chat-blocks--normalize-badges badge-text badge-face))
         (header (benedict-chat-blocks--header-text folded badges)))
    (let ((header-start (point-marker)))
      (let ((header-beg (point)))
        (insert header)
        (add-text-properties header-beg (point)
                             (append (list 'benedict-region-kind 'header
                                           'benedict-chat-item item)
                                     props)))
      (benedict-chat-blocks--insert-actions actions)
      (insert (propertize "\n" 'benedict-region-kind 'header))
      (set-marker-insertion-type header-start t)
      (plist-put item :header-start header-start)
      (plist-put item :header-end (copy-marker (1- (point)) t))
      (plist-put item :header header))))

(defun benedict-chat-blocks--update-header (item header-fn &optional actions props)
  "Update ITEM header using HEADER-FN to generate header text.
ACTIONS optionally inserts buttons after the header.  PROPS are appended
to the default header text properties."
  (let ((start (plist-get item :header-start))
        (end (plist-get item :header-end)))
    (when (and start end (marker-position start))
      (let ((buf (marker-buffer start)))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (let* ((inhibit-read-only t)
                   (text (funcall header-fn item))
                   (start-type (marker-insertion-type start)))
              (save-excursion
                (set-marker-insertion-type start nil)
                (delete-region start end)
                (goto-char start)
                (let ((header-beg (point)))
                  (insert text)
                  (add-text-properties header-beg (point)
                                       (append (list 'benedict-region-kind 'header
                                                     'benedict-chat-item item)
                                               props)))
                (benedict-chat-blocks--insert-actions actions)
                (set-marker-insertion-type start start-type)
                (plist-put item :header text))))))))))

(defun benedict-chat-blocks--set-folded (item folded &optional key)
  "Set ITEM fold state to FOLDED using KEY (or infer from ITEM)."
  (let ((key (or key (benedict-chat-blocks--fold-key item))))
    (when item
      (plist-put item key folded))
    (when-let ((section (plist-get item :section)))
      (benedict-chat-sections--set-folded section folded))))

(defun benedict-chat-blocks--toggle (item &optional key)
  "Toggle ITEM fold state using KEY (or infer from ITEM)."
  (let ((folded (benedict-chat-blocks--folded-p item key)))
    (benedict-chat-blocks--set-folded item (not folded) key)))

(provide 'benedict-chat-blocks)
;;; benedict-chat-blocks.el ends here
