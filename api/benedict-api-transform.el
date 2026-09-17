;;; benedict-api-transform.el --- Lowering canonical entries for a model  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; There is no conversion between wire formats.  Benedict never turns an
;; Anthropic-shaped message into an OpenAI-shaped one; there is exactly one
;; canonical representation -- the entry structs of `benedict-message' -- and
;; each API adapter lowers it into its own wire format at request time.  That is
;; what makes switching models mid-conversation cheap, and what keeps the cost
;; of adding an API O(1) rather than O(N) in the number of APIs that already
;; exist.
;;
;; Lowering has two steps, and keeping them separate is what makes the logic
;; testable: DEGRADE IN CANONICAL SPACE FIRST, THEN SERIALIZE.  This file is the
;; first step, shared by every adapter.  `benedict-api-lower' takes canonical
;; entries and returns canonical entries; only the serialization that follows it
;; is adapter-specific.  Nothing here builds JSON, and nothing here knows the
;; name of a single wire protocol.
;;
;; Two problems make the pass necessary:
;;
;; SIGNATURES ARE PROVIDER-OPAQUE.  A reasoning item id, a thinking signature, a
;; thought signature -- each is meaningful only to the model that issued it.  A
;; transcript may hold entries from four different models, so origin is compared
;; PER ENTRY (see `benedict-model-same-origin-p') and a foreign entry is rebuilt
;; without the protocol artifacts the new model did not issue.  The reasoning
;; itself is kept, as ordinary text; only the protocol is discarded.
;;
;; TRANSCRIPTS GO STRUCTURALLY INVALID.  An abort leaves a tool call with no
;; result.  An errored turn carries half-formed content that makes a provider
;; reject the whole request.  Tool call ids that one API mints routinely violate
;; another's constraints.  These are repaired here rather than in the kernel,
;; because the transcript is the real history and must keep them: it is the copy
;; sent to a provider that has to be well-formed, not the copy on disk.
;;
;; Do not add a hook to override the degradation rules.  The table is fixed on
;; purpose; see SPEC-001 D2.
;;
;; See SPEC-001 7.8.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'benedict-message)
(require 'benedict-provider)

;;;; Fixed vocabulary

(defconst benedict-api-image-placeholder
  "(image omitted: model does not support images)"
  "Text substituted for an image a model cannot accept.
Deliberately a constant rather than a user option: the degradation rules
are fixed, so that what a transcript lowers to is a property of the
transcript and the model rather than of a configuration.")

(defconst benedict-api-tool-image-placeholder
  "(tool image omitted: model does not support images)"
  "Text substituted for an image inside a tool result.
Distinct from `benedict-api-image-placeholder' so the model can tell an
image it was shown from one a tool produced.")

(defconst benedict-api-missing-tool-result "No result provided"
  "Content of the synthetic result standing in for an unanswered tool call.
A tool call with no matching result is invalid on every API, so one is
inserted rather than leaving the request to be rejected.")

(defconst benedict-api-incomplete-stop-reasons '(error aborted)
  "Stop reasons marking an assistant entry that must not be replayed.

Such an entry may carry partial content -- reasoning with no following
item, half-formed tool call arguments -- that causes provider errors on
replay.  The transcript keeps it, because it is real history and the UI
shows it; lowering omits it, and the model retries from the last valid
state.")

;;;; Notes

;; No wire protocol has a note role, so lowering is where notes stop existing.
;; A note that opted into provider context becomes a user entry: the mapping has
;; to happen somewhere, and doing it once here beats every adapter inventing the
;; same thing.  See SPEC-001 4.5 and 7.8.8.

(defun benedict-api-transform--notes (entries)
  "Return ENTRIES with note entries dropped or promoted to the user role.

A note carrying a non-nil `:context' in its metadata becomes a `user'
entry with its content intact, which is what makes \"remember X for the
rest of this session\" reach the model.  Every other note -- model-change
markers, UI markers, extension annotations -- is dropped."
  (delq nil
        (mapcar (lambda (entry)
                  (if (benedict-entry-note-p entry)
                      (when (benedict-entry-context-p entry)
                        (benedict-entry-with entry :role 'user))
                    entry))
                entries)))

;;;; Images

(defun benedict-api-transform--placeholders (blocks placeholder)
  "Return BLOCKS with every image block replaced by PLACEHOLDER text.

Consecutive placeholders collapse into one, counting a text block that
already reads exactly PLACEHOLDER, so a turn carrying ten screenshots
becomes one line of explanation rather than ten."
  (let ((result nil)
        (previous-placeholder nil))
    (dolist (block blocks (nreverse result))
      (if (benedict-block-image-p block)
          (unless previous-placeholder
            (push (benedict-block-text placeholder) result)
            (setq previous-placeholder t))
        (push block result)
        (setq previous-placeholder
              (and (benedict-block-text-p block)
                   (equal (plist-get block :text) placeholder)))))))

(defun benedict-api-transform--result-images (block)
  "Return BLOCK with images inside a tool result replaced by placeholders.

Only applies to a `tool-result' block whose payload is a list of content
blocks; a string payload has no images in it and is returned untouched."
  (let ((payload (plist-get block :content)))
    (if (not (and (benedict-block-tool-result-p block)
                  (consp payload)
                  (consp (car payload))))
        block
      (let ((lowered (benedict-api-transform--placeholders
                      payload benedict-api-tool-image-placeholder)))
        (if (equal lowered payload)
            block
          (plist-put (copy-sequence block) :content lowered))))))

(defun benedict-api-transform--images (entries model)
  "Return ENTRIES with images degraded for MODEL.
A no-op when MODEL accepts image input."
  (if (benedict-model-supports-p model 'image)
      entries
    (mapcar
     (lambda (entry)
       (let* ((content (benedict-entry-content entry))
              (lowered (mapcar #'benedict-api-transform--result-images
                               (benedict-api-transform--placeholders
                                content benedict-api-image-placeholder))))
         (if (equal lowered content)
             entry
           (benedict-entry-with entry :content lowered))))
     entries)))

;;;; Tool call identifiers

;; Each API constrains ids differently -- Anthropic wants ^[a-zA-Z0-9_-]+$ under
;; 64 characters, OpenAI Responses mints composite ids that run past 450 and
;; contain `|'.  Replaying one into the other requires a rewrite, and rewriting
;; a call id without rewriting its result produces an orphaned result and a
;; rejected request.  The map is collected first and applied second so that the
;; rewrite does not depend on a result following its call in the entry list.

(defun benedict-api-transform--tool-call-ids (entries model normalize)
  "Return a hash table mapping ENTRIES' tool call ids to normalized ones.

NORMALIZE is called with (ID MODEL ENTRY) and returns the id to use; an
unchanged id records no mapping.  Only foreign entries are normalized,
since a same-origin id is one the model itself minted.  Returns an empty
table when NORMALIZE is nil."
  (let ((map (make-hash-table :test #'equal)))
    (when normalize
      (dolist (entry entries)
        (when (and (benedict-entry-assistant-p entry)
                   (not (benedict-model-same-origin-p
                         model (benedict-entry-origin entry))))
          (dolist (block (benedict-entry-tool-calls entry))
            (let* ((id (plist-get block :id))
                   (normalized (funcall normalize id model entry)))
              (unless (equal id normalized)
                (puthash id normalized map)))))))
    map))

;;;; Degradation

(defun benedict-api-transform--block (block same-origin ids)
  "Return BLOCK lowered, or nil to drop it.

SAME-ORIGIN is non-nil when the entry holding BLOCK was produced by the
model being lowered for, in which case provider-opaque signatures may be
replayed verbatim.  IDS is the tool call id map.

The branch order is the rule: redacted thinking is dropped for a foreign
model because it is ciphertext only its issuer can decrypt, while
ordinary thinking becomes visible text because the reasoning still has
value and it is only the signature the new model cannot accept.  An empty
thinking block with a signature survives same-origin, since a provider
returning encrypted reasoning sends exactly that and dropping it breaks
replay continuity."
  (pcase block
    ((benedict-block thinking)
     (let ((text (plist-get block :thinking)))
       (cond
        ((plist-get block :redacted) (and same-origin block))
        ((and same-origin (plist-get block :signature)) block)
        ((or (null text) (string-blank-p text)) nil)
        (same-origin block)
        (t (benedict-block-text text)))))
    ((benedict-block text)
     (if same-origin block (benedict-block-text (plist-get block :text))))
    ((benedict-block tool-call)
     (if same-origin
         block
       (let ((id (plist-get block :id)))
         (benedict-block-tool-call (gethash id ids id)
                                   (plist-get block :name)
                                   (plist-get block :arguments)))))
    (_ block)))

(defun benedict-api-transform--entry (entry model ids)
  "Return ENTRY lowered for MODEL, rewriting tool call ids through IDS.

Returns ENTRY itself when nothing changed, so a same-origin transcript
costs no copying on a request."
  (let ((content (benedict-entry-content entry)))
    (cond
     ((benedict-entry-assistant-p entry)
      (let* ((same-origin (benedict-model-same-origin-p
                           model (benedict-entry-origin entry)))
             (lowered (delq nil
                            (mapcar (lambda (block)
                                      (benedict-api-transform--block
                                       block same-origin ids))
                                    content))))
        (if (equal lowered content)
            entry
          (benedict-entry-with entry :content lowered))))
     ((benedict-entry-tool-result-p entry)
      (let ((lowered (mapcar
                      (lambda (block)
                        (let ((new (and (benedict-block-tool-result-p block)
                                        (gethash (plist-get block :id) ids))))
                          (if new
                              (plist-put (copy-sequence block) :id new)
                            block)))
                      content)))
        (if (equal lowered content)
            entry
          (benedict-entry-with entry :content lowered))))
     (t entry))))

;;;; Structural repair

(defun benedict-api-transform--incomplete-p (entry)
  "Return non-nil when ENTRY is an assistant turn that must not be replayed.
See `benedict-api-incomplete-stop-reasons'."
  (and (benedict-entry-assistant-p entry)
       (memq (benedict-entry-meta-get entry :stop-reason)
             benedict-api-incomplete-stop-reasons)
       t))

(defun benedict-api-transform--live-call-ids (entries)
  "Return a hash table of the tool call ids in ENTRIES that survive lowering.

Computed in its own sweep so that deciding whether a result is orphaned
does not depend on where the result sits relative to its call."
  (let ((live (make-hash-table :test #'equal)))
    (dolist (entry entries live)
      (when (and (benedict-entry-assistant-p entry)
                 (not (benedict-api-transform--incomplete-p entry)))
        (dolist (block (benedict-entry-tool-calls entry))
          (puthash (plist-get block :id) t live))))))

(defun benedict-api-transform--synthetic-result (block)
  "Return a synthetic error result entry answering tool call BLOCK.
The entry carries no id or parent: it is not a transcript member and
exists only for the length of one request."
  (benedict-entry-create
   :role 'tool-result
   :content (list (benedict-block-tool-result
                   (plist-get block :id)
                   (plist-get block :name)
                   benedict-api-missing-tool-result
                   :error-p t))))

(defun benedict-api-transform--repair (entries)
  "Return ENTRIES with the states every API rejects repaired.

Errored and aborted assistant entries are omitted, tool calls left
unanswered gain synthetic error results, and results whose call did not
survive are dropped -- an orphaned result is rejected exactly as hard as
an orphaned call, so removing one without the other trades a broken
request for a different broken request."
  (let ((live (benedict-api-transform--live-call-ids entries))
        (seen (make-hash-table :test #'equal))
        (pending nil)
        (result nil))
    (cl-flet ((flush ()
                (dolist (block pending)
                  (unless (gethash (plist-get block :id) seen)
                    (push (benedict-api-transform--synthetic-result block)
                          result)))
                (setq pending nil)
                (clrhash seen)))
      (dolist (entry entries)
        (cond
         ((benedict-entry-assistant-p entry)
          (flush)
          (unless (benedict-api-transform--incomplete-p entry)
            (setq pending (benedict-entry-tool-calls entry))
            (push entry result)))
         ((benedict-entry-tool-result-p entry)
          (let ((ids (mapcar (lambda (block) (plist-get block :id))
                             (benedict-entry-tool-results entry))))
            (when (or (null ids)
                      (seq-some (lambda (id) (gethash id live)) ids))
              (dolist (id ids) (puthash id t seen))
              (push entry result))))
         (t
          (flush)
          (push entry result))))
      (flush))
    (nreverse result)))

;;;; The pass

;;;###autoload
(defun benedict-api-lower (entries model &optional normalize-tool-call-id)
  "Return ENTRIES lowered to canonical form for MODEL, ready to serialize.

This is the shared half of lowering, called by every API adapter before
it builds a wire payload.  It works canonical-to-canonical: the result is
a list of `benedict-entry' structs, not JSON.

NORMALIZE-TOOL-CALL-ID, when given, is called with (ID MODEL ENTRY) for
each tool call in a foreign entry and returns the id that API accepts;
returning ID unchanged means no rewrite.  Whatever it returns is applied
to the matching tool result as well, which is the point of routing it
through here rather than letting an adapter rewrite ids on its own.

The passes, in order:

  1. Notes are dropped, or promoted to `user' when context-flagged.
  2. Images become placeholder text when MODEL has no vision.
  3. Tool call ids are collected, then rewritten along with their results.
  4. Each entry is degraded against its own origin, so signatures are
     replayed only to the model that issued them.
  5. Errored and aborted turns are omitted, unanswered tool calls gain
     synthetic error results, and orphaned results are dropped.

ENTRIES is never modified.  Entries that needed no change are returned by
identity rather than copied, so the common same-origin request costs
nothing; changed and synthetic entries are fresh.  The result is detached
from any transcript -- synthetic entries have no id or parent -- and must
never be appended to one."
  (let* ((entries (benedict-api-transform--notes entries))
         (entries (benedict-api-transform--images entries model))
         (ids (benedict-api-transform--tool-call-ids
               entries model normalize-tool-call-id))
         (entries (mapcar (lambda (entry)
                            (benedict-api-transform--entry entry model ids))
                          entries)))
    (benedict-api-transform--repair entries)))

(provide 'benedict-api-transform)

;;; benedict-api-transform.el ends here
