;;; benedict-message.el --- Transcript entries, content blocks, and the tree  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The canonical data model.  Per SPEC-001 P4, these structures are the primary
;; contract: extensions and frontends couple to them more tightly than to any
;; function, so a change in struct shape is a breaking change while a new
;; function is not.
;;
;; Three things live here.
;;
;; `benedict-entry' is a transcript entry: an id, a parent id, a role, a list of
;; content blocks, a timestamp, and a metadata plist.  Entries are structs
;; because they are long-lived, carry identity, and benefit from typed
;; accessors.
;;
;; Content blocks are plists tagged by `:type', because they cross the JSON
;; boundary constantly and because frontends dispatch on their type in `pcase'.
;; See `benedict-block' for the pattern.
;;
;; `benedict-transcript' is the tree.  Every entry names its parent, so the
;; transcript is a tree stored as a flat append-only log with a `head' pointing
;; at the current tip.  Appending creates a child of head; forking moves head
;; somewhere earlier so the next append creates a sibling; materializing walks
;; head back to a root.  Nothing is ever rewritten, which is what makes
;; branching structurally free and durability trivial to guarantee.
;;
;; SPEC-001 3.2 assigns the tree accessors to this file while 4.1 lists them on
;; the session, and Phase 0 has no session yet.  The transcript here is
;; therefore session-independent; `benedict-session' will hold one in a slot and
;; delegate to it.
;;
;; See SPEC-001 4.5 and 5.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'benedict)

;;;; Errors

(define-error 'benedict-entry-error
  "Invalid Benedict transcript entry"
  'benedict-error)

(define-error 'benedict-transcript-error
  "Benedict transcript error"
  'benedict-error)

(define-error 'benedict-transcript-unknown-entry
  "No such entry in this Benedict transcript"
  'benedict-transcript-error)

(define-error 'benedict-transcript-broken-chain
  "Benedict transcript parent chain refers to a missing entry"
  'benedict-transcript-error)

(define-error 'benedict-transcript-cycle
  "Benedict transcript parent chain contains a cycle"
  'benedict-transcript-error)

;;;; Identity

;; SPEC-001 5.5 requires entry ids that are stable across restarts and unique
;; within a session, and specifies a counter plus the session id rather than
;; random UUIDs so that logs stay readable by hand.  It does not fix a format;
;; this one is filename-safe, sorts correctly, greps cleanly, and lets the
;; counter be recovered from an id by regexp -- so reloading a session restores
;; the counter without a sidecar record.

(defconst benedict-entry-id-regexp "\\`\\(.*\\)-e\\([0-9]+\\)\\'"
  "Regexp matching a Benedict entry id.
Group 1 is the session id and group 2 is the counter.  The session id
part is greedy so that a session id which itself contains \"-e\" still
splits at the final separator.")

(defun benedict-entry-mint-id (session-id counter)
  "Return the entry id for COUNTER within SESSION-ID.

Ids look like \"20260806T142530-a3f9-e0007\": the session id, the
separator \"-e\", and the counter zero-padded to four digits.  Counters
beyond 9999 simply grow wider, which breaks lexical sorting but not
uniqueness or parsing."
  (format "%s-e%04d" session-id counter))

