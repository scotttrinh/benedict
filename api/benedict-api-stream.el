;;; benedict-api-stream.el --- The shared auth, transport, and parse path  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; One function, reached by `fboundp' from `benedict-provider-stream' and by
;; nothing else.  It is the composition every HTTP-backed provider shares:
;; resolve a credential, ask the wire adapter for a URL, headers, and a body,
;; hand those to the transport, and feed the bytes that come back through the
;; adapter's parser.
;;
;; The composition is here rather than in each adapter because what it composes
;; is the same for every wire protocol, and because SPEC-001 7.3's hardest
;; promise is easier to keep in one place than in N:
;;
;;   A STREAM NEVER SIGNALS, AND ENDS IN EXACTLY ONE `:done' OR `:error'.
;;
;; Both halves are load-bearing.  Signalling is not an option because most of
;; this file runs inside a process filter or a sentinel, where a signal
;; propagates nowhere a caller can catch it -- the request simply stops and the
;; session waits in `provider-wait' forever.  So an adapter that signals while
;; building a request, and a parser that signals halfway through a stream, are
;; both caught here and reported as a terminal `:error' the kernel already
;; knows how to handle.  And exactly one terminal event, because the reducer
;; finalizes the open entry when it sees one; a second would arrive after the
;; turn it belongs to has closed.
;;
;; Nothing here knows a wire format.  The three functions on a `benedict-api'
;; record are the whole seam:
;;
;;   endpoint     (MODEL AUTH) -> URL string
;;   headers      (MODEL AUTH) -> alist of (NAME . VALUE)
;;   build        (REQUEST MODEL) -> request body string
;;   make-parser  () -> (lambda (SSE-EVENT)) -> list of normalized events
;;
;; SSE-EVENT is a plist of `:event' and `:data', both strings and `:event' nil
;; when the stream sent no `event:' field.  The names are the SSE field names
;; on purpose: a parser reads the wire, and calling the fields anything else
;; would make the adapter and the recorded fixture describe the same bytes in
;; two vocabularies.
;;
;; See SPEC-001 7.3 and D19.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'benedict-provider)
(require 'benedict-log)
(require 'benedict-http)
(require 'benedict-auth)

;; Deliberately no `require' of `benedict-core'.  The kernel reaches this file
;; by `fboundp' precisely so that the two are separable, and requiring the
;; reducer back the other way to borrow one variable would undo that.  The
;; pattern is `benedict-provider-fake's; see `benedict-api-stream--defer'.
(defvar benedict-core-defer-function)

;;;; Configuration

(defconst benedict-api-stream-body-limit 400
  "Characters of an unrecognized error body to put in an error message.
A service that answers with an HTML page from a proxy in front of it is
an ordinary failure, and the whole page is not what the user needs to
read to understand it.")

;;;; The state of one stream

(cl-defstruct (benedict-api-stream--state
               (:constructor benedict-api-stream--state-create)
               (:copier nil))
  "Everything one call to `benedict-api-stream' has to remember.

Internal.  The two flags are what enforce SPEC-001 7.3: `terminated' is
set when a terminal event is ACCEPTED rather than when it is delivered,
so that events produced later in the same process filter are dropped
before they are ever queued."
  (handler nil
           :documentation "The kernel's event handler, called with one event.")
  (api nil
       :documentation "Symbol naming the wire API, once one has been resolved.
Carried only so that a failure can name the adapter it came from.  A
parser that signals is a bug in one adapter, and the log line that says
which is the difference between a report worth acting on and a report
that a stream broke.")
  (cancel nil
          :documentation "Thunk that abandons the transport, or nil.")
  (terminated nil
              :documentation "Non-nil once a `:done' or `:error' was accepted.")
  (cancelled nil
             :documentation "Non-nil once the caller asked to stop."))

;;;; Emitting

(defun benedict-api-stream--defer (thunk)
  "Schedule THUNK to run on a later turn of the event loop.

Every event goes through the kernel's own scheduler when it is bound.
Two reasons, and the first is not theoretical: `process-send-string' on a
body larger than the pipe buffer blocks, and a blocked send runs pending
filters and sentinels -- including another session's -- so a handler
called straight from a filter can re-enter the reducer in the middle of a
transition.  The second is that a test then steps this path with
`benedict-test-with-manual-defer', exactly as it steps every other."
  (funcall (or (and (boundp 'benedict-core-defer-function)
                    benedict-core-defer-function)
               (lambda (thunk) (run-at-time 0 nil thunk)))
           thunk))

(defun benedict-api-stream--emit (state event)
  "Deliver EVENT to STATE's handler on a later turn of the event loop.

Does nothing once the stream has been cancelled or has produced a
terminal event.  A terminal EVENT also abandons the transport: the stream
is over as far as the kernel is concerned, and leaving curl to pull
tokens nobody will read is waste at best and, after a parser failure,
waste for as long as the model keeps talking."
  (unless (or (benedict-api-stream--state-cancelled state)
              (benedict-api-stream--state-terminated state))
    (let ((handler (benedict-api-stream--state-handler state))
          (terminal (memq (plist-get event :type) '(:done :error))))
      (when terminal
        (setf (benedict-api-stream--state-terminated state) t))
      (benedict-api-stream--defer
       (lambda ()
         (unless (benedict-api-stream--state-cancelled state)
           (funcall handler event))))
      (when terminal
        (benedict-api-stream--abandon state)))))

(defun benedict-api-stream--fail (state message &optional error-data)
  "End STATE's stream with a terminal error carrying MESSAGE and ERROR-DATA.

A no-op once a terminal event has been emitted, which is what lets every
failure path call it without first working out whether it is the first
one to notice.  MESSAGE goes in `:message' rather than in a wider
`:reason' vocabulary: SPEC-001 7.3 has `error' and `aborted', and no
frontend yet exists that would branch on more."
  (benedict-api-stream--emit
   state (append (list :type :error :reason 'error :message message)
                 (when error-data (list :error-data error-data)))))

(defun benedict-api-stream--abandon (state)
  "Stop STATE's transport, if it has started one, emitting nothing."
  (when-let* ((cancel (benedict-api-stream--state-cancel state)))
    (setf (benedict-api-stream--state-cancel state) nil)
    (funcall cancel)))

(defun benedict-api-stream--cancel (state)
  "Abandon STATE at the kernel's request, emitting nothing at all.

Deliberately silent.  `benedict-session-abort' sets the stop reason and
finalizes the open entry itself rather than waiting to hear back, so a
terminal event from here would arrive after the turn it belongs to had
closed.  Events already queued are dropped rather than delivered."
  (setf (benedict-api-stream--state-cancelled state) t)
  (benedict-api-stream--abandon state))

;;;; The entry point

(defun benedict-api-stream (model request handler)
  "Send REQUEST for MODEL over its wire API, calling HANDLER with events.

The HTTP-backed implementation of `benedict-provider-stream', which
reaches it by `fboundp' and is the only caller.  MODEL, REQUEST, HANDLER,
the normalized event vocabulary, and the returned cancel thunk are all as
documented there.

MODEL's `api' names a `benedict-api' record, whose `endpoint', `headers',
and `build' functions produce the request and whose `make-parser' turns
the response into normalized events.  MODEL's `provider' names the
service whose credential is resolved, and whose `base-url' the adapter
sees through the auth value it is handed; see
`benedict-api-stream--effective-auth'.

Never signals.  A model whose API is not registered, a missing
credential, an adapter that signals while building, a transport failure,
a non-2xx response, a parser that signals mid-stream, and a connection
that closes early all arrive at HANDLER as one terminal `:error' event.

Returns a cancel thunk.  Calling it abandons the request and delivers
nothing further, including no terminal event."
  (let ((state (benedict-api-stream--state-create :handler handler)))
    (benedict-api-stream--begin state model request)
    (lambda () (benedict-api-stream--cancel state))))

(defun benedict-api-stream--begin (state model request)
  "Resolve MODEL's wire API and credential, then send REQUEST through STATE."
  (let ((api (benedict-api-get (benedict-model-api model)))
        (provider (benedict-provider-get (benedict-model-provider model))))
    (cond
     ((null provider)
      (benedict-api-stream--fail
       state (format "No provider named `%s' is registered"
                     (benedict-model-provider model))))
     ((null api)
      (benedict-api-stream--fail
       state (format "Model %s speaks `%s', and no such wire API is registered"
                     (benedict-model-id model) (benedict-model-api model))))
     (t
      (setf (benedict-api-stream--state-api state) (benedict-api-id api))
      ;; `benedict-auth-resolve' reports a missing or unusable credential
      ;; through its callback rather than by signalling, so this is one
      ;; failure path rather than two.  It may call back before it returns.
      (benedict-auth-resolve
       provider
       (lambda (auth error)
         (if error
             (benedict-api-stream--fail state (plist-get error :error))
           (benedict-api-stream--send
            state model request api
            (benedict-api-stream--effective-auth auth provider)))))))))

(defun benedict-api-stream--effective-auth (auth provider)
  "Return AUTH with PROVIDER's base URL filled in when AUTH names none.

SPEC-001 8.1 lets a credential carry its own `:base-url', and it wins:
some subscription providers hand back the endpoint to use at login.
Resolving that here rather than in each adapter is what lets an adapter's
`endpoint' function read `:base-url' off the auth value it is given and
never see a provider record at all.

A provider that authenticates nothing resolves to an AUTH of nil, and
gets a value carrying only the base URL -- an adapter reads `:api-key'
and finds it absent either way."
  (if (plist-get auth :base-url)
      auth
    (append auth (list :base-url (benedict-provider-base-url provider)))))

;;;; Building and sending

(defun benedict-api-stream--send (state model request api auth)
  "Build REQUEST for MODEL under API and AUTH, and stream it through STATE.

The method is POST because every wire protocol Benedict speaks posts;
`benedict-api' has no method slot because nothing has needed one."
  (unless (benedict-api-stream--state-cancelled state)
    (condition-case error
        (let ((url (funcall (benedict-api-endpoint api) model auth))
              (headers (funcall (benedict-api-headers api) model auth))
              (body (funcall (benedict-api-build api) request model))
              (parser (funcall (benedict-api-make-parser api))))
          (benedict-log-debug "api-stream: %s over %s"
            (benedict-model-id model) (benedict-api-id api))
          (setf (benedict-api-stream--state-cancel state)
                (benedict-http-stream
                 url
                 :method "POST"
                 :headers headers
                 :body body
                 :retry 0
                 :on-event (lambda (type data)
                             (benedict-api-stream--sse state parser type data))
                 :on-end (lambda (result)
                           (benedict-api-stream--end state result)))))
      ;; An adapter that signals here has emitted nothing, so the failure is
      ;; still expressible in the vocabulary the kernel understands.  Letting
      ;; it through instead would signal out of `benedict-provider-stream'
      ;; and leave the session waiting for a stream that was never opened.
      (error
       (benedict-api-stream--fail
        state (format "The %s adapter could not build the request: %s"
                      (benedict-api-id api) (error-message-string error)))))))

;;;; Reading the response

(defun benedict-api-stream--sse (state parser type data)
  "Feed the SSE event TYPE carrying DATA to PARSER, emitting through STATE."
  (unless (or (benedict-api-stream--state-cancelled state)
              (benedict-api-stream--state-terminated state))
    (condition-case error
        (dolist (event (funcall parser (list :event type :data data)))
          (benedict-api-stream--emit state event))
      ;; SPEC-001 D19, and the reason this file exists.  This runs inside a
      ;; process filter: a signal here reaches no caller, so without the
      ;; wrapper a parser bug is invisible and the session waits in
      ;; `provider-wait' until someone aborts it by hand.
      (error
       (benedict-log-error "api-stream: %s signalled: %s"
         (benedict-api-stream--state-api state) (error-message-string error))
       (benedict-api-stream--fail
        state (format "The %s adapter could not read the response: %s"
                      (benedict-api-stream--state-api state)
                      (error-message-string error)))))))

(defun benedict-api-stream--end (state result)
  "Turn the transport's RESULT into a terminal event on STATE.

RESULT is the plist `benedict-http-stream' passes its callback.  The 2xx
branch reads as though it fails a successful request, and does not:
`benedict-api-stream--fail' is a no-op once the parser has produced a
terminal event, so it fires only for a response that ended without one --
a connection closed mid-answer, which the transport sees as success
because the bytes it did receive arrived intact."
  ;; Whatever happens below is terminal, and the transport has already
  ;; stopped; dropping the handle keeps the terminal event from asking it to
  ;; stop again and logging a cancellation that did not happen.
  (setf (benedict-api-stream--state-cancel state) nil)
  (let ((status (plist-get result :status)))
    (cond
     ((plist-member result :error)
      (benedict-api-stream--fail state (plist-get result :error)
                                 (plist-get result :error-data)))
     ((and (integerp status) (<= 200 status 299))
      (benedict-api-stream--fail
       state "The response ended before the model finished answering"))
     (t
      (benedict-api-stream--fail
       state (benedict-api-stream--status-message
              status (plist-get result :body))
       (plist-get result :error-data))))))

(defun benedict-api-stream--status-message (status body)
  "Return the error message for a response with STATUS and BODY."
  (let ((detail (benedict-api-stream--body-message body)))
    (if detail
        (format "HTTP %s: %s" status detail)
      (format "HTTP %s, with no message in the response" status))))

(defun benedict-api-stream--body-message (body)
  "Return the human-readable message BODY carries, or nil when it has none.

BODY is whatever a service sent with a non-2xx status.  A JSON body in
one of the shapes services actually use gives up its message; anything
else -- an HTML page, a bare string, a truncated body -- falls back to
its own opening characters, which is worth more to whoever reads the
error than the fact that it did not parse."
  (when (and (stringp body) (not (string-empty-p (string-trim body))))
    (or (benedict-api-stream--json-message body)
        (benedict-api-stream--truncate (string-trim body)))))

(defun benedict-api-stream--json-message (body)
  "Return the message the JSON error BODY carries, or nil.

Four shapes, in order: OpenAI's and the gateway's nested
{\"error\":{\"message\"}}, an `error' that is itself the string, and a
bare `message' or `detail' at the top level."
  (let ((parsed (condition-case nil
                    (json-parse-string body :object-type 'plist
                                       :null-object nil :false-object nil)
                  (error nil))))
    (when (plistp parsed)
      (let ((nested (plist-get parsed :error)))
        (seq-find (lambda (candidate)
                    (and (stringp candidate) (not (string-empty-p candidate))))
                  (list (and (plistp nested) (plist-get nested :message))
                        nested
                        (plist-get parsed :message)
                        (plist-get parsed :detail)))))))

(defun benedict-api-stream--truncate (text)
  "Return TEXT, shortened to `benedict-api-stream-body-limit' characters."
  (if (<= (length text) benedict-api-stream-body-limit)
      text
    (concat (substring text 0 benedict-api-stream-body-limit) "...")))

(provide 'benedict-api-stream)

;;; benedict-api-stream.el ends here
