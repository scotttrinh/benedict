;;; benedict-core.el --- The reducer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The agent loop, which is not a loop.
;;
;; Emacs is single-threaded and has no `await', so the kernel is a REDUCER: a
;; function that inspects session state, dispatches one asynchronous action, and
;; arranges to be re-entered from that action's callback.  The medium forces
;; this, but it is also better than a loop here -- every state transition is an
;; explicit, observable, interceptable point, and the whole kernel is testable
;; against a scripted provider with no network and no timing.
;;
;; The hard rule is that `benedict-core--advance' must never be called from
;; within itself.  A fast provider or a synchronous tool would otherwise grow
;; the stack by a frame per turn and eventually overflow.  Every asynchronous
;; completion therefore re-enters through `benedict-core--defer', never by
;; calling the reducer directly.  Making the deferral a variable rather than a
;; convention also makes it testable: bind `benedict-core-defer-function' and a
;; test can single-step the machine.
;;
;; What this file does NOT own is as important as what it does.  It has no
;; opinion about whether a tool call needs confirmation, no notion of a budget,
;; no compaction strategy, and it never touches the filesystem.  Each of those
;; is a hook subscriber.  The hook variables themselves live in
;; `benedict-session', which owns the scoping mechanism they run through.
;;
;; See SPEC-001 4.2, 4.3, and 6.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'benedict)
(require 'benedict-message)
(require 'benedict-tool)
(require 'benedict-provider)
(require 'benedict-session)

;;;; Configuration

(defcustom benedict-queue-drain-mode 'one-at-a-time
  "How many queued messages are injected at a turn boundary.

`one-at-a-time' (the default) injects a single message per boundary.
This lets the agent act between messages queued while a run is active.

`all' injects everything queued.  It exists for scripted and batch use,
where the messages are a prepared sequence rather than reactions."
  :type '(choice (const :tag "One message per boundary" one-at-a-time)
                 (const :tag "Everything queued" all))
  :group 'benedict)

;;;; Deferral

(defun benedict-core--defer-with-timer (thunk)
  "Schedule THUNK to run on the next turn of the event loop."
  (run-at-time 0 nil thunk))

(defvar benedict-core-defer-function #'benedict-core--defer-with-timer
  "Function called with a THUNK of no arguments to run it later.

It must not call THUNK synchronously because reducer re-entry must happen on a
later event-loop turn.

The default schedules THUNK with `run-at-time'.  Bind this to a queue
that a test drains by hand to step the state machine deterministically,
one transition at a time.")

