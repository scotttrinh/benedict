;;; benedict-api-stream-test.el --- Tests for the shared HTTP path  -*- lexical-binding: t; -*-

;;; Commentary:

;; The whole of this suite is about one promise, made by SPEC-001 7.3 and kept
;; here rather than in each adapter:
;;
;;   A STREAM NEVER SIGNALS, AND ENDS IN EXACTLY ONE `:done' OR `:error'.
;;
;; So most of these tests are failures.  Every way a request can go wrong --
;; an unregistered API, a credential that is not there, an adapter that signals
;; while building, a parser that signals halfway through, a transport that
;; never connects, a 404, a connection that closes mid-answer -- has a test
;; asserting that it arrives at the handler as one terminal `:error' and does
;; not escape as an Elisp signal.  A signal would be worse than a wrong answer:
;; most of this code runs inside a process filter or a sentinel, where nothing
;; catches it and the session waits in `provider-wait' until someone aborts it
;; by hand.
;;
;; No socket is opened and no credential is read.  `benedict-http-stream' is
;; stubbed, which is not a shortcut -- it is the seam being tested.  This file
;; owns the composition of auth, an adapter, and the transport; whether curl
;; frames SSE correctly is `benedict-http-test.el's question and is answered
;; there against recorded bytes.
;;
;; Two tests are about a decision rather than a defect:
;;
;;   `benedict-api-stream-delivers-nothing-synchronously' is why every event
;;   goes through `benedict-core-defer-function'.  A blocking
;;   `process-send-string' runs pending filters, including another session's,
;;   so a handler called straight out of a filter can re-enter the reducer
;;   mid-transition.
;;
;;   `benedict-api-stream-emits-nothing-after-being-cancelled' is the abort
;;   contract.  `benedict-session-abort' finalizes the open entry itself
;;   instead of waiting to hear back, so a terminal event from a cancelled
;;   stream would arrive after the turn it belongs to had closed.
;;
;; See SPEC-001 7.3, 8.1, 12.5, and D19.

;;; Code:

(require 'ert)
(require 'test-helper)

;;;; A transport that never starts curl

(defvar benedict-api-stream-test--calls nil
  "Arguments each stubbed `benedict-http-stream' call received, newest first.")

(defvar benedict-api-stream-test--cancelled 0
  "How many times the stubbed transport's cancel thunk has been called.")

