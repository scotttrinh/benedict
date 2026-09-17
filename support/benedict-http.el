;;; benedict-http.el --- Streaming HTTP over curl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The transport, and nothing above it.  This file knows about processes,
;; bytes, frames, statuses, and retries.  It does not know what a provider is,
;; what an SSE payload means, or that JSON exists.
;;
;; It shells out to `curl' (SPEC-001 D18).  Emacs has no usable native SSE
;; story: `url.el' can be made to stream by attaching a filter to its internal
;; process, but the internals are undocumented and the attachment is delicate,
;; and raw `make-network-process' means owning chunked transfer-encoding,
;; redirects, and proxies.  curl is what gptel and plz both do.  The price is a
;; SYSTEM dependency, which `package.el' has no vocabulary for, so a missing
;; binary has to fail with a message naming `curl' and
;; `benedict-http-curl-program' rather than with whatever `make-process'
;; signals (SPEC-001 12.2).
;;
;; Four things here are load-bearing and each was a bug in the version of this
;; file that preceded the reset:
;;
;; THE REQUEST NEVER TOUCHES THE COMMAND LINE.  Every argument -- the URL, the
;; method, and above all the headers -- goes into a curl config file created
;; mode 600, and the body goes in on stdin.  `-H "Authorization: Bearer sk-..."'
;; in `make-process' is an API key readable by every local process for as long
;; as the request runs.
;;
;; SSE FIELDS ARE PARSED, NOT GUESSED.  `data:' accumulates, `event:' sets the
;; type, and `id:', `retry:', comments, and unknown fields are IGNORED.  The
;; predecessor swept unknown fields into the payload, which corrupts the JSON
;; of any stream whose server sends an `id:' line.
;;
;; STATUS COMES FROM THE HEADERS.  `--dump-header' to a temporary file, read in
;; the sentinel.  Reporting a hardcoded 200 because curl exited zero cannot
;; distinguish a 200 from a 204, and a bounded raw buffer runs alongside the
;; framer so that a non-2xx body reaches the caller intact instead of being fed
;; through SSE framing that was never going to match it.
;;
;; RETRY HAPPENS ONLY BEFORE THE FIRST EVENT (SPEC-001 D20).  Retrying a stream
;; that has already delivered deltas appends the retried content on top of what
;; the kernel accumulated.  Connection failures and non-2xx statuses are both
;; known before any event is emitted; anything later is terminal.
;;
;; The entry points:
;;
;;   (benedict-http-stream URL :on-event ... :on-end ...)  ; -> cancel thunk
;;   (benedict-http-request URL :on-end ...)               ; -> cancel thunk
;;   (benedict-http-request-sync URL)                      ; -> result plist
;;   (benedict-http-sse-parser ON-EVENT)                   ; -> (lambda (CHUNK))
;;
;; `benedict-http-sse-parser' is public because the framer is the part most
;; worth testing on its own: replaying a recorded stream through it at many
;; different chunk boundaries must produce one identical event sequence, and
;; that property needs no process at all to assert.
;;
;; See SPEC-001 3.2, 8.6, 12.2, and D18/D20.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'benedict)
(require 'benedict-log)

(defgroup benedict-http nil
  "HTTP transport for Benedict."
  :group 'benedict
  :prefix "benedict-http-")

;;;; Errors

(define-error 'benedict-http-error
  "Benedict HTTP error"
  'benedict-error)

;;;; Configuration

(defcustom benedict-http-curl-program "curl"
  "Name of, or path to, the curl executable.
Must support `--no-buffer', `--fail-with-body', and `--config' (curl
7.76+).  A missing binary is reported through the caller's callback and
names this variable, because it is the one dependency failure a user can
act on immediately."
  :type 'string
  :group 'benedict-http)

(defcustom benedict-http-extra-args nil
  "Extra curl options appended to every request's config file.

Each element is a whole config-file line, written exactly as it would
appear after the other options -- \"--proxy \\\"http://localhost:8080\\\"\",
\"--insecure\".  This is the escape hatch for proxies and corporate TLS;
Benedict itself never puts anything here."
  :type '(repeat string)
  :group 'benedict-http)

(defcustom benedict-http-timeout 120
  "Seconds without a single received byte before a request is abandoned.

A stall timeout rather than a total one: a long completion is a
legitimately long-running transfer, and capping its total duration would
abort the request that most needed to finish.  The clock resets on every
chunk.  Set to nil to wait indefinitely."
  :type '(choice (const :tag "No limit" nil) number)
  :group 'benedict-http)

(defcustom benedict-http-connect-timeout 30
  "Seconds curl waits for the connection phase alone.
Passed through as `--connect-timeout'."
  :type '(choice (const :tag "curl default" nil) number)
  :group 'benedict-http)

