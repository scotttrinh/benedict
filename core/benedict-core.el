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
This produces finer interleaving: if a user types three corrections while
the agent works, injecting all three at once means the agent never gets
to act on the first before seeing the third, and the later messages were
usually written without knowledge of what the first would change.

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

It MUST NOT call THUNK synchronously.  The reducer re-enters itself only
through this function, and a synchronous implementation would grow the
stack by a frame per turn until it overflows -- which is exactly what a
fast scripted provider produces.

The default schedules THUNK with `run-at-time'.  Bind this to a queue
that a test drains by hand to step the state machine deterministically,
one transition at a time.")

(defun benedict-core--defer (session)
  "Arrange for the reducer to advance SESSION later.
Never advances it now; see `benedict-core-defer-function'."
  (funcall benedict-core-defer-function
           (lambda () (benedict-core--advance session))))

;;;; Run bookkeeping

;; The session carries this in its opaque `run' slot.  It holds everything that
;; is true only while a run is in flight, so that a session at rest is just its
;; transcript and its configuration.

(cl-defstruct (benedict-run (:constructor benedict-run--create)
                            (:copier nil))
  "Reducer bookkeeping for one run in flight."
  (generation 0
              :documentation "Counter bumped whenever outstanding work is superseded.

A stream and its tool callbacks capture the generation they were started
under, and anything arriving under a stale generation is discarded.  This
is what makes abort safe without trusting a provider to stop emitting
promptly, or a suspended tool never to resume.")
  (stream-active nil
                 :documentation "Non-nil while a provider stream is open.")
  (stream-cancel nil
                 :documentation "Thunk that asks the provider to stop, or nil.")
  (streaming-entry nil
                   :documentation "The partially-built assistant entry, or nil.
Mutated in place by stream events and not appended to the transcript
until the stream terminates.")
  (assistant-entry nil
                   :documentation "The assistant entry this turn produced, once final.")
  (pending-calls nil
                 :documentation "Invocations from this turn not yet dispatched, in order.")
  (results nil
           :documentation "Results collected this turn, in reverse call order."))

(defun benedict-run-stream-active-p (run)
  "Return non-nil when RUN has a provider stream open."
  (and (benedict-run-stream-active run) t))

(defun benedict-session-streaming-entry (session)
  "Return SESSION's live, partially-built assistant entry, or nil.

The kernel owns the stream accumulator: events mutate this entry in place
and are re-emitted as `benedict-entry-update-functions' carrying only a
block index and a delta, so a frontend re-renders the referenced block
from here rather than accumulating deltas itself.

The entry HAS NO ID until the stream terminates and it is appended."
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

Called on submit and re-entered from every asynchronous completion.  This
function must never be called from within itself; use
`benedict-core--defer'."
  (pcase (benedict-session-state session)
    ('provider-wait (benedict-core--request session))
    ('tool-dispatch (benedict-core--dispatch-next-tool session))
    ('tool-wait nil)                    ; waiting on a callback
    ('stopping (benedict-core--drain session))
    ('idle (benedict-core--maybe-start session))))

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

;;;; Lifecycle

;; These four are named for the session rather than for this file because
;; SPEC-001 4.1 publishes them under those names: they are the session's
;; verbs, and it is only their implementation that belongs with the reducer.

(defun benedict-session-submit (session input)
  "Submit INPUT to SESSION and start a run.  Return the session state.

INPUT is anything `benedict-entry-create' accepts, including a bare
string, or nil to resume without adding a message -- which is what
fork-and-switch does after moving the head.

