;;; benedict-tool.el --- Tool definitions, registry, and invocation  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; What a tool is, how one is registered, and the protocol by which one is
;; called.  This file knows nothing about sessions, the reducer, or providers;
;; it is the vocabulary they share.
;;
;; Two things here are load-bearing and neither is obvious.
;;
;; First, EVERY handler is asynchronous: it takes an invocation and a `done'
;; continuation, and the call is finished when `done' is called.  A synchronous
;; handler is sugar (`:sync t') that gets wrapped, so the kernel has exactly one
;; code path.  The payoff is that a handler which never calls `done' simply
;; leaves the run suspended -- which is precisely what an approval prompt needs,
;; and it is why Benedict has no separate yield concept, no approval state in
;; the kernel, and no resume entry point.
;;
;; Second, an invocation is a value that filters rewrite rather than a command
;; they intercept.  `benedict-tool-blocked' returns a modified invocation, so
;; denying a call is the same operation as allowing one: hand `next' an
;; invocation.  Rerouting is that operation too -- substitute a `tool' whose
;; handler runs the call in a subordinate Emacs and execution here cannot tell,
;; which is what keeps sandboxing entirely an extension's business.  The filter
;; chain that consumes these lives in `benedict-core'.
;;
;; See SPEC-001 6.

;;; Code:

(require 'cl-lib)
(require 'benedict)
(require 'benedict-schema)

;;;; Errors

(define-error 'benedict-tool-error
  "Benedict tool error"
  'benedict-error)

(define-error 'benedict-tool-unknown
  "No such Benedict tool"
  'benedict-tool-error)

;;;; Tools

(cl-defstruct (benedict-tool (:constructor benedict-tool--create)
                             (:copier nil))
  "A callable capability offered to the model.

Construct with `benedict-tool-create', which compiles the parameter DSL,
or with the `benedict-deftool' macro, which also registers the result."
  (id nil
      :documentation "Symbol naming this tool.  Unique across the registry.")
  (label nil
         :documentation "Short human-readable name, for a frontend to display.
Falls back to the id when nil.")
  (description nil
               :documentation "Prose sent to the model describing what the tool does.
This is prompt text, not a docstring: it is the model's only guidance on
when to reach for the tool, so write it for that reader.")
  (parameters nil
              :documentation "The `benedict-schema' parameter DSL this tool was defined with.
Kept alongside the compiled schema because it is what a human or an agent
reading the tool back wants to see.")
  (schema nil
          :documentation "Compiled JSON Schema plist, ready for `json-serialize'.
Produced from `parameters' by `benedict-schema-compile' at definition
time, so a malformed DSL fails when the tool is defined rather than when
a request is built.")
  (handler nil
           :documentation "Function of (INVOCATION DONE) that performs the call.
DONE is called with a `benedict-tool-result-value' when the call
finishes.  A handler that never calls DONE leaves the run suspended,
which is a supported state rather than a bug.")
  (meta nil
        :documentation "Property list for extension-defined attributes.
The kernel does not interpret it."))

(cl-defun benedict-tool-create (&key id label description parameters handler sync)
  "Return a new tool named ID.

LABEL is the short human-readable name a frontend displays, defaulting
to ID.  DESCRIPTION is the prose the model sees.  PARAMETERS is the
`benedict-schema' DSL and is compiled here, so a malformed DSL signals
`benedict-schema-error' now rather than at request time.  HANDLER is a
function of (INVOCATION DONE) unless SYNC is non-nil, in which case it
is a function of (INVOCATION) returning a result and is wrapped to
satisfy the asynchronous contract.

Signal `benedict-tool-error' when ID is not a symbol or HANDLER is not a
function.  Does not register the tool; see `benedict-tool-register'."
  (unless (and id (symbolp id))
    (signal 'benedict-tool-error (list "Tool id is not a symbol" id)))
  (unless (functionp handler)
    (signal 'benedict-tool-error (list "Tool handler is not a function" id handler)))
  (benedict-tool--create
   :id id
   :label (or label (symbol-name id))
   :description description
   :parameters parameters
   :schema (benedict-schema-compile parameters)
   :handler (if sync (benedict-tool--sync-handler handler) handler)
   :meta nil))

(defun benedict-tool--sync-handler (handler)
  "Return HANDLER, a function of (INVOCATION), as one of (INVOCATION DONE).

The wrapper calls HANDLER and passes its return value to DONE, so a
synchronous tool satisfies the asynchronous contract without the kernel
learning that synchronous tools exist."
  (lambda (invocation done)
    (funcall done (funcall handler invocation))))

;;;; The registry

(defvar benedict-tool--registry (make-hash-table :test #'eq)
  "Hash table mapping a tool id symbol to its `benedict-tool'.")

(defun benedict-tool-register (tool)
  "Add TOOL to the registry, replacing any tool with the same id.  Return TOOL.

Replacement rather than refusal is deliberate: reloading an extension is
`load-file', and every registration primitive has to be idempotent for
that to work without an unregister protocol.  See SPEC-001 9.2."
  (unless (benedict-tool-p tool)
    (signal 'benedict-tool-error (list "Not a tool" tool)))
  (puthash (benedict-tool-id tool) tool benedict-tool--registry)
  tool)

(defun benedict-tool-get (id)
  "Return the registered tool named ID, or nil when there is none."
  (gethash id benedict-tool--registry))

(defun benedict-tool-get-or-signal (id)
  "Return the registered tool named ID.
Signal `benedict-tool-unknown' when no tool is registered under ID."
  (or (benedict-tool-get id)
      (signal 'benedict-tool-unknown (list id))))

(defun benedict-tool-unregister (id)
  "Remove the tool named ID from the registry.
Return non-nil when a tool was removed.

Reloading an extension does not need this, since registration replaces by
id, but withdrawing a tool does, and this is the only image-wide way:
withdrawing from one session is a tool selection that excludes it.  A
session selecting the whole registry stops offering ID on its next
request, while one naming ID in a list selection signals
`benedict-tool-unknown' the next time it resolves -- the selection
promised a tool that is gone, and a list quietly one entry short is not
something the model can notice."
  (let ((present (and (gethash id benedict-tool--registry) t)))
    (remhash id benedict-tool--registry)
    present))

(defun benedict-tool-list ()
  "Return every registered tool, sorted by id.

Sorted rather than in registration order because the list reaches the
model in this order, and a stable order keeps provider-side prompt caches
warm across restarts."
  (let ((tools nil))
    (maphash (lambda (_id tool) (push tool tools)) benedict-tool--registry)
    (sort tools (lambda (a b) (string< (symbol-name (benedict-tool-id a))
                                       (symbol-name (benedict-tool-id b)))))))

(defun benedict-tool-resolve (specs)
  "Return the tools named by SPECS, a list of ids and tool structs.

Ids are looked up in the registry and structs pass through, so a session
can be given a mix of registry names and one-off tools.  Signal
`benedict-tool-unknown' for an id with no registered tool -- silently
dropping it would present the model a tool list quietly missing an entry."
  (mapcar (lambda (spec)
            (cond
             ((benedict-tool-p spec) spec)
             ((symbolp spec) (benedict-tool-get-or-signal spec))
             (t (signal 'benedict-tool-error (list "Not a tool or tool id" spec)))))
          specs))

;;;###autoload
(defmacro benedict-deftool (name &rest body)
  "Define and register the tool NAME.

BODY is a plist accepting `:label', `:description', `:parameters',
`:sync', and `:handler', with the meanings given by
`benedict-tool-create'.  The tool is registered as a side effect of
evaluating the definition, so loading the file that defines it is all
that is required to make it available.

  (benedict-deftool eval-elisp
    :label \"Evaluate Elisp\"
    :description \"Evaluate an Emacs Lisp form in the running image.\"
    :parameters \\='((form :type string :required t
                        :description \"A single Emacs Lisp form.\"))
    :handler (lambda (invocation done)
               (funcall done (benedict-tool-result :content \"nil\"))))

Re-evaluating a definition replaces the previous tool, which is what
makes reloading an extension a plain `load-file'.  Returns the tool."
  (declare (indent 1) (doc-string 3))
  `(benedict-tool-register (benedict-tool-create :id ',name ,@body)))

;;;; Invocations

;; An invocation is one tool call in flight.  Filters receive it and return it
;; -- possibly a changed copy -- so blocking, rewriting, and rerouting are all
;; the same operation on the same value.

(cl-defstruct (benedict-invocation (:constructor benedict-invocation--create)
                                   (:copier nil))
  "One tool call in flight.

Passed through `benedict-tool-dispatch-functions', where a filter may
allow it, rewrite it, block it with `benedict-tool-blocked', reroute it
by substituting a `tool' that runs the call elsewhere, or suspend the run
by holding its continuation."
  (id nil
      :documentation "The provider's identifier for this call.
Matches the id of the `tool-result' block that answers it.")
  (name nil
        :documentation "Symbol naming the tool the model asked for.")
  (arguments nil
             :documentation "Decoded argument plist.
Adapters assemble and parse partial argument JSON before emitting a
tool-call block, so this is always complete and valid.  Read one
argument with `benedict-tool-arg'.")
  (tool nil
        :documentation "The resolved `benedict-tool', or nil when the model named
a tool that is not registered.  A nil tool becomes an error result
rather than a signal: the model must be told what happened.

This is also where a call is rerouted.  Execution funcalls whatever
handler this slot holds, so a dispatch filter that substitutes a tool
whose handler ships the invocation elsewhere -- a subordinate Emacs, a
worker -- has moved the work without anything here being aware that it
moved.  `name' and `arguments' are untouched by the substitution, so the
substituted handler still knows what was asked for.")
  (blocked-reason nil
                  :documentation "Non-nil when a filter denied this call, and the
prose explaining why.  A blocked invocation never reaches a handler; it
becomes an error result carrying this string."))

(cl-defun benedict-invocation-create (&key id name arguments tool)
  "Return a new invocation of the tool NAME with ARGUMENTS.

ID is the provider's call identifier.  TOOL is the resolved
`benedict-tool'; when omitted it is looked up in the registry and left
nil if there is none, since an unknown tool has to reach the model as an
error result rather than as a signal."
  (benedict-invocation--create
   :id id
   :name name
   :arguments arguments
   :tool (or tool (benedict-tool-get name))))

(defun benedict-invocation-from-block (block)
  "Return an invocation for BLOCK, a `tool-call' content block."
  (benedict-invocation-create
   :id (plist-get block :id)
   :name (plist-get block :name)
   :arguments (plist-get block :arguments)))

(defun benedict-tool-arg (invocation key &optional default)
  "Return the value of KEY in INVOCATION's arguments, or DEFAULT when absent.
Distinguishes an absent argument from one present with a nil value."
  (let ((arguments (benedict-invocation-arguments invocation)))
    (if (plist-member arguments key) (plist-get arguments key) default)))

(defun benedict-invocation--copy (invocation)
  "Return a shallow copy of INVOCATION.
The struct copier is suppressed so that `benedict-invocation-with' is the
only documented way to derive one; this is its implementation."
  (benedict-invocation--create
   :id (benedict-invocation-id invocation)
   :name (benedict-invocation-name invocation)
   :arguments (benedict-invocation-arguments invocation)
   :tool (benedict-invocation-tool invocation)
   :blocked-reason (benedict-invocation-blocked-reason invocation)))

(defun benedict-invocation-with (invocation &rest keys-and-values)
  "Return a copy of INVOCATION with KEYS-AND-VALUES replacing its slots.

Does not modify INVOCATION.  KEYS-AND-VALUES is a plist whose keys are
`:id', `:name', `:arguments', `:tool', or `:blocked-reason'.
This is how a dispatch filter rewrites a call -- mutating the invocation
in place would be visible to filters that already ran.

Signal `benedict-tool-error' on an odd argument count or an unknown key."
  (when (cl-oddp (length keys-and-values))
    (signal 'benedict-tool-error
            (list "Odd number of invocation arguments" keys-and-values)))
  (let ((copy (benedict-invocation--copy invocation))
        (rest keys-and-values))
    (while rest
      (let ((key (pop rest))
            (value (pop rest)))
        (pcase key
          (:id (setf (benedict-invocation-id copy) value))
          (:name (setf (benedict-invocation-name copy) value))
          (:arguments (setf (benedict-invocation-arguments copy) value))
          (:tool (setf (benedict-invocation-tool copy) value))
          (:blocked-reason (setf (benedict-invocation-blocked-reason copy) value))
          (_ (signal 'benedict-tool-error (list "Unknown invocation key" key))))))
    copy))

(defun benedict-tool-blocked (invocation reason)
  "Return a copy of INVOCATION marked as denied, explaining REASON.

Hand the result to a dispatch filter's `next' continuation to deny a
call.  Denial is not an error and not an exception: the call becomes a
tool result with `error-p' set and REASON as its content, because a model
that asked for a tool must always be told what happened to it."
  (benedict-invocation-with invocation :blocked-reason reason))

(defun benedict-invocation-blocked-p (invocation)
  "Return non-nil when INVOCATION was denied by a dispatch filter."
  (and (benedict-invocation-blocked-reason invocation) t))

;;;; Results

(cl-defstruct (benedict-tool-result-value
               (:constructor benedict-tool-result-value--create)
               (:copier nil))
  "The outcome of one tool call.

Construct with `benedict-tool-result'.  A failed call is still a normal
result rather than a signal: it is appended to the transcript and shown
to the model like any other."
  (content nil
           :documentation "The payload the model sees.
A string, or a list of content blocks when the result carries structure
a frontend should render -- a diff, an image.")
  (error-p nil
           :documentation "Non-nil when the call failed.
The content is then the explanation.")
  (meta nil
        :documentation "Property list of extension-defined attributes.
The kernel does not interpret it; a frontend may."))

(cl-defun benedict-tool-result (&key content error-p meta)
  "Return a tool result carrying CONTENT.

ERROR-P marks a failed call, in which case CONTENT explains the failure.
META is a plist the kernel does not interpret.  This is what a handler
passes to its `done' continuation."
  (benedict-tool-result-value--create :content content :error-p error-p :meta meta))

(defun benedict-tool-result-error (content &optional meta)
  "Return a failed tool result explaining CONTENT, with metadata META."
  (benedict-tool-result :content content :error-p t :meta meta))

(defun benedict-tool-result-block (invocation result)
  "Return the `tool-result' content block answering INVOCATION with RESULT.
The block's id matches INVOCATION's, which is what pairs a result with
its call when the transcript is lowered to the wire."
  (list :type 'tool-result
        :id (benedict-invocation-id invocation)
        :name (benedict-invocation-name invocation)
        :content (benedict-tool-result-value-content result)
        :error-p (and (benedict-tool-result-value-error-p result) t)))

;;;; Execution

;; Execution funcalls the handler of whatever tool the invocation carries, and
;; that is the whole of it.  There is no table of execution targets, because
;; there is nothing for one to decide: a dispatch filter that wants a call to
;; run somewhere else substitutes a tool whose handler sends it there, and this
;; function cannot tell the difference.  An earlier design had a `target' slot
;; and a registry of executors keyed by it; the registry turned out to be a
;; second way to spell tool substitution, and the worse one, since a custom
;; executor ran outside the `condition-case' below.

(defun benedict-tool-execute (invocation done)
  "Execute INVOCATION and call DONE with a `benedict-tool-result-value'.

Two conditions short-circuit to a failed result rather than signalling,
because each is something the model has to learn about in order to
recover: INVOCATION was blocked by a dispatch filter, or it names a tool
that is not registered.  An error signalled by the handler is a third:
a tool that breaks must not take the run with it, and the model needs to
see what went wrong in order to try something else.

DONE may be called on a later turn of the event loop.  A handler that
never calls it leaves the run suspended, which is how approval works --
and is also how a handler that sends the call to another process waits
for the answer."
  (cond
   ((benedict-invocation-blocked-p invocation)
    (funcall done (benedict-tool-result-error
                   (benedict-invocation-blocked-reason invocation))))
   ((null (benedict-invocation-tool invocation))
    (funcall done (benedict-tool-result-error
                   (format "No such tool: %s" (benedict-invocation-name invocation)))))
   (t
    (condition-case error
        (funcall (benedict-tool-handler (benedict-invocation-tool invocation))
                 invocation done)
      (error
       (funcall done
                (benedict-tool-result-error
                 (format "Tool %s signalled: %s"
                         (benedict-invocation-name invocation)
                         (error-message-string error)))))))))

(provide 'benedict-tool)

;;; benedict-tool.el ends here
