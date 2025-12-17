;;; benedict-chat-ui.el --- Magit section scaffolding for chat UI -*- lexical-binding: t; -*-
;; Author: Benedict maintainers
;; Package-Requires: ((emacs "27.1") (magit "3.3.0") (svg-lib "0.2.8"))

;;; Commentary:
;; Section-aware rendering scaffolding for the Benedict chat buffer.
;; This module standardizes section kinds (conversation, turn, message,
;; tool, thinking) and provides helper macros to build magit-section
;; hierarchies while preserving the existing marker-backed rendering
;; model and `benedict-region-kind' boundaries used for markdown
;; fontification.

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'magit-section)
(require 'svg-lib nil t)
(require 'benedict-chat-mode)
(require 'benedict-chat-render)

(defgroup benedict-chat-ui nil
  "Structured chat UI built on magit-section."
  :group 'benedict-chat
  :prefix "benedict-chat-ui-")

(defcustom benedict-chat-ui-fringe-bars-enabled t
  "When non-nil, draw role/state bars in the fringe for top-level blocks.
No effect on terminals or when fringes are unavailable."
  :type 'boolean
  :group 'benedict-chat-ui)

(defvar-local benedict-chat-ui--conversation-section nil
  "Conversation root section for the current chat buffer.

All UI sections are inserted under this stable parent to avoid ad-hoc
root sections when streaming inserts append later.")

(defvar-local benedict-chat-ui--current-turn-section nil
  "Most recent turn section in the current chat buffer.

Turn sections group user and assistant blocks for stable navigation and
folding semantics in the UI renderer.")

(defun benedict-chat-ui--svg-supported-p ()
  "Return non-nil when SVG badges can be rendered."
  (and (display-graphic-p)
       (featurep 'svg)
       (require 'svg-lib nil t)
       (fboundp 'svg-lib-tag)))

(defun benedict-chat-ui--badge-face (face)
  "Return FACE coerced to a single face symbol."
  (cond
   ((and (symbolp face) (facep face)) face)
   ((listp face)
    (or (cl-some (lambda (candidate)
                   (and (symbolp candidate) (facep candidate)))
                 face)
        'benedict-chat-header))
   (t 'benedict-chat-header)))

(defun benedict-chat-ui--badge (label face)
  "Render LABEL as a badge using FACE.
Falls back to a propertized text badge when SVG is unavailable."
  (let* ((label (format "%s" label))
         (face (benedict-chat-ui--badge-face face))
         (fg (face-foreground face nil 'default))
         (bg (or (face-background face nil 'default)
                 (face-background 'default nil))))
    (if (benedict-chat-ui--svg-supported-p)
        (let ((image (svg-lib-tag label nil
                                  :stroke 0
                                  :radius 4
                                  :padding 1.0
                                  :foreground fg
                                  :background bg
                                  :font-family "Menlo")))
          (propertize label 'display image 'face face))
      (propertize (format "[%s]" label) 'face face))))

(defclass benedict-chat-ui-section (magit-section)
  ((item :initarg :item :initform nil :accessor benedict-chat-ui-section-item)
   (kind :initarg :kind :initform nil :accessor benedict-chat-ui-section-kind))
  :documentation "Base section for Benedict chat UI.")

(defclass benedict-chat-ui-conversation-section (benedict-chat-ui-section) ()
  :documentation "Top-level conversation container.")
(defclass benedict-chat-ui-turn-section (benedict-chat-ui-section) ()
  :documentation "Turn section grouping user/assistant blocks.")
(defclass benedict-chat-ui-message-user-section (benedict-chat-ui-section) ()
  :documentation "User message section.")
(defclass benedict-chat-ui-message-assistant-section (benedict-chat-ui-section) ()
  :documentation "Assistant message section.")
(defclass benedict-chat-ui-message-system-section (benedict-chat-ui-section) ()
  :documentation "System message section.")
(defclass benedict-chat-ui-thinking-section (benedict-chat-ui-section) ()
  :documentation "Thinking/analysis section.")
(defclass benedict-chat-ui-tool-section (benedict-chat-ui-section) ()
  :documentation "Tool call section.")

(defconst benedict-chat-ui--section-classes
  '((conversation . benedict-chat-ui-conversation-section)
    (turn . benedict-chat-ui-turn-section)
    (message/user . benedict-chat-ui-message-user-section)
    (message/assistant . benedict-chat-ui-message-assistant-section)
    (message/system . benedict-chat-ui-message-system-section)
    (thinking . benedict-chat-ui-thinking-section)
    (tool . benedict-chat-ui-tool-section))
  "Canonical mapping from chat block kinds to magit-section classes.
These keys remain stable across renders to keep folding/navigation predictable.")

(dolist (entry benedict-chat-ui--section-classes)
  (add-to-list 'magit--section-type-alist entry))

(defun benedict-chat-ui-active-p ()
  "Return non-nil when the current buffer uses `benedict-chat-ui-mode'."
  (derived-mode-p 'benedict-chat-ui-mode))

(defun benedict-chat-ui--normalize-role (role)
  "Normalize ROLE (symbol/string/keyword) into a lowercase symbol."
  (cond
   ((keywordp role) (intern (substring (symbol-name role) 1)))
   ((stringp role) (intern (downcase role)))
   ((symbolp role) (intern (downcase (symbol-name role))))
   (t 'unknown)))

(defun benedict-chat-ui--item-section-kind (item)
  "Return the canonical section kind keyword for ITEM.
ITEM may be a chat render plist (with :kind) or a plain message plist.
Message kinds are refined by role (user/assistant/system). Unknown
items default to `turn'."
  (let ((kind (plist-get item :kind)))
    (pcase kind
      ('message
       (pcase (benedict-chat-ui--normalize-role (plist-get item :role))
         ('user 'message/user)
         ('system 'message/system)
         (_ 'message/assistant)))
      ('thinking 'thinking)
      ('tool 'tool)
      (_ (cond
          ((plist-member item :tool-call) 'tool)
          ((plist-member item :thinking-id) 'thinking)
          ((plist-member item :role)
           (pcase (benedict-chat-ui--normalize-role (plist-get item :role))
             ('user 'message/user)
             ('system 'message/system)
             (_ 'message/assistant)))
          (t 'turn))))))

(defun benedict-chat-ui--section-p (section)
  "Return non-nil when SECTION is a Benedict chat UI section."
  (and section
       (condition-case nil
           (object-of-class-p section 'magit-section)
         (error nil))
       (memq (oref section type) (mapcar #'car benedict-chat-ui--section-classes))))

(defun benedict-chat-ui--set-section-folded (section folded)
  "Show or hide SECTION according to FOLDED."
  (when (benedict-chat-ui--section-p section)
    (let ((inhibit-read-only t))
      (condition-case nil
          (if folded
              (magit-section-hide section)
            (magit-section-show section))
        (error
         (oset section hidden folded))))))

(defun benedict-chat-ui--section-end-position (section)
  "Return a buffer position for SECTION end, defaulting to `point-max'."
  (let ((end (and section (ignore-errors (oref section end)))))
    (cond
     ((markerp end) (or (marker-position end) (point-max)))
     ((integerp end) end)
     (t (point-max)))))

(defun benedict-chat-ui--insert-anchor ()
  "Insert an invisible anchor character for magit sections.

Magit sections without any buffer text can be difficult to reference and
extend reliably. This inserts a zero-width display anchor so the section
has a stable position without changing the visible buffer."
  (let ((pos (point)))
    (insert (propertize " " 'display "" 'benedict-region-kind 'header))
    (put-text-property pos (1+ pos) 'benedict-chat-ui-anchor t)))

(defun benedict-chat-ui--ensure-conversation-root ()
  "Ensure a stable conversation root section exists in the current buffer."
  (when (benedict-chat-ui-active-p)
    (unless (benedict-chat-ui--section-p benedict-chat-ui--conversation-section)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (benedict-chat-ui--insert-section 'conversation nil nil
            (benedict-chat-ui--insert-anchor)
            (setq benedict-chat-ui--conversation-section
                  (or (and (boundp 'magit-insert-section--current)
                           magit-insert-section--current)
                      (magit-current-section)))
            (setq-local magit-root-section benedict-chat-ui--conversation-section)))))))

(defun benedict-chat-ui--current-turn ()
  "Return the current turn section when it is valid."
  (when (benedict-chat-ui--section-p benedict-chat-ui--current-turn-section)
    benedict-chat-ui--current-turn-section))

(defun benedict-chat-ui--begin-turn ()
  "Insert a new turn section and make it current.

The turn section is a structural container; it does not insert any
visible header text."
  (when (benedict-chat-ui-active-p)
    (benedict-chat-ui--ensure-conversation-root)
    (let ((parent benedict-chat-ui--conversation-section))
      (when (benedict-chat-ui--section-p parent)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (benedict-chat-ui--section-end-position parent))
            (let ((magit-insert-section--parent parent))
              (benedict-chat-ui--insert-section 'turn nil nil
                (benedict-chat-ui--insert-anchor)
                (setq benedict-chat-ui--current-turn-section
                      (or (and (boundp 'magit-insert-section--current)
                               magit-insert-section--current)
                          (magit-current-section)))))))))
    (benedict-chat-ui--current-turn)))

(defun benedict-chat-ui--sync-fold-state (section)
  "Keep SECTION's item plist in sync with its visibility."
  (when (benedict-chat-ui--section-p section)
    (let* ((item (oref section value))
           (hidden (oref section hidden)))
      (pcase (oref section type)
        ('tool
         (when item
           (plist-put item :tool-folded hidden)
           (benedict-chat--update-tool-header item)))
        ('thinking
         (when item
           (plist-put item :thinking-folded hidden)
           (when (fboundp 'benedict-chat--update-thinking-header)
             (benedict-chat--update-thinking-header item))))))))

(defun benedict-chat-ui--sync-fold-state-after-visibility (section &rest _)
  "Advice: update SECTION metadata after magit visibility changes."
  (benedict-chat-ui--sync-fold-state section))

(advice-add 'magit-section-show :after #'benedict-chat-ui--sync-fold-state-after-visibility)
(advice-add 'magit-section-hide :after #'benedict-chat-ui--sync-fold-state-after-visibility)

(defmacro benedict-chat-ui--insert-section (kind value &optional hide &rest body)
  "Insert a magit-section for chat KIND with VALUE and optional HIDE flag.
KIND must be a key in `benedict-chat-ui--section-classes'. BODY inserts
the section header/body content. This helper only sets up the section
object; callers remain responsible for marker-backed insertion so
streaming updates stay stable."
  (declare (indent 3))
  (let ((kind-sym (make-symbol "kind"))
        (value-sym (make-symbol "value"))
        (hide-sym (make-symbol "hide")))
    `(let ((,kind-sym ,kind)
           (,value-sym ,value)
           (,hide-sym ,hide))
       (pcase ,kind-sym
         ,@(mapcar
            (lambda (entry)
              (let ((section-kind (car entry)))
                `(,(list 'quote section-kind)
                  (magit-insert-section (,section-kind ,value-sym ,hide-sym)
                    (let ((section (magit-current-section)))
                      (benedict-chat-ui--register-section section ',section-kind ,value-sym))
                    ,@body))))
            benedict-chat-ui--section-classes)
         (_ (error "Unknown chat section kind: %S" ,kind-sym))))))

(defun benedict-chat-ui--register-section (section kind item)
  "Attach SECTION metadata to KIND and ITEM."
  (when section
    (oset section type kind)
    (when item
      (oset section value item))
    (when (and item (plistp item))
      (plist-put item :section section)))
  section)

(defmacro benedict-chat-ui--with-section (item &rest body)
  "Wrap BODY in a magit section for ITEM when chat UI is active."
  (declare (indent 1))
  `(let ((item-value ,item))
     (if (not (benedict-chat-ui-active-p))
         (progn ,@body)
       (progn
         (benedict-chat-ui--ensure-conversation-root)
         (let* ((kind (benedict-chat-ui--item-section-kind item-value))
                (parent benedict-chat-ui--conversation-section))
           (save-excursion
             (goto-char (benedict-chat-ui--section-end-position parent))
             (let ((magit-insert-section--parent parent))
               (benedict-chat-ui--insert-section kind item-value nil
                  (when (and (plistp item-value) parent)
                    (plist-put item-value :parent-section parent))
                  ,@body))))))))

(defmacro benedict-chat-ui--with-parent-section (parent item &rest body)
  "Wrap BODY in a magit section for ITEM under PARENT when possible."
  (declare (indent 2))
  `(let ((parent-section ,parent)
         (item-value ,item))
     (if (and (benedict-chat-ui-active-p)
              (benedict-chat-ui--section-p parent-section))
         (progn
           (benedict-chat-ui--ensure-conversation-root)
           (save-excursion
             (goto-char (benedict-chat-ui--section-end-position parent-section))
             (let ((magit-insert-section--parent parent-section))
                (let ((kind (benedict-chat-ui--item-section-kind item-value)))
                  (benedict-chat-ui--insert-section kind item-value nil
                    (when (and (plistp item-value) parent-section)
                      (plist-put item-value :parent-section parent-section))
                    ,@body)))))
       (benedict-chat-ui--with-section item-value ,@body))))

(defun benedict-chat-ui--propertize-region (beg end kind)
  "Apply `benedict-region-kind' KIND to region between BEG and END."
  (put-text-property beg end 'benedict-region-kind kind))

(defun benedict-chat-ui--insert-header-line (text item)
  "Insert TEXT as a header line for ITEM and tag it as non-body.
This only applies text properties; callers handle marker tracking."
  (let ((start (point)))
    (insert text)
    (benedict-chat-ui--propertize-region start (point) 'header)
    (put-text-property start (point) 'benedict-chat-item item)
    (insert "\n")
    (benedict-chat-ui--propertize-region (1- (point)) (point) 'header)))

(defun benedict-chat-ui--insert-body (content &optional kind)
  "Insert CONTENT and tag the region as KIND (defaults to `body')."
  (let* ((kind (or kind 'body))
         (start (point)))
    (insert (or content ""))
    (benedict-chat-ui--propertize-region start (point) kind)
    (insert "\n")
    (benedict-chat-ui--propertize-region (1- (point)) (point) kind)))

(defvar benedict-chat-ui-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g l") #'benedict-chat-jump-to-latest)
    (define-key map (kbd "g a") #'benedict-chat-jump-to-last-assistant)
    (define-key map (kbd "g A") #'benedict-chat-jump-to-last-assistant-with-tools)
    (define-key map (kbd "] t") #'benedict-chat-next-tool)
    (define-key map (kbd "[ t") #'benedict-chat-previous-tool)
    (define-key map (kbd "] f") #'benedict-chat-next-tool-failure)
    (define-key map (kbd "[ f") #'benedict-chat-previous-tool-failure)
    (define-key map (kbd "] e") #'benedict-chat-next-error)
    (define-key map (kbd "[ e") #'benedict-chat-previous-error)
    (define-key map (kbd "] h") #'benedict-chat-next-thinking)
    (define-key map (kbd "[ h") #'benedict-chat-previous-thinking)
    (define-key map (kbd "s") #'benedict-chat-toggle-thinking)
    map)
  "Keymap for `benedict-chat-ui-mode'.")

;;;###autoload
(define-derived-mode benedict-chat-ui-mode magit-section-mode "Benedict-Chat-UI"
  "Major mode for Benedict's section-based chat UI."
  (benedict-chat--setup-common-buffer)
  (benedict-chat-ui--ensure-conversation-root))

(provide 'benedict-chat-ui)
;;; benedict-chat-ui.el ends here