(defmacro benedict-api-stream-test--with-transport (&rest body)
  "Evaluate BODY with `benedict-http-stream' recorded instead of run.

Each call lands on `benedict-api-stream-test--calls' as a plist of the
URL and every keyword, so a test both asserts on what the adapter
produced and drives the response by hand."
  (declare (indent 0) (debug body))
  `(let ((benedict-api-stream-test--calls nil)
         (benedict-api-stream-test--cancelled 0))
     (cl-letf (((symbol-function 'benedict-http-stream)
                (lambda (url &rest keys)
                  (push (append (list :url url) keys)
                        benedict-api-stream-test--calls)
                  (lambda () (cl-incf benedict-api-stream-test--cancelled)))))
       ,@body)))

(defmacro benedict-api-stream-test--with-registrations (&rest body)
  "Evaluate BODY against a stubbed transport and a hand-stepped reducer.

Unregisters the test API and provider afterwards even when BODY fails, so
one test's catalog cannot resolve in the next.  The log is quiet because
several of these tests take paths that log at `error', which is echoed by
default, and a suite whose expected failures print teaches its reader to
skim output that is sometimes real."
  (declare (indent 0) (debug body))
  `(benedict-test-with-quiet-log
     (benedict-test-with-manual-defer
       (benedict-api-stream-test--with-transport
         (unwind-protect (progn ,@body)
           (benedict-provider-unregister 'benedict-api-stream-test-service)
           (benedict-api-unregister 'benedict-api-stream-test-wire))))))

(defun benedict-api-stream-test--call ()
  "Return the most recent stubbed transport call, as a plist."
  (car benedict-api-stream-test--calls))

(defun benedict-api-stream-test--sse (type data)
  "Deliver the SSE event TYPE carrying DATA to the current request."
  (funcall (plist-get (benedict-api-stream-test--call) :on-event) type data))

(defun benedict-api-stream-test--finish (result)
  "Deliver RESULT to the current request as the transport's outcome."
  (funcall (plist-get (benedict-api-stream-test--call) :on-end) result))

(ert-deftest benedict-api-stream-disables-invisible-http-retries ()
  "A model attempt reaches the transport with retry disabled."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--open (lambda (_event) nil))
    (should (equal (plist-get (benedict-api-stream-test--call) :retry) 0))))

;;;; Opening a stream

(cl-defun benedict-api-stream-test--open (handler &key endpoint headers build
                                                  parser auth base-url)
  "Register a test API and provider and stream through them to HANDLER.

Every keyword defaults to something inert, so a test names only the piece
it is about.  ENDPOINT, HEADERS, and BUILD are the `benedict-api'
functions of those names.  PARSER is the per-event closure `make-parser'
would return -- one closure rather than a maker, because a test opens one
stream.  AUTH is the provider's auth method descriptor, nil meaning a
provider that authenticates nothing.  BASE-URL is the provider's.

Returns the cancel thunk `benedict-api-stream' returned."
  (benedict-defapi benedict-api-stream-test-wire
    :name "Test Wire"
    :endpoint (or endpoint
                  (lambda (_model auth)
                    (concat (plist-get auth :base-url) "/responses")))
    :headers (or headers (lambda (_model _auth) nil))
    :build (or build (lambda (_request _model) "{}"))
    :make-parser (let ((parser (or parser (lambda (_event) nil))))
                   (lambda () parser)))
  (benedict-defprovider benedict-api-stream-test-service
    :name "Test Service"
    :base-url (or base-url "https://example.invalid/v1")
    :api 'benedict-api-stream-test-wire
    :auth auth)
  (benedict-api-stream
   (benedict-model-create :id "test-model"
                          :provider 'benedict-api-stream-test-service
                          :api 'benedict-api-stream-test-wire)
   '(:entries nil :system-prompt nil :tools nil)
   handler))

(defmacro benedict-api-stream-test--collecting (var &rest body)
  "Bind VAR to a fresh event collector and evaluate BODY.

Pass VAR to `benedict-api-stream-test-handler' to get the handler that
fills it, and to `benedict-api-stream-test-events' to read what it
collected, in order.  A cons cell rather than a list variable, so that
the handler closure and BODY see the same one."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (list 'events)))
     ,@body))

(defun benedict-api-stream-test-handler (cell)
  "Return a handler appending each event it receives to CELL's cdr."
  (lambda (event) (setcdr cell (append (cdr cell) (list event)))))

(defun benedict-api-stream-test-events (cell)
  "Return the events collected into CELL, in order."
  (cdr cell))

(defun benedict-api-stream-test--terminal (events)
  "Return the single terminal event in EVENTS, failing when there is not one."
  (let ((terminal (seq-filter
                   (lambda (event) (memq (plist-get event :type) '(:done :error)))
                   events)))
    (should (= (length terminal) 1))
    (car terminal)))

;;;; Exit criterion: an adapter's request reaches the transport intact

(ert-deftest benedict-api-stream-sends-what-the-adapter-built ()
  "URL, headers, and body come from the API record and nothing rewrites them."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :endpoint (lambda (_model auth)
                   (concat (plist-get auth :base-url) "/responses"))
       :headers (lambda (_model _auth) '(("content-type" . "application/json")))
       :build (lambda (_request _model) "{\"stream\":true}"))
      (let ((call (benedict-api-stream-test--call)))
        (should (equal (plist-get call :url)
                       "https://example.invalid/v1/responses"))
        (should (equal (plist-get call :method) "POST"))
        (should (equal (plist-get call :headers)
                       '(("content-type" . "application/json"))))
        (should (equal (plist-get call :body) "{\"stream\":true}"))))))

(ert-deftest benedict-api-stream-delivers-the-parser-s-events-in-order ()
  "The normalized events a parser returns reach the handler unchanged."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :parser (lambda (event)
                 (pcase (plist-get event :event)
                   ("start" (list '(:type :start)))
                   ("delta" (list (list :type :block-delta :index 0
                                        :delta (plist-get event :data))))
                   ("stop" (list '(:type :done :reason stop)))
                   (_ nil))))
      (benedict-api-stream-test--sse "start" "{}")
      (benedict-api-stream-test--sse "delta" "Hel")
      (benedict-api-stream-test--sse "delta" "lo")
      (benedict-api-stream-test--sse "stop" "{}")
      (benedict-test-drain)
      (should (equal (benedict-api-stream-test-events cell)
                     '((:type :start)
                       (:type :block-delta :index 0 :delta "Hel")
                       (:type :block-delta :index 0 :delta "lo")
                       (:type :done :reason stop)))))))

(ert-deftest benedict-api-stream-hands-the-parser-the-sse-fields-verbatim ()
  "A parser sees `:event' and `:data' as the stream sent them.
The wire's own field names, so that an adapter and the recorded fixture
it was written against describe the same bytes in one vocabulary."
  (benedict-api-stream-test--with-registrations
    (let ((seen nil))
      (benedict-api-stream-test--collecting cell
        (benedict-api-stream-test--open
         (benedict-api-stream-test-handler cell)
         :parser (lambda (event) (push event seen) nil))
        (benedict-api-stream-test--sse "response.output_text.delta"
                                       "{\"delta\":\"hi\"}")
        (benedict-api-stream-test--sse nil "[DONE]")
        (should (equal (nreverse seen)
                       '((:event "response.output_text.delta"
                                 :data "{\"delta\":\"hi\"}")
                         (:event nil :data "[DONE]"))))))))

;;;; Where the base URL comes from

(ert-deftest benedict-api-stream-gives-the-adapter-the-provider-s-base-url ()
  "A provider needing no credential still resolves to an auth value with one.
An adapter reads `:base-url' off the value it is handed and never needs
the provider record, which is what keeps it a wire protocol rather than a
service."
  (benedict-api-stream-test--with-registrations
    (let ((seen nil))
      (benedict-api-stream-test--collecting cell
        (benedict-api-stream-test--open
         (benedict-api-stream-test-handler cell)
         :base-url "https://gateway.invalid/v1"
         :endpoint (lambda (_model auth) (setq seen auth) "https://x.invalid"))
        (should (equal (plist-get seen :base-url) "https://gateway.invalid/v1"))
        (should-not (plist-get seen :api-key))))))

(ert-deftest benedict-api-stream-prefers-the-credential-s-base-url ()
  "SPEC-001 8.1: a credential may carry its own endpoint, and it wins."
  (benedict-api-stream-test--with-registrations
    (let ((seen nil))
      (cl-letf (((symbol-function 'benedict-auth-resolve)
                 (lambda (_provider callback)
                   (funcall callback '(:api-key "sk-test"
                                                :base-url "https://mine.invalid")
                            nil))))
        (benedict-api-stream-test--collecting cell
          (benedict-api-stream-test--open
           (benedict-api-stream-test-handler cell)
           :base-url "https://gateway.invalid/v1"
           :endpoint (lambda (_model auth) (setq seen auth) "https://x.invalid"))
          (should (equal (plist-get seen :base-url) "https://mine.invalid"))
          (should (equal (plist-get seen :api-key) "sk-test")))))))

;;;; Failures that arrive before a byte is sent

(ert-deftest benedict-api-stream-reports-a-missing-credential ()
  "A resolution error becomes a terminal event, and nothing is sent."
  (benedict-api-stream-test--with-registrations
    (cl-letf (((symbol-function 'benedict-auth-resolve)
               (lambda (_provider callback)
                 (funcall callback nil (list :error "No Test Service API key"
                                             :reason 'missing)))))
      (benedict-api-stream-test--collecting cell
        (benedict-api-stream-test--open (benedict-api-stream-test-handler cell))
        (benedict-test-drain)
        (should-not benedict-api-stream-test--calls)
        (should (equal (benedict-api-stream-test-events cell)
                       '((:type :error :reason error
                                :message "No Test Service API key"))))))))

(ert-deftest benedict-api-stream-reports-an-unregistered-wire-api ()
  "A model naming an API nobody registered fails visibly rather than silently."
  (benedict-api-stream-test--with-registrations
    (benedict-defprovider benedict-api-stream-test-service
      :name "Test Service" :base-url "https://example.invalid" :api 'nowhere)
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream
       (benedict-model-create :id "test-model"
                              :provider 'benedict-api-stream-test-service
                              :api 'nowhere)
       nil (benedict-api-stream-test-handler cell))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (eq (plist-get event :type) :error))
        (should (eq (plist-get event :reason) 'error))
        (should (string-match-p "nowhere" (plist-get event :message)))))))

(ert-deftest benedict-api-stream-reports-an-unregistered-provider ()
  "An unregistered provider is a terminal event here, not a signal.
`benedict-provider-stream' signals for one, because it is called from the
reducer and can.  This is called from a stream, and cannot."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream
       (benedict-model-create :id "test-model" :provider 'nobody :api 'nowhere)
       nil (benedict-api-stream-test-handler cell))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (eq (plist-get event :type) :error))
        (should (string-match-p "nobody" (plist-get event :message)))))))

