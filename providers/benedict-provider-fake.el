;;; benedict-provider-fake.el --- A scripted provider  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A provider that replays a script instead of talking to a service.
;;
;; This is a first-class deliverable, not a test fixture that happened to grow.
;; Everything in the kernel, the tool layer, the extension mechanism, the store,
;; and the frontend must be exercisable against it with no network and no
;; credentials -- if a behavior can only be tested against a live provider, that
;; is a design smell in the boundary, and this file is how the smell is
;; detected.
;;
;; Two properties are worth stating because they are what make the reducer's
;; hard cases testable at all:
;;
;;   - It emits ONE EVENT PER DEFER TICK rather than replaying a whole stream
;;     synchronously.  Aborting mid-stream is then a deterministic assertion
;;     instead of a race, and a test can watch a partial entry accumulate.
;;   - It impersonates ANY provider/api/model triple.  Cross-model degradation
;;     is a per-entry comparison of that triple, so it can be tested in both
;;     directions with no second real provider.
;;
;; A script is a list of turns and a turn is a list of steps.  Each request the
;; kernel makes consumes the next turn, so a multi-turn conversation is a
;; literal:
;;
;;   (benedict-provider-fake-script
;;    '(((:text "Let me look.")
;;       (:tool-call eval-elisp (:form "(+ 1 2)")))
;;      ((:text "It is 3."))))
;;
;; Steps expand into the normalized event vocabulary of SPEC-001 7.3, so a test
;; that needs an event this sugar cannot express writes the events directly:
;; a step that is already an event plist is passed through.
;;
;; See SPEC-001 7.7.

;;; Code:

