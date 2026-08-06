;;; benedict-session.el --- Sessions, hooks, and hook scoping  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A session is one conversation: a transcript, the model it is talking to, the
;; tools it may call, its queues, and its hooks.  It is the thing every hook
;; receives and every extension scopes itself to.
;;
;; The hook variables of SPEC-001 4.4 are defined here rather than in
;; `benedict-core' -- a refinement of the module map in 3.2, made because every
;; hook is scoped by a session and the scoping mechanism is this file's.
;; Putting the variables with the reducer that fires them would mean the session
;; could not announce a fork without requiring the reducer, and the reducer
;; already requires the session.  Firing a hook is not owning it.  Nothing is
;; lost for a reader: SPEC-001 10.2 makes `apropos' on "benedict-.*-functions"
;; the way these are found, and it does not care which file they live in.
;;
;; Two scoping mechanisms, because one image holds several sessions and a
;; project-local extension loaded for one project must not intercept tool calls
;; in another:
;;
;;   - Session-local hook lists.  Every hook run concatenates the global list
;;     and the session's own, global first at equal depth.
;;   - `benedict-current-session', bound around every hook invocation, so a
;;     GLOBALLY registered function can discriminate without every extension
;;     author being forced to thread a session argument.
;;
;; Buffer-local hooks are the tempting Emacs-native answer and are wrong here:
;; headless sessions have no buffer, and binding the correct buffer around every
;; asynchronous dispatch is fragile.
;;
;; See SPEC-001 4.1, 4.4, and 4.4.1.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'benedict)
(require 'benedict-message)
(require 'benedict-tool)
(require 'benedict-provider)

;;;; Errors

(define-error 'benedict-session-error
  "Benedict session error"
  'benedict-error)

;;;; The current session

(defvar benedict-current-session nil
  "The session whose hook is currently running, or nil outside a hook.

Bound dynamically around every hook, filter, and dispatch-chain
invocation.  Observation hooks already receive their session as the first
argument; this variable exists for the transform and dispatch chains,
whose signatures are shaped by the value they operate on rather than by
the session, and for globally registered functions that need to
discriminate between coexisting sessions:

  (defun my-approvals--dispatch (invocation next)
    (if (benedict-session-get benedict-current-session :trusted)
        (funcall next invocation)
      (my-approvals--confirm invocation next)))

Do not set this.  Bind it only if you are implementing a hook runner.")

;;;; Hooks -- observation

;; Run with every function called and every return value ignored.

(defvar benedict-run-start-functions nil
  "Functions called when a run begins, with one argument, the session.
A run is the sequence of turns from a submit until the session returns to
the `idle' state.  Return values are ignored.")