(ert-deftest benedict-api-stream-turns-a-build-signal-into-a-terminal-error ()
  "An adapter that signals while building has emitted nothing, so it can say so."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :build (lambda (_request _model)
                (signal 'benedict-error (list "cannot lower this entry"))))
      (benedict-test-drain)
      (should-not benedict-api-stream-test--calls)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (eq (plist-get event :type) :error))
        (should (string-match-p "cannot lower this entry"
                                (plist-get event :message)))))))

;;;; Failures that arrive mid-stream

(ert-deftest benedict-api-stream-turns-a-parser-signal-into-a-terminal-error ()
  "SPEC-001 D19.  A parser bug is visible rather than a session that hangs.
The signal must not escape either: this runs inside a process filter,
where nothing would catch it."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :parser (lambda (event)
                 (if (equal (plist-get event :event) "boom")
                     (error "Unparsable item shape")
                   (list '(:type :start)))))
      (benedict-api-stream-test--sse "start" "{}")
      (benedict-api-stream-test--sse "boom" "{}")
      (benedict-test-drain)
      (let ((events (benedict-api-stream-test-events cell)))
        (should (equal (car events) '(:type :start)))
        (let ((event (benedict-api-stream-test--terminal events)))
          (should (eq (plist-get event :type) :error))
          (should (string-match-p "Unparsable item shape"
                                  (plist-get event :message))))))))

(ert-deftest benedict-api-stream-stops-at-the-first-terminal-event ()
  "SPEC-001 7.3.  Whatever a parser produces after a terminal event is dropped."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :parser (lambda (_event)
                 (list '(:type :done :reason stop)
                       '(:type :block-delta :index 0 :delta "late")
                       '(:type :done :reason length))))
      (benedict-api-stream-test--sse "everything" "{}")
      (benedict-test-drain)
      (should (equal (benedict-api-stream-test-events cell)
                     '((:type :done :reason stop)))))))

(ert-deftest benedict-api-stream-abandons-the-transport-at-the-terminal-event ()
  "The stream is over, so curl is not left pulling bytes nobody will read."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :parser (lambda (_event) (list '(:type :done :reason stop))))
      (should (= benedict-api-stream-test--cancelled 0))
      (benedict-api-stream-test--sse "stop" "{}")
      (should (= benedict-api-stream-test--cancelled 1)))))

;;;; What the transport's outcome means

(ert-deftest benedict-api-stream-reports-the-service-s-own-error-message ()
  "A 404 carries a message worth reading, and it is what the user gets.
The body is the one recorded from the gateway, not a plausible-looking
invention -- SPEC-001 12.5."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open (benedict-api-stream-test-handler cell))
      (benedict-api-stream-test--finish
       (list :status 404 :headers nil
             :body (benedict-test-fixture-contents
                    "openai-responses-error-404.json")))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (eq (plist-get event :type) :error))
        (should (equal (plist-get event :message)
                       "HTTP 404: Model 'deepseek/no-such-model' not found"))))))

(ert-deftest benedict-api-stream-falls-back-to-a-body-it-cannot-parse ()
  "An HTML page from a proxy is still the only evidence there is."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open (benedict-api-stream-test-handler cell))
      (benedict-api-stream-test--finish
       (list :status 502 :headers nil :body "<html>Bad Gateway</html>"))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (equal (plist-get event :message)
                       "HTTP 502: <html>Bad Gateway</html>"))))))