(require 'cl-lib)
(require 'benedict)
(require 'benedict-provider)

;;;; Errors

(define-error 'benedict-provider-fake-exhausted
  "The fake Benedict provider ran out of scripted turns"
  'benedict-provider-error)

;;;; Scripts

(cl-defstruct (benedict-provider-fake-script
               (:constructor benedict-provider-fake-script--create)
               (:copier nil))
  "A scripted conversation for the fake provider to replay.

Create with `benedict-provider-fake-script'.  A script is stateful: it
remembers how many turns have been consumed, so one script drives one
conversation."
  (turns nil
         :documentation "List of remaining turns, each a list of steps.")
  (requests nil
            :documentation "Requests received so far, most recent first.
Read with `benedict-provider-fake-requests', which puts them in order.
Recorded so a test can assert on context filtering and, later, on what
lowering produced.")
  (exhausted-action 'error
                    :documentation "What to do when the script runs out of turns.
`error' emits a terminal error event naming the exhaustion, which is
almost always what a test wants -- an unexpected extra request is a bug
worth failing on.  `stop' emits an empty turn instead."))

(cl-defun benedict-provider-fake-script (turns &key exhausted-action)
  "Return a script that replays one turn per request.

TURNS is a list of turns and each turn is a list of steps.  A step is
either a normalized event plist,
passed through untouched, or one of these shorthands:

  (:text \"...\")                       an assistant text block
  (:thinking \"...\" :signature \"s\")    a reasoning block
  (:tool-call NAME ARGS :id \"call_1\")  a tool call, arguments already parsed
  (:done :reason stop :usage PLIST)    end the turn explicitly
  (:error :reason error :message \"m\")  fail the turn

A turn with no explicit `:done' or `:error' gets a `:done' with a reason
of `tool-use' when it called a tool and `stop' when it did not, which is
what a real provider does and saves every test from spelling it out.

EXHAUSTED-ACTION is `error' (the default) or `stop'; see the
`exhausted-action' slot."
  (benedict-provider-fake-script--create
   :turns (copy-sequence turns)
   :exhausted-action (or exhausted-action 'error)))

(defun benedict-provider-fake-requests (script)
  "Return the requests SCRIPT has received, oldest first."
  (reverse (benedict-provider-fake-script-requests script)))

(defun benedict-provider-fake-last-request (script)
  "Return the most recent request SCRIPT received, or nil."
  (car (benedict-provider-fake-script-requests script)))

;;;; Expanding a turn into events

(defun benedict-provider-fake--step-events (step index)
  "Return the normalized events for STEP, a script step at block INDEX.

Returns a cons of the event list and the number of blocks consumed, so
the caller can keep block indexes contiguous across steps."
  (pcase step
    ;; Already an event: pass it through, and assume it manages its own index.
    ((and (pred consp) (guard (plist-member step :type)))
     (cons (list step) 0))
    (`(:text ,text . ,rest)
     (cons (append
            (list (list :type :block-start :index index :block-type 'text))
            (when (and text (not (string-empty-p text)))
              (list (list :type :block-delta :index index :delta text)))
            (list (append (list :type :block-end :index index)
                          (when (plist-get rest :signature)
                            (list :signature (plist-get rest :signature))))))
           1))
    (`(:thinking ,text . ,rest)
     (cons (append
            (list (list :type :block-start :index index :block-type 'thinking))
            (when (and text (not (string-empty-p text)))
              (list (list :type :block-delta :index index :delta text)))
            (list (append (list :type :block-end :index index)
                          (when (plist-get rest :signature)
                            (list :signature (plist-get rest :signature))))))
           1))
    (`(:tool-call ,name ,arguments . ,rest)
     (let ((id (or (plist-get rest :id) (format "call_%d" (1+ index)))))
       (cons (list (list :type :block-start :index index :block-type 'tool-call
                         :id id :name name)
                   (list :type :block-delta :index index
                         :delta (format "%S" arguments))
                   (append (list :type :block-end :index index :arguments arguments)
                           (when (plist-get rest :signature)
                             (list :signature (plist-get rest :signature)))))
             1)))
    (`(:done . ,rest)
     (cons (list (append (list :type :done) rest)) 0))
    (`(:error . ,rest)
     (cons (list (append (list :type :error) rest)) 0))
    (_ (signal 'benedict-provider-error (list "Unknown fake script step" step)))))

(defun benedict-provider-fake--turn-events (turn)
  "Return the normalized events for TURN, a scripted assistant turn.

TURN is a list of script steps.  Prepends a `:start' and appends a
terminal event when the turn does not
end with one of its own.  The inferred reason is `tool-use' when the turn
called a tool and `stop' otherwise, which is what a real provider sends
and what the reducer branches on."
  (let ((events (list (list :type :start)))
        (index 0)
        (tool-call-p nil)
        (terminal-p nil))
    (dolist (step turn)
      (pcase-let ((`(,step-events . ,consumed)
                   (benedict-provider-fake--step-events step index)))
        (setq index (+ index consumed))
        (dolist (event step-events)
          (when (memq (plist-get event :type) '(:done :error))
            (setq terminal-p t))
          (when (eq (plist-get event :block-type) 'tool-call)
            (setq tool-call-p t))
          (push event events))))
    (unless terminal-p
      (push (list :type :done :reason (if tool-call-p 'tool-use 'stop)) events))
    (nreverse events)))

;;;; The transport

(defvar benedict-provider-fake-defer-function nil
  "Function called with a THUNK to emit the next event later.

Defaults to `benedict-core-defer-function' when that is bound, so the
fake paces itself exactly like the reducer it feeds and a test steps both
with one mechanism.  Set this only to give the fake a schedule of its
own.")

;; Deliberately no `require' of `benedict-core': a provider has no business
;; depending on the reducer, and this file is useful for lowering tests where
;; the reducer is not loaded at all.  Borrowing the kernel's deferral when it
;; happens to be present is what makes one test mechanism step both.
(defvar benedict-core-defer-function)

(defun benedict-provider-fake--defer (thunk)
  "Schedule THUNK to run on a later turn of the event loop."
  (funcall (or benedict-provider-fake-defer-function
               (and (boundp 'benedict-core-defer-function)
                    benedict-core-defer-function)
               (lambda (thunk) (run-at-time 0 nil thunk)))
           thunk))

(defun benedict-provider-fake--next-turn (script)
  "Return the events for SCRIPT's next turn, consuming it."
  (if-let* ((turn (pop (benedict-provider-fake-script-turns script))))
      (benedict-provider-fake--turn-events turn)
    (if (eq (benedict-provider-fake-script-exhausted-action script) 'stop)
        (list (list :type :start) (list :type :done :reason 'stop))
      (list (list :type :start)
            (list :type :error :reason 'error
                  :message "Fake provider script is exhausted")))))

(defun benedict-provider-fake--stream (model request handler)
  "Replay MODEL's script for REQUEST, calling HANDLER with each event.

The script is read from MODEL's metadata, so a model record and the
conversation it drives travel together.  Returns a cancel thunk that
stops emission; events already delivered stand, exactly as they would
with a real stream cancelled mid-flight."
  (let* ((script (plist-get (benedict-model-meta model) :script))
         (events (progn
                   (push request (benedict-provider-fake-script-requests script))
                   (benedict-provider-fake--next-turn script)))
         (cancelled nil))
    (letrec ((emit (lambda ()
                     (unless cancelled
                       (when-let* ((event (pop events)))
                         (funcall handler event)
                         (when events
                           (benedict-provider-fake--defer emit)))))))
      (benedict-provider-fake--defer emit))
    (lambda () (setq cancelled t))))

;;;; The provider and its models

(defvar benedict-provider-fake--models nil
  "Models registered with the fake provider, most recent first.
Reset with `benedict-provider-fake-reset'.")

(benedict-defprovider fake
  :name "Fake"
  :base-url "fake://localhost"
  :api 'fake
  :stream #'benedict-provider-fake--stream
  :models (lambda (&optional _force) benedict-provider-fake--models))

(cl-defun benedict-provider-fake-model (script &key id provider api name
                                               context-window max-tokens
                                               reasoning-p input-modalities
                                               compat)
  "Return a model that replays SCRIPT, and register it with the fake provider.

SCRIPT is a `benedict-provider-fake-script'.  With no other arguments the
model impersonates the fake provider itself, which is what a test of the
reducer wants.

PROVIDER, API, and ID override the triple this model claims to be.  That
is the point of this function: origin is a per-entry comparison of those
three values, so impersonating `vercel-ai-gateway'/`openai-responses'
/\"openai/gpt-5\" here lets cross-model degradation be tested in both
directions without a second real provider or a single network call.

Note that only the CLAIMED triple changes -- requests still come back
here, because `benedict-provider-stream' resolves transport from the
provider record and the fake registers no impersonated providers.  A
model impersonating another provider is therefore usable for lowering
tests, not for dispatch tests.

NAME, CONTEXT-WINDOW, MAX-TOKENS, REASONING-P, INPUT-MODALITIES, and
COMPAT fill in the rest of the record; INPUT-MODALITIES defaults to text
and images so that image degradation has to be asked for explicitly."
  (let ((model (benedict-model-create
                :id (or id "fake-model")
                :name (or name "Fake Model")
                :provider (or provider 'fake)
                :api (or api 'fake)
                :context-window (or context-window 128000)
                :max-tokens (or max-tokens 4096)
                :reasoning-p reasoning-p
                :input-modalities (or input-modalities '(text image))
                :compat compat
                :meta (list :script script))))
    (push model benedict-provider-fake--models)
    model))

(defun benedict-provider-fake-script-of (model)
  "Return the script MODEL replays."
  (plist-get (benedict-model-meta model) :script))

(defun benedict-provider-fake-reset ()
  "Forget every model registered with the fake provider.
Call between tests so one test's catalog cannot resolve in another."
  (setq benedict-provider-fake--models nil))

(provide 'benedict-provider-fake)

;;; benedict-provider-fake.el ends here
