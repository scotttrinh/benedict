;;; benedict-http.el --- HTTP client wrapper for Benedict -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; A robust wrapper around curl for making HTTP requests, with first-class
;; support for Server-Sent Events (SSE).
;;
;; Handles process management, command construction, error logging, and
;; streaming response parsing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'lgr)
(require 'benedict-provider)

(defgroup benedict-http nil
  "HTTP client settings for Benedict."
  :group 'benedict
  :prefix "benedict-http-")

(defcustom benedict-http-curl-program "curl"
  "Path to the curl executable.
Must support --no-buffer and --fail-with-body (curl 7.60+)."
  :type 'file
  :group 'benedict-http)

(defcustom benedict-http-proxy-args nil
  "List of extra arguments to pass to curl (e.g. proxy settings)."
  :type '(repeat string)
  :group 'benedict-http)

(defconst benedict-http--stream-log-limit 32768
  "Maximum number of bytes to retain from streaming stdout/stderr.")

(cl-defstruct (benedict-http-response
               (:constructor benedict-http--make-response))
  "Structured response from an HTTP request."
  status headers body error)

(cl-defun benedict-http-request (url &key method headers body stream on-success on-error on-delta on-complete request-id provider)
  "Execute an HTTP request to URL.

Arguments:
- METHOD: HTTP method string (default \"GET\").
- HEADERS: Alist of header pairs (strings).
- BODY: Request body string.
- STREAM: When non-nil, expect SSE and invoke ON-DELTA.
- ON-SUCCESS: Function called with (status headers body) or parsed JSON.
- ON-ERROR: Function called with error plist.
- ON-DELTA: Function called with (event-type data) for SSE.
- ON-COMPLETE: Function called when stream finishes.
- REQUEST-ID: Optional ID for logging context.
- PROVIDER: Provider symbol for logging context.

Returns the process object."
  (let* ((method (or method "GET"))
         (headers (or headers '()))
         (request-id (or request-id (format "req-%x" (random #x1000000))))
         (provider (or provider 'http))
         (context (list :url url
                        :method method
                        :headers headers
                        :body body
                        :stream stream
                        :on-success on-success
                        :on-error on-error
                        :on-delta on-delta
                        :on-complete on-complete
                        :request-id request-id
                        :provider provider
                        :partial ""
                        :stdout-log ""
                        :stderr-log ""))
         (lgr (lgr-get-logger "benedict.http")))
    
    (lgr-debug lgr "HTTP start"
               :method method
               :url url
               :stream stream
               :request-id request-id)

    (let ((command (benedict-http--make-command url method headers body stream))
          (stderr-buffer (generate-new-buffer (format " *benedict-http-stderr-%s*" request-id))))
      (condition-case err
          (let ((process (make-process
                          :name (format "benedict-http-%s" request-id)
                          :buffer nil ; We handle output in filter
                          :command command
                          :stderr stderr-buffer
                          :coding 'utf-8
                          :noquery t
                          :connection-type 'pipe
                          :filter #'benedict-http--process-filter
                          :sentinel #'benedict-http--process-sentinel)))
            (process-put process 'benedict-http-context context)
            (process-put process 'benedict-http-stderr stderr-buffer)
            ;; Store command for debug/inspection if needed
            (process-put process 'benedict-http-command command)
            process)
        (error
         (lgr-error lgr "HTTP start failed"
                    :request-id request-id
                    :error (error-message-string err))
         (when (buffer-live-p stderr-buffer)
           (kill-buffer stderr-buffer))
         (when on-error
           (funcall on-error (list :type 'process :message (error-message-string err))))
         nil)))))

(defun benedict-http--make-command (url method headers body stream)
  "Build the curl command list."
  (let ((base (list benedict-http-curl-program
                    "--silent" "--show-error"
                    "--no-buffer" "--fail-with-body"
                    "-X" method)))
    (when stream
      (push (cons "Accept" "text/event-stream") headers))
    
    (setq base (append base
                       (cl-mapcan (lambda (h) (list "-H" (format "%s: %s" (car h) (cdr h))))
                                  headers)
                       benedict-http-proxy-args
                       (list url)))
    
    (when body
      (setq base (append base (list "--data-binary" body))))
    
    base))

(defun benedict-http--process-filter (process chunk)
  "Handle incoming CHUNK from PROCESS."
  (let ((context (process-get process 'benedict-http-context)))
    (when context
      (benedict-http--append-log context :stdout-log chunk)
      
      (if (plist-get context :stream)
          (benedict-http--handle-stream-chunk context (string-replace "\r" "" chunk))
        (benedict-http--handle-buffer-chunk context chunk)))))

(defun benedict-http--append-log (context key chunk)
  "Append CHUNK to CONTEXT's log at KEY, respecting limits."
  (let* ((log (or (plist-get context key) ""))
         (combined (concat log chunk))
         (limit benedict-http--stream-log-limit))
    (setf (plist-get context key)
          (if (> (length combined) limit)
              (substring combined (- (length combined) limit))
            combined))))

(defun benedict-http--handle-buffer-chunk (context chunk)
  "Buffer non-streaming response."
  (let ((current (or (plist-get context :partial) "")))
    (setf (plist-get context :partial) (concat current chunk))))

(defun benedict-http--handle-stream-chunk (context chunk)
  "Process SSE CHUNK for CONTEXT."
  (let ((buffer (concat (or (plist-get context :partial) "") chunk))
        (continue t))
    (while continue
      (let ((pos (string-match "\n\n" buffer)))
        (if (null pos)
            (setq continue nil)
          (let ((event (substring buffer 0 pos)))
            (setq buffer (substring buffer (+ pos 2)))
            (unless (string-empty-p event)
              (benedict-http--process-sse-block context event))))))
    (setf (plist-get context :partial) buffer)))

(defun benedict-http--process-sse-block (context block)
  "Parse SSE BLOCK and dispatch via ON-DELTA."
  (let ((lines (split-string block "\n"))
        (data-lines nil)
        (event-type nil))
    (dolist (line lines)
      (cond
       ((string-prefix-p "data:" line)
        (push (string-trim-left (substring line 5)) data-lines))
       ((string-prefix-p "event:" line)
        (setq event-type (string-trim (substring line 6))))
       ((string-prefix-p ":" line) nil) ; Comment
       ((string-empty-p line) nil)
       (t (push (string-trim line) data-lines))))
    
    (let ((payload (string-join (nreverse (delq nil data-lines)) "\n"))
          (on-delta (plist-get context :on-delta)))
      (when (and on-delta (> (length payload) 0))
        (let ((lgr (lgr-get-logger "benedict.http")))
          (lgr-trace lgr "Stream event"
                     :event-type event-type
                     :payload-length (length payload)
                     :request-id (plist-get context :request-id)))
        (funcall on-delta event-type payload)))))

(defun benedict-http--process-sentinel (process _event)
  "Handle completion of PROCESS with _EVENT."
  (let ((context (process-get process 'benedict-http-context))
        (stderr-buf (process-get process 'benedict-http-stderr)))
    (when (memq (process-status process) '(exit signal))
      (let ((exit-code (process-exit-status process))
            (stderr (when (buffer-live-p stderr-buf)
                      (with-current-buffer stderr-buf (buffer-string)))))
        
        ;; Clean up stderr buffer
        (when (buffer-live-p stderr-buf)
          (kill-buffer stderr-buf))
        
        (let ((lgr (lgr-get-logger "benedict.http")))
          (lgr-debug lgr "HTTP exit"
                     :exit-code exit-code
                     :request-id (plist-get context :request-id)))

        (if (zerop exit-code)
            (benedict-http--finish-success context)
          (benedict-http--finish-error context exit-code stderr))))))

(defun benedict-http--finish-success (context)
  "Handle successful completion."
  (if (plist-get context :stream)
      (when-let ((cb (plist-get context :on-complete)))
        (funcall cb))
    (when-let ((cb (plist-get context :on-success)))
      ;; For non-streaming, we have the full body in partial.
      ;; Note: This assumes curl --fail-with-body handles HTTP errors by
      ;; exiting non-zero? No, --fail-with-body returns exit code 22 on 400+ 
      ;; BUT it prints the body to stdout.
      ;; Wait, curl behaviour:
      ;; -f, --fail: Fail silently (no output at all) on server errors.
      ;; --fail-with-body: Fail on server errors but still write the response body.
      ;; Returns 22 (CURLE_HTTP_RETURNED_ERROR) for 400+.
      ;; So if exit code is 0, it's a success (2xx).
      (funcall cb 200 nil (plist-get context :partial)))))

(defun benedict-http--finish-error (context code stderr)
  "Handle error completion."
  (let ((on-error (plist-get context :on-error))
        (provider (plist-get context :provider))
        (request-id (plist-get context :request-id))
        (lgr (lgr-get-logger "benedict.http")))
    
    ;; Check if it's an HTTP error (curl code 22)
    (if (eq code 22)
        (let ((body (or (plist-get context :partial) "")))
          (lgr-warn lgr "HTTP error response"
                    :code code
                    :request-id request-id)
          (when on-error
            ;; Try to parse body if JSON? 
            ;; For now just pass raw body and let caller handle it.
            (funcall on-error (list :type 'http :code code :body body :stderr stderr))))
      
      ;; Other network/process error
      (lgr-error lgr "Curl error"
                 :code code
                 :request-id request-id)
      (when on-error
        (funcall on-error (list :type 'process :code code :stderr stderr))))))

(provide 'benedict-http)
;;; benedict-http.el ends here