(defun benedict-entry-id-counter (id)
  "Return the integer counter encoded in ID.
Return nil when ID was not minted by `benedict-entry-mint-id' -- for
instance a hand-written or imported id.  Such ids are perfectly usable;
they simply do not advance a transcript's counter."
  (when (and (stringp id) (string-match benedict-entry-id-regexp id))
    (string-to-number (match-string 2 id))))

(defun benedict-entry-id-session (id)
  "Return the session id encoded in ID, or nil when ID is not Benedict-minted."
  (when (and (stringp id) (string-match benedict-entry-id-regexp id))
    (match-string 1 id)))

(defun benedict-generate-session-id ()
  "Return a fresh session id, unique for practical purposes.

The form is \"YYYYMMDDTHHMMSS-XXXX\": a UTC timestamp plus four hex
characters derived from the process id and sub-second clock.  The random
part only has to separate two sessions started in the same second, so
this is deliberately not a UUID -- session ids appear in every entry id
and in log filenames, and stay readable."
  (format "%s-%s"
          (format-time-string "%Y%m%dT%H%M%S" nil t)
          (substring (md5 (format "%s-%s" (emacs-pid) (float-time))) 0 4)))

;;;; Content blocks

;; Blocks are plists rather than structs: they cross the JSON boundary on every
;; request and every frontend dispatches on `:type'.  See SPEC-001 4.5.
;;
;; Signatures are provider-opaque blobs -- an OpenAI reasoning item id, an
;; Anthropic thinking signature, a Google thought signature.  They are
;; meaningless to Benedict and must never be interpreted, only stored, replayed
;; to the model that issued them, and discarded for any other model.

(cl-defun benedict-block-text (text &key signature)
  "Return a text content block carrying TEXT.
SIGNATURE, when given, is the provider-opaque blob that accompanied this
block.  Omitted keys are absent from the returned plist rather than
present and nil, so blocks compare with `equal' the way you expect."
  (append (list :type 'text :text text)
          (when signature (list :signature signature))))

(cl-defun benedict-block-thinking (text &key signature redacted)
  "Return a thinking content block carrying TEXT.

SIGNATURE is the provider-opaque blob identifying this reasoning to the
model that produced it; replaying it is what preserves multi-turn
reasoning continuity.  REDACTED marks content the provider returned as
opaque ciphertext, which only the issuing model can decrypt -- such
blocks are dropped rather than converted when the transcript is lowered
for a different model.

TEXT may be empty when a provider returns a signature and no visible
reasoning; such blocks are still meaningful and must not be discarded."
  (append (list :type 'thinking :thinking text)
          (when signature (list :signature signature))
          (when redacted (list :redacted t))))

(defun benedict-block-image (data mime-type)
  "Return an image content block carrying DATA, a base64 string.
MIME-TYPE is a string such as \"image/png\"."
  (list :type 'image :data data :mime-type mime-type))

(cl-defun benedict-block-tool-call (id name arguments &key signature)
  "Return a tool-call content block.

ID is the provider's call identifier, NAME the tool symbol, and
ARGUMENTS the decoded argument plist -- adapters assemble and parse
partial argument JSON before emitting a block, so ARGUMENTS is always
complete and valid here.  SIGNATURE is the provider-opaque blob, if any."
  (append (list :type 'tool-call :id id :name name :arguments arguments)
          (when signature (list :signature signature))))

(cl-defun benedict-block-tool-result (id name content &key error-p)
  "Return a tool-result content block.
ID matches the tool-call block being answered and NAME its tool symbol.
CONTENT is the result payload.  ERROR-P marks a failed invocation; the
result is still a normal part of the transcript, since a model that
called a tool must always see what happened."
  (append (list :type 'tool-result :id id :name name :content content)
          (when error-p (list :error-p t))))

(defsubst benedict-block-type (block)
  "Return the type symbol of content BLOCK.
One of `text', `thinking', `image', `tool-call', or `tool-result'."
  (plist-get block :type))

(defun benedict-block-get (block key &optional default)
  "Return the value of KEY in content BLOCK, or DEFAULT when KEY is absent.
Distinguishes an absent key from one present with a nil value."
  (if (plist-member block key) (plist-get block key) default))

(defun benedict-block-of-type-p (block type)
  "Return non-nil when content BLOCK has type TYPE."
  (eq (benedict-block-type block) type))

(defun benedict-block-text-p (block)
  "Return non-nil when content BLOCK is a text block."
  (benedict-block-of-type-p block 'text))

(defun benedict-block-thinking-p (block)
  "Return non-nil when content BLOCK is a thinking block."
  (benedict-block-of-type-p block 'thinking))

(defun benedict-block-image-p (block)
  "Return non-nil when content BLOCK is an image block."
  (benedict-block-of-type-p block 'image))

(defun benedict-block-tool-call-p (block)
  "Return non-nil when content BLOCK is a tool-call block."
  (benedict-block-of-type-p block 'tool-call))

(defun benedict-block-tool-result-p (block)
  "Return non-nil when content BLOCK is a tool-result block."
  (benedict-block-of-type-p block 'tool-result))

(defun benedict-blocks-of-type (blocks type)
  "Return the members of BLOCKS whose type is TYPE, in order."
  (seq-filter (lambda (block) (benedict-block-of-type-p block type)) blocks))

(pcase-defmacro benedict-block (type &rest keys)
  "Match a Benedict content block of TYPE, destructuring KEYS.

KEYS is a sequence of keyword and pattern pairs; each keyword is looked
up in the block and matched against the pattern that follows it.  There
is no built-in `pcase' pattern for plists, and frontends dispatch on
block type constantly, so this is the intended way to do it:

  (pcase block
    ((benedict-block text :text s)            (insert s))
    ((benedict-block tool-call :name n :id i) (render-call n i))
    ((benedict-block thinking :redacted t)    (insert \"[redacted]\")))

TYPE is matched literally and must not be quoted."
  (let ((patterns (list '(pred listp)
                        `(app (lambda (block) (plist-get block :type)) ',type))))
    (while keys
      (let ((key (pop keys))
            (pattern (pop keys)))
        (push `(app (lambda (block) (plist-get block ,key)) ,pattern) patterns)))
    `(and ,@(nreverse patterns))))

;;;; Entries

(defconst benedict-entry-roles '(user assistant tool-result note)
  "The roles a `benedict-entry' may carry.

There is deliberately no `system' role: the system prompt is a property
of the session, not an entry in its transcript.

`note' is for entries that are part of the record but are not ordinarily
sent to a provider -- extension annotations, model-change markers, UI
markers, and evaluated forms that modified the running image.  A note may
opt into provider context; see `benedict-entry-context-p'.")

(cl-defstruct (benedict-entry (:constructor benedict-entry--create)
                              (:copier nil))
  "A canonical transcript entry.

Entries are never mutated once appended to a transcript: the canonical
representation is the single source of truth, and each provider lowers
it to that provider's wire format at request time.  Use
`benedict-entry-with' to derive a changed copy.

Construct with `benedict-entry-create', which validates the role and
normalizes content."
  (id nil
      :documentation "Unique string id, stable across restarts.
Assigned by `benedict-transcript-append' when nil.  See
`benedict-entry-mint-id' for the format.")
  (parent nil
          :documentation "Id of the preceding entry, or nil at a branch root.")
  (role nil
        :documentation "One of `benedict-entry-roles'.")
  (content nil
           :documentation "List of content-block plists.
See `benedict-block-text' and its siblings for the shapes, and
`benedict-block' for the matching pattern.")
  (timestamp nil
             :documentation "Creation time, as returned by `float-time'.")
  (meta nil
        :documentation "Property list of entry metadata.
Well-known keys: `:provider', `:api', and `:model' record which model
produced an assistant entry and are load-bearing rather than diagnostic,
since a transcript may mix entries from several models and each must be
lowered according to its own origin.  Also `:usage', `:stop-reason',
`:error-message', and `:context' (see `benedict-entry-context-p')."))

(defun benedict-entry-normalize-content (content)
  "Return CONTENT as a list of content blocks.

Accepts a list of blocks unchanged, wraps a single block plist in a
list, converts a bare string into a one-element list holding a text
block, and passes nil through.  This is what lets callers and tests
write :content \"hello\" instead of spelling out the block.

Signal `benedict-entry-error' when CONTENT is none of those."
  (cond
   ((null content) nil)
   ((stringp content) (list (benedict-block-text content)))
   ((and (consp content) (keywordp (car content))) (list content))
   ((consp content) content)
   (t (signal 'benedict-entry-error (list "Invalid entry content" content)))))

(cl-defun benedict-entry-create (&key id parent role content timestamp meta)
  "Return a new entry with ROLE and CONTENT.

ROLE must be one of `benedict-entry-roles'; anything else signals
`benedict-entry-error'.  CONTENT is passed through
`benedict-entry-normalize-content', so a bare string is accepted.

ID and PARENT are normally left nil and filled in by
`benedict-transcript-append'.  TIMESTAMP defaults to now.  META is a
plist; see the `benedict-entry-meta' accessor for well-known keys."
  (unless (memq role benedict-entry-roles)
    (signal 'benedict-entry-error (list "Unknown entry role" role)))
  (benedict-entry--create
   :id id
   :parent parent
   :role role
   :content (benedict-entry-normalize-content content)
   :timestamp (or timestamp (float-time))
   :meta meta))

(cl-defun benedict-entry-with (entry &key (id nil id-p) (parent nil parent-p)
                                     (role nil role-p) (content nil content-p)
                                     (timestamp nil timestamp-p) (meta nil meta-p))
  "Return a new entry derived from ENTRY with the given slots replaced.

Does not modify ENTRY.  ID, PARENT, ROLE, CONTENT, TIMESTAMP, and META
each replace the corresponding slot when supplied, including when
supplied as nil.  Slots that are not supplied are carried over, and
carried-over CONTENT and META are copied with `copy-tree' so the result
shares no mutable structure with ENTRY.

This is the replacement for the struct copier, which is deliberately
suppressed: entries carry identity, so a shallow copy that silently
shares content with the original is almost always a bug.  Rebuilding an
entry with degraded content for a foreign model is exactly
\(benedict-entry-with entry :content degraded)."
  (benedict-entry-create
   :id (if id-p id (benedict-entry-id entry))
   :parent (if parent-p parent (benedict-entry-parent entry))
   :role (if role-p role (benedict-entry-role entry))
   :content (if content-p content (copy-tree (benedict-entry-content entry)))
   :timestamp (if timestamp-p timestamp (benedict-entry-timestamp entry))
   :meta (if meta-p meta (copy-tree (benedict-entry-meta entry)))))

(defun benedict-entry-user-p (entry)
  "Return non-nil when ENTRY has the `user' role."
  (eq (benedict-entry-role entry) 'user))

(defun benedict-entry-assistant-p (entry)
  "Return non-nil when ENTRY has the `assistant' role."
  (eq (benedict-entry-role entry) 'assistant))

(defun benedict-entry-tool-result-p (entry)
  "Return non-nil when ENTRY has the `tool-result' role."
  (eq (benedict-entry-role entry) 'tool-result))

(defun benedict-entry-note-p (entry)
  "Return non-nil when ENTRY has the `note' role."
  (eq (benedict-entry-role entry) 'note))

;;;; Entry metadata

(defun benedict-entry-meta-get (entry key &optional default)
  "Return the value of KEY in ENTRY's metadata, or DEFAULT when absent."
  (let ((meta (benedict-entry-meta entry)))
    (if (plist-member meta key) (plist-get meta key) default)))

(defun benedict-entry-meta-member (entry key)
  "Return non-nil when KEY is present in ENTRY's metadata.
Use this to tell a key that is absent from one whose value is nil."
  (and (plist-member (benedict-entry-meta entry) key) t))

(defun benedict-entry-meta-put (entry key value)
  "Set KEY to VALUE in ENTRY's metadata and return ENTRY.

Modifies ENTRY in place.  Valid only before ENTRY has been appended to a
transcript: appended entries are canonical and are never mutated.  The
kernel's one legitimate use is the streaming entry, which is not yet
appended.  Everywhere else use `benedict-entry-with-meta'."
  (setf (benedict-entry-meta entry)
        (plist-put (benedict-entry-meta entry) key value))
  entry)

(defun benedict-entry-with-meta (entry &rest keys-and-values)
  "Return a copy of ENTRY with KEYS-AND-VALUES merged into its metadata.

Does not modify ENTRY.  KEYS-AND-VALUES is a plist; an odd number of
arguments signals `benedict-entry-error'.  Merging is shallow: a value
carried over from ENTRY is shared with it, so do not modify one in place."
  (when (cl-oddp (length keys-and-values))
    (signal 'benedict-entry-error
            (list "Odd number of metadata arguments" keys-and-values)))
  (let ((meta (copy-sequence (benedict-entry-meta entry))))
    (while keys-and-values
      (setq meta (plist-put meta (pop keys-and-values) (pop keys-and-values))))
    (benedict-entry-with entry :meta meta)))

(defun benedict-entry-origin (entry)
  "Return the provider, API, and model that produced ENTRY, as a plist.

The plist has keys `:provider', `:api', and `:model'.  Origin decides how
an entry is lowered to the wire: a transcript may hold entries from
several models, and each is lowered according to its own origin rather
than the conversation's current model, so signatures are only ever
replayed to the model that issued them."
  (list :provider (benedict-entry-meta-get entry :provider)
        :api (benedict-entry-meta-get entry :api)
        :model (benedict-entry-meta-get entry :model)))

(defun benedict-entry-context-p (entry)
  "Return non-nil when ENTRY should be included in provider context.

Entries with an ordinary role always are.  Note entries are not, unless
their metadata carries a non-nil `:context', which is what makes durable
instructions like \"remember X for the rest of this session\" possible."
  (if (benedict-entry-note-p entry)
      (and (benedict-entry-meta-get entry :context) t)
    t))

;;;; Entry content

(defun benedict-entry-text (entry)
  "Return ENTRY's text blocks concatenated into a single string.
Returns the empty string when ENTRY has no text blocks.  Thinking blocks
are not text blocks and are not included."
  (mapconcat (lambda (block) (or (plist-get block :text) ""))
             (benedict-blocks-of-type (benedict-entry-content entry) 'text)
             ""))

(defun benedict-entry-tool-calls (entry)
  "Return ENTRY's tool-call content blocks, in order."
  (benedict-blocks-of-type (benedict-entry-content entry) 'tool-call))

(defun benedict-entry-tool-results (entry)
  "Return ENTRY's tool-result content blocks, in order."
  (benedict-blocks-of-type (benedict-entry-content entry) 'tool-result))

;;;; The transcript tree

(cl-defstruct (benedict-transcript (:constructor benedict-transcript-create)
                                   (:copier nil))
  "A tree of `benedict-entry' objects, stored as a flat append-only log.

Every entry names its parent, so the tree needs no nested structure: a
conversation is materialized by walking `head' back to a root.  Appending
creates a child of head; `benedict-transcript-fork' moves head somewhere
earlier so the next append creates a sibling instead.  Nothing is ever
rewritten or removed, which is what makes branching free and what lets
non-destructive compaction be expressed as a fork.

This struct is session-independent so that it can be built and tested
without a session; `benedict-session' holds one and delegates to it."
  (session-id (benedict-generate-session-id)
              :documentation "String used to mint entry ids.")
  (table (make-hash-table :test #'equal)
         :documentation "Hash table mapping entry id to `benedict-entry'.")
  (kids (make-hash-table :test #'equal)
        :documentation "Hash table mapping parent id to child ids, in append order.
The nil key holds the transcript's root entries.")
  (order nil
         :documentation "All entry ids in append order, reversed.
Present because hash-table iteration order is not a guaranteed API and
callers need a deterministic sequence.  Read it through
`benedict-transcript-entries'.")
  (head nil
        :documentation "Id of the current tip, or nil for an empty transcript.")
  (counter 0
           :documentation "Highest entry counter minted so far.
Restored on load from the ids themselves; see `benedict-entry-id-counter'."))

(defun benedict-transcript--index (transcript entry)
  "Record ENTRY in TRANSCRIPT's tables.  Return ENTRY.

Signal `benedict-entry-error' when ENTRY has no id or its id is already
present, and `benedict-transcript-broken-chain' when its parent is not
already in TRANSCRIPT."
  (let ((id (benedict-entry-id entry))
        (parent (benedict-entry-parent entry)))
    (unless id
      (signal 'benedict-entry-error (list "Entry has no id" entry)))
    (when (gethash id (benedict-transcript-table transcript))
      (signal 'benedict-entry-error (list "Duplicate entry id" id)))
    (when (and parent (not (gethash parent (benedict-transcript-table transcript))))
      (signal 'benedict-transcript-broken-chain (list "Unknown parent" parent id)))
    (puthash id entry (benedict-transcript-table transcript))
    (puthash parent
             (append (gethash parent (benedict-transcript-kids transcript)) (list id))
             (benedict-transcript-kids transcript))
    (push id (benedict-transcript-order transcript))
    entry))

(defun benedict-transcript--absorb-counter (transcript id)
  "Advance TRANSCRIPT's counter to cover ID, if ID encodes a larger one."
  (setf (benedict-transcript-counter transcript)
        (max (benedict-transcript-counter transcript)
             (or (benedict-entry-id-counter id) 0))))

(defun benedict-transcript-append (transcript entry)
  "Append ENTRY to TRANSCRIPT at its head and return ENTRY.

Modifies ENTRY in place, filling in its id and parent, and moves
TRANSCRIPT's head to it.

ENTRY's id is minted when nil and honored otherwise.  ENTRY's parent is
set to the current head when nil and honored otherwise -- so to start a
new root branch while head is non-nil, first call
\(benedict-transcript-fork TRANSCRIPT nil).

Signal `benedict-entry-error' on a duplicate id and
`benedict-transcript-broken-chain' when an explicitly-set parent is not
in TRANSCRIPT.

Note that ids come from a transcript-wide counter, so after forking to an
early entry the next id continues from the highest minted so far rather
than from the fork point.  That is what keeps ids unique, but it does
mean ids are not contiguous along any single branch."
  (let ((id (benedict-entry-id entry)))
    (if id
        (benedict-transcript--absorb-counter transcript id)
      (setf (benedict-entry-id entry)
            (benedict-entry-mint-id
             (benedict-transcript-session-id transcript)
             (cl-incf (benedict-transcript-counter transcript))))))
  (unless (benedict-entry-parent entry)
    (setf (benedict-entry-parent entry) (benedict-transcript-head transcript)))
  (benedict-transcript--index transcript entry)
  (setf (benedict-transcript-head transcript) (benedict-entry-id entry))
  entry)

(defun benedict-transcript-insert (transcript entry)
  "Record ENTRY in TRANSCRIPT without moving head.  Return ENTRY.

This is the load path.  ENTRY must already carry an id, which advances
TRANSCRIPT's counter if it encodes a larger one.  Head is left alone
because a log replays head separately -- a session that ended on a fork
has a head that is not its last entry.

Use `benedict-transcript-append' to add an entry to a live conversation."
  (let ((id (benedict-entry-id entry)))
    (unless id
      (signal 'benedict-entry-error (list "Entry has no id" entry)))
    (benedict-transcript--absorb-counter transcript id)
    (benedict-transcript--index transcript entry)))

(defun benedict-transcript-entry (transcript id)
  "Return the entry in TRANSCRIPT with ID, or nil when there is none."
  (gethash id (benedict-transcript-table transcript)))

(defun benedict-transcript-children (transcript id)
  "Return the entries in TRANSCRIPT whose parent is ID, in append order.
ID may be nil, which returns TRANSCRIPT's root entries."
  (mapcar (lambda (child-id) (benedict-transcript-entry transcript child-id))
          (gethash id (benedict-transcript-kids transcript))))

(defun benedict-transcript-siblings (transcript id)
  "Return the entry with ID in TRANSCRIPT together with its siblings.

The result is in append order and includes ID's own entry, so a renderer
showing \"2 of 3\" can take its position and count directly from it.
Signal `benedict-transcript-unknown-entry' when ID is not in TRANSCRIPT."
  (let ((entry (benedict-transcript-entry transcript id)))
    (unless entry
      (signal 'benedict-transcript-unknown-entry (list id)))
    (benedict-transcript-children transcript (benedict-entry-parent entry))))

(defun benedict-transcript-fork (transcript id)
  "Move TRANSCRIPT's head to ID and return ID.

The next append then creates a sibling of ID's existing children rather
than extending the current branch.  Nothing is removed: the abandoned
branch stays in the transcript and stays renderable.

ID may be nil, which makes the next append a new root.  Signal
`benedict-transcript-unknown-entry' when ID is not in TRANSCRIPT."
  (when (and id (not (benedict-transcript-entry transcript id)))
    (signal 'benedict-transcript-unknown-entry (list id)))
  (setf (benedict-transcript-head transcript) id))

(defun benedict-transcript-path (transcript &optional id)
  "Return the entries from a root down to ID in TRANSCRIPT, root first.

ID defaults to TRANSCRIPT's head, so with no ID this returns the current
conversation.  Returns nil for an empty transcript.

Signal `benedict-transcript-unknown-entry' when ID itself is absent,
`benedict-transcript-broken-chain' when some ancestor is, and
`benedict-transcript-cycle' when the parent chain revisits an entry --
which can only happen in a hand-edited or corrupted log, and is worth an
error rather than an infinite loop inside a renderer."
  (let ((id (or id (benedict-transcript-head transcript)))
        (seen (make-hash-table :test #'equal))
        (path nil))
    (while id
      (when (gethash id seen)
        (signal 'benedict-transcript-cycle (list id)))
      (puthash id t seen)
      (let ((entry (benedict-transcript-entry transcript id)))
        (unless entry
          (signal (if path
                      'benedict-transcript-broken-chain
                    'benedict-transcript-unknown-entry)
                  (list id)))
        (push entry path)
        (setq id (benedict-entry-parent entry))))
    path))

(defun benedict-transcript-entries (transcript)
  "Return every entry in TRANSCRIPT, in append order.
This is the whole tree, not a single branch; see
`benedict-transcript-path' for a conversation."
  (mapcar (lambda (id) (benedict-transcript-entry transcript id))
          (reverse (benedict-transcript-order transcript))))

(defun benedict-transcript-count (transcript)
  "Return the number of entries in TRANSCRIPT."
  (hash-table-count (benedict-transcript-table transcript)))

(defun benedict-transcript-equal-p (a b)
  "Return non-nil when transcripts A and B hold the same entries and head.

Compares entries in append order, and head.  Ignores the child index,
which is derived, and the counter, which is worth asserting separately.

This exists because `equal' on the struct itself is always nil: two hash
tables are never `equal', however identical their contents."
  (and (equal (benedict-transcript-head a) (benedict-transcript-head b))
       (equal (benedict-transcript-entries a) (benedict-transcript-entries b))))

(provide 'benedict-message)

;;; benedict-message.el ends here