(ert-deftest benedict-api-stream-truncates-an-enormous-error-body ()
  "A megabyte of HTML in a chat transcript helps nobody."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open (benedict-api-stream-test-handler cell))
      (benedict-api-stream-test--finish
       (list :status 500 :headers nil :body (make-string 100000 ?x)))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (< (length (plist-get event :message)) 500))
        (should (string-suffix-p "..." (plist-get event :message)))))))

(ert-deftest benedict-api-stream-reports-a-status-with-no-message-at-all ()
  "An empty body still names the status, which is the whole of what is known."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open (benedict-api-stream-test-handler cell))
      (benedict-api-stream-test--finish (list :status 429 :headers nil :body ""))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (string-match-p "429" (plist-get event :message)))))))

(ert-deftest benedict-api-stream-reports-a-transport-failure ()
  "Curl's own diagnostic reaches the handler rather than being swallowed.
The transport is not asked to stop on the way out: it has already
stopped, and asking would log a cancellation that never happened."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open (benedict-api-stream-test-handler cell))
      (benedict-api-stream-test--finish
       (list :error "Could not resolve host" :reason 'process :exit 6))
      (benedict-test-drain)
      (should (= benedict-api-stream-test--cancelled 0))
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (equal (plist-get event :message) "Could not resolve host"))))))

