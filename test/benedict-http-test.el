;;; benedict-http-test.el --- Tests for the curl transport  -*- lexical-binding: t; -*-

;;; Commentary:

;; This suite never opens a socket.  The framer is a pure function of bytes,
;; the request is a file curl would have read, and the outcome is a header dump
;; curl would have written, so all three are testable with no service and no
;; credential -- which is what SPEC-001 12.5 requires of everything under
;; test/.
;;
;; The property tested hardest is CHUNK-SPLIT INVARIANCE.  A streaming parser
;; is correct on the chunking it happened to be developed against and wrong on
;; every other one, and the wrong version fails in production as a truncated
;; word or a JSON payload that will not parse -- never as a crash.  Each
;; recorded fixture is therefore replayed through the framer at chunk sizes
;; from one byte upward, and every replay must produce one identical event
;; sequence.  One byte at a time is not a silly extreme: it is the only size
;; that exercises every possible boundary, including the one inside a CRLF.
;;
;; Three assertions correspond to specific defects in the transport that
;; preceded the reset, and each is written to fail if that defect returns:
;;
;;   `benedict-http-ignores-unknown-sse-fields' -- the predecessor's field
;;   parser ended in a fallback that swept any unrecognized line into the data
;;   payload.  A server that also sends `id:' lines, which the SSE grammar
;;   explicitly allows, would have produced JSON that does not parse.
;;
;;   `benedict-http-reports-the-status-it-was-given' -- the predecessor
;;   reported a hardcoded 200 whenever curl exited zero, which cannot tell a
;;   200 from a 204 and cannot see a redirect at all.
;;
;;   `benedict-http-keeps-the-request-off-the-command-line' -- headers went to
;;   curl as process arguments, which puts a bearer token in `ps' output for
;;   every local user for as long as the request runs.
;;
;; And one corresponds to a decision rather than a defect:
;; `benedict-http-does-not-retry-once-an-event-has-been-emitted' is SPEC-001
;; D20.  Retrying a stream that has already delivered deltas appends the
;; retried content on top of what the kernel accumulated, so the rule is not a
;; policy the transport applies but an invariant it cannot violate.
;;
;; See SPEC-001 3.2, 7.4.1, 12.2, 12.5, D18, and D20.

;;; Code:

