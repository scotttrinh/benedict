;;; benedict-chat-fold.el --- Chat folding adapter  -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Adapts benedict-fold-core to chat buffers. Declares fold specs for
;; thinking blocks (overlay backend) and tool details (text-property
;; backend) and provides helpers to keep item plists in sync.

;;; Code:

(require 'cl-lib)
(require 'benedict-fold-core)
(require 'isearch)

(defvar-local benedict-chat-fold--isearch-open-folds nil
  "Fold ranges temporarily opened during isearch.")

(defconst benedict-chat-fold-thinking-spec
  (benedict-fold-core-define-spec 'benedict-chat-thinking
    :alias 'benedict-chat-thinking
    :priority 0
    :front-sticky t
    :rear-sticky nil
    :backend benedict-fold-core-overlay-backend)
  "Fold spec for thinking blocks (overlay-backed).")

(defconst benedict-chat-fold-tool-spec
  (benedict-fold-core-define-spec 'benedict-tool-details
    :alias 'benedict-tool-details
    :priority 0
    :backend benedict-fold-core-text-property-backend)
  "Fold spec for tool call detail bodies (text-property-backed).")

(defun benedict-chat-fold--filter-buffer-substring (beg end delete)
  "Return substring from BEG to END without text properties.
If DELETE is non-nil, delete the region after extracting it."
  (let ((text (if delete
                  (delete-and-extract-region beg end)
                (buffer-substring beg end))))
    (set-text-properties 0 (length text) nil text)
    text))

(defun benedict-chat-fold--isearch-fold-alias-p (alias)
  "Return non-nil when ALIAS is a chat fold alias."
  (memq alias (list (benedict-fold-core-spec-alias benedict-chat-fold-thinking-spec)
                    (benedict-fold-core-spec-alias benedict-chat-fold-tool-spec))))

(defun benedict-chat-fold--isearch-normalize-alias (value)
  "Normalize VALUE from an `invisible' property into a fold alias, if known."
  (let ((candidate (cond
                    ((symbolp value) value)
                    ((consp value) (car value))
                    ((listp value) (cl-find-if #'symbolp value)))))
    (when (benedict-chat-fold--isearch-fold-alias-p candidate)
      candidate)))

(defun benedict-chat-fold--isearch-alias-at (pos)
  "Return fold alias at POS, preferring text properties over overlays."
  (or (benedict-chat-fold--isearch-normalize-alias
       (get-text-property pos 'invisible))
      (cl-loop for ov in (overlays-at pos)
               do (when-let ((start (overlay-get ov 'benedict-chat-content-start))
                             (end (overlay-get ov 'benedict-chat-content-end))
                             (s-pos (marker-position start))
                             (e-pos (marker-position end)))
                    (move-overlay ov s-pos e-pos))
               for spec = (overlay-get ov 'benedict-fold-core-spec)
               for alias = (and spec (benedict-fold-core-spec-alias spec))
               when (benedict-chat-fold--isearch-fold-alias-p alias)
               return alias)))

(defun benedict-chat-fold--isearch-text-range (pos alias)
  "Return cons of region bounds around POS hidden by ALIAS text properties."
  (when (eq (benedict-chat-fold--isearch-normalize-alias
             (get-text-property pos 'invisible))
            alias)
    (let ((start pos)
          (end pos))
      (while (and (> start (point-min))
                  (eq alias (benedict-chat-fold--isearch-normalize-alias
                             (get-text-property (1- start) 'invisible))))
        (setq start (1- start)))
      (while (and (< end (point-max))
                  (eq alias (benedict-chat-fold--isearch-normalize-alias
                             (get-text-property end 'invisible))))
        (setq end (1+ end)))
      (cons start end))))

(defun benedict-chat-fold--isearch-entry-contains-p (entry pos)
  "Return non-nil when ENTRY already covers POS."
  (pcase (plist-get entry :kind)
    ('overlay (let ((ov (plist-get entry :overlay)))
                (and (overlayp ov)
                     (overlay-buffer ov)
                     (>= pos (overlay-start ov))
                     (< pos (overlay-end ov)))))
    ('text (let ((start (plist-get entry :start))
                 (end (plist-get entry :end)))
             (and start end (>= pos start) (< pos end))))))

(defun benedict-chat-fold--isearch-restore-entry (entry)
  "Re-hide ENTRY that was opened for isearch."
  (pcase (plist-get entry :kind)
    ('overlay
     (let ((ov (plist-get entry :overlay))
           (alias (plist-get entry :alias)))
       (when (and (overlayp ov) (overlay-buffer ov))
         (overlay-put ov 'invisible alias))))
    ('text
     (let ((start (plist-get entry :start))
           (end (plist-get entry :end))
           (alias (plist-get entry :alias)))
       (when (and start end)
         (put-text-property start end 'invisible alias))))))

(defun benedict-chat-fold--isearch-close-others (pos)
  "Close opened folds that do not cover POS."
  (let ((inhibit-read-only t))
    (setq benedict-chat-fold--isearch-open-folds
          (cl-loop for entry in benedict-chat-fold--isearch-open-folds
                   if (and pos (benedict-chat-fold--isearch-entry-contains-p entry pos))
                   collect entry
                   else do (benedict-chat-fold--isearch-restore-entry entry)))))

(defun benedict-chat-fold--isearch-open-at (pos)
  "Reveal the hidden fold covering POS, if any."
  (when-let* ((alias (benedict-chat-fold--isearch-alias-at pos)))
    (let ((inhibit-read-only t))
      ;; Prefer overlays (thinking) when present.
      (let* ((overlays (cl-remove-if-not
                        (lambda (ov)
                          (and (overlay-get ov 'benedict-fold-core)
                               (eq (benedict-fold-core-spec-alias
                                    (overlay-get ov 'benedict-fold-core-spec))
                                   alias)))
                        (overlays-at pos)))
             (_realigned (mapc (lambda (ov)
                                 (when-let ((start (overlay-get ov 'benedict-chat-content-start))
                                            (end (overlay-get ov 'benedict-chat-content-end))
                                            (s-pos (marker-position start))
                                            (e-pos (marker-position end)))
                                   (move-overlay ov s-pos e-pos)))
                               overlays))
             (existing (cl-find-if (lambda (entry)
                                     (and (eq (plist-get entry :kind) 'overlay)
                                          (benedict-chat-fold--isearch-entry-contains-p entry pos)))
                                   benedict-chat-fold--isearch-open-folds)))
        (unless existing
          (dolist (ov overlays)
            (push (list :kind 'overlay :overlay ov :alias alias)
                  benedict-chat-fold--isearch-open-folds)
            (overlay-put ov 'invisible nil))))
      ;; If no overlays matched (or alias is text-property-backed), fall back to text props.
      (unless (cl-some (lambda (entry)
                         (and (eq (plist-get entry :kind) 'overlay)
                              (benedict-chat-fold--isearch-entry-contains-p entry pos)))
                       benedict-chat-fold--isearch-open-folds)
        (when-let* ((range (benedict-chat-fold--isearch-text-range pos alias))
                    (start (car range))
                    (end (cdr range)))
          (unless (cl-find-if (lambda (entry)
                                (and (eq (plist-get entry :kind) 'text)
                                     (benedict-chat-fold--isearch-entry-contains-p entry pos)))
                              benedict-chat-fold--isearch-open-folds)
            (push (list :kind 'text :start start :end end :alias alias)
                  benedict-chat-fold--isearch-open-folds))
          (when noninteractive
            (message "benedict-chat-fold isearch open text alias=%S start=%s end=%s before=%S"
                     alias start end (get-text-property start 'invisible)))
          (remove-text-properties start end '(invisible nil front-sticky nil rear-nonsticky nil)))))))

(defun benedict-chat-fold--isearch-update ()
  "Reveal only the fold covering the current isearch match."
  (when isearch-success
    (let ((pos (or isearch-other-end (point))))
      (when noninteractive
        (message "benedict-chat-fold isearch-update pos=%s alias=%S"
                 pos (benedict-chat-fold--isearch-alias-at pos)))
      (benedict-chat-fold--isearch-close-others pos)
      (benedict-chat-fold--isearch-open-at pos))))

(defun benedict-chat-fold--isearch-open ()
  "Prepare isearch hooks to reveal only the matching fold."
  (setq benedict-chat-fold--isearch-open-folds nil)
  (add-hook 'isearch-update-post-hook #'benedict-chat-fold--isearch-update nil t))

(defun benedict-chat-fold--isearch-close ()
  "Restore folds opened during isearch."
  (benedict-chat-fold--isearch-close-others nil)
  (setq benedict-chat-fold--isearch-open-folds nil)
  (remove-hook 'isearch-update-post-hook #'benedict-chat-fold--isearch-update t))

(defun benedict-chat-fold-init-buffer (&optional backend)
  "Initialize folding defaults for the current chat buffer.
Optional BACKEND overrides the default overlay backend."
  (benedict-fold-core-set-backend (or backend benedict-fold-core-overlay-backend))
  (benedict-fold-core-ensure-invisibility-entry benedict-chat-fold-thinking-spec)
  (benedict-fold-core-ensure-invisibility-entry benedict-chat-fold-tool-spec)
  (setq-local filter-buffer-substring-function
              #'benedict-chat-fold--filter-buffer-substring)
  (setq-local search-invisible t)
  (add-hook 'isearch-mode-hook #'benedict-chat-fold--isearch-open nil t)
  (add-hook 'isearch-mode-end-hook #'benedict-chat-fold--isearch-close nil t))

(defun benedict-chat-fold--region (item)
  "Return (START . END) markers for ITEM content."
  (let ((start (plist-get item :content-start))
        (end (plist-get item :content-end)))
    (when (and start end (marker-position start) (marker-position end))
      (cons start end))))

(defun benedict-chat-fold--apply-marker-stickiness (item spec)
  "Make ITEM's content markers match SPEC's stickiness."
  (when-let* ((range (benedict-chat-fold--region item))
              (start (car range))
              (end (cdr range)))
    (set-marker-insertion-type start
                               (not (benedict-fold-core-spec-front-sticky spec)))
    (set-marker-insertion-type end
                               (benedict-fold-core-spec-rear-sticky spec))))

(defun benedict-chat-fold--ensure (item key spec)
  "Ensure ITEM has a fold stored at KEY using SPEC.
Returns the fold object or nil if boundaries are missing."
  (when-let* ((range (benedict-chat-fold--region item))
              (raw-start (marker-position (car range)))
              (raw-end (marker-position (cdr range))))
    (let* ((start (min raw-start raw-end))
           (end (max raw-start raw-end))
           (fold (plist-get item key)))
      (if (and fold (benedict-fold-core-fold-p fold))
          (progn
            (benedict-fold-core-resize fold start end)
            (setq fold fold))
        (let ((created (benedict-fold-core-fold-region start end spec)))
          (plist-put item key created)
          (setq fold created)))
      (when (and fold
                 (eq (benedict-fold-core-spec-backend spec)
                     benedict-fold-core-overlay-backend))
        (let ((handle (benedict-fold-core-fold-handle fold)))
          (when (overlayp handle)
            (overlay-put handle 'benedict-chat-content-start (car range))
            (overlay-put handle 'benedict-chat-content-end (cdr range)))))
      fold)))

(defun benedict-chat-fold-ensure-thinking (item)
  "Ensure ITEM has a thinking fold."
  (benedict-chat-fold--ensure item :thinking-fold benedict-chat-fold-thinking-spec))

(defun benedict-chat-fold-ensure-tool (item)
  "Ensure ITEM has a tool fold."
  (benedict-chat-fold--ensure item :tool-fold benedict-chat-fold-tool-spec))

(defun benedict-chat-fold-set-thinking-folded (item folded)
  "Set ITEM thinking fold to FOLDED."
  (plist-put item :thinking-folded folded)
  (benedict-chat-fold--apply-marker-stickiness item benedict-chat-fold-thinking-spec)
  (when-let ((fold (benedict-chat-fold-ensure-thinking item)))
    (benedict-fold-core-set-folded fold folded)))

(defun benedict-chat-fold-set-tool-folded (item folded)
  "Set ITEM tool body fold to FOLDED."
  (plist-put item :tool-folded folded)
  (when-let ((range (benedict-chat-fold--region item)))
    (let* ((raw-start (marker-position (car range)))
           (raw-end (marker-position (cdr range))))
      (when (> raw-start raw-end)
        (set-marker (car range) raw-end)
        (set-marker (cdr range) raw-start))))
  (let ((alias (benedict-fold-core-spec-alias benedict-chat-fold-tool-spec)))
    (benedict-fold-core-ensure-invisibility-entry benedict-chat-fold-tool-spec)
    (when-let ((fold (benedict-chat-fold-ensure-tool item)))
      (benedict-fold-core-set-folded fold folded))
    (when-let* ((range (benedict-chat-fold--region item))
                (start (marker-position (car range)))
                (end (marker-position (cdr range))))
      (let ((inhibit-read-only t))
        (if folded
            (add-text-properties start end `(invisible ,alias))
          (remove-text-properties start end `(invisible ,alias)))))))

(defun benedict-chat-fold-update-thinking (item)
  "Refresh boundaries for ITEM thinking fold."
  (when-let ((fold (plist-get item :thinking-fold)))
    (when-let* ((range (benedict-chat-fold--region item))
                (start (marker-position (car range)))
                (end (marker-position (cdr range))))
      (when (and start end (>= (point) start) (> (point) end))
        (set-marker (cdr range) (point))))
    (benedict-chat-fold--apply-marker-stickiness item benedict-chat-fold-thinking-spec)
    (benedict-chat-fold-ensure-thinking item)
    (benedict-fold-core-set-folded fold (plist-get item :thinking-folded))))

(defun benedict-chat-fold-update-tool (item)
  "Refresh boundaries for ITEM tool fold."
  (when-let ((fold (plist-get item :tool-fold)))
    (benedict-chat-fold-ensure-tool item)
    (benedict-fold-core-set-folded fold (plist-get item :tool-folded))))

(provide 'benedict-chat-fold)
;;; benedict-chat-fold.el ends here
