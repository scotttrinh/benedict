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
;;     first and the session's own list second.  `add-hook' DEPTH orders
;;     functions within each scope; it never sorts across these scopes.
;;   - `benedict-current-session', bound around every hook invocation, so a
;;     GLOBALLY registered function can discriminate without every extension
;;     author being forced to thread a session argument.
;;
;; A local negative depth therefore cannot precede a global hook.  Policy
;; functions whose order is coupled must be installed together in the
;; appropriate scope.  These hooks compose scoped policy, but do not establish
;; an isolation boundary against image-wide Elisp.
;;
;; Buffer-local hooks are the tempting Emacs-native answer and are wrong here:
;; headless sessions have no buffer, and binding the correct buffer around every
;; asynchronous dispatch is fragile.  Extension callbacks that outlive a hook
;; invocation must capture their SESSION lexically; this dynamic binding does
;; not follow arbitrary timers created by extension code.
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
  "The session bound during a hook invocation, resumed dispatch-chain step,
or tool-handler entry, or nil outside those dynamic boundaries.

Bound dynamically around every hook, filter, dispatch-chain step, and handler
entry.  Observation hooks receive the session directly.  Transform and
dispatch hooks read this variable when they need to distinguish between
sessions:

  (defun my-approvals--dispatch (invocation next)
    (if (benedict-session-get benedict-current-session :trusted)
        (funcall next invocation)
      (my-approvals--confirm invocation next)))

Do not set this variable.  Bind it only when implementing a hook runner.
The binding does not follow arbitrary timers created by extension code, so
callbacks that outlive the hook invocation must capture their SESSION
lexically.")

;;;; Hooks -- observation

;; Run with every function called and every return value ignored.

(defvar benedict-run-start-functions nil
  "Functions called when a run begins, with one argument, the session.
A run is the sequence of turns from a submit until the session returns to
the `idle' state.  Return values are ignored.")

