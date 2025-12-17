;;; benedict-chat-mode.el --- Major mode for Benedict chat -*- lexical-binding: t; -*-

;; Author: Benedict maintainers

;;; Commentary:
;; Dedicated major mode for Benedict chat buffers.
;; Inherits from special-mode (read-only).
;; Uses markdown-mode font-lock machinery for message bodies.

;;; Code:

(require 'markdown-mode)
(require 'benedict-chat-render)

(defvar benedict-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    ;; Bindings will be moved here from benedict-chat.el
    map)
  "Keymap for `benedict-chat-mode'.")

(defun benedict-chat--extend-region-body-only ()
  "Restrict font-lock to only body regions.
Non-body regions are marked with the `benedict-region-kind' text property.
This function is a member of `font-lock-extend-region-functions', so it
takes no arguments and modifies `font-lock-beg' and `font-lock-end' dynamically."
  (save-excursion
    (save-match-data
      (let ((new-start font-lock-beg)
            (new-end font-lock-end)
            (changed nil))
        ;; If we're not in a body region, don't fontify
        (unless (eq (get-text-property new-start 'benedict-region-kind) 'body)
          (setq new-start (point-max)
                new-end (point-max)
                changed t))

        ;; Move START backward to the beginning of the current body run
        (when (eq (get-text-property new-start 'benedict-region-kind) 'body)
          (goto-char new-start)
          (while (and (> (point) (point-min))
                      (eq (get-text-property (1- (point)) 'benedict-region-kind)
                          'body))
            (backward-char))
          (when (< (point) new-start)
            (setq new-start (point))
            (setq changed t)))

        ;; Move END forward to the end of the current body run
        (when (eq (get-text-property new-end 'benedict-region-kind) 'body)
          (goto-char new-end)
          (while (and (< (point) (point-max))
                      (eq (get-text-property (point) 'benedict-region-kind)
                          'body))
            (forward-char))
          (when (> (point) new-end)
            (setq new-end (point))
            (setq changed t)))

        (when changed
          (setq font-lock-beg new-start
                font-lock-end new-end)
          t)))))

(defun benedict-chat--enable-markdown-fontification-in-body ()
  "Enable `markdown-mode` fontification only in regions marked as `'body."
  ;; Borrow markdown-mode's keywords and syntax propertize function
  (setq-local font-lock-defaults `(markdown-mode-font-lock-keywords
                                   nil nil nil nil
                                   (font-lock-multiline . t)
                                   (font-lock-extend-region-functions . (benedict-chat--extend-region-body-only))))

  (setq-local syntax-propertize-function #'markdown-syntax-propertize)

  ;; Enable native code block fontification
  (setq-local markdown-fontify-code-blocks-natively t))

(defun benedict-chat--setup-common-buffer ()
  "Apply shared buffer settings for Benedict chat modes."
  (setq buffer-read-only t)
  (setq-local word-wrap t)
  (setq-local truncate-lines nil)
  (setq-local benedict-region-kind-property 'benedict-region-kind)
  (benedict-chat--enable-markdown-fontification-in-body))

(define-derived-mode benedict-chat-mode special-mode "Benedict-Chat"
  "Major mode for Benedict chat buffers."
  (benedict-chat--setup-common-buffer))

(provide 'benedict-chat-mode)
;;; benedict-chat-mode.el ends here