(defvar benedict-core--generation-counter 0
  "Monotonic token source for provider and tool callbacks.

Tokens are private reducer bookkeeping: every asynchronous operation gets a
fresh value, including across successive runs of one session, so a late event
cannot collide with a newer run that restarted its local counters.")

(defun benedict-core--defer (session)
  "Arrange for SESSION's current run to advance later.

The deferred thunk is bound to the active run object and generation.  If failure
cleanup or abort has invalidated that operation before the event-loop turn, the
thunk is a no-op rather than taking the idle branch and reviving queued work."
  (let* ((run (benedict-session-run session))
         (generation (and run (benedict-run-generation run))))
    (funcall benedict-core-defer-function
             (lambda ()
               (when (and run
                          (eq run (benedict-session-run session))
                          (= generation (benedict-run-generation run)))
                 (benedict-core--advance session))))))

(defun benedict-core--defer-idle (session terminal-epoch reason)
  "Arrange for queued input after SESSION's run has cleanly cleared.

The deferred thunk belongs to one terminal boundary of one session: it retains
SESSION's TERMINAL-EPOCH and terminal REASON, so a later run on that session
invalidates it while unrelated sessions cannot."
  (funcall benedict-core-defer-function
           (lambda ()
             (when (and (null (benedict-session-run session))
                        (equal reason (benedict-session-stop-reason session))
                        (not (memq reason '(error aborted)))
                        (= terminal-epoch
                           (benedict-session-terminal-epoch session))
                        (or (benedict-session-steer-queue session)
                            (benedict-session-follow-up-queue session)))
               (benedict-core--advance session)))))



;;;; Run bookkeeping

;; The session carries this in its opaque `run' slot.  It holds everything that
;; is true only while a run is in flight, so that a session at rest is just its
;; transcript and its configuration.

(cl-defstruct (benedict-run (:constructor benedict-run--create)
                            (:copier nil))
  "Reducer bookkeeping for one run in flight."
  (generation 0
              :documentation "Current callback-generation token.

A stream and its tool callbacks capture this token, and anything arriving under
a stale token is discarded.  Tokens are globally monotonic across runs.")
  (stream-active nil
                 :documentation "Non-nil while a provider stream is open.")
  (stream-cancel nil
                 :documentation "Thunk that asks the provider to stop, or nil.")
  (preparation-active nil
                      :documentation "Non-nil while asynchronous request preparation is pending.")
  (preparation-cancel nil
                      :documentation "Thunk cancelling request preparation, or nil.")
  (streaming-entry nil
                   :documentation "The partially-built assistant entry, or nil.
Mutated in place by stream events and not appended to the transcript
until the stream terminates.")
  (assistant-entry nil
                  :documentation "The assistant entry this turn produced, once final.")
  (origin nil
          :documentation "Copied scalar origin plist for the active request.
Values come from the final filtered request and are not read from a mutable
session model after dispatch.")
  (offered-tools nil
                 :documentation "Borrowed read-only tool objects offered by the
active request, normalized first-wins by id.")
  (pending-calls nil
                 :documentation "Invocations from this turn not yet dispatched, in order.")
  (results nil
           :documentation "Results collected this turn, in reverse call order.")
  (turn-started nil
                :documentation "Non-nil after this run's current turn starts.")
  (turn-ended nil
              :documentation "Non-nil after this run's current turn ends.")
  (cleanup-active nil
                  :documentation "Non-nil while terminal failure cleanup is running.")
  (terminal-notified nil
                     :documentation "Non-nil after run-end observers were attempted."))

(cl-defstruct (benedict-core--tool-operation (:constructor benedict-core--tool-operation--create)
                                              (:copier nil))
  "Private identity and consumption state for one outstanding tool call."
  run
  generation
  dispatch-consumed
  result-consumed)

(defun benedict-core--tool-operation-valid-p (session operation)
  "Return non-nil when OPERATION still belongs to SESSION's active run.

The check uses object identity as well as the monotonically increasing
generation, so a stale continuation cannot act on a replacement run."
  (let ((run (benedict-session-run session)))
    (and run
         (eq run (benedict-core--tool-operation-run operation))
         (= (benedict-core--tool-operation-generation operation)
            (benedict-run-generation run)))))


(defun benedict-core--record-error (session condition)
  "Preserve the first caught Elisp CONDITION for SESSION's active run.

CONDITION is the `condition-case' data list.  The copy prevents later mutation
from changing the diagnostic exposed by `benedict-session-last-error'."
  (unless (benedict-session-last-error session)
    (setf (benedict-session-last-error session) (copy-tree condition))))

(defun benedict-core--safe-hook-run (session hook &rest args)
  "Run each HOOK observer for SESSION once, returning the first condition.

Later observers still run after an earlier observer signals, which keeps
terminal cleanup bounded and gives every observer one notification attempt."
  (let ((first nil)
        (benedict-current-session session))
    (dolist (function (benedict-session-hook-functions session hook))
      (condition-case error
          (apply function session args)
        (error
         (unless first
           (setq first error)))))
    first))

(defun benedict-core--fail-run (session condition)
  "Stop SESSION for caught CONDITION without recursively re-entering cleanup.

Callbacks are invalidated before cancellation and terminal observers are
attempted once each.  The first condition remains in SESSION's last-error slot;
later observer or cancellation failures cannot replace it.  A started turn gets
one best-effort turn-end notification before run-end cleanup."
  (benedict-core--record-error session condition)
  (setf (benedict-session-stop-reason session) 'error)
  (when-let ((run (benedict-session-run session)))
    (unless (benedict-run-cleanup-active run)
      (setf (benedict-run-cleanup-active run) t
            (benedict-run-generation run) (cl-incf benedict-core--generation-counter))
      (when-let ((cancel (benedict-run-stream-cancel run)))
        (setf (benedict-run-stream-cancel run) nil)
        (condition-case cancel-error
            (funcall cancel)
          (error (benedict-core--record-error session cancel-error))))
      (when-let ((cancel (benedict-run-preparation-cancel run)))
        (setf (benedict-run-preparation-cancel run) nil)
        (condition-case cancel-error
            (funcall cancel)
          (error (benedict-core--record-error session cancel-error))))
      (setf (benedict-run-stream-active run) nil
            (benedict-run-stream-cancel run) nil
            (benedict-run-preparation-active run) nil
            (benedict-run-preparation-cancel run) nil)
      (when-let ((entry (benedict-run-streaming-entry run)))
        (setf (benedict-run-streaming-entry run) nil)
        (benedict-core--tag-origin session entry)
        (benedict-entry-meta-put entry :stop-reason 'error)
        (benedict-entry-meta-put entry :error-message
                                 (error-message-string condition))
        (condition-case append-error
            (benedict-core--append-entry session entry)
          (error
           (benedict-core--record-error session append-error)
           (warn "Benedict failed to persist terminal entry: %s"
                 (error-message-string append-error)))))
      (when-let ((turn-error (and (benedict-run-turn-started run)
                                  (not (benedict-run-turn-ended run))
                                  (benedict-core--end-turn session t))))
        (benedict-core--record-error session turn-error))
      (let ((old (benedict-session-state session)))
        (setf (benedict-session-state session) 'idle)
        (when (not (eq old 'idle))
          (benedict-core--safe-hook-run
           session 'benedict-state-change-functions old 'idle)))
      (unless (benedict-run-terminal-notified run)
        (setf (benedict-run-terminal-notified run) t)
        (when-let ((end-error
                    (benedict-core--safe-hook-run
                     session 'benedict-run-end-functions)))
          (benedict-core--record-error session end-error)
          (setf (benedict-session-stop-reason session) 'error)))
      (setf (benedict-session-run session) nil)))
  (benedict-session-state session))

(defun benedict-run-stream-active-p (run)
  "Return non-nil when RUN has a provider stream open."
  (and (benedict-run-stream-active run) t))

(defun benedict-session-streaming-entry (session)
  "Return SESSION's live, partially-built assistant entry, or nil.

Stream events mutate this entry in place.  Frontends should read the changed
block from this entry when `benedict-entry-update-functions' runs instead of
accumulating deltas.

The entry has no id until the stream terminates and it is appended."
  (when-let* ((run (benedict-session-run session)))
    (benedict-run-streaming-entry run)))

(defun benedict-core--run (session)
  "Return SESSION's run bookkeeping, signalling when there is none."
  (or (benedict-session-run session)
      (signal 'benedict-session-error (list "No run in flight" session))))

;;;; State

(defun benedict-core--set-state (session state)
  "Move SESSION to STATE and announce the transition.  Return STATE.
Does nothing and announces nothing when SESSION is already in STATE."
  (let ((old (benedict-session-state session)))
    (unless (eq old state)
      (setf (benedict-session-state session) state)
      (benedict-hook-run session 'benedict-state-change-functions old state)))
  state)

(defun benedict-core--advance (session)
  "Dispatch the next action for SESSION based on its run state.

Called on submit and re-entered from every asynchronous completion.  Any
condition escaping a reducer boundary enters non-recursive terminal cleanup."
  (condition-case error
      (pcase (benedict-session-state session)
        ('provider-wait (benedict-core--request session))
        ('tool-dispatch (benedict-core--dispatch-next-tool session))
        ('tool-wait nil)
        ('stopping (benedict-core--drain session))
        ('idle (benedict-core--maybe-start session)))
    (error (benedict-core--fail-run session error))))

;;;; Entries

(defun benedict-core--emit-entry (session entry)
  "Announce ENTRY, append it to SESSION, and announce that it is complete.
Return ENTRY.  This is the path every entry takes except a streamed
assistant entry, which announces its start when the stream opens and
reaches the second half of this path through
`benedict-core--finalize-stream'."
  (benedict-hook-run session 'benedict-entry-start-functions entry)
  (benedict-core--append-entry session entry))

(defun benedict-core--append-entry (session entry)
  "Append ENTRY to SESSION's transcript and announce it is complete.
Return ENTRY."
  (benedict-session-append session entry)
  (benedict-hook-run session 'benedict-entry-end-functions entry)
  entry)

(defun benedict-core--emit-user-entry (session content)
  "Append a user entry carrying CONTENT to SESSION.  Return the entry."
  (benedict-core--emit-entry session (benedict-entry-create :role 'user
                                                            :content content)))

(defun benedict-session-note (session content &optional meta)
  "Append a note carrying CONTENT to SESSION, announce it, and return the entry.

This is the public entry-creation path for extensions.  CONTENT accepts the
forms documented by `benedict-entry-create', including a string.  Entry hooks
run around the append, so stores and renderers observe the note.

META is the entry's metadata plist.  A note stays out of provider context
unless META contains a non-nil `:context'.

This function may be called during a run.  It appends at the current head, so a
note created by a tool handler may appear between the assistant call and its
tool result."
  (benedict-core--emit-entry
   session
   (benedict-entry-create :role 'note :content content :meta meta)))

;;;; Lifecycle

;; These four are named for the session rather than for this file because
;; SPEC-001 4.1 publishes them under those names: they are the session's
;; verbs, and it is only their implementation that belongs with the reducer.

(defun benedict-session-submit (session input)
  "Submit INPUT to SESSION and start a run.  Return the session state.

INPUT is anything `benedict-entry-create' accepts, including a bare
string, or nil to resume without adding a message -- which is what
fork-and-switch does after moving the head.

When a run is active, queue non-nil INPUT as steering and return `steered'
without starting another run.

Signal `benedict-session-error' when SESSION has no model."
  (cond
   ((or (not (eq (benedict-session-state session) 'idle))
        (benedict-session-run session))
    (when input (benedict-session-steer session input))
    'steered)
   (t
    (unless (benedict-session-model session)
      (signal 'benedict-session-error (list "Session has no model" session)))
    (when input (benedict-core--emit-user-entry session input))
    (benedict-core--start-run session))))

(defun benedict-session-abort (session)
  "Ask SESSION to stop its run as soon as it can.  Return the session state.

Cancels any active stream, finalizes a partial entry with stop reason `aborted',
and ignores later results from outstanding tools.  Return immediately; the run
ends on a later event-loop turn.  Abort during terminal notification is a
no-op because that run is already ending."
  (unless (or (and (eq (benedict-session-state session) 'idle)
                   (null (benedict-session-run session)))
              (eq (benedict-session-state session) 'stopping)
              (and (benedict-session-run session)
                   (benedict-run-terminal-notified
                    (benedict-session-run session))))
    (setf (benedict-session-stop-reason session) 'aborted)
    (let ((transition-error nil))
      (condition-case error
          (benedict-core--set-state session 'stopping)
        (error (setq transition-error error)))
      (if transition-error
          (benedict-core--fail-run session transition-error)
        (progn
          (when-let* ((run (benedict-session-run session)))
            (setf (benedict-run-generation run)
                  (cl-incf benedict-core--generation-counter))
            (when-let* ((cancel (benedict-run-stream-cancel run)))
              (setf (benedict-run-stream-cancel run) nil)
              (condition-case error
                  (funcall cancel)
                (error
                 (benedict-core--record-error session error)
                 (setf (benedict-session-stop-reason session) 'error))))
            (when-let* ((cancel (benedict-run-preparation-cancel run)))
              (setf (benedict-run-preparation-cancel run) nil
                    (benedict-run-preparation-active run) nil)
              (condition-case error
                  (funcall cancel)
                (error
                 (benedict-core--record-error session error)
                 (setf (benedict-session-stop-reason session) 'error)))))
          (benedict-core--defer session)))))
  (benedict-session-state session))

(defun benedict-core--start-run (session)
  "Begin a run for SESSION and return its state.

Allocate a generation token that cannot collide with callbacks from an earlier
run of this session."
  (let ((run (benedict-run--create
              :generation (cl-incf benedict-core--generation-counter))))
    (cl-incf (benedict-session-terminal-epoch session))
    (setf (benedict-session-run session) run
          (benedict-session-stop-reason session) nil
          (benedict-session-last-error session) nil)
    (condition-case error
        (benedict-hook-run session 'benedict-run-start-functions)
      (error (benedict-core--fail-run session error)))
    (when (and (eq run (benedict-session-run session))
               (not (eq (benedict-session-state session) 'stopping)))
      (benedict-core--start-turn session))))

(defun benedict-core--start-turn (session)
  "Begin a turn for SESSION and return its state.

The transition into `provider-wait' is part of the same bounded failure path as
turn-start observers, so a signalling state observer cannot wedge the run."
  (let ((run (benedict-core--run session)))
    (setf (benedict-run-results run) nil
          (benedict-run-assistant-entry run) nil
          (benedict-run-turn-started run) t
          (benedict-run-turn-ended run) nil)
    (condition-case error
        (progn
          (benedict-hook-run session 'benedict-turn-start-functions)
          (when (and (eq run (benedict-session-run session))
                     (not (eq (benedict-session-state session) 'stopping)))
            (benedict-core--set-state session 'provider-wait)
            (benedict-core--defer session)))
      (error (benedict-core--fail-run session error))))
  (benedict-session-state session))

(defun benedict-core--finish-run (session)
  "End SESSION's run, returning it to `idle'.  Return the state.

The ending run remains installed until its idle transition and run-end
observers have been attempted.  Submissions reentrant from those observers are
therefore queued against the ending run rather than replacing it, and any
observer failure is recorded on the run being ended.  The terminal marker is
set before the idle transition so an idle observer cannot restart abort
cleanup."
  (let* ((run (benedict-session-run session))
         (notify-end (and run (not (benedict-run-terminal-notified run)))))
    (when notify-end
      (setf (benedict-run-terminal-notified run) t))
    (condition-case error
        (benedict-core--set-state session 'idle)
      (error
       (benedict-core--record-error session error)
       (setf (benedict-session-stop-reason session) 'error
             (benedict-session-state session) 'idle)))
    (when notify-end
      (when-let ((end-error
                  (benedict-core--safe-hook-run
                   session 'benedict-run-end-functions)))
        (benedict-core--record-error session end-error)
        (setf (benedict-session-stop-reason session) 'error)))
    (when (eq run (benedict-session-run session))
      (setf (benedict-session-run session) nil)
      (cl-incf (benedict-session-terminal-epoch session))
      (when (and (not (memq (benedict-session-stop-reason session)
                            '(error aborted)))
                 (or (benedict-session-steer-queue session)
                     (benedict-session-follow-up-queue session)))
        (benedict-core--defer-idle
         session (benedict-session-terminal-epoch session)
         (benedict-session-stop-reason session))))
  (benedict-session-state session)))


(defun benedict-core--maybe-start (session)
  "Start a run for SESSION when something is queued for it.
Called when the reducer advances an idle session.  Returns the state."
  (if (benedict-core--drain-queues session)
      (benedict-core--start-run session)
    (benedict-session-state session)))

;;;; Requesting

(defun benedict-core--context-entries (session)
  "Return the entries to send for SESSION, after filtering.

The materialized path from a root to head, minus entries that do not
belong in provider context -- notes, unless they carry `:context' -- and
then through `benedict-context-filter-functions', which is where
compaction, injection, and pruning live.  The transcript itself is not
modified."
  (benedict-hook-filter
   session 'benedict-context-filter-functions
   (seq-filter #'benedict-entry-context-p (benedict-session-path session))
   session))

(defun benedict-core--normalize-tools (specs)
  "Resolve request tool SPECS with first-wins duplicate normalization.

Tool objects are borrowed read-only values for the request lifetime.  Signal
`benedict-tool-unknown' for an unregistered id and `benedict-tool-error' for a
malformed selection.  Preserve the first object for each id, even when later
registry entries replace it."
  (unless (listp specs)
    (signal 'benedict-tool-error (list "Request tools are not a list" specs)))
  (let ((seen nil)
        (tools nil))
    (dolist (tool (benedict-tool-resolve specs) (nreverse tools))
      (unless (memq (benedict-tool-id tool) seen)
        (push (benedict-tool-id tool) seen)
        (push tool tools)))))

(defun benedict-core--validate-request (request)
  "Validate final filtered REQUEST and return it unchanged.

Signal `benedict-session-error' when the request is not a plist with a model,
session, and normalized tool objects of the required types.  Unknown extension
keys remain untouched; this is the kernel boundary before provider dispatch."
  (unless (listp request)
    (signal 'benedict-session-error (list "Request is not a plist" request)))
  (let ((model (plist-get request :model))
        (session (plist-get request :session))
        (tools (plist-get request :tools)))
    (unless (benedict-model-p model)
      (signal 'benedict-session-error (list "Request has no valid model" model)))
    (unless (benedict-session-p session)
      (signal 'benedict-session-error (list "Request has no valid session" session)))
    (unless (and (listp tools) (seq-every-p #'benedict-tool-p tools))
      (signal 'benedict-session-error (list "Request has invalid tools" tools))))
  request)

(defun benedict-core--build-request (session)
  "Return the final canonical request plist for SESSION's next turn.

Request filters are authoritative: the returned model and tools are the values
used for transport and tool resolution, after final type validation."
  (let* ((model (benedict-session-model session))
         (request (benedict-hook-filter
                   session 'benedict-request-filter-functions
                   (list :entries (benedict-core--context-entries session)
                         :system-prompt (benedict-session-system-prompt session)
                         :tools (benedict-session-tool-list session)
                         :model model
                         :session session)
                   model session)))
    (setq request (copy-sequence request))
    (plist-put request :tools
               (benedict-core--normalize-tools (plist-get request :tools)))
    (benedict-core--validate-request request)))

(defun benedict-core--request-owned-p (session run generation)
  "Return non-nil while RUN/GENERATION may dispatch work for SESSION."
  (and (eq run (benedict-session-run session))
       (= generation (benedict-run-generation run))
       (not (eq (benedict-session-state session) 'stopping))))

(defun benedict-core--request (session)
  "Open a provider stream for SESSION's next turn.  Return the state.
Does nothing when a stream is already open, so re-entering the reducer in
`provider-wait' is harmless."
  (let ((run (benedict-core--run session)))
    (unless (benedict-run-stream-active-p run)
      ;; The entry is installed before the request is built so that a context
      ;; or request filter which signals still produces a terminal entry saying
      ;; so, rather than wedging the session in `provider-wait' forever.
      (let ((entry (benedict-entry-create :role 'assistant :content nil))
            (generation (progn
                          (setf (benedict-run-generation run)
                                (cl-incf benedict-core--generation-counter))
                          (benedict-run-generation run))))
        (setf (benedict-run-streaming-entry run) entry)
        (setf (benedict-run-stream-active run) t)
        (benedict-hook-run session 'benedict-entry-start-functions entry)
        (when (benedict-core--request-owned-p session run generation)
          (benedict-core--open-stream session run generation)))))
  (benedict-session-state session))

(defun benedict-core--cancel-invalid-request (session cancel)
  "Call CANCEL for a request invalidated on SESSION before dispatch returned."
  (condition-case error
      (funcall cancel)
    (error
     (benedict-core--record-error session error)
     (setf (benedict-session-stop-reason session) 'error))))

(defun benedict-core--open-stream (session run generation)
  "Build and send SESSION's next request for RUN under GENERATION.  Return nil.

Events arriving under a superseded GENERATION are discarded, which is how
an aborted stream stops mattering without the provider having to
cooperate.

Anything that signals on the way to the wire -- a filter, a missing
transport, a provider that raises instead of reporting a terminal error
event -- is caught and turned into an `:error' event, so the reducer
keeps one error path rather than two."
  (setf (benedict-run-origin run) nil
        (benedict-run-offered-tools run) nil)
  (condition-case error
      (when (benedict-core--request-owned-p session run generation)
        (let ((request (benedict-core--build-request session)))
          (setf (benedict-run-preparation-active run) t)
          (let ((cancel
                 (benedict-hook-prepare
                  session request
                  (lambda (prepared)
                    (when (and (benedict-core--request-owned-p
                                session run generation)
                               (benedict-run-preparation-active run))
                      (setf (benedict-run-preparation-active run) nil
                            (benedict-run-preparation-cancel run) nil)
                      (condition-case prepare-error
                          (benedict-core--dispatch-prepared-request
                           session run generation prepared)
                        (error
                         (benedict-core--record-error session prepare-error)
                         (benedict-core--receive
                          session generation
                          (list :type :error :reason 'error
                                :message (error-message-string prepare-error)))))))
                  (lambda (condition)
                    (when (and (benedict-core--request-owned-p
                                session run generation)
                               (benedict-run-preparation-active run))
                      (setf (benedict-run-preparation-active run) nil
                            (benedict-run-preparation-cancel run) nil)
                      (benedict-core--record-error session condition)
                      (benedict-core--receive
                       session generation
                       (list :type :error :reason 'error
                             :message (error-message-string condition)))))
                  (lambda ()
                    (benedict-core--request-owned-p session run generation)))))
            (when (and (benedict-run-preparation-active run)
                       (benedict-core--request-owned-p session run generation))
              (setf (benedict-run-preparation-cancel run) cancel))
            (unless (and (benedict-run-preparation-active run)
                         (benedict-core--request-owned-p session run generation))
              (when (functionp cancel)
                (benedict-core--cancel-invalid-request session cancel))))))
    (error
     (benedict-core--record-error session error)
     (when (benedict-core--request-owned-p session run generation)
       (benedict-core--receive
        session generation
        (list :type :error :reason 'error
              :message (error-message-string error))))))
  nil)

(defun benedict-core--dispatch-prepared-request (session run generation request)
  "Validate and dispatch SESSION's prepared REQUEST owned by RUN and GENERATION."
  (setq request (copy-sequence request))
  (plist-put request :tools
             (benedict-core--normalize-tools (plist-get request :tools)))
  (benedict-core--validate-request request)
  (let* ((model (plist-get request :model))
         (tools (plist-get request :tools))
         (origin (list :provider (benedict-model-provider model)
                       :api (benedict-model-api model)
                       :model (let ((id (benedict-model-id model)))
                                (if (stringp id) (copy-sequence id) id)))))
    (when (benedict-core--request-owned-p session run generation)
      (setf (benedict-run-origin run) origin
            (benedict-run-offered-tools run) tools)
      (let ((cancel
             (benedict-provider-stream
              model request
              (lambda (event)
                (benedict-core--receive session generation event)))))
        (if (and (benedict-core--request-owned-p session run generation)
                 (benedict-run-stream-active-p run))
            (setf (benedict-run-stream-cancel run) cancel)
          (when (and (benedict-run-stream-active-p run)
                     (functionp cancel))
            (benedict-core--cancel-invalid-request session cancel))))))
  nil)

;;;; Stream events

(defun benedict-core--receive (session generation event)
  "Apply EVENT to SESSION unless GENERATION has been superseded.  Return nil.

Provider callbacks are an asynchronous boundary, so failures from lifecycle or
persistence observers enter the same bounded cleanup path as reducer errors.
Events after a stream's terminal event are ignored."
  (when-let* ((run (benedict-session-run session)))
    (when (and (= generation (benedict-run-generation run))
               (benedict-run-stream-active-p run))
      (condition-case error
          (benedict-core--handle-event session event)
        (error (benedict-core--fail-run session error)))))
  nil)

(defun benedict-core--handle-event (session event)
  "Apply one normalized stream EVENT to SESSION.  Return nil.
See `benedict-provider-stream' for the event vocabulary."
  (pcase (plist-get event :type)
    (:start (benedict-core--stream-start session event))
    (:block-start (benedict-core--block-start session event))
    (:block-delta (benedict-core--block-delta session event))
    (:block-end (benedict-core--block-end session event))
    (:done (benedict-core--finalize-stream session 'done event))
    (:error (benedict-core--finalize-stream session 'error event))
    (_ nil))
  nil)

(defun benedict-core--stream-start (session event)
  "Record the opening of a stream for SESSION from EVENT."
  (when-let* ((entry (benedict-session-streaming-entry session))
              (response-id (plist-get event :response-id)))
    (benedict-entry-meta-put entry :response-id response-id)))


(defun benedict-core--new-block (event)
  "Return an empty content block for the block-start EVENT."
  (pcase (plist-get event :block-type)
    ('thinking (list :type 'thinking :thinking ""))
    ('tool-call (list :type 'tool-call
                      :id (plist-get event :id)
                      :name (plist-get event :name)
                      :arguments nil))
    (_ (list :type 'text :text ""))))

(defun benedict-core--block-at (entry index)
  "Return ENTRY's content block at INDEX, growing the content list to reach it.
Padding with empty text blocks is defensive: a well-behaved adapter emits
indexes in order, and a gap should not lose the blocks that follow it."
  (let ((content (benedict-entry-content entry)))
    (while (<= (length content) index)
      (setq content (append content (list (list :type 'text :text "")))))
    (setf (benedict-entry-content entry) content)
    (nth index content)))

(defun benedict-core--set-block (entry index block)
  "Replace ENTRY's content block at INDEX with BLOCK.  Return BLOCK.
Grows the content list first when it is too short to reach INDEX."
  (benedict-core--block-at entry index)
  (let ((content (benedict-entry-content entry)))
    (setf (benedict-entry-content entry)
          (append (seq-take content index)
                  (list block)
                  (nthcdr (1+ index) content))))
  block)

(defun benedict-core--block-delta-key (block)
  "Return the plist key BLOCK accumulates streamed text into.
Tool-call arguments accumulate as raw partial JSON under a scratch key;
the adapter delivers the parsed arguments at block end, so the scratch
value is only ever shown, never interpreted."
  (pcase (benedict-block-type block)
    ('thinking :thinking)
    ('tool-call :arguments-json)
    (_ :text)))

(defun benedict-core--block-start (session event)
  "Install the content block EVENT opens on SESSION's streaming entry."
  (when-let* ((entry (benedict-session-streaming-entry session))
              (index (plist-get event :index)))
    (benedict-core--set-block entry index (benedict-core--new-block event))
    (benedict-hook-run session 'benedict-entry-update-functions entry index "")))

(defun benedict-core--block-delta (session event)
  "Append EVENT's delta to SESSION's streaming entry, in place."
  (when-let* ((entry (benedict-session-streaming-entry session))
              (index (plist-get event :index))
              (delta (plist-get event :delta)))
    (let* ((block (benedict-core--block-at entry index))
           (key (benedict-core--block-delta-key block)))
      ;; The key is present from block creation, so `plist-put' mutates the
      ;; block in place and every holder of it sees the growth.
      (plist-put block key (concat (or (plist-get block key) "") delta)))
    (benedict-hook-run session 'benedict-entry-update-functions entry index delta)))

(defun benedict-core--block-end (session event)
  "Finish the content block EVENT closes on SESSION's streaming entry.

A block-end may carry `:arguments' and `:signature'.  Arguments arrive
here rather than as deltas because an adapter is responsible for
assembling and parsing partial argument JSON before closing the block, so
the kernel never sees invalid JSON."
  (when-let* ((entry (benedict-session-streaming-entry session))
              (index (plist-get event :index)))
    (let ((block (benedict-core--block-at entry index)))
      (when (plist-member event :arguments)
        (plist-put block :arguments (plist-get event :arguments)))
      (when-let* ((signature (plist-get event :signature)))
        ;; `plist-put' extends a non-empty plist in place, so the block keeps
        ;; its identity and anything already holding it sees the signature.
        (plist-put block :signature signature))
      ;; The scratch key held partial argument JSON so a frontend could render
      ;; a tool call as it arrived.  It is display state, never interpreted,
      ;; and has no business in the transcript or the log.
      (when (plist-member block :arguments-json)
        (benedict-core--set-block
         entry index (benedict-core--strip-key block :arguments-json))))
    (benedict-hook-run session 'benedict-entry-update-functions entry index "")))

(defun benedict-core--strip-key (plist key)
  "Return a copy of PLIST with KEY and its value removed."
  (let ((out nil)
        (rest plist))
    (while rest
      (let ((k (pop rest))
            (v (pop rest)))
        (unless (eq k key)
          (push k out)
          (push v out))))
    (nreverse out)))

;;;; Finalizing a turn

(defun benedict-core--finalize-stream (session kind event)
  "Close SESSION's stream and append the entry it produced.  Return nil.

KIND is `done' or `error' and EVENT is the terminal stream event, which
carried the reason, the usage, and any message.  Either way a terminal
entry reaches the transcript with a stop reason and, for a failure, an
error message, so a failed turn is visible history rather than a gap."
  (let* ((run (benedict-core--run session))
         (entry (benedict-run-streaming-entry run)))
    (setf (benedict-run-stream-active run) nil)
    (setf (benedict-run-stream-cancel run) nil)
    (setf (benedict-run-streaming-entry run) nil)
    (when entry
      (benedict-core--tag-origin session entry)
      (benedict-entry-meta-put
       entry :stop-reason
       (if (eq kind 'done)
           (or (plist-get event :reason) 'stop)
         (or (plist-get event :reason) 'error)))
      (when-let* ((usage (plist-get event :usage)))
        (benedict-entry-meta-put entry :usage usage))
      (when-let* ((response-id (plist-get event :response-id)))
        (benedict-entry-meta-put entry :response-id response-id))
      (when-let* ((message (plist-get event :message)))
        (benedict-entry-meta-put entry :error-message message))
      (when (plist-member event :error-data)
        (benedict-entry-meta-put entry :error-data
                                 (plist-get event :error-data)))
      (benedict-core--append-entry session entry)
      (setf (benedict-run-assistant-entry run) entry))
    (cond
     ;; An abort already decided how this run ends; let the drain finish it.
     ((eq (benedict-session-state session) 'stopping)
      (benedict-core--defer session))
     ((eq kind 'done)
      (benedict-core--after-assistant-entry session entry))
     (t
      (setf (benedict-session-stop-reason session)
            (or (plist-get event :reason) 'error))
      (benedict-core--end-turn session)
      (benedict-core--finish-run session))))
  nil)

(defun benedict-core--tag-origin (session entry)
  "Record on ENTRY the copied origin of SESSION's active request.

Mutates ENTRY metadata.  The origin is captured from the final filtered request
at dispatch, so changing SESSION's model during a stream cannot relabel this
entry or its opaque signatures."
  (when-let* ((run (benedict-session-run session))
              (origin (benedict-run-origin run)))
    (benedict-entry-meta-put entry :provider (plist-get origin :provider))
    (benedict-entry-meta-put entry :api (plist-get origin :api))
    (benedict-entry-meta-put entry :model (plist-get origin :model)))
  entry)

(defun benedict-core--after-assistant-entry (session entry)
  "Dispatch the tools ENTRY asked for on SESSION.
Closes the turn instead when ENTRY asked for none."
  (let* ((run (benedict-core--run session))
         (calls (and entry (benedict-entry-tool-calls entry))))
    (cond
     (calls
      (setf (benedict-run-pending-calls run)
            (mapcar (lambda (call)
                      (benedict-invocation-from-block
                       call (benedict-run-offered-tools run)))
                    calls))
      (benedict-core--set-state session 'tool-dispatch)
      (benedict-core--defer session))
     (t
      (benedict-core--end-turn session)
      (benedict-core--continue-or-stop session)))))

(defun benedict-core--end-turn (session &optional safely)
  "Announce the end of SESSION's current turn once.

When SAFELY is non-nil, catch observer failures and return the first condition;
this is used by failure cleanup so turn-end notification cannot trap run-end
cleanup.  Every observer is attempted before a normal-path condition is
signalled."
  (let ((run (benedict-session-run session)))
    (when (and run (benedict-run-turn-started run)
               (not (benedict-run-turn-ended run)))
      (if safely
          (progn
            (setf (benedict-run-turn-ended run) t)
            (benedict-core--safe-hook-run
             session 'benedict-turn-end-functions
             (benedict-run-assistant-entry run)
             (reverse (benedict-run-results run))))
        (let (condition)
          (setf (benedict-run-turn-ended run) t)
          (setq condition
                (benedict-core--safe-hook-run
                 session 'benedict-turn-end-functions
                 (benedict-run-assistant-entry run)
                 (reverse (benedict-run-results run))))
          (when condition
            (signal (car condition) (cdr condition))))))))

;;;; Tool dispatch

(defun benedict-core--dispatch-next-tool (session)
  "Dispatch SESSION's next pending tool call, or finish the turn.  Return state."
  (let ((run (benedict-core--run session)))
    (let ((invocation (pop (benedict-run-pending-calls run))))
      (if invocation
          (let* ((generation (benedict-run-generation run))
                 (operation (benedict-core--tool-operation--create
                             :run run :generation generation)))
            (benedict-core--set-state session 'tool-wait)
            (when (and (benedict-core--tool-operation-valid-p session operation)
                       (not (eq (benedict-session-state session) 'stopping)))
              (benedict-hook-run session 'benedict-tool-start-functions invocation)
              (when (and (benedict-core--tool-operation-valid-p session operation)
                         (not (eq (benedict-session-state session) 'stopping)))
                (benedict-hook-dispatch
                 session invocation
                 (lambda (dispatched)
                   (when (and (benedict-core--tool-operation-valid-p session operation)
                              (not (benedict-core--tool-operation-dispatch-consumed
                                    operation))
                              (not (eq (benedict-session-state session) 'stopping)))
                     (setf (benedict-core--tool-operation-dispatch-consumed operation) t)
                     (benedict-tool-execute
                      dispatched
                      (lambda (result)
                        (condition-case error
                            (benedict-core--tool-done session operation dispatched result)
                          (error (benedict-core--fail-run session error)))))))
                 (lambda ()
                   (and (benedict-core--tool-operation-valid-p session operation)
                        (not (eq (benedict-session-state session) 'stopping))))))))
        (benedict-core--end-turn session)
        (benedict-core--continue-or-stop session))))
  (benedict-session-state session))

(defun benedict-core--tool-done (session operation invocation result)
  "Record RESULT for SESSION's OPERATION and INVOCATION, then advance once.

The operation identity and generation are checked before consuming the result
callback and after every extension boundary.  A consumed or stale callback is a
no-op, including callbacks that arrive after an aborted run has been replaced."
  (when (and (benedict-core--tool-operation-valid-p session operation)
             (not (benedict-core--tool-operation-result-consumed operation))
             (not (eq (benedict-session-state session) 'stopping)))
    (setf (benedict-core--tool-operation-result-consumed operation) t)
    (let ((run (benedict-session-run session)))
      (let ((result (benedict-hook-filter session 'benedict-tool-result-filter-functions
                                          result invocation)))
        (when (and (benedict-core--tool-operation-valid-p session operation)
                   (not (eq (benedict-session-state session) 'stopping)))
          (benedict-hook-run session 'benedict-tool-end-functions invocation result)
          (when (and (benedict-core--tool-operation-valid-p session operation)
                     (not (eq (benedict-session-state session) 'stopping)))
            (push result (benedict-run-results run))
            (benedict-core--emit-entry
             session
             (benedict-entry-create
              :role 'tool-result
              :content (list (benedict-tool-result-block invocation result))))
            (when (and (benedict-core--tool-operation-valid-p session operation)
                       (not (eq (benedict-session-state session) 'stopping)))
              (benedict-core--set-state session 'tool-dispatch)
              (benedict-core--defer session)))))))
  nil)

;;;; Turn boundaries

(defun benedict-core--continue-or-stop (session)
  "Decide at a turn boundary whether SESSION carries on.  Return the state.

A turn that produced tool results continues by default, because the model
has not yet seen them.  A turn that produced only text stops by default.
`benedict-continue-predicate-functions' may veto either way, and queued
input overrides a veto -- a human's queued message outranks a budget
filter."
  (let* ((run (benedict-core--run session))
         (continue (and (benedict-run-results run) t))
         (veto (benedict-hook-run-until-success
                session 'benedict-continue-predicate-functions)))
    (when veto
      (setf (benedict-session-stop-reason session) veto)
      (setq continue nil))
    (when (benedict-core--drain-queues session)
      (setq continue t))
    (if continue
        (benedict-core--start-turn session)
      (benedict-core--finish-run session))))

(defun benedict-core--drain-queues (session)
  "Move queued content for SESSION into the transcript.  Return non-nil if any.

Steering drains first; follow-ups are considered only when steering had
nothing, since a steering message has already kept the run alive and the
follow-up can wait for the next boundary.  How much is taken from a queue
is `benedict-queue-drain-mode'."
  (or (benedict-core--drain-queue session 'steer)
      (benedict-core--drain-queue session 'follow-up)))

(defun benedict-core--drain-queue (session which)
  "Drain SESSION's `steer' or `follow-up' queue, as WHICH names.
Return non-nil when at least one message was taken."
  (let ((queue (if (eq which 'steer)
                   (benedict-session-steer-queue session)
                 (benedict-session-follow-up-queue session))))
    (when queue
      (let* ((taken (if (eq benedict-queue-drain-mode 'all) queue (list (car queue))))
             (left (nthcdr (length taken) queue)))
        (if (eq which 'steer)
            (setf (benedict-session-steer-queue session) left)
          (setf (benedict-session-follow-up-queue session) left))
        (dolist (content taken)
          (benedict-core--emit-user-entry session content))
        t))))

;;;; Draining an abort

(defun benedict-core--drain (session)
  "Finish aborting SESSION and return it to `idle'.  Return the state.

Called when the reducer advances a `stopping' session.  A stream that was
open is finalized as an aborted entry so the transcript never holds a
half-written one."
  (let ((run (benedict-session-run session)))
    (when (and run (benedict-run-streaming-entry run))
      (let ((entry (benedict-run-streaming-entry run)))
        (setf (benedict-run-stream-active run) nil)
        (setf (benedict-run-stream-cancel run) nil)
        (setf (benedict-run-streaming-entry run) nil)
        (benedict-core--tag-origin session entry)
        (benedict-entry-meta-put entry :stop-reason 'aborted)
        (benedict-entry-meta-put entry :error-message "Aborted")
        (benedict-core--append-entry session entry)
        (setf (benedict-run-assistant-entry run) entry)))
    (benedict-core--end-turn session))
  (benedict-core--finish-run session))

(provide 'benedict-core)

;;; benedict-core.el ends here
