;;; benedict-chat-widgets.el --- Faces and shared render pieces for the chat UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;;; Commentary:

;; The presentational leaf of the chat frontend: faces, the markdown
;; fontification arrangement, and the small vnode builders that several block
;; renderers share.  Nothing here knows about sessions, entries, or hooks -- it
;; takes strings and returns vnodes, which is what makes it the one layer of the
;; frontend worth unit-testing directly.
;;
;; MARKDOWN.  Assistant prose is markdown, but the chat buffer is not a
;; `markdown-mode' buffer and must not become one: it also holds role headers,
;; tool cards, and badges that markdown would happily mangle.  Instead the buffer
;; borrows markdown's font-lock keywords and syntax-propertize function, and
;; gates them to the regions this file stamps with `benedict-chat-region-kind'
;; set to `body'.  A `font-lock-extend-region-functions' member collapses the
;; region to nothing when it does not start inside such a run, so fontification
;; simply never reaches the chrome.
;;
;; This arrangement predates the SPEC-001 reset and is revived deliberately.  It
;; is strictly better now than it was then: the transcript is written through
;; `vui-stream', which appends rather than erasing and rebuilding the buffer, so
;; jit-lock refontifies only the newly arrived text instead of the whole
;; transcript on every token.
;;
;; CODE BLOCKS use a different mechanism on purpose.  Fenced code is fontified
;; off-buffer, in a temp buffer running the language's own major mode, and the
;; propertized string is inserted as literal text.  That keeps it independent of
;; the buffer's font-lock -- which is gated to `body' and would otherwise have to
;; understand every language -- and it is why `benedict-chat-fontify-code' can be
;; memoized by its caller.

;;; Code:

(require 'benedict)
(require 'vui)
(require 'markdown-mode)

;;;; Customization

(defgroup benedict-chat nil
  "Chat frontend for Benedict."
  :group 'benedict
  :prefix "benedict-chat-")

(defface benedict-chat-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user role header."
  :group 'benedict-chat)

(defface benedict-chat-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the assistant role header."
  :group 'benedict-chat)

(defface benedict-chat-note
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for a `note' entry, which is record rather than conversation."
  :group 'benedict-chat)