(defvar benedict-run-end-functions nil
  "Functions called when a run ends, with one argument, the session.
The session is already in `idle', but the ending run remains attached while
observers are attempted once.  Submissions made reentrantly are queued instead
of replacing that run.  Read `benedict-session-stop-reason' to distinguish
completed, vetoed, failed, and aborted outcomes.  Return values are ignored.")
(defvar benedict-turn-end-functions nil
  "Functions called when a turn ends, with (SESSION ENTRY RESULTS).

ENTRY is the assistant entry that turn produced.  RESULTS is the list of
`benedict-tool-result-value' objects its tool calls returned, in call order,
and is nil for a turn that called no tools.  Terminal failure cleanup attempts
this notification once for a started turn.  Return values are ignored.")

(defvar benedict-turn-start-functions nil
  "Functions called when a turn begins, with one argument, the session.
A turn is one assistant message plus the tool results it produced.
Return values are ignored.")


(defvar benedict-entry-start-functions nil
  "Functions called when an entry begins, with (SESSION ENTRY).

For a streamed assistant entry, functions run when the stream opens, before the
entry has content or an id.  Use the entry object's identity until
`benedict-entry-end-functions' runs.  For other entries, functions run
immediately before append.  Return values are ignored.")

(defvar benedict-entry-update-functions nil
  "Functions called as a streamed entry grows, with (SESSION ENTRY INDEX DELTA).

INDEX is the changed content block's position.  DELTA is the text just added.
ENTRY has already been mutated, so renderers should read block INDEX from ENTRY
instead of accumulating DELTA.  Return values are ignored.")

(defvar benedict-entry-end-functions nil
  "Functions called when an entry is complete, with (SESSION ENTRY).

Functions run after append, when ENTRY has an id and is the transcript head.
Failed and aborted streams also produce a terminal entry and call these
functions.  Stores use this hook to persist completed entries.  Return values
are ignored.")

(defvar benedict-head-change-functions nil
  "Functions called when the transcript head moves, with (SESSION OLD-ID NEW-ID).

Functions run for explicit head moves, including forks, but not for append;
`benedict-entry-end-functions' reports append.  Stores use this hook to persist
the selected branch, and renderers use it to update branch controls.  Return
values are ignored.")

(defvar benedict-tool-start-functions nil
  "Functions called before a tool call is dispatched, with (SESSION INVOCATION).

Functions run before `benedict-tool-dispatch-functions', so they observe calls
that a dispatch filter later denies.  Return values are ignored; use a dispatch
filter to block a call.")

(defvar benedict-tool-end-functions nil
  "Functions called when a tool call finishes, with (SESSION INVOCATION RESULT).

INVOCATION is the final, possibly rewritten call.  RESULT is its
`benedict-tool-result-value', including a result produced for a denied or
unknown tool.  Return values are ignored.")

(defvar benedict-state-change-functions nil
  "Functions called on every run-state transition, with (SESSION OLD NEW).

OLD and NEW are the state symbols `idle', `provider-wait',
`tool-dispatch', `tool-wait', and `stopping'.  Return values are
ignored.")

;;;; Hooks -- veto

(defvar benedict-continue-predicate-functions nil
  "Functions asked whether a run should stop, with one argument, the session.

Called at every turn boundary.  The first non-nil return value stops the run
after the current turn and becomes `benedict-session-stop-reason'.  Return a
string or symbol that explains the reason.  Nil means no opinion.

A veto does not discard queued input.  A steering or follow-up message still
continues the run.")

;;;; Hooks -- transform

;; Filter chains.  Each function takes the value being transformed as its first
;; argument and returns a replacement.  A function that returns nil returns nil;
;; there is no "no opinion" convention here, so a filter that declines to act
;; must return its input unchanged.

(defvar benedict-context-filter-functions nil
  "Functions that transform the entries sent to a provider, as (ENTRIES SESSION).

Each function receives the previous function's output and must return a list of
canonical `benedict-entry' objects.  Use this hook for compaction, injection,
and pruning.  Wire-format conversion happens later in the API adapter.

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

A function may:

  allow             (funcall next invocation)
  modify and allow  (funcall next (benedict-invocation-with invocation ...))
  deny              (funcall next (benedict-tool-blocked invocation \"reason\"))
  reroute           (funcall next (benedict-invocation-with invocation
                                    :tool a-tool-that-runs-it-elsewhere))
  suspend           hold NEXT and call it later, from a callback

A function suspends the run by retaining NEXT and calling it later.  NEXT must
be called exactly once; until then, the run remains suspended.

Return values are ignored -- the chain advances through NEXT.  The
`benedict-current-session' binding identifies the session at every resumed
chain step and handler entry.  It does not follow arbitrary timers created by
extension code, so those callbacks must capture SESSION lexically.

Scope order is global functions first, then session-local functions.  DEPTH
orders functions within each scope; it does not sort across scopes.  Thus a
local negative depth cannot precede a global hook.  Install order-dependent
policy functions together in the appropriate scope.  Within a scope, use the
convention approval filters at depth 0, routing filters at depth 90, and
observation-only wrappers at depth -90.")

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
  (tool-selection nil
                  :documentation "What this session offers, before resolution.
Either a list of tool ids and `benedict-tool' objects, or a function of
the session returning such a list.  A function is called on every
resolution, so (lambda (_session) (benedict-tool-list)) is the live view
of every registered tool, and the selection that lets a session see a
tool registered after it was created.

Read through `benedict-session-tool-list', which resolves this.  Nothing
should read this slot: resolution is what makes the answer current, and a
list taken from here is unresolved rather than merely stale.")
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
  (last-error nil
              :documentation "The first Elisp condition data caught during the current or last run, or nil.
Cleared when a new run starts.  This records kernel-caught conditions only;
provider-reported error events remain on their terminal transcript entry.")
  (terminal-epoch 0
                  :documentation "Private terminal-boundary epoch for deferred idle restarts.
Bumped at each run start and finish so an idle thunk belongs only to one
terminal boundary of this session.")
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
  "Create and return a session.

MODEL is a `benedict-model' or a \"PROVIDER-ID/MODEL-ID\" string resolved
through `benedict-model-resolve'.  PROVIDER, when given, is the provider
id used as the prefix for a MODEL string that has none, so a caller
holding the two separately need not concatenate them.

TOOLS selects what the session may call.  It is either a list of tool ids
and `benedict-tool' objects, or a function that receives the session and
returns such a list.  Use (lambda (_session) (benedict-tool-list)) to
select the live registry.  A list is validated now and resolved again for
every request; see `benedict-session-tool-list'.

SYSTEM-PROMPT is the instruction text sent with every request.  STORE is
an opaque persistence handle the kernel never calls into.

When TRANSCRIPT is non-nil, the session adopts it and uses its session id
instead of ID.  This resumes a transcript without changing how later entry
ids are minted.  Otherwise, the function creates an empty transcript using
ID or a new session id.

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
     :tool-selection (benedict-session--check-tools tools)
     :store store)))

(defun benedict-session--check-tools (tools)
  "Return the tool selection TOOLS, having validated a list one.

A list is resolved and the result discarded: the point is to signal
`benedict-tool-unknown' for a misspelled id while the caller is still
holding the stack that named it, rather than on the first request.  The
resolution is thrown away because the selection is resolved again per
request, which is what keeps a long-lived session current.

A function cannot be checked without calling it, and calling it here
would run it against a session that does not exist yet."
  (unless (functionp tools)
    (benedict-tool-resolve tools))
  tools)

(defun benedict-session--resolve-model (model provider)
  "Return the `benedict-model' MODEL names, prefixing with PROVIDER if needed.
Returns nil when MODEL is nil, so a session may be created before a model
is chosen."
  (cond
   ((null model) nil)
   ((and provider (stringp model) (not (string-search "/" model)))
    (benedict-model-resolve (format "%s/%s" provider model)))
   (t (benedict-model-resolve model))))

(defun benedict-session-tool-list (session)
  "Return the `benedict-tool' objects currently available to SESSION.

Every request uses this function.  Frontends must also call it instead of
caching the result because a session may use a dynamic selection.  Returned
objects are borrowed read-only values for the request; do not mutate them.

Ids resolve through the current registry.  An explicit list fixes which tools
are offered, but re-registering one of those tools updates the object returned
for the next request.

Signal `benedict-tool-unknown' when the selection names an unregistered id."
  (let ((selection (benedict-session-tool-selection session)))
    (benedict-tool-resolve
     (if (functionp selection) (funcall selection session) selection))))

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

The next append extends the branch at ID.  Existing entries remain in the
transcript.

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

Steering is drained before follow-ups.  `benedict-queue-drain-mode' controls
whether one or all queued messages are consumed at a boundary."
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
;; default global list first and the session's list second, independently of
;; the current buffer.  DEPTH orders functions only within their own scope;
;; there is no cross-scope sort.

(defun benedict-session-add-hook (session hook function &optional depth)
  "Add FUNCTION to SESSION's local list for HOOK.  Return FUNCTION.

HOOK is the symbol of one of the hook variables in this file.  FUNCTION is
called with the argument signature documented by HOOK; its return value is
interpreted according to that hook's contract.  DEPTH orders functions within
this session's scope: a lower value runs earlier, the default is 0, and
equal-depth functions retain session-local insertion order.  A repeated
FUNCTION replaces its earlier entry and is re-inserted at the requested depth.

All session-local functions run after every global function, regardless of
depth.  A local negative depth therefore cannot precede a global hook.
Session-local hooks compose scoped policy; they do not establish an isolation
boundary against image-wide hooks, advice, variables, or registries.
Registration mutates SESSION's hook table and lasts until FUNCTION is removed
or SESSION is discarded.  This function does not invoke FUNCTION or signal
on its behalf; return values and signalling are governed by the later hook
run.

Use a named function when it must be removable or survive extension reloads
without duplication."
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

The default global value of HOOK comes first, then SESSION's own additions.
SESSION may be nil, which returns the default global list alone.  The
global value is read with `default-value', never from the active buffer;
the `t' marker that `add-hook' uses for a buffer-local list is discarded.
Session scope is the session hook table, never the current buffer.  There is
no cross-scope depth sort.  Session-local hooks compose scoped policy; they do
not establish an isolation boundary against image-wide hooks, advice, variables,
or registries.  This function does not invoke callbacks or mutate SESSION; the
returned list is a fresh concatenation, and its functions remain registered
until removed or until SESSION is discarded."
  (let ((global (and (default-boundp hook) (default-value hook))))
    (append
     (seq-remove (lambda (function) (eq function t))
                 (cond ((null global) nil)
                       ((eq global t) nil)
                       ((functionp global) (list global))
                       (t global)))
     (and session (benedict-session-local-hook-functions session hook)))))

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

(defun benedict-hook-dispatch (session invocation done &optional valid-p)
  "Run INVOCATION through SESSION's dispatch chain, then call DONE with it.

Each `benedict-tool-dispatch-functions' member receives the current invocation
and a continuation.  The chain advances when the member calls that continuation.
DONE receives the final invocation, which may be rewritten, blocked, or routed
to another tool.  When VALID-P is non-nil, it is checked before every filter
and continuation step; an invalidated operation makes all captured continuations
no-ops, including those resumed after a replacement run.

This function rebinds `benedict-current-session' at each step so an asynchronous
continuation receives the correct session.  Continuations remain valid only
while VALID-P returns non-nil (or, when omitted, for the lifetime of the chain)."
  (let ((functions (benedict-session-hook-functions
                    session 'benedict-tool-dispatch-functions)))
    (letrec ((step (lambda (remaining current)
                     (when (or (null valid-p) (funcall valid-p))
                       (let ((benedict-current-session session))
                         (if (null remaining)
                             (funcall done current)
                           (let ((consumed nil))
                             (funcall (car remaining) current
                                      (lambda (next)
                                        (when (and (not consumed)
                                                   (or (null valid-p)
                                                       (funcall valid-p)))
                                          (setq consumed t)
                                          (funcall step (cdr remaining) next)))))))))))
      (funcall step functions invocation))))

(provide 'benedict-session)

;;; benedict-session.el ends here
