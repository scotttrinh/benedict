;;; benedict-chat-blocks.el --- Content block renderers for the chat UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;;; Commentary:

;; One renderer per content block type of SPEC-001 4.5: `text', `thinking',
;; `image', `tool-call', and `tool-result'.  Blocks arrive as typed plists, so
;; there is no normalization layer here and there must not be one -- the
;; pre-reset frontend spent roughly a hundred and eighty lines tolerating alists,
;; vectors, bare strings, and three different spellings of the type key, all of
;; which SPEC-001's data model exists to make unnecessary.
;;
;; TWO SHAPES OF RENDERER, and which one a block gets is a performance decision,
;; not a stylistic one:
;;
;; - A block whose text GROWS token by token renders as a plain CONTENT vnode.
;;   Its stream node then takes `vui-stream-append-to', which inserts only the
;;   new characters and marks only those dirty, so a delta costs O(delta) no
;;   matter how long the message or the transcript has become.  `text' is the
;;   case that matters, and it has TWO vnodes for that reason: deltas arrive
;;   through `benedict-chat-streaming-text-vnode', which is untagged and so
;;   invisible to markdown fontification, and the block is re-rendered once
;;   through `benedict-chat-text-vnode' when it closes.
;;
;; - A block that is INTERACTIVE or changes wholesale renders as a COMPONENT,
;;   which becomes a stream row owning its own region and its own state.  Its
;;   updates cost O(that block) and leave everything around it untouched.
;;   `thinking' and the two tool blocks are these.
;;
;; Collapse state lives in the component, once.  Three pre-reset components took
;; a `collapsed' prop AND declared a `collapsed' state slot with the same
;; meaning, which is precisely why collapse state and the root's idea of it could
;; disagree after a re-render.  Here `vui-collapsible' owns it in uncontrolled
;; mode and nothing above reads it back.

;;; Code:

(require 'benedict)
(require 'benedict-message)
(require 'vui)
(require 'vui-components)
(require 'benedict-chat-widgets)

(defcustom benedict-chat-thinking-summary-width 60
  "Characters of reasoning shown on a collapsed thinking block's header."
  :type 'integer
  :group 'benedict-chat)

(defcustom benedict-chat-tool-result-summary-width 60
  "Characters of output shown on a collapsed tool result's header."
  :type 'integer
  :group 'benedict-chat)

(defcustom benedict-chat-max-block-length 20000
  "Characters of a single block rendered before eliding the remainder."
  :type 'integer
  :group 'benedict-chat)

;;;; Text

(defun benedict-chat-text-vnode (block)
  "Return a content vnode for a finished `text' BLOCK.

Plain content rather than a component, deliberately: this is the block
that streams, and only a content node gets `vui-stream-append-to''s
O(delta) append.

Tagged as markdown body, so it is for a block whose text is COMPLETE --
either it never streamed or it has closed.  While it is still arriving,
`benedict-chat-streaming-text-vnode' is the one to use."
  (benedict-chat-body-text
   (benedict-chat-truncate (or (benedict-block-get block :text) "")
                           benedict-chat-max-block-length)))

(defun benedict-chat-streaming-text-vnode (block)
  "Return a content vnode for a `text' BLOCK that has not closed yet.

UNTAGGED, unlike `benedict-chat-text-vnode', and that is the point: half
a construct is not markdown.  An unclosed fence would style the rest of
the message as code until its partner arrived, and every delta would pay
to re-scan the whole message to find that out.  The block is re-rendered
tagged when it closes, which is the one moment its markdown is whole."
  (vui-text (benedict-chat-truncate (or (benedict-block-get block :text) "")
                                    benedict-chat-max-block-length)))

(defun benedict-chat-streaming-delta-vnode (delta)
  "Return an untagged content vnode carrying DELTA, freshly arrived text.
The append-shaped counterpart of `benedict-chat-streaming-text-vnode'."
  (vui-text delta))

;;;; Image