Submitting while a run is already in flight does not start a second one:
INPUT is queued as steering and the symbol `steered' is returned.  A user
typing while the agent works is the ordinary case, and both a chat
frontend and a batch script want it to mean the same thing.

Signal `benedict-session-error' when SESSION has no model."
  (cond
   ((not (eq (benedict-session-state session) 'idle))
    (when input (benedict-session-steer session input))
    'steered)
   (t
    (unless (benedict-session-model session)
      (signal 'benedict-session-error (list "Session has no model" session)))
    (when input (benedict-core--emit-user-entry session input))
    (benedict-core--start-run session))))

(defun benedict-session-abort (session)
  "Ask SESSION to stop its run as soon as it can.  Return the session state.

Cancels any stream in flight, finalizes a partially-streamed entry with a
stop reason of `aborted' so the transcript never holds a half-written
entry, and discards results from tools that were still outstanding.
Returns immediately; the run ends on a later turn of the event loop.

Does nothing when SESSION is already idle, and nothing further when an
abort is already in progress -- a second call must not schedule a second
drain, or `benedict-run-end-functions' fires twice for one run.  Orphaned
tool calls left behind are not repaired here -- that is the lowering
pass's job, and keeping it there is what lets an aborted transcript still
be replayed."
  (unless (memq (benedict-session-state session) '(idle stopping))
    (setf (benedict-session-stop-reason session) 'aborted)
    (benedict-core--set-state session 'stopping)
    (when-let* ((run (benedict-session-run session)))
      (cl-incf (benedict-run-generation run))
      (when-let* ((cancel (benedict-run-stream-cancel run)))
        (setf (benedict-run-stream-cancel run) nil)
        (funcall cancel)))
    (benedict-core--defer session))
  (benedict-session-state session))

(defun benedict-core--start-run (session)
  "Begin a run for SESSION and return its state."
  (setf (benedict-session-run session) (benedict-run--create))
  (setf (benedict-session-stop-reason session) nil)
  (benedict-hook-run session 'benedict-run-start-functions)
  (benedict-core--start-turn session))

(defun benedict-core--start-turn (session)
  "Begin a turn for SESSION and return its state."
  (let ((run (benedict-core--run session)))
    (setf (benedict-run-results run) nil)
    (setf (benedict-run-assistant-entry run) nil))
  (benedict-hook-run session 'benedict-turn-start-functions)
  (benedict-core--set-state session 'provider-wait)
  (benedict-core--defer session)
  (benedict-session-state session))

(defun benedict-core--finish-run (session)
  "End SESSION's run, returning it to `idle'.  Return the state."
  (setf (benedict-session-run session) nil)
  (benedict-core--set-state session 'idle)
  (benedict-hook-run session 'benedict-run-end-functions)
  (benedict-session-state session))

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

(defun benedict-core--build-request (session)
  "Return the canonical request plist for SESSION's next turn."
  (let ((model (benedict-session-model session)))
    (benedict-hook-filter
     session 'benedict-request-filter-functions
     (list :entries (benedict-core--context-entries session)
           :system-prompt (benedict-session-system-prompt session)
           :tools (benedict-session-tools session)
           :model model
           :session session)
     model session)))

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
            (generation (cl-incf (benedict-run-generation run))))
        (setf (benedict-run-streaming-entry run) entry)
        (setf (benedict-run-stream-active run) t)
        (benedict-hook-run session 'benedict-entry-start-functions entry)
        (benedict-core--open-stream session generation))))
  (benedict-session-state session))

(defun benedict-core--open-stream (session generation)
  "Build and send SESSION's next request under GENERATION.  Return nil.

Events arriving under a superseded GENERATION are discarded, which is how
an aborted stream stops mattering without the provider having to
cooperate.

Anything that signals on the way to the wire -- a filter, a missing
transport, a provider that raises instead of reporting a terminal error
event -- is caught and turned into an `:error' event, so the reducer
keeps one error path rather than two."
  (let ((run (benedict-core--run session)))
    (condition-case error
        (let* ((model (benedict-session-model session))
               (request (benedict-core--build-request session))
               (cancel (benedict-provider-stream
                        model request
                        (lambda (event)
                          (benedict-core--receive session generation event)))))
          ;; A wholly synchronous provider can finish before returning, in
          ;; which case there is nothing left to cancel and the thunk is stale.
          (when (benedict-run-stream-active-p run)
            (setf (benedict-run-stream-cancel run) cancel)))
      (error
       (benedict-core--receive
        session generation
        (list :type :error :reason 'error
              :message (error-message-string error))))))
  nil)

(defun benedict-core--receive (session generation event)
  "Apply EVENT to SESSION unless GENERATION has been superseded.  Return nil."
  (when-let* ((run (benedict-session-run session)))
    (when (= generation (benedict-run-generation run))
      (benedict-core--handle-event session event)))
  nil)

;;;; Stream events

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
  "Record on ENTRY which model produced it for SESSION.

Load-bearing rather than diagnostic: a transcript may hold entries from
several models, and each is lowered to the wire according to its own
origin so that provider-opaque signatures are only ever replayed to the
model that issued them."
  (when-let* ((model (benedict-session-model session)))
    (benedict-entry-meta-put entry :provider (benedict-model-provider model))
    (benedict-entry-meta-put entry :api (benedict-model-api model))
    (benedict-entry-meta-put entry :model (benedict-model-id model)))
  entry)

(defun benedict-core--after-assistant-entry (session entry)
  "Dispatch the tools ENTRY asked for on SESSION.
Closes the turn instead when ENTRY asked for none."
  (let* ((run (benedict-core--run session))
         (calls (and entry (benedict-entry-tool-calls entry))))
    (cond
     (calls
      (setf (benedict-run-pending-calls run)
            (mapcar #'benedict-invocation-from-block calls))
      (benedict-core--set-state session 'tool-dispatch)
      (benedict-core--defer session))
     (t
      (benedict-core--end-turn session)
      (benedict-core--continue-or-stop session)))))

(defun benedict-core--end-turn (session)
  "Announce the end of SESSION's current turn."
  (let ((run (benedict-session-run session)))
    (benedict-hook-run session 'benedict-turn-end-functions
                       (and run (benedict-run-assistant-entry run))
                       (and run (reverse (benedict-run-results run))))))

;;;; Tool dispatch

(defun benedict-core--dispatch-next-tool (session)
  "Dispatch SESSION's next pending tool call, or finish the turn.  Return state."
  (let ((run (benedict-core--run session)))
    (if-let* ((invocation (pop (benedict-run-pending-calls run))))
        (let ((generation (benedict-run-generation run)))
          ;; The state moves before the chain runs, so a tool that completes
          ;; synchronously still finds the session where it expects to.
          (benedict-core--set-state session 'tool-wait)
          (benedict-hook-run session 'benedict-tool-start-functions invocation)
          (benedict-hook-dispatch
           session invocation
           (lambda (dispatched)
             (benedict-tool-execute
              dispatched
              (lambda (result)
                (benedict-core--tool-done session generation dispatched result))))))
      (benedict-core--end-turn session)
      (benedict-core--continue-or-stop session)))
  (benedict-session-state session))

(defun benedict-core--tool-done (session generation invocation result)
  "Record RESULT for INVOCATION on SESSION and advance.  Return nil.

Does nothing when GENERATION has been superseded, which is how a tool
that was suspended on an approval when the run was aborted quietly stops
mattering instead of appending to a finished transcript."
  (let ((run (benedict-session-run session)))
    (when (and run (= generation (benedict-run-generation run)))
      (let ((result (benedict-hook-filter session 'benedict-tool-result-filter-functions
                                          result invocation)))
        (benedict-hook-run session 'benedict-tool-end-functions invocation result)
        (push result (benedict-run-results run))
        (benedict-core--emit-entry
         session
         (benedict-entry-create
          :role 'tool-result
          :content (list (benedict-tool-result-block invocation result))))
        (unless (eq (benedict-session-state session) 'stopping)
          (benedict-core--set-state session 'tool-dispatch))
        (benedict-core--defer session))))
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
