;;; benedict-provider.el --- Provider and API registries, model records  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A provider is not an API, and conflating the two is the most expensive
;; mistake available in this part of the system.
;;
;; An API is a WIRE PROTOCOL: request shape, header set, streaming event
;; grammar.  There are few of them and each is expensive -- eight hundred to
;; fifteen hundred lines.
;;
;; A provider is a SERVICE that speaks one: an id, a base URL, an auth method,
;; and a model catalog.  There are many of them and each is a dozen lines.
;; Vercel AI Gateway, OpenRouter, Groq, Together, and Fireworks are catalog
;; entries over the same handful of protocol implementations.  Keeping them
;; separate is what makes adding the fifth service cost nothing.
;;
;; This file holds both registries, the model record, and the single entry
;; point through which the kernel reaches a provider: `benedict-provider-stream'.
;; It contains no protocol implementation of its own.  Wire adapters live in
;; api/ and services in providers/, both above this layer.
;;
;; Differences between services that speak the same protocol are declarative:
;; a `compat' plist on the provider or the model, consulted by the adapter.
;; They are never `if provider-is-x' branches inside an adapter -- that is the
;; thing this split exists to prevent.  When a new service needs a behavior no
;; flag expresses, add a flag.
;;
;; See SPEC-001 7.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'benedict)

;;;; Errors

(define-error 'benedict-provider-error
  "Benedict provider error"
  'benedict-error)

(define-error 'benedict-provider-unknown
  "No such Benedict provider"
  'benedict-provider-error)

(define-error 'benedict-api-unknown
  "No such Benedict wire API"
  'benedict-provider-error)

(define-error 'benedict-model-unknown
  "No such Benedict model"
  'benedict-provider-error)

(define-error 'benedict-provider-no-transport
  "Benedict provider has no way to send a request"
  'benedict-provider-error)

;;;; Wire APIs

(cl-defstruct (benedict-api (:constructor benedict-api--create)
                            (:copier nil))
  "One wire protocol: how a request is shaped and how a stream is read.

Every function here is pure with respect to Benedict state; an adapter
holds no globals.  Streaming state lives in the closure `make-parser'
returns, which is more idiomatic in Emacs Lisp than threading an explicit
state object and keeps an adapter's internals genuinely private."
  (id nil
      :documentation "Symbol naming this protocol, such as `openai-responses'.")
  (name nil
        :documentation "Human-readable protocol name.")
  (endpoint nil
            :documentation "Function of (MODEL AUTH) returning the request URL.")
  (headers nil
           :documentation "Function of (MODEL AUTH) returning an alist of HTTP headers.")
  (build nil
         :documentation "Function of (REQUEST MODEL) returning the request body.
REQUEST is the canonical plist described by `benedict-provider-stream';
lowering its entries to this protocol's wire shape happens here.")
  (make-parser nil
               :documentation "Function of no arguments returning a stream parser.

The parser is a closure of (SSE-EVENT) returning a list of normalized
events.  It is a closure rather than a function plus a state object
because it holds mutable state -- partial JSON accumulators, block index
mapping, reasoning item ids -- across the whole stream.")
  (meta nil
        :documentation "Property list of adapter-defined attributes."))

(defvar benedict-api--registry (make-hash-table :test #'eq)
  "Hash table mapping an API id symbol to its `benedict-api'.")

(defun benedict-api-register (api)
  "Add API to the registry, replacing any API with the same id.  Return API.
Replacement keeps `load-file' working as the reload mechanism; see
SPEC-001 9.2."
  (unless (benedict-api-p api)
    (signal 'benedict-provider-error (list "Not an API" api)))
  (puthash (benedict-api-id api) api benedict-api--registry)
  api)

(defun benedict-api-get (id)
  "Return the registered wire API named ID, or nil when there is none."
  (gethash id benedict-api--registry))

(defun benedict-api-get-or-signal (id)
  "Return the registered wire API named ID.
Signal `benedict-api-unknown' when nothing is registered under ID."
  (or (benedict-api-get id) (signal 'benedict-api-unknown (list id))))

(defun benedict-api-unregister (id)
  "Remove the wire API named ID from the registry.
Return non-nil when an API was removed."
  (let ((present (and (gethash id benedict-api--registry) t)))
    (remhash id benedict-api--registry)
    present))

(defun benedict-api-list ()
  "Return every registered wire API, sorted by id."
  (let ((apis nil))
    (maphash (lambda (_id api) (push api apis)) benedict-api--registry)
    (sort apis (lambda (a b) (string< (symbol-name (benedict-api-id a))
                                      (symbol-name (benedict-api-id b)))))))

;;;###autoload
(defmacro benedict-defapi (name &rest body)
  "Define and register the wire API NAME.

BODY is a plist accepting `:name', `:endpoint', `:headers', `:build',
`:make-parser', and `:meta', with the meanings given by the `benedict-api'
slot documentation.

  (benedict-defapi openai-responses
    :name        \"OpenAI Responses\"
    :endpoint    #\\='my-api--endpoint
    :headers     #\\='my-api--headers
    :build       #\\='my-api--build
    :make-parser #\\='my-api--parser)

Re-evaluating replaces the previous definition.  Returns the API."
  (declare (indent 1))
  `(benedict-api-register (benedict-api--create :id ',name ,@body)))

;;;; Providers

(cl-defstruct (benedict-provider (:constructor benedict-provider--create)
                                 (:copier nil))
  "One service that speaks a wire API.

Cheap by construction: an id, where to reach it, which protocol it
speaks, how to authenticate, and what models it offers.  A provider
carries no protocol logic, which is what keeps adding one to a dozen
lines."
  (id nil
      :documentation "Symbol naming this service, such as `vercel-ai-gateway'.")
  (name nil
        :documentation "Human-readable service name.")
  (base-url nil
            :documentation "Root URL requests are built against.
May be overridden per credential: some subscription providers return
their own endpoint at login, which is why resolved auth carries a
`:base-url' of its own.")
  (api nil
       :documentation "Symbol naming the wire API this service speaks.")
  (auth nil
        :documentation "Authentication method descriptor.
Opaque to this file; `benedict-auth' interprets it.")
  ;; These two slots are spelled `-function' so that their generated accessors
  ;; do not collide with `benedict-provider-models' and
  ;; `benedict-provider-stream', which are the functions callers actually want.
  ;; `benedict-defprovider' accepts the short `:models' and `:stream' keys.
  (models-function nil
                   :documentation "Function of (&optional FORCE) returning this service's models.
Resolved at runtime with an on-disk cache rather than generated at build
time, because Benedict has no build step.  Falls back to a small
hardcoded list when the network is unavailable, so the system stays
usable offline.  Call it through `benedict-provider-models'.")
  (stream-function nil
                   :documentation "Optional function of (MODEL REQUEST HANDLER) that sends a request.

Present only for providers that supply their own transport, such as the
fake provider.  When nil, `benedict-provider-stream' routes through this
provider's wire API and the shared HTTP layer.  Returns a cancel thunk;
see `benedict-provider-stream'.")
  (compat nil
          :documentation "Property list of declarative capability flags.
Consulted by the wire adapter so that services differing under one
protocol need no provider-specific branches inside it.  Merged with the
model's own flags by `benedict-model-compat', model winning.")
  (meta nil
        :documentation "Property list of provider-defined attributes."))

(defvar benedict-provider--registry (make-hash-table :test #'eq)
  "Hash table mapping a provider id symbol to its `benedict-provider'.")

(defun benedict-provider-register (provider)
  "Add PROVIDER to the registry, replacing any with the same id.
Return PROVIDER."
  (unless (benedict-provider-p provider)
    (signal 'benedict-provider-error (list "Not a provider" provider)))
  (puthash (benedict-provider-id provider) provider benedict-provider--registry)
  provider)

(defun benedict-provider-get (id)
  "Return the registered provider named ID, or nil when there is none."
  (gethash id benedict-provider--registry))

(defun benedict-provider-get-or-signal (id)
  "Return the registered provider named ID.
Signal `benedict-provider-unknown' when nothing is registered under ID."
  (or (benedict-provider-get id) (signal 'benedict-provider-unknown (list id))))

(defun benedict-provider-unregister (id)
  "Remove the provider named ID from the registry.
Return non-nil when a provider was removed.  Extensions do not need this
-- reloading replaces by id -- but tests and a provider-toggling UI do."
  (let ((present (and (gethash id benedict-provider--registry) t)))
    (remhash id benedict-provider--registry)
    present))

(defun benedict-provider-list ()
  "Return every registered provider, sorted by id."
  (let ((providers nil))
    (maphash (lambda (_id provider) (push provider providers))
             benedict-provider--registry)
    (sort providers (lambda (a b) (string< (symbol-name (benedict-provider-id a))
                                           (symbol-name (benedict-provider-id b)))))))

(eval-and-compile
  (defun benedict-provider--rename-keys (body)
    "Return BODY with `:models' and `:stream' renamed to their slot keys.
Used by `benedict-defprovider' so the definition surface keeps the short
names given in SPEC-001 7.2 while the slots keep collision-free
accessors."
    (let ((out nil)
          (rest body))
      (while rest
        (let ((key (pop rest))
              (value (pop rest)))
          (push (pcase key
                  (:models :models-function)
                  (:stream :stream-function)
                  (_ key))
                out)
          (push value out)))
      (nreverse out))))

;;;###autoload
(defmacro benedict-defprovider (name &rest body)
  "Define and register the provider NAME.

BODY is a plist accepting `:name', `:base-url', `:api', `:auth',
`:models', `:stream', `:compat', and `:meta', with the meanings given by
the `benedict-provider' slot documentation.

  (benedict-defprovider vercel-ai-gateway
    :name     \"Vercel AI Gateway\"
    :base-url \"https://ai-gateway.vercel.sh/v1\"
    :api      \\='openai-responses
    :models   #\\='my-provider--catalog
    :compat   \\='(:supports-developer-role t))

`:models' and `:stream' are accepted under those names and stored in the
`models-function' and `stream-function' slots, whose accessors would
otherwise collide with the functions of the same name.

Re-evaluating replaces the previous definition.  Returns the provider."
  (declare (indent 1))
  `(benedict-provider-register
    (benedict-provider--create :id ',name ,@(benedict-provider--rename-keys body))))

;;;; Models

(cl-defstruct (benedict-model (:constructor benedict-model-create)
                              (:copier nil))
  "One model offered by one provider over one wire API.

The provider/api/model triple is the model's IDENTITY, not a label: a
transcript may hold entries produced by several models, and each is
lowered to the wire according to its own origin so that signatures are
only ever replayed to the model that issued them.  See
`benedict-model-same-origin-p'."
  (id nil
      :documentation "String naming the model to its provider, such as \"openai/gpt-5\".
A string rather than a symbol because it is provider vocabulary and
frequently contains slashes and dots.")
  (name nil
        :documentation "Human-readable model name.")
  (provider nil
            :documentation "Symbol naming the provider offering this model.")
  (api nil
       :documentation "Symbol naming the wire API this model is addressed through.
Usually the provider's, but a provider may serve some models over a
different protocol.")
  (context-window nil
                  :documentation "Maximum context size in tokens, or nil when unknown.
Compaction reads this to pick its soft threshold.")
  (max-tokens nil
              :documentation "Maximum tokens this model will generate in one response.")
  (reasoning-p nil
               :documentation "Non-nil when this model emits thinking blocks.")
  (input-modalities nil
                    :documentation "List of accepted input kinds: `text', `image'.
Lowering turns images into placeholder text for a model without `image'.")
  (cost nil
        :documentation "Property list of per-million-token rates.
Keys `:input', `:output', `:cache-read', `:cache-write'.")
  (compat nil
          :documentation "Property list of declarative capability flags for this model.
Overrides the provider's flags of the same name; read a single flag with
inheritance through `benedict-model-compat-get'.")
  (meta nil
        :documentation "Property list of catalog-defined attributes."))

(defun benedict-model-triple (model)
  "Return MODEL's identity as a (PROVIDER API MODEL-ID) list.
Useful for reporting; use `benedict-model-same-origin-p' to compare."
  (list (benedict-model-provider model)
        (benedict-model-api model)
        (benedict-model-id model)))

(defun benedict-model-same-origin-p (model origin)
  "Return non-nil when ORIGIN names exactly MODEL's provider, API, and model.

ORIGIN is a plist with `:provider', `:api', and `:model', as returned by
`benedict-entry-origin'.  All three must match.  This is the test that
decides whether an entry's provider-opaque signatures may be replayed
verbatim or must be degraded, and it is evaluated per entry rather than
per conversation."
  (and (eq (plist-get origin :provider) (benedict-model-provider model))
       (eq (plist-get origin :api) (benedict-model-api model))
       (equal (plist-get origin :model) (benedict-model-id model))))

(defun benedict-model-supports-p (model modality)
  "Return non-nil when MODEL accepts MODALITY, a symbol such as `image'.
A model with no declared modalities is assumed to accept text only."
  (and (memq modality (or (benedict-model-input-modalities model) '(text))) t))

(defun benedict-model-compat-get (model key &optional default)
  "Return the capability flag KEY for MODEL, or DEFAULT when unset.

Consults MODEL's own flags first, then its provider's, so a model may
override a service-wide default.  Adapters read differences between
services through this function rather than through branches on a
provider id -- when a new service needs a behavior no flag expresses,
add a flag rather than a branch."
  (let ((own (benedict-model-compat model)))
    (if (plist-member own key)
        (plist-get own key)
      (let* ((provider (benedict-provider-get (benedict-model-provider model)))
             (theirs (and provider (benedict-provider-compat provider))))
        (if (plist-member theirs key) (plist-get theirs key) default)))))

(defun benedict-provider-models (provider &optional force)
  "Return PROVIDER's model catalog, refreshing it when FORCE is non-nil.
Returns nil when PROVIDER declares no catalog function."
  (when-let* ((models (benedict-provider-models-function provider)))
    (funcall models force)))

(defun benedict-model-resolve (spec)
  "Return the `benedict-model' that SPEC names.

SPEC is either a `benedict-model', which passes through, or a string
\"PROVIDER-ID/MODEL-ID\".  The split is at the FIRST slash only, because
model ids routinely contain slashes of their own:
\"vercel-ai-gateway/openai/gpt-5\" names the provider `vercel-ai-gateway'
and the model \"openai/gpt-5\".

Signal `benedict-provider-unknown' when no such provider is registered,
and `benedict-model-unknown' when the provider's catalog has no such
model."
  (cond
   ((benedict-model-p spec) spec)
   ((not (stringp spec))
    (signal 'benedict-provider-error (list "Not a model spec" spec)))
   (t
    (let ((slash (string-search "/" spec)))
      (unless slash
        (signal 'benedict-provider-error
                (list "Model spec has no provider prefix" spec)))
      (let* ((provider-id (intern (substring spec 0 slash)))
             (model-id (substring spec (1+ slash)))
             (provider (benedict-provider-get-or-signal provider-id)))
        (or (seq-find (lambda (model) (equal (benedict-model-id model) model-id))
                      (benedict-provider-models provider))
            (signal 'benedict-model-unknown (list provider-id model-id))))))))

;;;; Reaching a provider

;; This is the entire interface between the kernel and everything that talks to
;; a service.  The kernel knows the normalized event vocabulary of SPEC-001 7.3
;; and nothing else -- not HTTP, not SSE, not any wire shape.

(defun benedict-provider-stream (model request handler)
  "Send REQUEST for MODEL and call HANDLER with each normalized event.

REQUEST is the canonical plist the kernel assembles, after
`benedict-request-filter-functions' has transformed it:

  (:entries ENTRIES :system-prompt STRING :tools TOOLS :model MODEL
   :session SESSION)

ENTRIES are canonical `benedict-entry' structs.  Lowering them to a wire
format is the adapter's work, not the kernel's: there is one canonical
representation and N serializers, never a conversion between two wire
formats.

HANDLER receives event plists in the vocabulary of SPEC-001 7.3:

  (:type :start)
  (:type :block-start :index 0 :block-type text)
  (:type :block-delta :index 0 :delta \"Hel\")
  (:type :block-end   :index 0)
  (:type :done  :reason stop|length|tool-use :usage PLIST :response-id ID)
  (:type :error :reason error|aborted :message STRING)

A stream ends in exactly one of `:done' or `:error'.  An adapter must
never signal an Elisp error to its caller for a request, model, or
network failure -- failures are encoded as a terminal `:error' event, so
the kernel has one error path rather than two.

Returns a cancel thunk of no arguments, or nil when the stream cannot be
cancelled.  Calling it asks the provider to stop; the kernel does not
depend on it doing so promptly, and ignores any events that arrive
afterwards.

Signal `benedict-provider-no-transport' when MODEL's provider has no
`stream' function and its wire API has no HTTP transport available."
  (let* ((provider (benedict-provider-get-or-signal (benedict-model-provider model)))
         (stream (benedict-provider-stream-function provider)))
    (cond
     (stream (funcall stream model request handler))
     ;; The HTTP-backed path arrives with the first real wire adapter.  Naming
     ;; it here rather than requiring it keeps this file in the kernel layer:
     ;; `require' would point core/ at api/, which the boundary test forbids.
     ((fboundp 'benedict-api-stream)
      (funcall 'benedict-api-stream model request handler))
     (t
      (signal 'benedict-provider-no-transport
              (list (benedict-provider-id provider) (benedict-model-api model)))))))

(provide 'benedict-provider)

;;; benedict-provider.el ends here
