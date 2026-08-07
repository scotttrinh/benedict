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
;; set to `body'.
;;
;; THE GATE IS A REGION FUNCTION, not a region extension, and that is the whole
;; reason this works.  Font-lock fontifies ONE contiguous region, while a
;; transcript's markdown lives in disjoint runs separated by chrome.  A
;; `font-lock-extend-region-functions' member sees only that single region: it
;; can pick one run out of a jit-lock chunk and must discard everything else in
;; it -- and since a chunk begins wherever unfontified text starts, which for an
;; appended transcript is a role header or the stream's separator newline, in
;; practice it discards every run there is.  `benedict-chat--fontify-region'
;; instead fontifies the SET of runs the chunk touches, which is something only
;; `font-lock-fontify-region-function' can express.
;;
;; A RUN IS FONTIFIED WHOLE, ONCE, WHEN ITS BLOCK CLOSES.  Streaming text is
;; inserted untagged by `benedict-chat-streaming-text-vnode' and is retagged in a
;; single pass at block end, so markdown never sees half a construct -- an
;; unclosed fence would style the rest of the message as code until its partner
;; arrived.  It also keeps a message linear rather than quadratic: fontifying a
;; run needs the whole run, so doing it per delta would re-scan every character
;; of the message once per token.
;;
;; CODE BLOCKS.  Fenced code inside a body run is markdown's own affair: it
;; carries the fence, so `markdown-fontify-code-blocks-natively' recognizes it
;; and runs the language's mode over the contents like any markdown buffer.
;; `benedict-chat-fontify-code' is the mechanism for code that arrives WITHOUT a
;; fence around it -- a tool result that is known to be Lisp, say.  It fontifies
;; in a temp buffer and returns a propertized string, so the buffer's own
;; font-lock, gated to `body', never has to understand a language.  It is
;; deterministic and side-effect free, and so memoizable by its caller.  Nothing
;; calls it yet.

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
`benedict-chat--fontify-region', which is where that gate is actually
enforced.")

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
  (when (and (< position (point-max))
             (eq (get-text-property position benedict-chat-region-kind) 'body))
    (cons (or (previous-single-property-change (1+ position)
                                               benedict-chat-region-kind)
              (point-min))
          (or (next-single-property-change position benedict-chat-region-kind)
              (point-max)))))

(defun benedict-chat--body-runs (beg end)
  "Return the `body' runs overlapping BEG..END, in buffer order.

Each run is returned WHOLE, even where it reaches outside BEG..END.  A
markdown construct is only recognizable from its start and jit-lock cuts
its chunks wherever the previous redisplay happened to stop, so
fontifying the intersection would leave a construct half-matched purely
because a chunk boundary fell inside it."
  (let ((runs nil)
        (position beg))
    (while (< position end)
      (if-let* ((bounds (benedict-chat--body-run-bounds position)))
          (progn
            (push bounds runs)
            (setq position (cdr bounds)))
        (setq position (or (next-single-property-change
                            position benedict-chat-region-kind nil end)
                           end))))
    (nreverse runs)))

(defun benedict-chat--fontify-region (beg end &optional loudly)
  "Fontify every `body' run overlapping BEG..END.  Return the settled bounds.

Intended for `font-lock-fontify-region-function', whose contract is to
fontify BEG..END, honour LOUDLY as a progress-message flag, and return
\(jit-lock-bounds BEG . END) naming what it actually settled.  See this
file's commentary for why the gate has to live here rather than in
`font-lock-extend-region-functions'.

Reports the WHOLE request as settled, chrome included: there is nothing
to do to the chrome, and reporting only the runs would leave the rest
unfontified and have jit-lock ask again on every redisplay."
  (dolist (run (benedict-chat--body-runs beg end))
    ;; `vui' writes with `inhibit-modification-hooks' bound, so nothing has
    ;; told `syntax-propertize' that this text is new and its high-water mark
    ;; can already sit past it.  Without the flush a block rewritten at close
    ;; keeps whatever syntax properties stood here while it was streaming,
    ;; which is how a fence ends up unrecognized.
    (syntax-ppss-flush-cache (car run))
    (font-lock-default-fontify-region (car run) (cdr run) loudly))
  `(jit-lock-bounds ,beg . ,end))

(defun benedict-chat-setup-markdown-fontification ()
  "Arrange markdown fontification of `body' regions in the current buffer.

MUTATES several buffer-local font-lock variables.  Borrows markdown's
font-lock keywords and its syntax propertizer rather than enabling
`markdown-mode', because the buffer also holds role headers, tool cards,
and badges that markdown would misread; the gate is
`benedict-chat--fontify-region'."
  (setq-local font-lock-defaults
              `(markdown-mode-font-lock-keywords
                nil nil nil nil
                (font-lock-multiline . t)
                (font-lock-syntactic-face-function . markdown-syntactic-face)
                ;; Markdown's keywords set more than `face' -- `display' on a
                ;; fence's language, `invisible' under `markdown-hide-markup'.
                ;; Undeclared, unfontifying a run would leave them behind.
                (font-lock-extra-managed-props
                 . (composition display invisible rear-nonsticky
                                keymap help-echo mouse-face))
                (font-lock-fontify-region-function
                 . benedict-chat--fontify-region)
                ;; Region selection is `benedict-chat--fontify-region''s job
                ;; and it always hands whole runs down.  An extension here
                ;; could only reach past a run's end into the chrome, whose
                ;; faces font-lock would then unfontify.
                (font-lock-extend-region-functions . nil)))
  (setq-local syntax-propertize-function #'markdown-syntax-propertize)
  ;; Propertizing starts wherever the high-water mark left off, which is not
  ;; necessarily outside a fenced block; this is how markdown widens to one.
  (add-hook 'syntax-propertize-extend-region-functions
            #'markdown-syntax-propertize-extend-region nil t)
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
