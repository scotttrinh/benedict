;;; benedict-chat-sections.el --- Magit-section infrastructure for Benedict chat -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Defines chat-specific magit-section classes and helpers used by the UI
;; renderer to insert, track, and fold chat blocks.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'eieio)

(declare-function benedict-chat-tool-ui--update-header "benedict-chat-tool-ui")
(declare-function benedict-chat-thinking--update-header "benedict-chat-thinking")

;;; Section Classes

(defclass benedict-chat-section (magit-section)
  ((item :initarg :item :initform nil :accessor benedict-chat-section-item)
   (kind :initarg :kind :initform nil :accessor benedict-chat-section-kind))
  :documentation "Base section for Benedict chat UI.")

(defclass benedict-chat-conversation-section (benedict-chat-section) ()
  :documentation "Top-level conversation container.")
(defclass benedict-chat-turn-section (benedict-chat-section) ()
  :documentation "Turn section grouping user/assistant blocks.")
(defclass benedict-chat-message-user-section (benedict-chat-section) ()
  :documentation "User message section.")
(defclass benedict-chat-message-assistant-section (benedict-chat-section) ()
  :documentation "Assistant message section.")
(defclass benedict-chat-message-system-section (benedict-chat-section) ()
  :documentation "System message section.")
(defclass benedict-chat-thinking-section (benedict-chat-section) ()
  :documentation "Thinking/analysis section.")
(defclass benedict-chat-tool-section (benedict-chat-section) ()
  :documentation "Tool call section.")

(defconst benedict-chat-sections--classes
  '((conversation . benedict-chat-conversation-section)
    (turn . benedict-chat-turn-section)
    (message/user . benedict-chat-message-user-section)
    (message/assistant . benedict-chat-message-assistant-section)
    (message/system . benedict-chat-message-system-section)
    (thinking . benedict-chat-thinking-section)
    (tool . benedict-chat-tool-section))
  "Canonical mapping from chat block kinds to magit-section classes.")