(defvar benedict-run-end-functions nil
  "Functions called when a run ends, with one argument, the session.
Fires once the session has returned to `idle', whether the run finished,
was vetoed, errored, or was aborted; read `benedict-session-stop-reason'
to tell those apart.  Return values are ignored.")

(defvar benedict-turn-start-functions nil
  "Functions called when a turn begins, with one argument, the session.
A turn is one assistant message plus the tool results it produced.
Return values are ignored.")

(defvar benedict-turn-end-functions nil
  "Functions called when a turn ends, with (SESSION ENTRY RESULTS).

ENTRY is the assistant entry that turn produced.  RESULTS is the list of
`benedict-tool-result-value' objects its tool calls returned, in call
order, and is nil for a turn that called no tools.  Return values are
ignored.")

(defvar benedict-entry-start-functions nil
  "Functions called when an entry begins, with (SESSION ENTRY).

For a streamed assistant entry this fires when the stream opens, before
any content has arrived and BEFORE THE ENTRY HAS AN ID -- it is not
appended to the transcript until the stream terminates.  Key on the entry
object's identity rather than on its id.  For every other kind of entry
this fires immediately before it is appended.  Return values are
ignored.")

(defvar benedict-entry-update-functions nil
  "Functions called as a streamed entry grows, with (SESSION ENTRY INDEX DELTA).

INDEX is the position of the content block that changed and DELTA is the
text just added to it.  The entry has already been mutated, so a renderer
re-renders block INDEX from the entry rather than accumulating DELTA
itself.  Return values are ignored.")

(defvar benedict-entry-end-functions nil
  "Functions called when an entry is complete, with (SESSION ENTRY).

Fires after the entry has been appended to the transcript, so it has an
id and the transcript head points at it.  This is the durability hook:
the store subscribes here.  A failed or aborted stream still produces a
terminal entry and still fires this, so a turn is never silently lost.
Return values are ignored.")

(defvar benedict-head-change-functions nil
  "Functions called when the transcript head moves, with (SESSION OLD-ID NEW-ID).

Fires only for moves that no other hook reports -- in practice, forks.
An append moves head too, but `benedict-entry-end-functions' already
covers that case.  Two subscribers need this and neither is served by the
entry hooks: the store must write a head marker or a session that ends on
a fork reloads on the wrong branch, and a renderer must redraw its branch
affordance.  Return values are ignored.")

(defvar benedict-tool-start-functions nil
  "Functions called before a tool call is dispatched, with (SESSION INVOCATION).

Fires before `benedict-tool-dispatch-functions', so an audit or budget
observer sees every call including ones a filter goes on to deny.  Return
values are ignored; to block a call, write a dispatch filter.")

(defvar benedict-tool-end-functions nil
  "Functions called when a tool call finishes, with (SESSION INVOCATION RESULT).

INVOCATION is the possibly-rewritten invocation that actually ran and
RESULT is its `benedict-tool-result-value', including results
manufactured for a denied or unknown tool.  Return values are ignored.")

(defvar benedict-state-change-functions nil
  "Functions called on every run-state transition, with (SESSION OLD NEW).

OLD and NEW are the state symbols `idle', `provider-wait',
`tool-dispatch', `tool-wait', and `stopping'.  Return values are
ignored.")

;;;; Hooks -- veto

(defvar benedict-continue-predicate-functions nil
  "Functions asked whether a run should stop, with one argument, the session.

Called at every turn boundary.  The FIRST NON-NIL return value wins and
stops the run after this turn; its value is recorded as the session's
stop reason, so return a string or symbol explaining why rather than a
bare t.  Returning nil means \"no opinion\", not \"keep going\".

A veto does not discard queued input: a steering or follow-up message
still continues the run, because a human's queued message outranks a
budget filter.")

;;;; Hooks -- transform

;; Filter chains.  Each function takes the value being transformed as its first
;; argument and returns a replacement.  A function that returns nil returns nil;
;; there is no "no opinion" convention here, so a filter that declines to act
;; must return its input unchanged.

(defvar benedict-context-filter-functions nil
  "Functions that transform the entries sent to a provider, as (ENTRIES SESSION).

Each returns a replacement list of canonical `benedict-entry' objects and
is passed the previous function's output.  This is where compaction,
injection, and pruning live.  It operates on canonical entries only --
lowering them to a wire format happens later and belongs to the API
adapter, and conflating the two is the mistake this separation exists to
prevent.

The transcript itself is not modified; this shapes one request.")

(defvar benedict-request-filter-functions nil
  "Functions that transform an outgoing request, as (REQUEST MODEL SESSION).

Each returns a replacement request plist and is passed the previous
function's output.  REQUEST is the canonical plist described by
`benedict-provider-stream', not a wire payload.")

(defvar benedict-tool-result-filter-functions nil
  "Functions that transform a tool result, as (RESULT INVOCATION).

Each returns a replacement `benedict-tool-result-value' and is passed the
previous function's output.  Truncation, redaction, and result
summarizing live here.")

;;;; Hooks -- asynchronous intercept

(defvar benedict-tool-dispatch-functions nil
  "Filter chain around tool dispatch, each function taking (INVOCATION NEXT).

This is the load-bearing hook: approval, permission policy, path
protection, sandbox routing, and worker delegation are all this one
mechanism.  A member may

  allow             (funcall next invocation)
  modify and allow  (funcall next (benedict-invocation-with invocation ...))
  deny              (funcall next (benedict-tool-blocked invocation \"reason\"))
  reroute           (funcall next (benedict-tool-retarget invocation \\='sandbox))
  suspend           hold NEXT and call it later, from a callback

A suspended run is simply one whose continuation has not been called yet.
There is no separate yield concept, no approval state in the kernel, and
no resume entry point.  NEXT must be called exactly once, eventually, or
the run waits forever.

Return values are ignored -- the chain advances through NEXT.  The
session is available as `benedict-current-session'.  Order matters: by
convention approval filters take depth 0, routing filters depth 90, and
observation-only wrappers depth -90.")

;;;; The session

(defconst benedict-session-states
  '(idle provider-wait tool-dispatch tool-wait stopping)
  "The run states a session may be in.

  `idle'           no active run
  `provider-wait'  request in flight, stream events arriving
  `tool-dispatch'  tool calls passing through the dispatch filter chain
  `tool-wait'      a tool is outstanding: executing, or suspended on approval
  `stopping'       abort requested, draining outstanding work

See SPEC-001 4.2 for the transitions.")

(cl-defstruct (benedict-session (:constructor benedict-session--create)
                                (:copier nil))
  "One conversation, with its transcript, configuration, and hooks.

Create with `benedict-session-create'.  The struct is the primary
contract for frontends and extensions, so its shape changes are breaking
changes while added functions are not."
  (id nil
      :documentation "String identifying this session.
Shared with the transcript, so entry ids and the log filename all derive
from it.")
  (transcript nil
              :documentation "The `benedict-transcript' holding this conversation.
Session-independent by design, so it can be built, forked, and
serialized with no session at all.  Reach it through the delegating
accessors -- `benedict-session-head', `benedict-session-path',
`benedict-session-entry', `benedict-session-children',
`benedict-session-fork' -- rather than through this slot, which does not
announce head movement.")
  (state 'idle
         :documentation "Current run state, one of `benedict-session-states'.")
  (system-prompt nil
                 :documentation "Instructions sent with every request.
A property of the session rather than an entry in its transcript: it is
not part of the branching history and is not produced by a turn, so
giving it an entry would make every consumer special-case the first one.")
  (model nil
         :documentation "The `benedict-model' this session currently talks to.
Changing it mid-conversation is a first-class operation -- it is how
\"retry with a stronger model\" works -- and the transcript survives it,
because each entry records its own origin and is lowered accordingly.")
  (tools nil
         :documentation "List of `benedict-tool' objects offered to the model.")
  (store nil
         :documentation "Opaque handle on this session's persistence, or nil.

The kernel keeps it in this slot so that an extension can find a
session's store without a registry, and NEVER CALLS ANYTHING ON IT.
Persistence happens entirely through `benedict-entry-end-functions' and
`benedict-head-change-functions', which is why the store lives outside
the kernel.")
  (steer-queue nil
               :documentation "Content queued for injection at the next turn boundary.
FIFO.  Append with `benedict-session-steer'.")
  (follow-up-queue nil
                   :documentation "Content queued for after the run would otherwise stop.
FIFO.  Append with `benedict-session-follow-up'.")
  (stop-reason nil
               :documentation "Why the last run ended: nil, `error', `aborted',
or the value a continue predicate returned.")
  (run nil
       :documentation "Reducer bookkeeping for the run in flight, or nil.
Opaque here; `benedict-core' defines its shape and reads it.")
  (hooks nil
         :documentation "Alist of hook symbol to this session's own entries.
Manage with `benedict-session-add-hook' and
`benedict-session-remove-hook'; read with
`benedict-session-hook-functions'.")
  (properties nil
              :documentation "Property list of extension-defined session state.
Read and write with `benedict-session-get' and `benedict-session-put'.
The kernel does not interpret it."))

(cl-defun benedict-session-create (&key id system-prompt model provider tools
                                        store transcript)
  "Return a new session.

MODEL is a `benedict-model' or a \"PROVIDER-ID/MODEL-ID\" string resolved
through `benedict-model-resolve'.  PROVIDER, when given, is the provider
id used as the prefix for a MODEL string that has none, so a caller
holding the two separately need not concatenate them.

TOOLS is a list of tool ids and `benedict-tool' objects, resolved through
`benedict-tool-resolve'.  SYSTEM-PROMPT is the instruction text sent with
every request.  STORE is an opaque persistence handle the kernel never
calls into.

TRANSCRIPT adopts an existing `benedict-transcript' -- this is how a
session is resumed from a log -- and its session id then wins over ID, so
that entries appended after the reload keep being minted from the same
id.  With no TRANSCRIPT an empty one is created.

Signal `benedict-model-unknown' or `benedict-provider-unknown' when MODEL
cannot be resolved, and `benedict-tool-unknown' for an unregistered tool
id."
  (let* ((transcript (or transcript
                         (benedict-transcript-create
                          :session-id (or id (benedict-generate-session-id)))))
         (id (benedict-transcript-session-id transcript)))
    (benedict-session--create
     :id id
     :transcript transcript
     :state 'idle
     :system-prompt system-prompt
     :model (benedict-session--resolve-model model provider)
     :tools (benedict-tool-resolve tools)
     :store store)))

(defun benedict-session--resolve-model (model provider)
  "Return the `benedict-model' MODEL names, prefixing with PROVIDER if needed.
Returns nil when MODEL is nil, so a session may be created before a model
is chosen."
  (cond
   ((null model) nil)
   ((and provider (stringp model) (not (string-search "/" model)))
    (benedict-model-resolve (format "%s/%s" provider model)))
   (t (benedict-model-resolve model))))

(defun benedict-session-provider (session)
  "Return the id of the provider SESSION's model belongs to, or nil.
Derived from the model rather than stored, so the two can never disagree."
  (when-let* ((model (benedict-session-model session)))
    (benedict-model-provider model)))

;;;; Session properties

(defun benedict-session-get (session key &optional default)
  "Return the value of KEY in SESSION's properties, or DEFAULT when absent.
Distinguishes an absent key from one present with a nil value.  SESSION
may be nil, which returns DEFAULT -- convenient for a globally registered
hook reading `benedict-current-session' outside any run."
  (if (null session)
      default
    (let ((properties (benedict-session-properties session)))
      (if (plist-member properties key) (plist-get properties key) default))))

(defun benedict-session-put (session key value)
  "Set KEY to VALUE in SESSION's properties and return VALUE.
This is the sanctioned place for extension state that should live and die
with a session; the kernel never reads it."
  (setf (benedict-session-properties session)
        (plist-put (benedict-session-properties session) key value))
  value)

;;;; Transcript delegation

;; SPEC-001 3.2 puts the tree accessors on the message module and 4.1 lists
;; them on the session.  Both: the transcript is session-independent, and these
;; delegate to it.  Only `benedict-session-fork' does anything extra, because
;; only a fork moves head in a way no other hook reports.

(defun benedict-session-head (session)
  "Return the id of SESSION's current transcript tip, or nil when empty."
  (benedict-transcript-head (benedict-session-transcript session)))

(defun benedict-session-entry (session id)
  "Return SESSION's entry with ID, or nil when there is none."
  (benedict-transcript-entry (benedict-session-transcript session) id))

(defun benedict-session-children (session id)
  "Return the entries in SESSION whose parent is ID, in append order.
ID may be nil, which returns the transcript's root entries.  This is what
a renderer showing \"2 of 3\" branch affordances reads."
  (benedict-transcript-children (benedict-session-transcript session) id))

(defun benedict-session-siblings (session id)
  "Return SESSION's entry with ID together with its siblings, in append order."
  (benedict-transcript-siblings (benedict-session-transcript session) id))

(defun benedict-session-path (session &optional id)
  "Return the entries from a root down to ID in SESSION, root first.
ID defaults to SESSION's head, so with no ID this is the current
conversation.  Entries from abandoned branches are structurally
unreachable here, which is what makes fork-and-switch safe without
special handling."
  (benedict-transcript-path (benedict-session-transcript session) id))

(defun benedict-session-entries (session)
  "Return every entry in SESSION's transcript, in append order.
This is the whole tree; see `benedict-session-path' for one conversation."
  (benedict-transcript-entries (benedict-session-transcript session)))

(defun benedict-session-append (session entry)
  "Append ENTRY to SESSION's transcript and return ENTRY.

Modifies ENTRY in place, assigning its id and parent, and moves head to
it.  Does not run any hook: `benedict-core' announces entries, because it
is what knows when one is complete.  Callers outside the kernel almost
always want the kernel's entry path instead of this."
  (benedict-transcript-append (benedict-session-transcript session) entry))

(defun benedict-session-fork (session id)
  "Move SESSION's head to ID and return ID.

The next append then creates a sibling rather than extending the current
branch, which is how undo, edit-and-resubmit, retry with another model,
and non-destructive compaction are all expressed.  Nothing is removed:
the abandoned branch stays in the transcript and stays renderable.

ID may be nil, which makes the next append a new root.  Runs
`benedict-head-change-functions' unless head was already at ID.  Signal
`benedict-transcript-unknown-entry' when ID is not in SESSION."
  (let ((old (benedict-session-head session)))
    (benedict-transcript-fork (benedict-session-transcript session) id)
    (unless (equal old id)
      (benedict-hook-run session 'benedict-head-change-functions old id))
    id))

;;;; Queues

(defun benedict-session-steer (session content)
  "Queue CONTENT for injection into SESSION at the next turn boundary.
Returns CONTENT.  CONTENT is anything `benedict-entry-create' accepts,
including a bare string.

Steering is drained before follow-ups, and by default one message per
boundary: if a user types three corrections while the agent works,
injecting all three at once means the agent never acts on the first
before seeing the third.  See `benedict-queue-drain-mode'."
  (setf (benedict-session-steer-queue session)
        (append (benedict-session-steer-queue session) (list content)))
  content)

(defun benedict-session-follow-up (session content)
  "Queue CONTENT for SESSION for after the run would otherwise stop.
Returns CONTENT.  Unlike steering, a follow-up does not interrupt a
working agent; it keeps the run alive once the agent is done."
  (setf (benedict-session-follow-up-queue session)
        (append (benedict-session-follow-up-queue session) (list content)))
  content)

(defun benedict-session-queued-p (session)
  "Return non-nil when SESSION has steering or follow-up content waiting."
  (and (or (benedict-session-steer-queue session)
           (benedict-session-follow-up-queue session))
       t))

;;;; Session-local hooks

;; Each session carries its own hook table.  Every hook run concatenates the
;; global list and the session's, so a project-local extension can intercept
;; tool calls in one session without touching another, and a sandboxed worker
;; session does not inherit an interactive session's approval prompts.

(defun benedict-session-add-hook (session hook function &optional depth)
  "Add FUNCTION to SESSION's local list for HOOK.  Return FUNCTION.

HOOK is the symbol of one of the hook variables in this file.  DEPTH
works as it does for `add-hook': a lower value runs earlier, the default
is 0, and functions at equal depth run in the order they were added.
Adding a FUNCTION already present moves it to the new depth rather than
duplicating it.

Session-local functions run AFTER global ones at equal depth, so a global
policy sees a call before a session-specific one does.

As with global hooks, register a named function rather than a lambda: it
is what makes a function removable and what makes reloading an extension
file idempotent."
  (let* ((depth (or depth 0))
         (cell (assq hook (benedict-session-hooks session)))
         (kept (seq-remove (lambda (entry) (equal (car entry) function)) (cdr cell)))
         ;; The new entry goes last, then a stable sort by depth; `sort' on a
         ;; list is a merge sort, so equal depths keep insertion order.
         (updated (sort (append kept (list (cons function depth)))
                        (lambda (a b) (< (cdr a) (cdr b))))))
    (if cell
        (setcdr cell updated)
      (push (cons hook updated) (benedict-session-hooks session)))
    function))

(defun benedict-session-remove-hook (session hook function)
  "Remove FUNCTION from SESSION's local list for HOOK.
Return non-nil when FUNCTION was present."
  (let* ((entries (assq hook (benedict-session-hooks session)))
         (present (and entries (assoc function (cdr entries)) t)))
    (when entries
      (setcdr entries (seq-remove (lambda (entry) (equal (car entry) function))
                                  (cdr entries))))
    present))

(defun benedict-session-local-hook-functions (session hook)
  "Return SESSION's own functions for HOOK, in run order.
Excludes the global list; see `benedict-session-hook-functions' for the
list that actually runs."
  (mapcar #'car (cdr (assq hook (benedict-session-hooks session)))))

(defun benedict-session-hook-functions (session hook)
  "Return every function HOOK will call for SESSION, in run order.

The global value of HOOK first, then SESSION's own additions.  SESSION
may be nil, which returns the global list alone.  The t that `add-hook'
leaves as its marker for a buffer-local list is dropped, since Benedict
hooks are never buffer-local."
  (append (seq-remove (lambda (function) (eq function t))
                      (if (boundp hook) (symbol-value hook) nil))
          (and session (benedict-session-local-hook-functions session hook))))

;;;; Hook runners

;; Four kinds of hook, four runners.  Every one of them binds
;; `benedict-current-session' so that a globally registered function can tell
;; which session it is running for.
;;
;; The observation and veto runners pass SESSION as the first argument
;; themselves, because every hook of those two kinds takes it there.  The filter
;; and dispatch chains do not: their signatures are shaped by the value being
;; transformed, which is exactly why `benedict-current-session' exists.

(defun benedict-hook-run (session hook &rest args)
  "Run HOOK for SESSION, calling each function with SESSION and ARGS.
This is the observation-hook runner.  Return values are ignored; returns
nil."
  (let ((benedict-current-session session))
    (dolist (function (benedict-session-hook-functions session hook))
      (apply function session args)))
  nil)

(defun benedict-hook-run-until-success (session hook &rest args)
  "Run HOOK for SESSION with SESSION and ARGS, stopping at the first non-nil.
Return that result, or nil when every function declined.  This is the
veto-hook runner."
  (let ((benedict-current-session session)
        (result nil)
        (functions (benedict-session-hook-functions session hook)))
    (while (and functions (null result))
      (setq result (apply (pop functions) session args)))
    result))

(defun benedict-hook-filter (session hook value &rest args)
  "Pass VALUE through HOOK's filter chain for SESSION and return the result.

Each function is called with the running value followed by ARGS, and its
return value replaces the running value.  A filter that declines to act
must return its input; there is no \"no opinion\" return here."
  (let ((benedict-current-session session))
    (dolist (function (benedict-session-hook-functions session hook))
      (setq value (apply function value args))))
  value)

(defun benedict-hook-dispatch (session invocation done)
  "Run INVOCATION through SESSION's dispatch chain, then call DONE with it.

The chain is `benedict-tool-dispatch-functions'.  Each member receives
the running invocation and a continuation, and the chain advances only
when that continuation is called -- so a member may hold it and resume
the run later, which is what an approval prompt does.  DONE receives the
invocation as the chain left it: possibly rewritten, blocked, or
retargeted.

`benedict-current-session' is rebound at each step rather than once
around the whole chain, because a suspended step resumes long after the
original binding has been unwound."
  (let ((functions (benedict-session-hook-functions
                    session 'benedict-tool-dispatch-functions)))
    (letrec ((step (lambda (remaining current)
                     (let ((benedict-current-session session))
                       (if (null remaining)
                           (funcall done current)
                         (funcall (car remaining) current
                                  (lambda (next)
                                    (funcall step (cdr remaining) next))))))))
      (funcall step functions invocation))))

(provide 'benedict-session)

;;; benedict-session.el ends here
