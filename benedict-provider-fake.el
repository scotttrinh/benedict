;;; benedict-provider-fake.el --- Deterministic fake provider -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Lightweight provider that mimics async OpenRouter-style replies without
;; hitting the network.  Useful for automated tests and manual dry-runs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'lgr)
(require 'benedict-provider)

(defgroup benedict-provider-fake nil
  "Settings for the Benedict fake provider."
  :group 'benedict
  :prefix "benedict-provider-fake-")

(defcustom benedict-provider-fake-default-model "benedict/fake-echo"
  "Model name reported by the fake provider."
  :type 'string
  :group 'benedict-provider-fake)

(defcustom benedict-provider-fake-latency-seconds 0.05
  "Default simulated latency (seconds) before delivering a response."
  :type 'number
  :group 'benedict-provider-fake)

(defcustom benedict-provider-fake-streaming-chunk-delay 0.01
  "Default delay (seconds) between streaming chunks."
  :type 'number
  :group 'benedict-provider-fake)

(defvar benedict-provider-fake--request-counter 0
  "Internal counter for correlating fake provider logs.")

(defun benedict-provider-fake--next-request-id ()
  "Return a unique identifier for fake provider logs."
  (format "fake-%06d"
          (cl-incf benedict-provider-fake--request-counter)))

(defvar benedict-provider-fake-script nil
  "Queue of scripted responses for deterministic tests.
Each entry is a plist describing either a success (:type \='success) or
error (:type \='error) payload.  When nil, responses echo the last user
message using default metadata.")

(defmacro benedict-provider-fake-with-script (script &rest body)
  "Evaluate BODY with SCRIPT (a list of response plists) installed.
SCRIPT entries are consumed FIFO."
  (declare (indent 1))
  `(let ((benedict-provider-fake-script (copy-tree ,script)))
     ,@body))

(defun benedict-provider-fake-reset-script ()
  "Clear any queued scripted responses."
  (setq benedict-provider-fake-script nil))

(defun benedict-provider-fake-enqueue-response (content &rest plist)
  "Append a scripted success response with CONTENT and extra PLIST."
  (setq benedict-provider-fake-script
        (append benedict-provider-fake-script
                (list (apply #'list :type 'success :content content plist)))))

(defun benedict-provider-fake-enqueue-error (message &rest plist)
  "Append a scripted error response with MESSAGE and extra PLIST."
  (setq benedict-provider-fake-script
        (append benedict-provider-fake-script
                (list (apply #'list :type 'error :message message plist)))))

(defun benedict-provider-fake--next-script ()
  "Pop and return the next scripted entry, or nil."
  (when benedict-provider-fake-script
    (prog1 (car benedict-provider-fake-script)
      (setq benedict-provider-fake-script (cdr benedict-provider-fake-script)))))

(defun benedict-provider-fake--last-user-content (messages)
  "Return the content from the last user ROLE in MESSAGES."
  (let* ((user (cl-find-if
                (lambda (msg)
                  (let* ((role (benedict-provider-message-role msg))
                         (role-sym (cond
                                    ((symbolp role) role)
                                    ((stringp role) (intern (downcase role)))
                                    (t (intern (format "%s" role))))))
                    (eq role-sym 'user)))
                (reverse messages))))
    (if user
        (benedict-provider-message-content user)
      "")))

(defun benedict-provider-fake--build-usage (messages content)
  "Rudimentary usage payload derived from MESSAGES and CONTENT length."
  (let* ((prompt (apply #'+ (mapcar (lambda (msg)
                                      (length (benedict-provider-message-content msg)))
                                    messages)))
         (completion (length content)))
    `(("prompt_tokens" . ,prompt)
      ("completion_tokens" . ,completion)
      ("total_tokens" . ,(+ prompt completion)))))

(defun benedict-provider-fake--normalize-list (value)
  "Return VALUE coerced into a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((vectorp value) (append value nil))
   (t (list value))))

(defun benedict-provider-fake--normalize-thinking-entry (entry id index)
  "Normalize a scripted thinking ENTRY using fallback ID and INDEX."
  (cond
   ((null entry) nil)
   ((stringp entry)
    (list :id id
          :type "reasoning.text"
          :format "anthropic-claude-v1"
          :index index
          :chunks (list entry)))
   ((listp entry)
    (let* ((detail (copy-tree entry))
           (chunks (or (plist-get detail :chunks)
                       (when-let ((text (or (plist-get detail :text)
                                            (plist-get detail :summary)
                                            (plist-get detail :data))))
                         (list text)))))
      (plist-put detail :id (or (plist-get detail :id) id))
      (plist-put detail :type (or (plist-get detail :type) "reasoning.text"))
      (plist-put detail :format (or (plist-get detail :format) "anthropic-claude-v1"))
      (plist-put detail :index (or (plist-get detail :index) index))
      (plist-put detail :chunks (or (benedict-provider-fake--normalize-list chunks)
                                    (list "")))
      detail))
   (t nil)))

(defun benedict-provider-fake--normalize-thinking (thinking)
  "Return THINKING normalized into detail plists with chunk lists."
  (let ((counter 0))
    (cond
     ((null thinking) nil)
     ((stringp thinking)
      (list (benedict-provider-fake--normalize-thinking-entry thinking
                                                              (format "fake-thinking-%d" counter)
                                                              counter)))
     ((vectorp thinking)
      (benedict-provider-fake--normalize-thinking (append thinking nil)))
     ((and (listp thinking)
           (cl-every #'stringp thinking))
      (list (benedict-provider-fake--normalize-thinking-entry
             (string-join thinking "\n\n")
             (format "fake-thinking-%d" counter)
             counter)))
     ((listp thinking)
      (let (details)
        (dolist (entry thinking (nreverse details))
          (let* ((detail-id (format "fake-thinking-%d" counter))
                 (detail (benedict-provider-fake--normalize-thinking-entry entry detail-id counter)))
            (setq counter (1+ counter))
            (when detail
              (push detail details))))))
     (t nil))))

(defun benedict-provider-fake--finalize-thinking (details)
  "Produce the final thinking payload from DETAILS."
  (when details
    (mapcar
     (lambda (detail)
       (let* ((type (downcase (format "%s" (plist-get detail :type))))
              (chunks (or (plist-get detail :chunks) '("")))
              (text (mapconcat #'identity chunks "")))
         (plist-put detail :chunks nil)
         (pcase type
           ("reasoning.summary" (plist-put detail :summary text))
           ("reasoning.encrypted" (plist-put detail :data text))
           (_ (plist-put detail :text text)))
         detail))
     (copy-tree details))))

(defun benedict-provider-fake--make-reasoning-delta (detail chunk model)
  "Build a delta payload for DETAIL chunk CHUNK with MODEL."
  (let* ((type (downcase (format "%s" (plist-get detail :type))))
         (base (list :id (plist-get detail :id)
                     :type (plist-get detail :type)
                     :format (plist-get detail :format)
                     :index (plist-get detail :index))))
    (pcase type
      ("reasoning.summary" (plist-put base :summary chunk))
      ("reasoning.encrypted" (plist-put base :data chunk))
      (_ (plist-put base :text chunk)))
    (list :provider 'fake
          :model model
          :choices (vector (list :index 0
                                 :delta (list :reasoning_details (vector base)))))))

(defun benedict-provider-fake--success-payload (request entry start-time latency thinking)
  "Create a success payload using REQUEST, ENTRY, START-TIME, LATENCY, and THINKING."
  (let* ((messages (benedict-provider-request-messages request "Fake"))
         (content (or (plist-get entry :content)
                      (format "Fake echo: %s"
                              (benedict-provider-fake--last-user-content messages))))
         (role (or (plist-get entry :role) 'assistant))
         (model (or (plist-get entry :model)
                    benedict-provider-fake-default-model))
         (usage (or (plist-get entry :usage)
                    (benedict-provider-fake--build-usage messages content)))
         (final-thinking (or thinking (plist-get entry :thinking)))
         (tool-calls (plist-get entry :tool-calls)))
    (ignore role)
    (benedict-provider-result-create
     :text content
     :tool-calls tool-calls
     :model model
     :provider 'fake
     :usage usage
     :thinking final-thinking
     :latency (or (plist-get entry :latency)
                  (or latency (float-time (time-subtract (current-time) start-time)))))))

(defun benedict-provider-fake--error-payload (entry)
  "Create an error payload using ENTRY plist."
  (list :type (or (plist-get entry :type) 'error)
        :provider 'fake
        :message (or (plist-get entry :message) "Fake provider error")
        :status (plist-get entry :status)
        :code (plist-get entry :code)
        :retryable (plist-get entry :retryable)))

(cl-defun benedict-provider-fake--send (_provider request &key on-success on-error on-delta on-complete)
  "Dispatch REQUEST through the fake provider.
ON-SUCCESS/ON-ERROR/ON-DELTA/ON-COMPLETE mirror `benedict-provider-dispatch'.
Returns a handle plist with :request, :entry, :provider, and :timers."
  (let* ((entry (or (benedict-provider-fake--next-script)
                    (list :type 'success)))
         (start-time (current-time))
         (delay (or (plist-get entry :delay) benedict-provider-fake-latency-seconds))
         (chunks (plist-get entry :chunks))
         (chunk-delay (or (plist-get entry :chunk-delay) benedict-provider-fake-streaming-chunk-delay))
         (chunk-offset (or (plist-get entry :chunk-offset) 0.0))
         (model (or (plist-get entry :model) benedict-provider-fake-default-model))
         (thinking-details (benedict-provider-fake--normalize-thinking (plist-get entry :thinking)))
         (final-thinking (benedict-provider-fake--finalize-thinking thinking-details))
         (request-id (or (plist-get request :request-id)
                         (benedict-provider-fake--next-request-id)))
         (timers nil)
         (lgr (lgr-get-logger "benedict.fake")))
    
    (lgr-debug lgr "Fake request"
               :model model
               :request-id request-id)
    
    ;; Helper to schedule callbacks and track timers
    (cl-labels
        ((register (secs fn)
           (let ((timer (run-at-time secs nil fn)))
             (push timer timers)
             timer)))
      
      ;; Branch on entry type
      (if (eq (plist-get entry :type) 'error)
          ;; Error branch
          (progn
            (when (functionp on-error)
              (register delay
                        (lambda ()
                          (let ((payload (benedict-provider-fake--error-payload entry)))
                            (lgr-warn lgr "Fake response error"
                                      :request-id request-id
                                      :type 'error
                                      :message (plist-get payload :message)
                                      :status (plist-get payload :status))
                            (funcall on-error payload))))))
        ;; Success branch - MUST wrap in progn too!
        (progn
          (let ((last-chunk-time chunk-offset)
                (chunk-count 0)
                (last-thinking-time chunk-offset))
            ;; Schedule chunk emissions if chunks are provided
            (when chunks
              (dolist (chunk chunks)
                (let ((chunk-content chunk)
                      (chunk-idx chunk-count))
                  (register last-chunk-time
                            (lambda ()
                              (lgr-trace lgr "Delta chunk"
                                         :chunk-index chunk-idx
                                         :request-id request-id)
                              (when (functionp on-delta)
                                (funcall on-delta
                                         :message-id request-id
                                         :kind 'content-delta
                                         :text chunk-content))))
                  (setq last-chunk-time (+ last-chunk-time chunk-delay))
                  (setq chunk-count (1+ chunk-count)))))
            ;; Schedule reasoning chunks
            (when thinking-details
              (dolist (detail thinking-details)
                (dolist (chunk (plist-get detail :chunks))
                  (let* ((chunk-text (or chunk "")))
                    (register last-thinking-time
                              (lambda ()
                                (lgr-trace lgr "Thinking delta"
                                           :request-id request-id)
                                (when (functionp on-delta)
                                  (funcall on-delta
                                           :message-id request-id
                                           :kind 'thinking-delta
                                           :text chunk-text)))))
                  (setq last-thinking-time (+ last-thinking-time chunk-delay)))))

            ;; Schedule completion callback
            (let ((completion-delay (if chunks
                                        (max delay last-chunk-time last-thinking-time)
                                      (max delay last-thinking-time))))
              (register completion-delay
                        (lambda ()
                          (let ((payload (benedict-provider-fake--success-payload
                                          request entry start-time delay final-thinking)))
                            (lgr-info lgr "Completion"
                                      :request-id request-id
                                      :latency (plist-get payload :latency))
                            (if (functionp on-complete)
                                (funcall on-complete payload)
                              (when (functionp on-success)
                                (funcall on-success payload)))))))))))
        
    ;; Return handle with timers for cancellation
    (list :request request
          :entry entry
          :request-id request-id
          :provider 'fake
          :timers timers)))

(defun benedict-provider-fake--cancel (_provider handle)
  "Cancel all pending timers for HANDLE."
  (let ((timers (plist-get handle :timers)))
    (dolist (timer timers)
      (when (timerp timer)
        (cancel-timer timer)))))

(benedict-provider-register
 (benedict-provider--create
  :id 'fake
  :name "Fake (echo)"
  :send #'benedict-provider-fake--send
  :capabilities '(:streaming t :tools t)
  :cancel #'benedict-provider-fake--cancel))

(provide 'benedict-provider-fake)
;;; benedict-provider-fake.el ends here