(defun benedict-chat-image-vnode (block)
  "Return a placeholder vnode for an `image' BLOCK.

Images render as a note of their type and size rather than inline.  A
real image needs a display property whose height the stream's region
arithmetic would have to account for, which is a larger change than this
phase is scoped for."
  (vui-text (format "[image: %s, %d bytes]"
                    (or (benedict-block-get block :mime-type) "unknown")
                    (length (or (benedict-block-get block :data) "")))
            :face 'benedict-chat-badge))

;;;; Thinking

(vui-defcomponent benedict-chat-thinking-block (text redacted)
  "Render reasoning content, collapsed by default.

TEXT is the reasoning so far and REDACTED is non-nil for provider-opaque
ciphertext.  Collapsed is the right default because reasoning is usually
long, usually skimmed, and never the answer; the header carries enough of
it to decide whether to open."
  :render
  (if redacted
      ;; Redacted thinking has no text to show -- it is ciphertext only its
      ;; issuer can read.  Saying so beats an empty section.
      (vui-text "▶ Reasoning (redacted by the provider)"
                :face 'benedict-chat-thinking)
    (let ((text (or text "")))
      (vui-collapsible
       :title (format "Reasoning — %s"
                      (benedict-chat-one-line
                       text benedict-chat-thinking-summary-width))
       :title-face 'benedict-chat-thinking
       :initially-expanded nil
       (vui-text (benedict-chat-truncate text benedict-chat-max-block-length)
                 :face 'benedict-chat-thinking)))))

;;;; Tool call

(defun benedict-chat--format-arguments (arguments)
  "Return ARGUMENTS, a decoded plist, as a readable one-per-line string."
  (if (null arguments)
      ""
    (let ((lines nil)
          (rest arguments))
      (while rest
        (let ((key (pop rest))
              (value (pop rest)))
          (push (format "%s: %s"
                        (substring (symbol-name key) 1)
                        (if (stringp value) value (prin1-to-string value)))
                lines)))
      (string-join (nreverse lines) "\n"))))

(vui-defcomponent benedict-chat-tool-call-block (name arguments arguments-json status)
  "Render a tool invocation.

NAME is the tool symbol, ARGUMENTS the decoded plist, and ARGUMENTS-JSON
the raw partial JSON the kernel keeps on the block while it streams.
STATUS is `running', `done', `error', or nil.

ARGUMENTS-JSON is display state and is rendered verbatim, never parsed:
mid-stream it is by definition incomplete, and the adapter is what
guarantees the kernel only ever sees valid JSON once the block closes."
  :render
  (let ((body (if arguments
                  (benedict-chat--format-arguments arguments)
                (or arguments-json ""))))
    (vui-collapsible
     :title (format "%s %s"
                    (pcase status
                      ('running "⋯")
                      ('error "✗")
                      ('done "✓")
                      (_ "•"))
                    name)
     :title-face (if (eq status 'error) 'benedict-chat-error 'benedict-chat-tool)
     :initially-expanded nil
     (vui-text (benedict-chat-truncate body benedict-chat-max-block-length)))))

;;;; Tool result

(defun benedict-chat--result-text (content)
  "Return CONTENT, a tool result's payload, as a string.
CONTENT is a string, or a list of content blocks when the result carries
structure; anything else is printed rather than dropped."
  (cond
   ((stringp content) content)
   ((null content) "")
   ((listp content)
    (string-join
     (mapcar (lambda (block)
               (if (and (listp block) (benedict-block-text-p block))
                   (or (benedict-block-get block :text) "")
                 (prin1-to-string block)))
             content)
     "\n"))
   (t (prin1-to-string content))))

(vui-defcomponent benedict-chat-tool-result-block (name content error-p)
  "Render a tool result for NAME, collapsed by default.

CONTENT is the payload and ERROR-P selects the failure face.  There is no
status prop beyond ERROR-P because SPEC-001 gives a result no status
field: whether a call succeeded is exactly whether its result was flagged
an error."
  :render
  (let ((text (benedict-chat--result-text content)))
    (vui-collapsible
     :title (format "%s %s — %s"
                    (if error-p "✗" "→")
                    name
                    (benedict-chat-one-line
                     text benedict-chat-tool-result-summary-width))
     :title-face (if error-p 'benedict-chat-error 'benedict-chat-tool)
     :initially-expanded nil
     (vui-text (benedict-chat-truncate text benedict-chat-max-block-length)
               :face (and error-p 'benedict-chat-error)))))

;;;; Dispatch

(defun benedict-chat-block-vnode (block &optional status)
  "Return the vnode rendering BLOCK, with STATUS for a `tool-call'.

The result is a CONTENT vnode for a `text' block and a COMPONENT vnode
for the rest; `benedict-chat-block-streams-p' is the predicate that tells
callers which they are holding without re-dispatching on the type."
  (pcase (benedict-block-type block)
    ('text (benedict-chat-text-vnode block))
    ('image (benedict-chat-image-vnode block))
    ('thinking
     (vui-component 'benedict-chat-thinking-block
       :text (benedict-block-get block :thinking)
       :redacted (benedict-block-get block :redacted)))
    ('tool-call
     (vui-component 'benedict-chat-tool-call-block
       :name (benedict-block-get block :name)
       :arguments (benedict-block-get block :arguments)
       :arguments-json (benedict-block-get block :arguments-json)
       :status status))
    ('tool-result
     (vui-component 'benedict-chat-tool-result-block
       :name (benedict-block-get block :name)
       :content (benedict-block-get block :content)
       :error-p (benedict-block-get block :error-p)))
    (_ (vui-text (format "[unrenderable block: %s]"
                         (benedict-block-type block))
                 :face 'benedict-chat-badge))))

(defun benedict-chat-block-streams-p (block)
  "Return non-nil when BLOCK renders as a content vnode that can grow.

Such a block's stream node takes `vui-stream-append-to' and costs
O(delta) per token; every other block is a component row and is refreshed
with `vui-stream-update' instead."
  (eq (benedict-block-type block) 'text))

(provide 'benedict-chat-blocks)
;;; benedict-chat-blocks.el ends here
