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
This is prompt text, not API documentation.  Tell the model when to use
the tool and what result to expect.")
  (parameters nil
              :documentation "The `benedict-schema' parameter DSL this tool was defined with.
This is the readable source form of the compiled `schema' slot.")
  (schema nil
          :documentation "Compiled JSON Schema plist, ready for `json-serialize'.
`benedict-tool-create' compiles it from `parameters'.")
  (handler nil
           :documentation "Function of (INVOCATION DONE) that performs the call.
DONE is called with a `benedict-tool-result-value' when the call
finishes.  A handler that never calls DONE leaves the run suspended,
which allows approval prompts and external workers to resume it later.")
  (meta nil
        :documentation "Property list for extension-defined attributes.
The kernel does not interpret it."))

(cl-defun benedict-tool-create (&key id label description parameters handler sync)
  "Create and return a tool named ID without registering it.

LABEL is the short human-readable name a frontend displays, defaulting
to ID.  DESCRIPTION is the prose the model sees.  PARAMETERS is the
`benedict-schema' DSL and is compiled before the tool is returned.  HANDLER is a
function of (INVOCATION DONE) unless SYNC is non-nil, in which case it
is a function of (INVOCATION) returning a result and is wrapped to
satisfy the asynchronous contract.

Signal `benedict-tool-error' when ID is not a symbol or HANDLER is not a
function.  Signal `benedict-schema-error' when PARAMETERS is invalid."
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

Signal `benedict-tool-error' when TOOL is not a `benedict-tool'.
Replacement makes reloading an extension idempotent; see SPEC-001 9.2."
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

Sessions selecting the full registry stop offering ID on their next request.
A session whose explicit selection names ID instead signals
`benedict-tool-unknown' when it next resolves that selection."
  (let ((present (and (gethash id benedict-tool--registry) t)))
    (remhash id benedict-tool--registry)
    present))

(defun benedict-tool-list ()
  "Return every registered tool, sorted by id.

The stable order keeps provider-side prompt caches useful across restarts."
  (let ((tools nil))
    (maphash (lambda (_id tool) (push tool tools)) benedict-tool--registry)
    (sort tools (lambda (a b) (string< (symbol-name (benedict-tool-id a))
                                       (symbol-name (benedict-tool-id b)))))))

(defun benedict-tool-resolve (specs)
  "Resolve SPECS and return a list of `benedict-tool' objects.

Each member of SPECS may be a registered tool id or a `benedict-tool', which
passes through unchanged.  Signal `benedict-tool-unknown' for an unregistered
id and `benedict-tool-error' for any other value."
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
`benedict-tool-create'.  Evaluating the definition registers the tool.

  (benedict-deftool eval-elisp
    :label \"Evaluate Elisp\"
    :description \"Evaluate an Emacs Lisp form in the running image.\"
    :parameters \\='((form :type string :required t
                        :description \"A single Emacs Lisp form.\"))
    :handler (lambda (invocation done)
               (funcall done (benedict-tool-result :content \"nil\"))))

Re-evaluating NAME replaces its previous registration.  Return the tool."
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
`:id', `:name', `:arguments', `:tool', or `:blocked-reason'.  Dispatch
filters use this function to rewrite or reroute a call.

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

Pass the result to a dispatch filter's NEXT continuation to deny the call.
Execution converts it to a failed tool result whose content is REASON."
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

Blocked calls, unknown tools, and errors signalled by a handler become failed
tool results instead of escaping this function.  This ensures the model receives
a result for every call it made.

DONE may be called asynchronously.  Until it is called, the run remains
suspended."
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
