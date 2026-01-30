;;; benedict-vui-code-block.el --- Vui code block component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders syntax-highlighted code blocks with a copy action.

;;; Code:

(require 'subr-x)
(require 'vui)
(require 'markdown-mode)
(require 'benedict-vui-text-block)

(defvar benedict-vui-code-block-copy-feedback-timeout 1.5
  "Seconds to display copied feedback in code blocks.")

(defun benedict-vui-code-block--normalize (code)
  "Return CODE as a string, treating nil as empty."
  (cond
   ((stringp code) code)
   ((null code) "")
   (t (format "%s" code))))

(defun benedict-vui-code-block--normalize-language (language)
  "Return LANGUAGE as a lowercase string or nil."
  (cond
   ((stringp language)
    (let ((trimmed (string-trim language)))
      (unless (string-empty-p trimmed)
        (downcase trimmed))))
   ((symbolp language)
    (benedict-vui-code-block--normalize-language (symbol-name language)))
   (t nil)))

(defun benedict-vui-code-block--resolve-mode (language)
  "Return a major mode function for LANGUAGE, or nil if unknown."
  (let ((lang (benedict-vui-code-block--normalize-language language)))
    (cond
     ((null lang) nil)
     ((member lang '("elisp" "emacs-lisp")) #'emacs-lisp-mode)
     ((member lang '("bash" "sh" "shell")) #'sh-mode)
     ((fboundp 'markdown-get-lang-mode)
      (markdown-get-lang-mode lang))
     (t nil))))

(defun benedict-vui-code-block--apply-base-face (text)
  "Return TEXT with a base code face applied when available."
  (if (and (stringp text) (facep 'markdown-code-face))
      (let ((copy (copy-sequence text)))
        (add-face-text-property 0 (length copy) 'markdown-code-face t copy)
        copy)
    text))

(defun benedict-vui-code-block--apply-region-properties (text message-key block-id)
  "Return TEXT with region properties applied for navigation.

MESSAGE-KEY and BLOCK-ID are stored as text properties."
  (if (stringp text)
      (let ((copy (copy-sequence text)))
        (add-text-properties 0 (length copy)
                             (list 'benedict-region-kind 'body
                                   'benedict-message-key message-key
                                   'benedict-block-id block-id)
                             copy)
        copy)
    text))

(defun benedict-vui-code-block--fontify (code language)
  "Return CODE with syntax highlighting for LANGUAGE when possible."
  (let* ((normalized-code (benedict-vui-code-block--normalize code))
         (mode (benedict-vui-code-block--resolve-mode language)))
    (if (string-empty-p normalized-code)
        ""
      (if mode
          (with-temp-buffer
            (insert normalized-code)
            (funcall mode)
            (font-lock-ensure (point-min) (point-max))
            (benedict-vui-code-block--apply-base-face
             (buffer-substring (point-min) (point-max))))
        (benedict-vui-code-block--apply-base-face normalized-code)))))

(defun benedict-vui-code-block--fallback-content (code language)
  "Return CODE wrapped in fenced markdown for LANGUAGE."
  (let ((lang (or (benedict-vui-code-block--normalize-language language) "")))
    (concat "```" lang "\n" (benedict-vui-code-block--normalize code) "\n```")))

(defun benedict-vui-code-block--label (language)
  "Return a display label for LANGUAGE."
  (let ((lang (benedict-vui-code-block--normalize-language language)))
    (if lang (upcase lang) "TEXT")))

(defun benedict-vui-code-block--copy (code on-feedback)
  "Copy CODE and toggle feedback using ON-FEEDBACK callback.

Returns the timer created to clear feedback."
  (let ((normalized-code (benedict-vui-code-block--normalize code)))
    (kill-new normalized-code)
    (funcall on-feedback t)
    (run-at-time benedict-vui-code-block-copy-feedback-timeout nil
                 (lambda () (funcall on-feedback nil)))))

(vui-defcomponent benedict-vui-code-block (props state)
  :state ((copied-feedback nil))
  :render
  (let* ((code (plist-get props :code))
          (language (plist-get props :language))
          (message-key (plist-get props :message-key))
          (block-id (plist-get props :block-id))
          (normalized-code (benedict-vui-code-block--normalize code))
          (normalized-language (benedict-vui-code-block--normalize-language language))
          (timer-ref (vui-use-ref nil))
         (fontified (vui-use-memo (normalized-code normalized-language)
                      (benedict-vui-code-block--fontify normalized-code normalized-language)))
         (copy-label (if (plist-get state :copied-feedback) "Copied!" "Copy"))
         (copy-handler (vui-use-callback (normalized-code)
                         (let ((callback (vui-async-callback (value)
                                           (vui-set-state :copied-feedback value))))
                           (when (car timer-ref)
                             (cancel-timer (car timer-ref))
                             (setcar timer-ref nil))
                           (setcar timer-ref
                                   (benedict-vui-code-block--copy normalized-code callback))))))
    (vui-use-effect ()
      (lambda ()
        (when (car timer-ref)
          (cancel-timer (car timer-ref))
          (setcar timer-ref nil))))
    (vui-vstack
     (vui-hstack
      (vui-text (propertize (benedict-vui-code-block--label normalized-language)
                            'face 'shadow))
      (vui-button copy-label :on-click copy-handler))
       (if (benedict-vui-code-block--resolve-mode normalized-language)
           (vui-text (benedict-vui-code-block--apply-region-properties
                      fontified message-key block-id))
         (vui-component 'benedict-vui-text-block
          :content (benedict-vui-code-block--fallback-content normalized-code normalized-language)
          :message-key message-key
          :block-id block-id)))))

(defun benedict-vui-code-block (&rest props)
  "Create a code block component node from PROPS."
  (apply #'vui-component 'benedict-vui-code-block props))

(provide 'benedict-vui-code-block)
;;; benedict-vui-code-block.el ends here