(ert-deftest benedict-api-stream-propagates-safe-transport-error-data ()
  "Opaque classifier metadata reaches the normalized terminal event unchanged."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open (benedict-api-stream-test-handler cell))
      (benedict-api-stream-test--finish
       '(:status 429 :headers (("authorization" . "secret")) :body "private"
         :error-data (:benedict-retry-http (:transient t :retry-after 3))))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (equal (plist-get event :error-data)
                       '(:benedict-retry-http (:transient t :retry-after 3))))))))

(ert-deftest benedict-api-stream-reports-a-stream-that-ended-unfinished ()
  "A 2xx whose parser never produced a terminal event did not succeed.
The transport sees the bytes it received arriving intact and calls that
success; only this layer knows the answer was cut off."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :parser (lambda (_event)
                 (list '(:type :block-delta :index 0 :delta "half"))))
      (benedict-api-stream-test--sse "delta" "{}")
      (benedict-api-stream-test--finish (list :status 200 :headers nil))
      (benedict-test-drain)
      (let ((event (benedict-api-stream-test--terminal
                    (benedict-api-stream-test-events cell))))
        (should (eq (plist-get event :type) :error))
        (should (string-match-p "before the model finished"
                                (plist-get event :message)))))))

(ert-deftest benedict-api-stream-says-nothing-more-after-a-finished-stream ()
  "The 2xx outcome arrives after the parser's `:done' and adds nothing."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :parser (lambda (_event) (list '(:type :done :reason stop))))
      (benedict-api-stream-test--sse "stop" "{}")
      (benedict-api-stream-test--finish (list :status 200 :headers nil))
      (benedict-test-drain)
      (should (equal (benedict-api-stream-test-events cell)
                     '((:type :done :reason stop)))))))

;;;; Two decisions

(ert-deftest benedict-api-stream-delivers-nothing-synchronously ()
  "Events go through the kernel's scheduler, never straight out of a filter.
A blocking `process-send-string' runs pending process filters -- including
another session's -- so a handler called from inside one can re-enter the
reducer in the middle of a transition."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (benedict-api-stream-test--open
       (benedict-api-stream-test-handler cell)
       :parser (lambda (_event) (list '(:type :start))))
      (benedict-api-stream-test--sse "start" "{}")
      (should-not (benedict-api-stream-test-events cell))
      (benedict-test-drain)
      (should (equal (benedict-api-stream-test-events cell)
                     '((:type :start)))))))

(ert-deftest benedict-api-stream-emits-nothing-after-being-cancelled ()
  "A cancelled stream is silent, including about being cancelled.
`benedict-session-abort' finalizes the open entry itself rather than
waiting to hear back, so a terminal event from here would arrive after
the turn it belongs to had closed."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (let ((cancel (benedict-api-stream-test--open
                     (benedict-api-stream-test-handler cell)
                     :parser (lambda (_event) (list '(:type :start))))))
        (funcall cancel)
        (should (= benedict-api-stream-test--cancelled 1))
        (benedict-api-stream-test--sse "start" "{}")
        (benedict-api-stream-test--finish
         (list :error "killed" :reason 'process :exit 2))
        (benedict-test-drain)
        (should-not (benedict-api-stream-test-events cell))))))

(ert-deftest benedict-api-stream-drops-an-event-cancelled-before-delivery ()
  "Deferral opens a window between accepting an event and delivering it."
  (benedict-api-stream-test--with-registrations
    (benedict-api-stream-test--collecting cell
      (let ((cancel (benedict-api-stream-test--open
                     (benedict-api-stream-test-handler cell)
                     :parser (lambda (_event) (list '(:type :start))))))
        (benedict-api-stream-test--sse "start" "{}")
        (funcall cancel)
        (benedict-test-drain)
        (should-not (benedict-api-stream-test-events cell))))))

(provide 'benedict-api-stream-test)

;;; benedict-api-stream-test.el ends here
