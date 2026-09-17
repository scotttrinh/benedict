;;; benedict-chat.el --- Chat buffer frontend for Benedict  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;;; Commentary:

;; The chat frontend: a buffer, a mode, the commands, and the bridge from the
;; kernel's hooks to the buffer.  This is the only file in `ui/' that knows a
;; session exists.
;;
;; It is built entirely on SPEC-001 4.1 and 4.4 -- the published API and the
;; documented hooks -- which is Phase 5's actual exit criterion.  If something
;; here ever needs a private kernel accessor, that is a finding about the kernel
;; API and the API is what grows.
;;
;; THE BRIDGE.  The kernel emits `(SESSION ENTRY INDEX DELTA)' as a message
;; streams, and SPEC-001 4.3 asks a frontend to re-render the referenced block
;; rather than accumulate deltas itself.  `vui-stream' is how that is honoured:
;;
;;   entry-start   the streaming entry -> append its header, open no blocks yet
;;   entry-update  block INDEX -> `vui-stream-append-to' (O(delta)) for text,
;;                 `vui-stream-update' (O(block)) for a component row
;;   entry-end     retag the text blocks as markdown body -- they are whole
;;                 now, and only now -- then finalize every node of that
;;                 entry, releasing its markers
;;   head-change   a fork moved head -> rebuild the transcript wholesale
;;
;; A node per BLOCK, not per entry, because block indexes interleave: SPEC-001
;; 7.4.1 records adapters opening a `function_call' item while a `message' item
;; is still streaming.  Keying on INDEX makes that a lookup instead of a special
;; case, and `vui-stream-open' hands back a ref that stays valid "even as tool
;; cards and later messages land underneath".
;;
;; Finalizing at entry end is load-bearing, not tidiness: a live node holds
;; buffer markers, and every later append pays for every marker still live.
;; Finalizing bounds the live set by concurrency instead of by transcript length.
;;
;; WHAT DOES NOT HAPPEN HERE.  Nothing calls `vui-set-state', and nothing
;; re-renders the root after mount except a deliberate rebuild.  See
;; `benedict-chat-render' for why a root re-render is destructive to a live
;; stream.  Because the stream functions write to the buffer directly rather than
;; scheduling a render, they are safe to call from a kernel hook running on a
;; timer, with no `vui-async-callback' wrapper -- which is the bulk of the
;; complexity the pre-reset bridge carried.
;;
;; TWO WAYS TO DESTROY THIS BUFFER, both of which look innocent:
;;
;; - `vui-flush-sync' reads `vui--root-instance', which is BUFFER-LOCAL, so
;;   calling it inside a chat buffer forces a root re-render even though the
;;   name suggests it merely settles pending work.  Never call it here.  Nothing
;;   needs it: stream writes are synchronous, so the buffer is current as soon as
;;   a handler returns.
;;
;; - `vui-refresh', which `vui-mode' binds to \\`g', schedules the same root
;;   re-render.  `benedict-chat-mode-map' shadows it with
;;   `benedict-chat-revert'.
;;
;; Both cost the whole transcript AND silently drop every component row, which
;; is a rendering bug no assertion about buffer TEXT would catch -- the content
;; items are faithfully re-emitted.  That combination is how the pre-reset
;; frontend held a green suite while being unusable by hand.

;;; Code:

(require 'benedict)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-core)
(require 'benedict-retry)
(require 'vui)
(require 'benedict-chat-widgets)
(require 'benedict-chat-blocks)
(require 'benedict-chat-render)

;;;; Buffer-local state

(defvar-local benedict-chat--session nil
  "The `benedict-session' this buffer renders, or nil.")

(defvar-local benedict-chat--handle nil
  "The `vui-stream' handle owning this buffer's transcript region.")

(defvar-local benedict-chat--nodes nil
  "Hash table mapping a streaming entry to its block nodes.

Keyed on the entry OBJECT with `eq', because a streamed entry has no id
until it is appended -- `benedict-entry-start-functions' says so
explicitly.  Each value is itself a hash of block index to the
`vui-stream' node rendering that block.")

(defvar-local benedict-chat--active-tool nil
  "Name of the tool currently executing, for the header line.")

(defvar benedict-chat--buffers
  (make-hash-table :test 'eq :weakness 'key)
  "Weak map from session to the buffer rendering it.

Weak on the key so that attaching a buffer never keeps a finished session
alive.  Handlers installed globally consult this and no-op for sessions
that never opted in, which is what lets two sessions coexist in one image
without their renderers interfering.")

;;;; Attachment

(defun benedict-chat-buffer-for-session (session)
  "Return the buffer rendering SESSION, or nil when it has none or it died."
  (when-let* ((buffer (gethash session benedict-chat--buffers)))
    (and (buffer-live-p buffer) buffer)))

(defun benedict-chat-attach (session buffer)
  "Render SESSION into BUFFER from now on.  Return BUFFER."
  (puthash session buffer benedict-chat--buffers)
  buffer)

(defun benedict-chat-detach (session)
  "Stop rendering SESSION.  Return t when it had a buffer."
  (remhash session benedict-chat--buffers))

(defmacro benedict-chat--in-buffer (session &rest body)
  "Evaluate BODY in SESSION's chat buffer, or do nothing when it has none."
  (declare (indent 1) (debug (form body)))
  `(when-let* ((buffer (benedict-chat-buffer-for-session ,session)))
     (with-current-buffer buffer
       (let ((inhibit-read-only t))
         ,@body))))

;;;; Node bookkeeping

(defun benedict-chat--node-table (entry)
  "Return the block-index-to-node table for ENTRY, creating it if needed.
MUTATES `benedict-chat--nodes'."
  (or (gethash entry benedict-chat--nodes)
      (puthash entry (make-hash-table :test 'eql) benedict-chat--nodes)))

(defun benedict-chat--node (entry index)
  "Return the stream node rendering ENTRY's block at INDEX, or nil."
  (when-let* ((table (gethash entry benedict-chat--nodes)))
    (gethash index table)))

(defconst benedict-chat--header-index -1
  "Node-table key for a streamed entry's header.

The header is a live node rather than static text because two of the
things it displays are unknown while the entry streams: its branch
position needs an id, and ids are minted at append time, and its stop
reason is only decided when the stream terminates.  Rendering it once at
entry start would permanently show neither.")

;;;; Rendering entries into the stream

(defun benedict-chat--tool-status (session call-id)
  "Return `done', `error', or nil for the tool call CALL-ID in SESSION.

Derived by pairing on the call id rather than read off the block: a
`tool-call' block carries no status, and D12 gives every call its own
`tool-result' entry, so the result is where the outcome lives."
  (let ((status nil))
    (dolist (entry (benedict-session-path session) status)
      (dolist (block (benedict-entry-tool-results entry))
        (when (equal (benedict-block-get block :id) call-id)
          (setq status (if (benedict-block-get block :error-p) 'error 'done)))))))

(defun benedict-chat--block-vnode (session block)
  "Return the vnode for BLOCK, resolving a tool call's status against SESSION."
  (benedict-chat-block-vnode
   block
   (when (eq (benedict-block-type block) 'tool-call)
     (benedict-chat--tool-status session (benedict-block-get block :id)))))

(defun benedict-chat--append-entry (session entry)
  "Append ENTRY of SESSION to the stream complete, as static content.

For an entry that did not stream -- a user message, a tool result, a note
-- whose content is already whole when it reaches the buffer.  Nothing is
opened, so nothing needs finalizing."
  (vui-stream-append benedict-chat--handle
                     (benedict-chat-entry-header-vnode session entry))
  (dolist (block (benedict-entry-content entry))
    (vui-stream-append benedict-chat--handle
                       (benedict-chat--block-vnode session block))))

(defun benedict-chat--rebuild (session)
  "Rebuild this buffer's transcript from SESSION's current path.

MUTATES the buffer, the stream handle, and the node table.  Used when the
path changes wholesale -- a fork -- where there is no incremental answer
and a full rebuild is both correct and, being user-initiated, rare."
  (setq benedict-chat--handle (vui-make-stream "\n"))
  (clrhash benedict-chat--nodes)
  (vui-mount (vui-component 'benedict-chat-root :handle benedict-chat--handle)
             (buffer-name))
  (dolist (entry (benedict-session-path session))
    (benedict-chat--append-entry session entry)))

;;;; Hook handlers

(defun benedict-chat-on-entry-start (session entry)
  "Open ENTRY's region in SESSION's chat buffer.  Return nil.

Intended for `benedict-entry-start-functions', whose calling convention is
\(SESSION ENTRY) and whose return value is ignored.  Only a STREAMING
entry is opened here; every other kind is rendered whole at entry end,
because its content is already complete and rendering it twice would
merely flicker."
  (benedict-chat--in-buffer session
    (when (eq entry (benedict-session-streaming-entry session))
      (puthash benedict-chat--header-index
               (vui-stream-open benedict-chat--handle
                                (benedict-chat-entry-header-vnode session entry))
               (benedict-chat--node-table entry))))
  nil)

(defun benedict-chat-on-entry-update (session entry index delta)
  "Render ENTRY's block at INDEX after DELTA arrived.  Return nil.

Intended for `benedict-entry-update-functions', whose calling convention
is (SESSION ENTRY INDEX DELTA) and whose return value is ignored.  The
entry is already mutated, so the block is read from it rather than
reconstructed from DELTA -- except on the fast path, where DELTA is
exactly the text to append and appending it costs O(DELTA)."
  (benedict-chat--in-buffer session
    (when-let* ((blocks (benedict-entry-content entry))
                (block (nth index blocks)))
      (let ((table (benedict-chat--node-table entry))
            (node (benedict-chat--node entry index)))
        (cond
         ;; First sight of this block: open a node holding what it has so far.
         ((null node)
          (puthash index
                   (vui-stream-open
                    benedict-chat--handle
                    (if (benedict-chat-block-streams-p block)
                        (benedict-chat-streaming-text-vnode block)
                      (benedict-chat--block-vnode session block)))
                   table))
         ;; Growing text: append only the new characters.  This is the case
         ;; SPEC-001 4.3 is written for and the reason cost stays flat.
         ((and (benedict-chat-block-streams-p block)
               delta (not (string-empty-p delta)))
          (vui-stream-append-to node
                                (benedict-chat-streaming-delta-vnode delta)))
         ;; A component row: refresh the whole block.  A text block is not
         ;; refreshed here -- it is rewritten once at entry end, by
         ;; `benedict-chat--settle-text-blocks'.
         ((not (benedict-chat-block-streams-p block))
          (vui-stream-update node (benedict-chat--block-vnode session block)))))))
  nil)

(defun benedict-chat--settle-text-blocks (entry table)
  "Rewrite ENTRY's streamed text nodes in TABLE as finished markdown body.

MUTATES the buffer.  Text arrives untagged so that markdown fontification
never sees half a construct; this is the pass that tags each closed block
and hands it to font-lock, and there is exactly one of them per block.

Rewriting through `vui-stream-update' rather than retagging the text in
place keeps this on `vui-stream''s published API -- a node's bounds are
its own business -- and gets the invalidation for free: freshly inserted
text carries no `fontified' property, which is precisely the state that
asks jit-lock for a pass."
  (let ((blocks (benedict-entry-content entry)))
    (maphash
     (lambda (index node)
       (when (>= index 0)
         (when-let* ((block (nth index blocks)))
           (when (benedict-chat-block-streams-p block)
             (vui-stream-update node (benedict-chat-text-vnode block))))))
     table)))

(defun benedict-chat-on-entry-end (session entry)
  "Finish ENTRY in SESSION's chat buffer.  Return nil.

Intended for `benedict-entry-end-functions', whose calling convention is
\(SESSION ENTRY) and whose return value is ignored.  Finalizes the nodes a
streamed entry opened, releasing their markers so later appends stop
paying for them; renders any other entry whole, since this is the first
point at which it exists in the transcript."
  (benedict-chat--in-buffer session
    (if-let* ((table (gethash entry benedict-chat--nodes)))
        (progn
          ;; Redraw the header now that the entry has been appended: this is
          ;; the first moment it has an id to find its siblings by, and the
          ;; first moment its stop reason is decided.
          (when-let* ((header (gethash benedict-chat--header-index table)))
            (vui-stream-update header
                               (benedict-chat-entry-header-vnode session entry)))
          ;; Before finalizing, while the nodes can still be written: the
          ;; text blocks are whole now, so this is when their markdown is.
          (benedict-chat--settle-text-blocks entry table)
          (maphash (lambda (_index node) (vui-stream-finalize node)) table)
          (remhash entry benedict-chat--nodes))
      (benedict-chat--append-entry session entry))
    (benedict-chat--refresh-header session))
  nil)

(defun benedict-chat-on-head-change (session _old new)
  "Rebuild SESSION's chat buffer after head moved to NEW.  Return nil.

Intended for `benedict-head-change-functions', whose calling convention is
\(SESSION OLD-ID NEW-ID) and whose return value is ignored.  This fires
only for moves no other hook reports -- in practice a fork -- where the
whole rendered path has changed."
  (benedict-chat--in-buffer session
    (benedict-chat--rebuild session))
  nil)

(defun benedict-chat-on-state-change (session _old _new)
  "Redraw SESSION's header line for its new run state.  Return nil.

Intended for `benedict-state-change-functions', whose calling convention
is (SESSION OLD NEW) and whose return value is ignored."
  (benedict-chat--in-buffer session
    (benedict-chat--refresh-header session))
  nil)

(defun benedict-chat-on-tool-start (session invocation)
  "Note that INVOCATION is running, for SESSION's header line.  Return nil.

Intended for `benedict-tool-start-functions', whose calling convention is
\(SESSION INVOCATION) and whose return value is ignored."
  (benedict-chat--in-buffer session
    (setq benedict-chat--active-tool (benedict-invocation-name invocation))
    (benedict-chat--refresh-header session))
  nil)

(defun benedict-chat-on-tool-end (session _invocation _result)
  "Clear SESSION's running-tool note.  Return nil.

Intended for `benedict-tool-end-functions', whose calling convention is
\(SESSION INVOCATION RESULT) and whose return value is ignored."
  (benedict-chat--in-buffer session
    (setq benedict-chat--active-tool nil)
    (benedict-chat--refresh-header session))
  nil)

(defun benedict-chat--refresh-header (session)
  "Recompute the header line for SESSION in the current buffer."
  (setq header-line-format
        (concat (benedict-chat-header-line session)
                (when benedict-chat--active-tool
                  (format "  running %s" benedict-chat--active-tool))))
  (force-mode-line-update))

;;;; Installation

;;;###autoload
(defun benedict-chat-install ()
  "Subscribe the chat renderer to the kernel's hooks.  Return t.

Idempotent, because `add-hook' with a named function is: calling this
twice, or reloading this file, subscribes nothing twice.  Installation is
a command rather than a bare `add-hook' at load time so that requiring
this file to reach a face or a helper does not quietly subscribe the
caller to every session in the image; handlers no-op for any session with
no attached buffer."
  (add-hook 'benedict-entry-start-functions #'benedict-chat-on-entry-start)
  (add-hook 'benedict-entry-update-functions #'benedict-chat-on-entry-update)
  (add-hook 'benedict-entry-end-functions #'benedict-chat-on-entry-end)
  (add-hook 'benedict-head-change-functions #'benedict-chat-on-head-change)
  (add-hook 'benedict-state-change-functions #'benedict-chat-on-state-change)
  (add-hook 'benedict-tool-start-functions #'benedict-chat-on-tool-start)
  (add-hook 'benedict-tool-end-functions #'benedict-chat-on-tool-end)
  t)

(defun benedict-chat-uninstall ()
  "Unsubscribe the chat renderer from the kernel's hooks.  Return t.
Does not detach any session or kill any buffer."
  (remove-hook 'benedict-entry-start-functions #'benedict-chat-on-entry-start)
  (remove-hook 'benedict-entry-update-functions #'benedict-chat-on-entry-update)
  (remove-hook 'benedict-entry-end-functions #'benedict-chat-on-entry-end)
  (remove-hook 'benedict-head-change-functions #'benedict-chat-on-head-change)
  (remove-hook 'benedict-state-change-functions #'benedict-chat-on-state-change)
  (remove-hook 'benedict-tool-start-functions #'benedict-chat-on-tool-start)
  (remove-hook 'benedict-tool-end-functions #'benedict-chat-on-tool-end)
  t)

;;;; Commands

(defvar benedict-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-s") #'benedict-chat-send)
    (define-key map (kbd "C-c C-c") #'benedict-chat-abort)
    (define-key map (kbd "C-c C-r") #'benedict-chat-retry)
    (define-key map (kbd "C-c C-n") #'benedict-chat-next-sibling)
    (define-key map (kbd "C-c C-p") #'benedict-chat-previous-sibling)
    ;; Shadow `vui-refresh'.  Its idea of a refresh is a root re-render, which
    ;; for a stream-backed buffer erases everything and re-emits only the
    ;; content items -- every tool card and reasoning section would vanish.
    ;; `benedict-chat-revert' rebuilds from the transcript instead.
    (define-key map (kbd "g") #'benedict-chat-revert)
    map)
  "Keymap for `benedict-chat-mode', consulted ahead of `vui-mode-map'.")

(define-derived-mode benedict-chat-mode vui-mode "Benedict"
  "Major mode for a Benedict chat transcript.

The buffer is read-only: input goes through \\[benedict-chat-send], which
reads in the minibuffer.  Sending during a run is not an error -- the
kernel queues it as steering -- so one binding covers both cases."
  (setq-local word-wrap t)
  (setq-local truncate-lines nil)
  (benedict-chat-setup-markdown-fontification))

(defun benedict-chat--session-or-error ()
  "Return this buffer's session, or signal `benedict-session-error'."
  (or benedict-chat--session
      (signal 'benedict-session-error
              (list "Not a Benedict chat buffer" (current-buffer)))))

;;;###autoload
(defun benedict-chat-for-session (session)
  "Return a chat buffer rendering SESSION, creating and mounting it.

MUTATES the global session-to-buffer map.  Renders whatever the session's
transcript already holds, so this is also how a resumed session is
displayed."
  (let ((buffer (get-buffer-create (format "*benedict: %s*"
                                           (benedict-session-id session)))))
    (with-current-buffer buffer
      (benedict-chat-mode)
      (setq benedict-chat--session session)
      (setq benedict-chat--nodes (make-hash-table :test 'eq))
      (benedict-chat-attach session buffer)
      (let ((inhibit-read-only t))
        (benedict-chat--rebuild session))
      (benedict-chat--refresh-header session))
    buffer))

;;;###autoload
(defun benedict-chat-revert ()
  "Redraw this buffer from its session's current transcript path.

Bound to \\`g'.  Rebuilding from the transcript is the only correct way to
redraw a stream-backed buffer: `vui-refresh', which \\`g' would otherwise
run, re-renders the root, and a root re-render re-emits content items
while silently dropping every component row."
  (interactive)
  (let ((session (benedict-chat--session-or-error))
        (inhibit-read-only t))
    (benedict-chat--rebuild session)
    (benedict-chat--refresh-header session)))

;;;###autoload
(defun benedict-chat-send (text)
  "Submit TEXT to this buffer's session.

Interactively, reads TEXT in the minibuffer.  During a run the kernel
queues it as steering rather than starting a second run, so this is the
same command whether the agent is idle or working."
  (interactive (list (read-string "Benedict: ")))
  (let ((session (benedict-chat--session-or-error)))
    (unless (string-empty-p (string-trim text))
      (benedict-session-submit session text))))

;;;###autoload
(defun benedict-chat-abort ()
  "Abort this buffer's session.  Idempotent when it is already idle."
  (interactive)
  (benedict-session-abort (benedict-chat--session-or-error)))

;;;###autoload
(defun benedict-chat-retry ()
  "Retry this buffer's failed assistant attempt as a new visible run.

Bound to \\[benedict-chat-retry].  Signal `user-error' when the session is
active or its current head is not an errored assistant entry."
  (interactive)
  (benedict-retry-now (benedict-chat--session-or-error)))

(defun benedict-chat--cycle-sibling (step)
  "Move head to the sibling STEP positions from the entry at head.
STEP is 1 for the next sibling and -1 for the previous.  Wraps."
  (let* ((session (benedict-chat--session-or-error))
         (head (benedict-session-head session))
         (siblings (and head (benedict-session-siblings session head)))
         (ids (mapcar #'benedict-entry-id siblings)))
    (if (or (null ids) (< (length ids) 2))
        (message "No sibling branches here")
      (let* ((position (or (seq-position ids head) 0))
             (next (nth (mod (+ position step) (length ids)) ids)))
        (benedict-session-fork session next)
        (message "Branch %d/%d"
                 (1+ (mod (+ position step) (length ids)))
                 (length ids))))))

;;;###autoload
(defun benedict-chat-next-sibling ()
  "Move the session head to the next sibling branch.

Mutates the attached session's transcript head and signals
`benedict-session-error' when called outside a Benedict chat buffer."
  (interactive)
  (benedict-chat--cycle-sibling 1))

;;;###autoload
(defun benedict-chat-previous-sibling ()
  "Move the session head to the previous sibling branch.

Mutates the attached session's transcript head and signals
`benedict-session-error' when called outside a Benedict chat buffer."
  (interactive)
  (benedict-chat--cycle-sibling -1))

(provide 'benedict-chat)
;;; benedict-chat.el ends here