(defface benedict-chat-badge
  '((t :inherit shadow :height 0.9))
  "Face for the origin badge: provider, api, and model."
  :group 'benedict-chat)

(defface benedict-chat-thinking
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for reasoning content."
  :group 'benedict-chat)

(defface benedict-chat-tool
  '((t :inherit font-lock-builtin-face))
  "Face for a tool name."
  :group 'benedict-chat)

(defface benedict-chat-error
  '((t :inherit error))
  "Face for an errored tool result or a failed turn."
  :group 'benedict-chat)

(defface benedict-chat-branch
  '((t :inherit font-lock-constant-face :height 0.9))
  "Face for the branch affordance, as in \"2/3\"."
  :group 'benedict-chat)

(defface benedict-chat-status
  '((t :inherit mode-line-emphasis))
  "Face for the status line."
  :group 'benedict-chat)

;;;; Region tagging

(defconst benedict-chat-region-kind 'benedict-chat-region-kind
  "Text property naming what kind of region a stretch of buffer is.

Only one value is load-bearing: `body', which marks assistant prose and
is the sole region markdown fontification is allowed to touch.  See
`benedict-chat--extend-region-body-only', which is where that gate is
actually enforced.")

(defun benedict-chat-body-text (content &rest props)
  "Return a text vnode for CONTENT tagged as markdown-fontifiable body.

PROPS are extra text properties, passed through to `vui-text'.  Use this
rather than `vui-text' for anything that should be rendered as markdown;
using plain `vui-text' is how a block opts out."
  (apply #'vui-text content
         benedict-chat-region-kind 'body
         props))

;;;; Markdown fontification, gated to body regions

(defun benedict-chat--body-run-bounds (position)
  "Return the bounds of the `body' region containing POSITION, or nil.

Returns a cons of buffer positions.  A run is a maximal stretch over
which `benedict-chat-region-kind' is `body'."
  (when (eq (get-text-property position benedict-chat-region-kind) 'body)
    (let ((start position)
          (end position))
      (while (and (> start (point-min))
                  (eq (get-text-property (1- start) benedict-chat-region-kind)
                      'body))
        (setq start (1- start)))
      (while (and (< end (point-max))
                  (eq (get-text-property end benedict-chat-region-kind) 'body))
        (setq end (1+ end)))
      (cons start end))))

(defun benedict-chat--extend-region-body-only ()
  "Clamp the pending font-lock region to one `body' run.  Return non-nil if moved.

Intended for `font-lock-extend-region-functions', whose contract is to
adjust the free variables `font-lock-beg' and `font-lock-end' and return
non-nil when it changed either.  MUTATES those two variables, which is
the whole mechanism: when the region does not begin inside a body run
both are driven to `point-max', so markdown fontification matches
nothing and the chrome is left alone."
  (let ((bounds (benedict-chat--body-run-bounds font-lock-beg)))
    (cond
     ((null bounds)
      (if (and (= font-lock-beg (point-max)) (= font-lock-end (point-max)))
          nil
        (setq font-lock-beg (point-max)
              font-lock-end (point-max))
        t))
     ((and (= font-lock-beg (car bounds)) (= font-lock-end (cdr bounds)))
      nil)
     (t
      (setq font-lock-beg (car bounds)
            font-lock-end (cdr bounds))
      t))))

(defun benedict-chat-setup-markdown-fontification ()
  "Arrange markdown fontification of `body' regions in the current buffer.

MUTATES several buffer-local font-lock variables.  Borrows markdown's
font-lock keywords and its syntax propertizer rather than enabling
`markdown-mode', because the buffer also holds role headers, tool cards,
and badges that markdown would misread; the gate is
`benedict-chat--extend-region-body-only'."
  (setq-local font-lock-defaults
              `(markdown-mode-font-lock-keywords
                nil nil nil nil
                (font-lock-multiline . t)
                (font-lock-extend-region-functions
                 . (benedict-chat--extend-region-body-only))))
  (setq-local syntax-propertize-function #'markdown-syntax-propertize)
  ;; Fenced code inside a body run is handled by markdown itself; standalone
  ;; code blocks go through `benedict-chat-fontify-code' instead.
  (setq-local markdown-fontify-code-blocks-natively t)
  (font-lock-mode 1))

;;;; Off-buffer code fontification

(defun benedict-chat--language-mode (language)
  "Return the major mode function for LANGUAGE, or nil when there is none.
LANGUAGE is a string such as \"elisp\"; resolution is markdown's, so the
aliases it knows are the aliases this knows."
  (when (and language (not (string-empty-p language)))
    (let ((mode (ignore-errors (markdown-get-lang-mode language))))
      (and (fboundp mode) mode))))

(defun benedict-chat-fontify-code (code language)
  "Return CODE as a string propertized by LANGUAGE's major mode.

Fontifies in a temp buffer, so the chat buffer's own font-lock -- which
is gated to `body' regions -- never has to know about the language.
Returns CODE unchanged when LANGUAGE resolves to no available mode.
Deterministic and side-effect free, so callers may memoize it."
  (let ((mode (benedict-chat--language-mode language)))
    (if (or (null mode) (null code) (string-empty-p code))
        (or code "")
      (with-temp-buffer
        (insert code)
        (delay-mode-hooks (funcall mode))
        (font-lock-ensure (point-min) (point-max))
        (buffer-string)))))

;;;; Small shared vnodes

(defun benedict-chat-badge (text)
  "Return a badge vnode showing TEXT, or nil when TEXT is empty."
  (when (and text (not (string-empty-p text)))
    (vui-text text :face 'benedict-chat-badge)))

(defun benedict-chat-truncate (text limit)
  "Return TEXT shortened to LIMIT characters with an explicit elision marker.

The marker is deliberate: a silent truncation in a transcript reads as
the model having stopped early, which is a far more expensive confusion
than a visibly clipped line."
  (let ((text (or text "")))
    (if (<= (length text) limit)
        text
      (format "%s… (%d more characters)"
              (substring text 0 limit)
              (- (length text) limit)))))

(defun benedict-chat-one-line (text limit)
  "Return TEXT collapsed to a single line of at most LIMIT characters.
Used for collapsed summaries, where newlines would break the layout."
  (benedict-chat-truncate
   (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))
   limit))

(provide 'benedict-chat-widgets)
;;; benedict-chat-widgets.el ends here