(dolist (entry benedict-chat-sections--classes)
  (add-to-list 'magit--section-type-alist entry))

(defun benedict-chat-sections--normalize-role (role)
  "Normalize ROLE (symbol/string/keyword) into a lowercase symbol."
  (cond
   ((keywordp role) (intern (substring (symbol-name role) 1)))
   ((stringp role) (intern (downcase role)))
   ((symbolp role) (intern (downcase (symbol-name role))))
   (t 'unknown)))

(defun benedict-chat-sections--item-kind (item)
  "Return the canonical section kind keyword for ITEM.
ITEM may be a chat render plist (with :kind) or a plain message plist.
Message kinds are refined by role (user/assistant/system). Unknown
items default to `turn'."
  (let ((kind (plist-get item :kind)))
    (pcase kind
      ('message
       (pcase (benedict-chat-sections--normalize-role (plist-get item :role))
         ('user 'message/user)
         ('system 'message/system)
         (_ 'message/assistant)))
      ('thinking 'thinking)
      ('tool 'tool)
      (_ (cond
          ((plist-member item :tool-call) 'tool)
          ((plist-member item :thinking-id) 'thinking)
          ((plist-member item :role)
           (pcase (benedict-chat-sections--normalize-role (plist-get item :role))
             ('user 'message/user)
             ('system 'message/system)
             (_ 'message/assistant)))
          (t 'turn))))))

(defun benedict-chat-sections--section-p (section)
  "Return non-nil when SECTION is a Benedict chat UI section."
  (and section
       (condition-case nil
           (object-of-class-p section 'magit-section)
         (error nil))
       (memq (oref section type) (mapcar #'car benedict-chat-sections--classes))))

(defun benedict-chat-sections--set-folded (section folded)
  "Show or hide SECTION according to FOLDED.
Guards against stale sections, killed buffers, or sections not in the current buffer."
  (condition-case err
      (when (benedict-chat-sections--section-p section)
        ;; Check if section is still valid and belongs to current buffer
        (when-let ((section-end (ignore-errors (oref section end)))
                   ((markerp section-end))
                   (section-buffer (marker-buffer section-end))
                   ((buffer-live-p section-buffer))
                   ((eq section-buffer (current-buffer))))
          (let ((inhibit-read-only t))
            (condition-case nil
                (if folded
                    (magit-section-hide section)
                  (magit-section-show section))
              (error
               ;; Section may be stale or magit operations may fail;
               ;; fall back to setting the hidden flag directly
               (oset section hidden folded))))))
    ;; Catch any errors related to killed buffers or stale sections
    ((buffer-read-only error) nil)))

(defun benedict-chat-sections--end-position (section)
  "Return a buffer position for SECTION end, defaulting to `point-max'."
  (let ((end (and section (ignore-errors (oref section end)))))
    (cond
     ((markerp end) (or (marker-position end) (point-max)))
     ((integerp end) end)
     (t (point-max)))))

(defun benedict-chat-sections--insert-anchor ()
  "Insert an invisible anchor character for magit sections.

Magit sections without any buffer text can be difficult to reference and
extend reliably. This inserts a zero-width display anchor so the section
has a stable position without changing the visible buffer."
  (let ((pos (point)))
    (insert (propertize " " 'display "" 'benedict-region-kind 'header))
    (put-text-property pos (1+ pos) 'benedict-chat-anchor t)))

(defun benedict-chat-sections--ensure-root ()
  "Ensure a stable conversation root section exists in the current buffer."
  (unless (benedict-chat-sections--section-p benedict-chat--conversation-section)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (benedict-chat-sections--insert 'conversation nil nil
          (benedict-chat-sections--insert-anchor)
          (setq benedict-chat--conversation-section
                (or (and (boundp 'magit-insert-section--current)
                         magit-insert-section--current)
                    (magit-current-section)))
          ;; Ensure the conversation root's end marker advances when content is appended
          (when-let ((section benedict-chat--conversation-section))
            (when-let ((end (ignore-errors (oref section end))))
              (when (markerp end)
                (set-marker-insertion-type end t))))
          (setq-local magit-root-section benedict-chat--conversation-section))))))

(defun benedict-chat-sections--current-turn ()
  "Return the current turn section when it is valid."
  (when (benedict-chat-sections--section-p benedict-chat--current-turn-section)
    benedict-chat--current-turn-section))

(defun benedict-chat-sections--begin-turn ()
  "Insert a new turn section and make it current.

The turn section is a structural container; it does not insert any
visible header text."
  (benedict-chat-sections--ensure-root)
  (let ((parent benedict-chat--conversation-section))
    (when (benedict-chat-sections--section-p parent)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (benedict-chat-sections--end-position parent))
          (let ((magit-insert-section--parent parent))
            (benedict-chat-sections--insert 'turn nil nil
              (benedict-chat-sections--insert-anchor)
              (setq benedict-chat--current-turn-section
                    (or (and (boundp 'magit-insert-section--current)
                             magit-insert-section--current)
                        (magit-current-section))))))))
    (benedict-chat-sections--current-turn)))

(defun benedict-chat-sections--sync-fold-state (section)
  "Keep SECTION's item plist in sync with its visibility.
Guards against operations on killed buffers."
  (condition-case err
      (when (benedict-chat-sections--section-p section)
        (let* ((item (oref section value))
               (hidden (oref section hidden)))
          (pcase (oref section type)
            ('tool
             (when item
               (plist-put item :tool-folded hidden)
               (benedict-chat-tool-ui--update-header item)))
            ('thinking
             (when item
               (plist-put item :thinking-folded hidden)
               (when (fboundp 'benedict-chat-thinking--update-header)
                 (benedict-chat-thinking--update-header item)))))))
    ;; Silently ignore errors related to killed buffers
    ((buffer-read-only error) nil)))

(defun benedict-chat-sections--sync-fold-state-after-visibility (section &rest _)
  "Advice: update SECTION metadata after magit visibility changes."
  (benedict-chat-sections--sync-fold-state section))

(advice-add 'magit-section-show :after #'benedict-chat-sections--sync-fold-state-after-visibility)
(advice-add 'magit-section-hide :after #'benedict-chat-sections--sync-fold-state-after-visibility)

(defmacro benedict-chat-sections--insert (kind value &optional hide &rest body)
  "Insert a magit-section for chat KIND with VALUE and optional HIDE flag.
KIND must be a key in `benedict-chat-sections--classes'. BODY inserts
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
                    ;; Use magit-insert-section--current when bound (the newly created section)
                    ;; falling back to magit-current-section for compatibility
                    (let ((section (or (and (boundp 'magit-insert-section--current)
                                             magit-insert-section--current)
                                        (magit-current-section))))
                      (benedict-chat-sections--register section ',section-kind ,value-sym))
                    ,@body))))
            benedict-chat-sections--classes)
         (_ (error "Unknown chat section kind: %S" ,kind-sym))))))

(defun benedict-chat-sections--register (section kind item)
  "Attach SECTION metadata to KIND and ITEM."
  (when section
    (oset section type kind)
    (when-let ((end (ignore-errors (oref section end))))
      (when (markerp end)
        (set-marker-insertion-type end t)))
    ;; Also ensure the parent section's end marker advances when we insert content
    (when-let ((parent (oref section parent)))
      (when-let ((parent-end (ignore-errors (oref parent end))))
        (when (markerp parent-end)
          (set-marker-insertion-type parent-end t))))
    (when item
      (oset section value item))
    (when (and item (plistp item))
      (plist-put item :section section)))
  section)

(defmacro benedict-chat-sections--with (item &rest body)
  "Wrap BODY in a magit section for ITEM in the current buffer."
  (declare (indent 1))
  `(let ((item-value ,item))
     (benedict-chat-sections--ensure-root)
     (let* ((kind (benedict-chat-sections--item-kind item-value))
            (parent benedict-chat--conversation-section))
       (save-excursion
         (goto-char (benedict-chat-sections--end-position parent))
         (let ((magit-insert-section--parent parent))
           (benedict-chat-sections--insert kind item-value nil
              (when (and (plistp item-value) parent)
                (plist-put item-value :parent-section parent))
              ,@body))))))

(defmacro benedict-chat-sections--with-parent (parent item &rest body)
  "Wrap BODY in a magit section for ITEM under PARENT when possible."
  (declare (indent 2))
  `(let ((parent-section ,parent)
         (item-value ,item))
     (if (benedict-chat-sections--section-p parent-section)
         (progn
           (benedict-chat-sections--ensure-root)
           (save-excursion
             (goto-char (benedict-chat-sections--end-position parent-section))
             (let ((magit-insert-section--parent parent-section))
               (let ((kind (benedict-chat-sections--item-kind item-value)))
                 (benedict-chat-sections--insert kind item-value nil
                   (when (and (plistp item-value) parent-section)
                     (plist-put item-value :parent-section parent-section))
                   ,@body)))))
       (benedict-chat-sections--with item-value ,@body))))

(provide 'benedict-chat-sections)
;;; benedict-chat-sections.el ends here