(defvar benedict-http-result-filter-functions nil
  "Functions that transform a completed HTTP result before delivery.

Each function is called with one result plist and must return the plist passed
to the next function.  The final value reaches the request's ON-END callback.
Filters that attach `:error-data' must include only persistence-safe values;
raw bodies, headers, authorization values, and credentials must never be copied
there.")

(defcustom benedict-http-retry 2
  "Number of times a failed request is retried before it is reported.

Only failures observed BEFORE the first emitted event are retried
\(SPEC-001 D20): connection failures, and the retryable statuses in
`benedict-http-retry-status-codes'.  Set to 0 to disable."
  :type 'natnum
  :group 'benedict-http)

(defcustom benedict-http-retry-base-seconds 0.5
  "First retry delay in seconds; doubled on each subsequent attempt.
The actual delay is half this value plus a random half, so that several
requests failing together do not retry in lockstep."
  :type 'number
  :group 'benedict-http)

(defcustom benedict-http-retry-max-seconds 20
  "Ceiling on a retry delay in seconds, including a `Retry-After' header.
A service asking for a ten-minute wait gets one retry attempt's patience
and then an error the caller can show, which is more useful than an Emacs
that appears to have hung."
  :type 'number
  :group 'benedict-http)

(defconst benedict-http-retry-status-codes '(408 425 429)
  "Non-5xx HTTP statuses worth retrying.
Every status of 500 and above is retried as well.  408 and 425 are
timeouts the server itself is asking to have repeated; 429 is a rate
limit, and normally carries `Retry-After'.")

(defconst benedict-http-retry-exit-codes '(6 7 28 35 52 56)
  "The curl exit codes worth retrying: transport failures, not protocol ones.
Could not resolve host, could not connect, operation timed out, TLS
connect error, empty reply, and a receive error.  A 22 -- HTTP status
>= 400 -- is deliberately absent: the status decides that case, not the
exit code.")

(defconst benedict-http-raw-limit 65536
  "Bytes of a streaming response retained for error reporting.

Kept from the START of the body, because an error body's useful half is
its beginning.  A successful stream's bytes are consumed as events and
this buffer is never shown; it exists so that a non-2xx body arrives
whole instead of being fed through SSE framing it does not match.")

(defconst benedict-http--exit-descriptions
  '((2 . "curl could not read its configuration")
    (3 . "malformed URL")
    (6 . "could not resolve host")
    (7 . "could not connect to host")
    (22 . "server returned an error status")
    (23 . "write error")
    (28 . "operation timed out")
    (35 . "TLS connect error")
    (52 . "empty reply from server")
    (56 . "failure receiving data")
    (60 . "server certificate could not be verified")
    (77 . "could not read the CA certificate bundle"))
  "Alist of curl exit code to a short human description.
Only the codes a user might plausibly act on; anything else is reported
by number.")

;;;; SSE framing

(defun benedict-http-sse-parser (on-event)
  "Return a closure of one argument that frames SSE bytes for ON-EVENT.

Call the closure with each chunk of the response body as it arrives, in
any chunking whatsoever.  Whenever the accumulated bytes complete an
event, ON-EVENT is called with two arguments, the event type as a string
\(nil when the stream sent no `event:' field) and the data payload as a
string.

Framing follows the Server-Sent Events grammar rather than approximating
it, because the difference is a corrupted payload:

  - Lines end with CRLF, LF, or a lone CR, and an event ends at a blank
    line.  A CR at the end of a chunk is held back until the next chunk
    arrives, so a CRLF split across a chunk boundary is not read as two
    line endings.
  - `data:' fields accumulate and are joined with newlines.
  - `event:' sets the event type.
  - `id:', `retry:', comment lines beginning with a colon, and every
    unrecognized field are IGNORED.  Folding an unknown field into the
    payload is how a stream that also sends `id:' lines produces JSON
    that will not parse.
  - Exactly one leading space is stripped from a field value.
  - An event whose data is empty is not dispatched, per the grammar.

A trailing partial event -- bytes with no closing blank line -- is
discarded, which is what the grammar says and what every service tested
does not produce.  The closure keeps its own accumulator; use one per
request.

Call the closure with nil when the response body has ended.  That is not
a formality: a held-back CR can only be known to be a line ending rather
than half of a CRLF once no more bytes are coming, so a stream whose
lines end with bare CRs holds its last event until the flush."
  (let ((partial ""))
    (lambda (chunk)
      (let ((buffer (concat partial chunk))
            (held "")
            (start 0)
            (position nil))
        ;; A trailing CR may be the first half of a CRLF that has not
        ;; arrived yet.  Hold it back rather than deciding now -- unless
        ;; this is the flush, where nothing more is coming to decide with.
        (when (and chunk (string-suffix-p "\r" buffer))
          (setq held "\r"
                buffer (substring buffer 0 -1)))
        (setq buffer (replace-regexp-in-string "\r\n\\|\r" "\n" buffer))
        (while (setq position (string-search "\n\n" buffer start))
          (benedict-http--sse-dispatch (substring buffer start position) on-event)
          (setq start (+ position 2)))
        (setq partial (concat (substring buffer start) held))
        nil))))

(defun benedict-http--sse-dispatch (block on-event)
  "Parse one SSE event BLOCK and call ON-EVENT unless its data is empty.
BLOCK holds the event's lines with LF endings and no trailing blank line."
  (let ((type nil)
        (data nil))
    (dolist (line (split-string block "\n"))
      (cond
       ((string-empty-p line) nil)
       ((string-prefix-p ":" line) nil)   ; comment
       (t
        (let* ((colon (string-search ":" line))
               (field (if colon (substring line 0 colon) line))
               (value (if colon (substring line (1+ colon)) "")))
          ;; Exactly one leading space, not `string-trim': a payload may
          ;; legitimately begin with whitespace of its own.
          (when (string-prefix-p " " value)
            (setq value (substring value 1)))
          (cond
           ((equal field "data") (push value data))
           ((equal field "event") (setq type value))
           ;; `id', `retry', and anything unrecognized: ignored.
           (t nil))))))
    (when data
      (let ((payload (string-join (nreverse data) "\n")))
        ;; An empty data buffer is not an event, per the grammar -- a lone
        ;; `data:' is a keep-alive, not a payload of zero bytes.
        (unless (string-empty-p payload)
          (benedict-log-trace "http: sse event %s (%d bytes)"
            (or type "-") (length payload))
          (funcall on-event type payload))))))

;;;; The request object

(cl-defstruct (benedict-http--request
               (:constructor benedict-http--request-create)
               (:copier nil))
  "One in-flight request, including any attempts left to make.

Internal.  State lives here rather than in process properties so that a
retry can replace the process without losing the caller's callbacks, and
so that the pieces are reachable from a test that never starts a
process."
  url method headers body sse accumulate
  on-event on-end
  timeout connect-timeout retry
  attempt process parser
  config-file header-file stderr-file
  stall-timer retry-timer
  (raw nil) (raw-length 0)
  emitted timed-out cancelled finished)

;;;; Public entry points

(defun benedict-http-available-p ()
  "Return non-nil when `benedict-http-curl-program' can be found."
  (and (executable-find benedict-http-curl-program) t))

(cl-defun benedict-http-stream (url &key method headers body on-event on-end
                                    timeout connect-timeout retry)
  "Stream URL as Server-Sent Events, calling ON-EVENT with each one.

Returns a cancel thunk of no arguments.  Calling it abandons the request
without calling ON-END, and is harmless after the request has finished.

  METHOD           HTTP method string; defaults to \"POST\" with a BODY
                   and \"GET\" without one.
  HEADERS          Alist of (NAME . VALUE) strings.  Never logged and
                   never placed on the command line.
  BODY             Request body string, sent on curl's standard input.
  ON-EVENT         Called with (TYPE DATA), both strings, TYPE nil when
                   the stream sent no `event:' field.
  ON-END           Called exactly once with a result plist, unless the
                   request is cancelled, in which case it is not called
                   at all.
  TIMEOUT          Seconds without a received byte before giving up;
                   defaults to `benedict-http-timeout'.
  CONNECT-TIMEOUT  Seconds for the connection phase alone; defaults to
                   `benedict-http-connect-timeout'.
  RETRY            Attempts to make after the first; defaults to
                   `benedict-http-retry'.

The result plist passed to ON-END is one of:

  (:status 200 :headers ALIST)
  (:status 429 :headers ALIST :body \"...\")
  (:error \"message\" :reason process|timeout|no-curl :exit CODE)

A 2xx stream reports no `:body' -- its bytes were delivered as events.
Every other status carries the body it did produce, truncated to
`benedict-http-raw-limit'.  Header names in ALIST are downcased.

ON-END may be called BEFORE this function returns, but only for a
failure that makes the request unstartable, such as a missing curl.  A
caller that must not be re-entered should arrange its own deferral; see
`benedict-api-stream', which routes terminal events through the kernel's
defer function for exactly this reason."
  (benedict-http--send
   (benedict-http--request-create
    :url url :method (or method (if body "POST" "GET")) :headers headers
    :body body :sse t :accumulate nil
    :on-event on-event :on-end on-end
    :timeout (or timeout benedict-http-timeout)
    :connect-timeout (or connect-timeout benedict-http-connect-timeout)
    :retry (or retry benedict-http-retry)
    :attempt 0)))

(cl-defun benedict-http-request (url &key method headers body on-end
                                     timeout connect-timeout retry)
  "Send a request to URL and call ON-END once with the whole response.

METHOD, HEADERS, BODY, TIMEOUT, CONNECT-TIMEOUT, and RETRY are as
`benedict-http-stream'.  There is no ON-EVENT: the body is accumulated
rather than framed, and the result plist always carries `:body'.
Returns a cancel thunk.

This is the asynchronous non-streaming path -- an OAuth token exchange,
a catalog refresh that can afford to be asynchronous.  It has no size
limit, unlike the bounded error buffer a stream keeps."
  (benedict-http--send
   (benedict-http--request-create
    :url url :method (or method (if body "POST" "GET")) :headers headers
    :body body :sse nil :accumulate t
    :on-end on-end
    :timeout (or timeout benedict-http-timeout)
    :connect-timeout (or connect-timeout benedict-http-connect-timeout)
    :retry (or retry benedict-http-retry)
    :attempt 0)))

(cl-defun benedict-http-request-sync (url &key method headers body timeout)
  "Send a request to URL, blocking until it completes, and return the result.

METHOD, HEADERS, and BODY are as `benedict-http-stream', and the result
is the plist `benedict-http-request' would pass to its callback.  TIMEOUT
here is a TOTAL time limit rather than a stall limit, since nothing can
observe progress while Emacs is blocked; it defaults to
`benedict-http-timeout'.

Blocking is a considered exception, not a convenience.  The only caller
that may take it is model catalog resolution: `benedict-model-resolve' is
synchronous by SPEC-001 7.6 and the transport is not, and that path is
cache-first so a cold cache is the only time it is reached.  Never call
this from a process filter, a timer, or anything else the reducer drives
-- it will stall the whole image, including every other session."
  (if (not (benedict-http-available-p))
      (benedict-http--no-curl-result)
    (let* ((header-file (make-temp-file "benedict-http-head-"))
           (stderr-file (make-temp-file "benedict-http-err-"))
           (body-file (and body (make-temp-file "benedict-http-body-")))
           (config-file (make-temp-file "benedict-http-cfg-"))
           (buffer (generate-new-buffer " *benedict-http-sync*")))
      (unwind-protect
          (progn
            (benedict-http--write
             config-file
             (benedict-http--config
              :url url :method (or method (if body "POST" "GET"))
              :headers headers :body-p (and body t)
              :header-file header-file :stderr-file stderr-file :sse nil
              :connect-timeout benedict-http-connect-timeout
              :max-time (or timeout benedict-http-timeout)))
            (when body (benedict-http--write body-file body))
            (benedict-log-debug "http: sync %s %s"
              (or method "GET") (benedict-http--loggable-url url))
            (let* ((exit (call-process benedict-http-curl-program
                                       body-file buffer nil
                                       "--config" config-file))
                   (output (with-current-buffer buffer (buffer-string))))
              (benedict-http--outcome exit output header-file stderr-file)))
        (kill-buffer buffer)
        (dolist (file (list config-file header-file stderr-file body-file))
          (when file (ignore-errors (delete-file file))))))))

;;;; Starting an attempt

(defun benedict-http--send (request)
  "Start REQUEST and return a thunk that cancels it."
  (if (not (benedict-http-available-p))
      (progn
        (benedict-http--finish request (benedict-http--no-curl-result))
        #'ignore)
    (benedict-http--start request)
    (lambda () (benedict-http--cancel request))))

(defun benedict-http--no-curl-result ()
  "Return the result plist for a curl that is not installed."
  (let ((message (format "Cannot find `%s'.  Benedict needs curl on PATH; \
set `benedict-http-curl-program' if it is installed elsewhere"
                         benedict-http-curl-program)))
    (benedict-log-error "http: %s" message)
    (list :error message :reason 'no-curl)))

(defun benedict-http--start (request)
  "Start one attempt at REQUEST, replacing any per-attempt state."
  (setf (benedict-http--request-raw request) nil
        (benedict-http--request-raw-length request) 0
        (benedict-http--request-timed-out request) nil
        (benedict-http--request-config-file request)
        (make-temp-file "benedict-http-cfg-")
        (benedict-http--request-header-file request)
        (make-temp-file "benedict-http-head-")
        (benedict-http--request-stderr-file request)
        (make-temp-file "benedict-http-err-")
        (benedict-http--request-parser request)
        (when (benedict-http--request-sse request)
          (benedict-http-sse-parser
           (lambda (type data) (benedict-http--event request type data)))))
  (condition-case error
      (let ((body (benedict-http--request-body request)))
        (benedict-http--write
         (benedict-http--request-config-file request)
         (benedict-http--config
          :url (benedict-http--request-url request)
          :method (benedict-http--request-method request)
          :headers (benedict-http--request-headers request)
          :body-p (and body t)
          :header-file (benedict-http--request-header-file request)
          :stderr-file (benedict-http--request-stderr-file request)
          :sse (benedict-http--request-sse request)
          :connect-timeout (benedict-http--request-connect-timeout request)))
        (benedict-log-debug "http: %s %s (attempt %d)"
          (benedict-http--request-method request)
          (benedict-http--loggable-url (benedict-http--request-url request))
          (1+ (benedict-http--request-attempt request)))
        (let ((process (make-process
                        :name "benedict-http"
                        :buffer nil
                        :command (list benedict-http-curl-program
                                       "--config"
                                       (benedict-http--request-config-file request))
                        :coding 'utf-8
                        :noquery t
                        :connection-type 'pipe
                        :filter (lambda (_process chunk)
                                  (benedict-http--filter request chunk))
                        :sentinel (lambda (process _event)
                                    (benedict-http--sentinel request process)))))
          (setf (benedict-http--request-process request) process)
          (benedict-http--send-body request process body)))
    (error
     (benedict-http--cleanup-files request)
     (benedict-http--finish
      request
      (list :error (format "Could not run %s: %s"
                           benedict-http-curl-program
                           (error-message-string error))
            :reason 'process)))))

(defun benedict-http--send-body (request process body)
  "Write BODY to PROCESS for REQUEST, then close its input and start the clock.

BODY may exceed the pipe buffer, in which case `process-send-string'
blocks and Emacs runs process output -- including this process's own
sentinel, if curl has already failed.  That sentinel may retry, which
replaces the process this function is still writing to.  So a write
error is not a failure to report: the request has already been finished
or restarted by whoever caused it, and the only wrong move here is to
report a second outcome or to arm a timer for an attempt that is over."
  (when body
    (condition-case error
        (process-send-string process body)
      (error (benedict-log-debug "http: body write interrupted: %s"
               (error-message-string error)))))
  (when (process-live-p process)
    (ignore-errors (process-send-eof process)))
  (when (eq (benedict-http--request-process request) process)
    (benedict-http--arm-stall-timer request)))

(cl-defun benedict-http--config (&key url method headers body-p header-file
                                      stderr-file sse connect-timeout max-time)
  "Return the text of a curl config file for one request.

URL, METHOD, HEADERS, HEADER-FILE, STDERR-FILE, CONNECT-TIMEOUT and
MAX-TIME map to the corresponding curl options.  BODY-P non-nil reads the
body from standard input.  SSE non-nil adds an Accept header for event
streams.

Everything travels this way rather than as process arguments because a
bearer token in `argv' is readable by every other process on the machine
for as long as the request runs.  The file is created by `make-temp-file',
which is mode 600, and is deleted when the request finishes.

STDERR-FILE matters more than it looks: this process is started with no
separate error output, so without the redirection curl's own diagnostic
\(\"curl: (22) The requested URL returned error: 404\") is appended to
the response body and every JSON error body in the system stops
parsing."
  (let ((lines (list (format "--url %s" (benedict-http--quote url))
                     (format "--request %s" (benedict-http--quote method))
                     (format "--dump-header %s" (benedict-http--quote header-file))
                     (format "--stderr %s" (benedict-http--quote stderr-file))
                     "--silent"
                     "--show-error"
                     "--no-buffer"
                     "--fail-with-body")))
    (when connect-timeout
      (push (format "--connect-timeout %s" connect-timeout) lines))
    (when max-time
      (push (format "--max-time %s" max-time) lines))
    (when sse
      (push (format "--header %s"
                    (benedict-http--quote "Accept: text/event-stream"))
            lines))
    (dolist (header headers)
      (push (format "--header %s"
                    (benedict-http--quote (format "%s: %s" (car header) (cdr header))))
            lines))
    (when body-p
      (push "--data-binary @-" lines))
    (setq lines (append (nreverse lines) benedict-http-extra-args))
    (concat (string-join lines "\n") "\n")))

(defun benedict-http--quote (value)
  "Return VALUE as a double-quoted curl config-file argument.
curl unescapes backslash sequences inside a quoted value, so a header or
URL containing a quote or a backslash has to be escaped rather than
merely wrapped."
  (concat "\""
          (replace-regexp-in-string
           "[\\\"\n\r\t]"
           (lambda (match)
             (pcase match
               ("\\" "\\\\") ("\"" "\\\"")
               ("\n" "\\n") ("\r" "\\r") ("\t" "\\t")))
           value t t)
          "\""))

(defun benedict-http--write (file text)
  "Write TEXT to FILE without messages, backups, or a coding prompt."
  (let ((coding-system-for-write 'utf-8-unix)
        (write-region-inhibit-fsync t))
    (write-region text nil file nil 'silent)))

;;;; Receiving

(defun benedict-http--filter (request chunk)
  "Feed CHUNK to REQUEST's raw buffer and, when streaming, its framer."
  (unless (benedict-http--request-cancelled request)
    (benedict-http--arm-stall-timer request)
    (benedict-http--accumulate request chunk)
    (when-let* ((parser (benedict-http--request-parser request)))
      (funcall parser chunk))))

(defun benedict-http--accumulate (request chunk)
  "Retain CHUNK on REQUEST for error reporting, within the size limit."
  (let ((length (benedict-http--request-raw-length request)))
    (when (or (benedict-http--request-accumulate request)
              (< length benedict-http-raw-limit))
      (push chunk (benedict-http--request-raw request))
      (setf (benedict-http--request-raw-length request) (+ length (length chunk))))))

(defun benedict-http--raw (request)
  "Return the bytes retained on REQUEST, oldest first."
  (apply #'concat (reverse (benedict-http--request-raw request))))

(defun benedict-http--event (request type data)
  "Deliver one framed event TYPE with DATA to REQUEST's caller.
Records that an event was emitted, which is what makes every later
failure terminal rather than retryable (SPEC-001 D20)."
  (setf (benedict-http--request-emitted request) t)
  (when-let* ((on-event (benedict-http--request-on-event request)))
    (funcall on-event type data)))

;;;; Finishing

(defun benedict-http--sentinel (request process)
  "Decide REQUEST's outcome now that PROCESS has exited."
  (unless (or (benedict-http--request-cancelled request)
              (memq (process-status process) '(run stop open listen connect)))
    (benedict-http--disarm-stall-timer request)
    ;; No more bytes are coming, which is the only thing that can resolve a
    ;; line ending held back as possibly-half-a-CRLF.
    (when-let* ((parser (benedict-http--request-parser request)))
      (funcall parser nil))
    (let* ((exit (process-exit-status process))
           (result (if (benedict-http--request-timed-out request)
                       (list :error (format "No data received for %s seconds"
                                            (benedict-http--request-timeout request))
                             :reason 'timeout)
                     (benedict-http--outcome
                      exit (benedict-http--raw request)
                      (benedict-http--request-header-file request)
                      (benedict-http--request-stderr-file request)
                      (benedict-http--request-sse request)))))
      (benedict-http--cleanup-files request)
      (if-let* ((delay (benedict-http--retry-delay request result)))
          (benedict-http--schedule-retry request delay result)
        (benedict-http--finish request result)))))

(defun benedict-http--outcome (exit body header-file stderr-file &optional sse)
  "Return the result plist for a finished curl run.

EXIT is the process exit status, BODY everything curl wrote to standard
output, HEADER-FILE the path `--dump-header' was pointed at, and
STDERR-FILE the path `--stderr' was.  SSE non-nil omits the body from a
2xx result, whose bytes were delivered as events.

The status comes from the dumped headers, never from the exit code: a
zero exit means the transfer completed, which is not the same claim as
\"200\", and reporting a hardcoded 200 was how the predecessor lost the
difference between a 200 and a 204."
  (pcase-let ((`(,status . ,headers) (benedict-http--parse-headers header-file)))
    (cond
     (status
      (benedict-log-debug "http: status %d (%d bytes)" status (length body))
      (append (list :status status :headers headers)
              (unless (and sse (<= 200 status 299))
                (list :body body))))
     ;; No status line at all: curl never got a response, and its own
     ;; diagnostic is the only thing that can say why.
     (t
      (let* ((description (alist-get exit benedict-http--exit-descriptions))
             (detail (string-trim (benedict-http--read-file stderr-file)))
             (message (cond ((and description (not (string-empty-p detail)))
                             (format "%s: %s" description detail))
                            (description description)
                            ((not (string-empty-p detail)) detail)
                            (t (format "curl exited with status %d" exit)))))
        (benedict-log-warn "http: %s" message)
        (list :error message :reason 'process :exit exit))))))

(defun benedict-http--read-file (file)
  "Return the contents of FILE, or an empty string when it cannot be read."
  (if (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))
    ""))

(defun benedict-http--parse-headers (file)
  "Return (STATUS . HEADERS) parsed from the header dump at FILE.

STATUS is an integer and HEADERS an alist of downcased name to value;
both are nil when FILE holds no status line.  A response may dump several
header blocks -- a 100 Continue, a redirect -- and only the last one
describes the response the body belongs to, so each status line starts
the parse over."
  (let ((status nil)
        (headers nil))
    (when (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (string-trim-right
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))))
            (cond
             ((string-match "\\`HTTP/[0-9.]+[ \t]+\\([0-9]+\\)" line)
              (setq status (string-to-number (match-string 1 line))
                    headers nil))
             ((string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
              (push (cons (downcase (match-string 1 line)) (match-string 2 line))
                    headers))))
          (forward-line 1))))
    (cons status (nreverse headers))))

(defun benedict-http--finish (request result)
  "Call REQUEST's callback with RESULT, exactly once."
  (unless (or (benedict-http--request-finished request)
              (benedict-http--request-cancelled request))
    (setf (benedict-http--request-finished request) t)
    (when-let* ((on-end (benedict-http--request-on-end request)))
      (dolist (filter benedict-http-result-filter-functions)
        (setq result (funcall filter result)))
      (funcall on-end result))))

;;;; Retry

(defun benedict-http--retry-delay (request result)
  "Return the seconds to wait before retrying REQUEST after RESULT, or nil.

Nil whenever the failure is not retryable, no attempts remain, or -- the
rule that matters -- an event has already been emitted.  Retrying a
stream that has already delivered deltas appends the retried content on
top of what the caller accumulated, so a mid-stream failure is terminal
by construction rather than by policy (SPEC-001 D20)."
  (and (not (benedict-http--request-emitted request))
       (< (benedict-http--request-attempt request)
          (benedict-http--request-retry request))
       (benedict-http--retryable-p result)
       (min benedict-http-retry-max-seconds
            (or (benedict-http--retry-after result)
                (benedict-http--backoff (benedict-http--request-attempt request))))))

(defun benedict-http--retryable-p (result)
  "Return non-nil when RESULT is a failure worth trying again."
  (let ((status (plist-get result :status)))
    (cond
     (status (or (>= status 500)
                 (memq status benedict-http-retry-status-codes)))
     ((eq (plist-get result :reason) 'process)
      (and (memq (plist-get result :exit) benedict-http-retry-exit-codes) t))
     (t nil))))

(defun benedict-http--retry-after (result)
  "Return RESULT's `Retry-After' delay in seconds, or nil.

Only the delta-seconds form is honored.  The HTTP-date form is legal and
rare, and misreading one as a duration would produce a wait measured in
decades, so an unparsable value falls back to the ordinary backoff."
  (when-let* ((value (alist-get "retry-after" (plist-get result :headers)
                                nil nil #'equal))
              (trimmed (string-trim value)))
    (and (string-match-p "\\`[0-9]+\\'" trimmed)
         (string-to-number trimmed))))

(defun benedict-http--backoff (attempt)
  "Return the backoff delay in seconds for a zero-based ATTEMPT.
Half the doubling interval plus a random half, so that a fleet of
requests failing on the same rate limit does not retry in lockstep."
  (let ((interval (min benedict-http-retry-max-seconds
                       (* benedict-http-retry-base-seconds (expt 2 attempt)))))
    (+ (/ interval 2.0) (* (/ (random 1000) 1000.0) (/ interval 2.0)))))

(defun benedict-http--schedule-retry (request delay result)
  "Retry REQUEST after DELAY seconds, having observed RESULT."
  (cl-incf (benedict-http--request-attempt request))
  (benedict-log-info "http: retrying in %.1fs after %s (attempt %d of %d)"
    delay
    (or (plist-get result :status) (plist-get result :error))
    (1+ (benedict-http--request-attempt request))
    (1+ (benedict-http--request-retry request)))
  (setf (benedict-http--request-retry-timer request)
        (run-at-time delay nil
                     (lambda ()
                       (setf (benedict-http--request-retry-timer request) nil)
                       (unless (benedict-http--request-cancelled request)
                         (benedict-http--start request))))))

;;;; Timers, cancellation, and cleanup

(defun benedict-http--arm-stall-timer (request)
  "Start or restart REQUEST's stall timer, if it has a timeout."
  (benedict-http--disarm-stall-timer request)
  (when-let* ((timeout (benedict-http--request-timeout request)))
    (setf (benedict-http--request-stall-timer request)
          (run-at-time timeout nil
                       (lambda () (benedict-http--stall request))))))

(defun benedict-http--disarm-stall-timer (request)
  "Cancel REQUEST's stall timer if one is running."
  (when-let* ((timer (benedict-http--request-stall-timer request)))
    (cancel-timer timer)
    (setf (benedict-http--request-stall-timer request) nil)))

(defun benedict-http--stall (request)
  "Abandon REQUEST because nothing has arrived for its whole timeout.
Kills the process and lets the sentinel report the outcome, so that a
timeout takes the same finishing path as any other failure."
  (unless (or (benedict-http--request-cancelled request)
              (benedict-http--request-finished request))
    (benedict-log-warn "http: no data for %ss, abandoning %s"
      (benedict-http--request-timeout request)
      (benedict-http--loggable-url (benedict-http--request-url request)))
    (setf (benedict-http--request-timed-out request) t)
    (if-let* ((process (benedict-http--request-process request))
              ((process-live-p process)))
        (delete-process process)
      (benedict-http--cleanup-files request)
      (benedict-http--finish request
                             (list :error "Request timed out" :reason 'timeout)))))

(defun benedict-http--cancel (request)
  "Abandon REQUEST without calling its callback.

Clears the sentinel before deleting the process, so that the kill does
not arrive as a failure the caller has to distinguish from a real one.
Idempotent, and harmless once the request has finished."
  (unless (benedict-http--request-cancelled request)
    (setf (benedict-http--request-cancelled request) t)
    (benedict-http--disarm-stall-timer request)
    (when-let* ((timer (benedict-http--request-retry-timer request)))
      (cancel-timer timer)
      (setf (benedict-http--request-retry-timer request) nil))
    (when-let* ((process (benedict-http--request-process request)))
      (when (process-live-p process)
        (set-process-sentinel process #'ignore)
        (set-process-filter process #'ignore)
        (delete-process process)))
    (benedict-http--cleanup-files request)
    (benedict-log-debug "http: cancelled %s"
      (benedict-http--loggable-url (benedict-http--request-url request))))
  nil)

(defun benedict-http--cleanup-files (request)
  "Delete the temporary files REQUEST's current attempt created.
A retry makes its own, so the slots are cleared rather than reused."
  (when-let* ((file (benedict-http--request-config-file request)))
    (ignore-errors (delete-file file))
    (setf (benedict-http--request-config-file request) nil))
  (when-let* ((file (benedict-http--request-header-file request)))
    (ignore-errors (delete-file file))
    (setf (benedict-http--request-header-file request) nil))
  (when-let* ((file (benedict-http--request-stderr-file request)))
    (ignore-errors (delete-file file))
    (setf (benedict-http--request-stderr-file request) nil)))

(defun benedict-http--loggable-url (url)
  "Return URL with any query string removed, for logging.
Some services carry the API key in a query parameter, and the log is
read back by an agent that may show it to a model."
  (if-let* ((mark (string-search "?" url)))
      (concat (substring url 0 mark) "?…")
    url))

(provide 'benedict-http)

;;; benedict-http.el ends here