(require 'ert)
(require 'test-helper)

(defconst benedict-http-test-fixtures
  '("openai-responses-text.sse"
    "openai-responses-tool-call.sse"
    "openai-responses-reasoning-summary.sse"
    "openai-responses-no-reasoning.sse"
    "openai-responses-tool-result-continuation.sse")
  "Recorded streams replayed through the framer.
Every one of these is real captured output from Vercel AI Gateway; see
test/fixtures/README.md for which model produced each.")

(defconst benedict-http-test-chunk-sizes '(1 2 3 7 13 64 997 65536)
  "Chunk sizes each fixture is replayed at.
One byte splits every CRLF, every field name, and every frame boundary;
65536 delivers most fixtures whole.  The sizes between are coprime with
nothing in particular, which is the point.")

(defun benedict-http-test--replay (text &optional size)
  "Return the events framed out of TEXT, delivered SIZE bytes at a time.
SIZE defaults to the whole of TEXT.  Each event is a cons of its type and
its payload.  The parser is flushed afterwards, as the transport flushes
it in the sentinel, so this replays a whole response rather than a
prefix of one."
  (let* ((events nil)
         (parser (benedict-http-sse-parser
                  (lambda (type data) (push (cons type data) events))))
         (size (or size (max 1 (length text))))
         (position 0)
         (length (length text)))
    (while (< position length)
      (funcall parser (substring text position (min length (+ position size))))
      (setq position (+ position size)))
    (funcall parser nil)
    (nreverse events)))

(defun benedict-http-test--data-lines (text)
  "Return how many `data:' lines TEXT contains."
  (cl-count-if (lambda (line) (string-prefix-p "data:" line))
               (split-string text "\n")))

(defmacro benedict-http-test--quietly (&rest body)
  "Evaluate BODY with the log recording nothing and echoing nothing."
  (declare (indent 0) (debug body))
  `(let ((benedict-log-level nil)
         (benedict-log-echo-level nil))
     ,@body))

;;;; Exit criterion: a recorded stream frames identically at any chunking

(ert-deftest benedict-http-frames-a-recorded-stream-into-parsable-events ()
  "Every recorded fixture yields one event per `data:' line, all valid JSON.

The JSON assertion is the one that catches a field-handling bug: a framer
that folds an unknown field into the payload still produces the right
NUMBER of events, and produces them corrupted."
  (dolist (fixture benedict-http-test-fixtures)
    (ert-info (fixture)
      (let* ((text (benedict-test-fixture-contents fixture))
             (events (benedict-http-test--replay text)))
        (should (= (length events) (benedict-http-test--data-lines text)))
        (should (equal (car (car events)) "response.created"))
        (should (equal (car (car (last events))) "response.completed"))
        (dolist (event events)
          ;; Signals rather than returning nil on malformed input, which is
          ;; the assertion: the payload survived framing intact.
          (should (json-parse-string (cdr event))))))))

(ert-deftest benedict-http-splits-frames-across-chunk-boundaries ()
  "A recorded stream must frame identically however its bytes arrive."
  (dolist (fixture benedict-http-test-fixtures)
    (let* ((text (benedict-test-fixture-contents fixture))
           (expected (benedict-http-test--replay text)))
      (dolist (size benedict-http-test-chunk-sizes)
        (ert-info ((format "%s at %d bytes" fixture size))
          (should (equal (benedict-http-test--replay text size) expected)))))))

;;;; SSE field handling

(ert-deftest benedict-http-ignores-unknown-sse-fields ()
  "`id:', `retry:', comments, and unknown fields never reach the payload.

The SSE grammar allows all of them; a parser that treats anything it does
not recognize as data corrupts every payload in a stream that uses one."
  (should (equal (benedict-http-test--replay
                  (concat ": a comment\n"
                          "id: 42\n"
                          "retry: 3000\n"
                          "x-vendor: whatever\n"
                          "event: tick\n"
                          "data: {\"n\":1}\n"
                          "\n"))
                 '(("tick" . "{\"n\":1}")))))

(ert-deftest benedict-http-joins-multiple-data-lines-with-newlines ()
  "Several `data:' lines are one payload, joined with newlines, per the grammar."
  (should (equal (benedict-http-test--replay "data: one\ndata: two\ndata:\n\n")
                 '((nil . "one\ntwo\n")))))

(ert-deftest benedict-http-strips-exactly-one-leading-space ()
  "A payload may begin with whitespace of its own, so trimming is wrong."
  (should (equal (benedict-http-test--replay "data:  padded\n\n")
                 '((nil . " padded"))))
  (should (equal (benedict-http-test--replay "data:tight\n\n")
                 '((nil . "tight")))))

(ert-deftest benedict-http-accepts-every-line-ending-the-grammar-allows ()
  "CRLF, LF, and a lone CR all end a line; two in a row end an event."
  (let ((expected '(("tick" . "{\"n\":1}"))))
    (should (equal (benedict-http-test--replay
                    "event: tick\r\ndata: {\"n\":1}\r\n\r\n")
                   expected))
    (should (equal (benedict-http-test--replay
                    "event: tick\rdata: {\"n\":1}\r\r")
                   expected))
    (should (equal (benedict-http-test--replay
                    "event: tick\ndata: {\"n\":1}\n\n")
                   expected))))

(ert-deftest benedict-http-holds-back-a-trailing-carriage-return ()
  "A CRLF split across two chunks is one line ending, not two.

Without the hold-back the CR ends a line, the LF that follows ends
another, and the empty line between them dispatches the event one frame
early -- with half its data."
  (let* ((events nil)
         (parser (benedict-http-sse-parser
                  (lambda (type data) (push (cons type data) events)))))
    (funcall parser "data: one\r")
    (funcall parser "\ndata: two\r\n\r\n")
    (should (equal (nreverse events) '((nil . "one\ntwo"))))))

(ert-deftest benedict-http-holds-a-bare-carriage-return-until-the-flush ()
  "A trailing CR is ambiguous until the body ends, and only then resolves.

While bytes may still arrive, a final CR could be half a CRLF, so the
event it would close is held.  The flush is what says no more bytes are
coming -- which is why the transport calls the parser with nil in its
sentinel rather than letting the process exit speak for itself."
  (let* ((events nil)
         (parser (benedict-http-sse-parser
                  (lambda (type data) (push (cons type data) events)))))
    (funcall parser "event: tick\rdata: {\"n\":1}\r\r")
    (should-not events)
    (funcall parser nil)
    (should (equal events '(("tick" . "{\"n\":1}"))))))

(ert-deftest benedict-http-does-not-dispatch-an-event-without-data ()
  "An event with no data is not dispatched, per the grammar.
A lone `data:' is a keep-alive, not a payload of zero bytes, and a
comment is not an event at all."
  (should-not (benedict-http-test--replay "event: ping\n\n"))
  (should-not (benedict-http-test--replay ": keepalive\n\n"))
  (should-not (benedict-http-test--replay "data:\n\n")))

(ert-deftest benedict-http-discards-a-trailing-partial-event ()
  "Bytes with no closing blank line are held, not guessed at."
  (should (equal (benedict-http-test--replay "data: whole\n\ndata: partial\n")
                 '((nil . "whole")))))

(ert-deftest benedict-http-reports-a-missing-event-field-as-nil ()
  "A stream with no `event:' lines is legal; the type is nil, not empty."
  (should (equal (benedict-http-test--replay "data: bare\n\n")
                 '((nil . "bare")))))

;;;; What curl is asked to do

(defvar benedict-http-test--capture nil
  "What the stubbed `make-process' saw, as a plist.")

(defun benedict-http-test--make-process (&rest arguments)
  "Record ARGUMENTS instead of running curl.  Return a stand-in process."
  (let* ((command (plist-get arguments :command))
         (config (nth 2 command)))
    (setq benedict-http-test--capture
          (list :command command
                :config-file config
                :config (benedict-http-test--file-contents config)
                :modes (file-modes config))))
  'benedict-http-test--process)

(defun benedict-http-test--file-contents (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defmacro benedict-http-test--with-stubbed-curl (&rest body)
  "Evaluate BODY with curl stubbed out; return what it would have been sent.

The result is a plist of `:command', `:config', `:modes', and `:stdin'.
`benedict-http-timeout' is bound to nil so that no stall timer outlives
the test -- there is no process for it to kill and no sentinel to disarm
it, and a timer that fires during a later test is a hard failure to read."
  (declare (indent 0) (debug body))
  `(let ((benedict-http-test--capture nil)
         (benedict-http-timeout nil))
     (benedict-http-test--quietly
       (cl-letf (((symbol-function 'make-process)
                  #'benedict-http-test--make-process)
                 ((symbol-function 'process-send-string)
                  (lambda (_process text)
                    (setq benedict-http-test--capture
                          (plist-put benedict-http-test--capture :stdin text))))
                 ((symbol-function 'process-send-eof) #'ignore))
         ,@body))
     (benedict-http-test--clean-up benedict-http-test--capture)
     benedict-http-test--capture))

(defun benedict-http-test--clean-up (capture)
  "Delete the temporary files the request in CAPTURE created.
Nothing ran, so no sentinel deleted them."
  (let ((config (plist-get capture :config))
        (start 0))
    (while (string-match "\"\\(/[^\"]*benedict-http-[^\"]*\\)\"" (or config "") start)
      (ignore-errors (delete-file (match-string 1 config)))
      (setq start (match-end 0))))
  (when-let* ((file (plist-get capture :config-file)))
    (ignore-errors (delete-file file))))

(ert-deftest benedict-http-keeps-the-request-off-the-command-line ()
  "Nothing but a config file path may appear in curl's arguments.

A header passed as a process argument is readable by every other process
on the machine, which for an `Authorization' header means the API key is
readable by every other process on the machine."
  (let* ((capture (benedict-http-test--with-stubbed-curl
                    (benedict-http-stream
                     "https://example.invalid/v1/responses"
                     :method "POST"
                     :headers '(("Authorization" . "Bearer sk-secret-value"))
                     :body "{\"model\":\"m\"}"
                     :on-event #'ignore :on-end #'ignore)))
         (command (plist-get capture :command))
         (config (plist-get capture :config)))
    (should (= (length command) 3))
    (should (equal (nth 1 command) "--config"))
    (should-not (seq-find (lambda (argument)
                            (string-match-p "sk-secret-value" argument))
                          command))
    (should (string-match-p "sk-secret-value" config))
    ;; `make-temp-file' creates mode 600; assert it rather than assume it,
    ;; since the whole argument above depends on it.
    (should (equal (plist-get capture :modes) #o600))
    (should (equal (plist-get capture :stdin) "{\"model\":\"m\"}"))))

(ert-deftest benedict-http-sends-the-body-on-standard-input ()
  "A body is read from stdin, so its size is not an argument-length limit."
  (let ((config (plist-get (benedict-http-test--with-stubbed-curl
                             (benedict-http-stream "https://example.invalid/"
                                                   :body "{}"
                                                   :on-event #'ignore
                                                   :on-end #'ignore))
                           :config)))
    (should (string-match-p "^--data-binary @-$" config)))
  (let ((config (plist-get (benedict-http-test--with-stubbed-curl
                             (benedict-http-stream "https://example.invalid/"
                                                   :method "GET"
                                                   :on-event #'ignore
                                                   :on-end #'ignore))
                           :config)))
    (should-not (string-match-p "--data-binary" config))))

(ert-deftest benedict-http-asks-for-an-event-stream-only-when-streaming ()
  (let ((streaming (plist-get (benedict-http-test--with-stubbed-curl
                                (benedict-http-stream "https://example.invalid/"
                                                      :on-event #'ignore
                                                      :on-end #'ignore))
                              :config))
        (plain (plist-get (benedict-http-test--with-stubbed-curl
                            (benedict-http-request "https://example.invalid/"
                                                   :on-end #'ignore))
                          :config)))
    (should (string-match-p "Accept: text/event-stream" streaming))
    (should-not (string-match-p "text/event-stream" plain))))

(ert-deftest benedict-http-defaults-the-method-to-the-presence-of-a-body ()
  (let ((with-body (plist-get (benedict-http-test--with-stubbed-curl
                                (benedict-http-stream "https://example.invalid/"
                                                      :body "{}"
                                                      :on-event #'ignore
                                                      :on-end #'ignore))
                              :config))
        (without (plist-get (benedict-http-test--with-stubbed-curl
                              (benedict-http-stream "https://example.invalid/"
                                                    :on-event #'ignore
                                                    :on-end #'ignore))
                            :config)))
    (should (string-match-p "^--request \"POST\"$" with-body))
    (should (string-match-p "^--request \"GET\"$" without))))

(ert-deftest benedict-http-quotes-values-curl-would-otherwise-misread ()
  "A quote, a backslash, or a newline in a header must survive the config file."
  (should (equal (benedict-http--quote "plain") "\"plain\""))
  (should (equal (benedict-http--quote "a\"b") "\"a\\\"b\""))
  (should (equal (benedict-http--quote "a\\b") "\"a\\\\b\""))
  (should (equal (benedict-http--quote "a\nb") "\"a\\nb\""))
  ;; A newline written literally would end the config line and turn the rest
  ;; of the value into an option curl does not have.
  (should-not (string-match-p "\n" (benedict-http--quote "a\nb"))))

(ert-deftest benedict-http-names-curl-when-it-cannot-be-found ()
  "A missing system dependency reports itself; it does not signal.

SPEC-001 12.2: curl is a system dependency package.el has no vocabulary
for, so the failure has to name the binary and the variable that points
at it."
  (benedict-http-test--quietly
    (let ((benedict-http-curl-program "benedict-definitely-not-curl")
          (result 'unset))
      (let ((cancel (benedict-http-stream "https://example.invalid/"
                                          :on-event #'ignore
                                          :on-end (lambda (r) (setq result r)))))
        (should (functionp cancel)))
      (should (eq (plist-get result :reason) 'no-curl))
      (should (string-match-p "benedict-definitely-not-curl"
                              (plist-get result :error)))
      (should (string-match-p "benedict-http-curl-program"
                              (plist-get result :error))))))

;;;; What curl reported

(defun benedict-http-test--outcome (exit body headers &optional stderr sse)
  "Return the result plist for a run that wrote HEADERS, BODY, and STDERR.
EXIT is curl's exit status and SSE marks the request as streaming."
  (let ((header-file (make-temp-file "benedict-http-test-head-"))
        (stderr-file (make-temp-file "benedict-http-test-err-")))
    (unwind-protect
        (progn
          (write-region (or headers "") nil header-file nil 'silent)
          (write-region (or stderr "") nil stderr-file nil 'silent)
          (benedict-http-test--quietly
            (benedict-http--outcome exit body header-file stderr-file sse)))
      (delete-file header-file)
      (delete-file stderr-file))))

(ert-deftest benedict-http-reports-the-status-it-was-given ()
  "The status comes from the dumped headers, never from the exit code.

Reporting 200 because curl exited zero cannot distinguish a 200 from a
204, and cannot see a 404 that arrived with a body at all."
  (let ((result (benedict-http-test--outcome
                 0 "" "HTTP/2 204 \r\ncontent-length: 0\r\n\r\n")))
    (should (equal (plist-get result :status) 204)))
  (let ((result (benedict-http-test--outcome
                 22 "{\"error\":\"nope\"}"
                 "HTTP/1.1 404 Not Found\r\ncontent-type: application/json\r\n\r\n")))
    (should (equal (plist-get result :status) 404))
    (should (equal (plist-get result :body) "{\"error\":\"nope\"}"))))

(ert-deftest benedict-http-downcases-header-names ()
  (let ((result (benedict-http-test--outcome
                 0 "" "HTTP/2 429 \r\nRetry-After: 30\r\n\r\n")))
    (should (equal (alist-get "retry-after" (plist-get result :headers)
                              nil nil #'equal)
                   "30"))))

(ert-deftest benedict-http-reads-the-last-header-block ()
  "A 100 Continue or a redirect leaves an earlier block that is not the answer."
  (let ((result (benedict-http-test--outcome
                 0 ""
                 (concat "HTTP/1.1 100 Continue\r\n\r\n"
                         "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n"))))
    (should (equal (plist-get result :status) 200))
    (should (equal (plist-get result :headers)
                   '(("content-type" . "text/event-stream"))))))

(ert-deftest benedict-http-omits-the-body-from-a-successful-stream ()
  "A 2xx stream's bytes were delivered as events; repeating them is noise.
Every other status carries its body, which is where an error message is."
  (let ((success (benedict-http-test--outcome 0 "ignored" "HTTP/2 200 \r\n\r\n"
                                              nil t))
        (failure (benedict-http-test--outcome 22 "{\"error\":1}"
                                              "HTTP/2 500 \r\n\r\n" nil t)))
    (should-not (plist-member success :body))
    (should (equal (plist-get failure :body) "{\"error\":1}"))))

(ert-deftest benedict-http-reports-a-transport-failure-with-curls-reason ()
  "With no status line there was no response, so curl's own message is all there is."
  (let ((result (benedict-http-test--outcome
                 7 "" ""
                 "curl: (7) Failed to connect to localhost port 1")))
    (should-not (plist-member result :status))
    (should (eq (plist-get result :reason) 'process))
    (should (equal (plist-get result :exit) 7))
    (should (string-match-p "could not connect to host" (plist-get result :error)))
    (should (string-match-p "Failed to connect" (plist-get result :error)))))

(ert-deftest benedict-http-reports-an-unknown-exit-code-by-number ()
  (let ((result (benedict-http-test--outcome 91 "" "" "")))
    (should (string-match-p "91" (plist-get result :error)))))

;;;; Retry policy

(defun benedict-http-test--request (&rest keys)
  "Return a request struct with KEYS, defaulted for a retry decision.
KEYS come first because a `cl-defstruct' constructor takes the first
occurrence of a keyword, so anything after them would be a default that
cannot be overridden."
  (apply #'benedict-http--request-create
         (append keys (list :url "https://example.invalid/" :method "POST"
                            :attempt 0 :retry 2))))

(ert-deftest benedict-http-does-not-retry-once-an-event-has-been-emitted ()
  "SPEC-001 D20.  A retry after a delta duplicates content into the transcript.

Both requests here saw the same retryable failure; the only difference is
that one had already handed the caller an event, and that is what makes
its failure terminal."
  (should (benedict-http--retry-delay (benedict-http-test--request)
                                      '(:status 503 :headers nil)))
  (should-not (benedict-http--retry-delay
               (benedict-http-test--request :emitted t)
               '(:status 503 :headers nil))))

(ert-deftest benedict-http-retries-only-failures-that-could-differ ()
  "Timeouts, rate limits, and 5xx are worth repeating; a 404 is not."
  (let ((request (benedict-http-test--request)))
    (dolist (status '(408 425 429 500 502 503 504))
      (ert-info ((format "status %d" status))
        (should (benedict-http--retry-delay request (list :status status)))))
    (dolist (status '(200 201 400 401 403 404 422))
      (ert-info ((format "status %d" status))
        (should-not (benedict-http--retry-delay request (list :status status)))))))

(ert-deftest benedict-http-retries-a-connection-failure-but-not-a-bad-certificate ()
  "Retryable curl exits are the transport ones; a rejected certificate is not."
  (let ((request (benedict-http-test--request)))
    (dolist (exit '(6 7 28 35 52 56))
      (ert-info ((format "exit %d" exit))
        (should (benedict-http--retry-delay
                 request (list :error "x" :reason 'process :exit exit)))))
    (dolist (exit '(3 22 60 77))
      (ert-info ((format "exit %d" exit))
        (should-not (benedict-http--retry-delay
                     request (list :error "x" :reason 'process :exit exit)))))))

(ert-deftest benedict-http-stops-retrying-when-its-attempts-are-spent ()
  (should-not (benedict-http--retry-delay
               (benedict-http-test--request :attempt 2 :retry 2)
               '(:status 503)))
  (should-not (benedict-http--retry-delay
               (benedict-http-test--request :retry 0)
               '(:status 503))))

(ert-deftest benedict-http-honors-retry-after-within-its-ceiling ()
  "A service asking for a wait gets it, up to the point of appearing hung."
  (let ((request (benedict-http-test--request))
        (benedict-http-retry-max-seconds 20))
    (should (= (benedict-http--retry-delay
                request '(:status 429 :headers (("retry-after" . "3"))))
               3))
    (should (= (benedict-http--retry-delay
                request '(:status 429 :headers (("retry-after" . "600"))))
               20))))

(ert-deftest benedict-http-falls-back-to-backoff-for-a-retry-after-date ()
  "The HTTP-date form is legal; reading one as seconds means waiting decades."
  (let* ((request (benedict-http-test--request))
         (delay (benedict-http--retry-delay
                 request '(:status 429
                           :headers (("retry-after" . "Wed, 21 Oct 2026 07:28:00 GMT"))))))
    (should (< delay benedict-http-retry-max-seconds))))

(ert-deftest benedict-http-backs-off-with-jitter ()
  "Delays grow with the attempt and are not identical across requests.
Identical delays mean every request that failed on one rate limit comes
back at the same instant."
  (let ((first (benedict-http--backoff 0))
        (later (benedict-http--backoff 3)))
    (should (< first later))
    (should (<= (/ benedict-http-retry-base-seconds 2) first))
    (should (<= first benedict-http-retry-base-seconds)))
  (should (> (length (delete-dups (mapcar (lambda (_) (benedict-http--backoff 4))
                                          (number-sequence 1 20))))
             1)))

(ert-deftest benedict-http-retrying-restarts-instead-of-finishing ()
  "A scheduled retry re-enters the request; the caller hears nothing yet."
  (let ((ended nil)
        (started 0)
        (delay nil))
    (benedict-http-test--quietly
      (cl-letf* (((symbol-function 'run-at-time)
                  (lambda (seconds _repeat function &rest _)
                    (setq delay seconds)
                    (funcall function)
                    nil))
                 ((symbol-function 'benedict-http--start)
                  (lambda (_request) (cl-incf started))))
        (benedict-http--schedule-retry
         (benedict-http-test--request :on-end (lambda (_) (setq ended t)))
         1.5 '(:status 503))))
    (should (= started 1))
    (should (= delay 1.5))
    (should-not ended)))

;;;; Finishing exactly once

(ert-deftest benedict-http-result-filters-compose-before-delivery ()
  "Each filter sees the prior result and the caller sees only the final value."
  (let ((benedict-http-result-filter-functions
         (list (lambda (result) (plist-put result :first t))
               (lambda (result)
                 (should (plist-get result :first))
                 (plist-put result :second t))))
        delivered)
    (benedict-http--finish
     (benedict-http-test--request :on-end (lambda (result) (setq delivered result)))
     '(:status 503))
    (should (equal delivered '(:status 503 :first t :second t)))))

(ert-deftest benedict-http-calls-its-callback-exactly-once ()
  "The stream contract of SPEC-001 7.3 rests on this one being true."
  (let* ((calls 0)
         (request (benedict-http-test--request
                   :on-end (lambda (_result) (cl-incf calls)))))
    (benedict-http--finish request '(:status 200))
    (benedict-http--finish request '(:status 200))
    (should (= calls 1))))

(ert-deftest benedict-http-does-not-call-its-callback-after-cancelling ()
  "Cancelling is the caller saying it stopped caring, not a failure to report."
  (let* ((calls 0)
         (request (benedict-http-test--request
                   :on-end (lambda (_result) (cl-incf calls)))))
    (benedict-http-test--quietly
      (benedict-http--cancel request)
      (benedict-http--cancel request)
      (benedict-http--finish request '(:status 200)))
    (should (= calls 0))))

(provide 'benedict-http-test)

;;; benedict-http-test.el ends here
