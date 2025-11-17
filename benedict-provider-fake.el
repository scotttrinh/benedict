;;; benedict-provider-fake.el --- Deterministic fake provider -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Lightweight provider that mimics async OpenRouter-style replies without
;; hitting the network. Useful for automated tests and manual dry-runs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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

(defvar benedict-provider-fake-script nil
  "Queue of scripted responses for deterministic tests.
Each entry is a plist describing either a success (:type 'success) or
error (:type 'error) payload. When nil, responses echo the last user
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
                  (let* ((role (plist-get msg :role))
                         (role-sym (cond
                                    ((symbolp role) role)
                                    ((stringp role) (intern (downcase role)))
                                    (t (intern (format "%s" role))))))
                    (eq role-sym 'user)))
                (reverse messages))))
    (or (plist-get user :content) "")))

(defun benedict-provider-fake--build-usage (messages content)
  "Rudimentary usage payload derived from MESSAGES and CONTENT length."
  (let* ((prompt (apply #'+ (mapcar (lambda (msg)
                                      (length (or (plist-get msg :content) "")))
                                    messages)))
         (completion (length content)))
    `(("prompt_tokens" . ,prompt)
      ("completion_tokens" . ,completion)
      ("total_tokens" . ,(+ prompt completion)))))

(defun benedict-provider-fake--success-payload (request entry start-time latency)
  "Create a success payload using REQUEST, ENTRY, START-TIME, and LATENCY."
  (let* ((messages (plist-get request :messages))
         (content (or (plist-get entry :content)
                      (format "Fake echo: %s"
                              (benedict-provider-fake--last-user-content messages))))
         (model (or (plist-get entry :model)
                    benedict-provider-fake-default-model))
         (usage (or (plist-get entry :usage)
                    (benedict-provider-fake--build-usage messages content)))
         (message (list :role 'assistant :content content)))
    (list :message message
          :model model
          :provider 'fake
          :usage usage
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
         (timers nil))
    
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
                          (funcall on-error (benedict-provider-fake--error-payload entry))))))
        ;; Success branch - MUST wrap in progn too!
        (progn
          (let ((last-chunk-time chunk-offset)
                (chunk-count 0))
            ;; Schedule chunk emissions if chunks are provided
            (when chunks
              (dolist (chunk chunks)
                (let ((chunk-content chunk)
                      (chunk-idx chunk-count))
                  (register last-chunk-time
                            (lambda ()
                              (when (functionp on-delta)
                                (funcall on-delta
                                         (list :content chunk-content
                                               :index chunk-idx
                                               :provider 'fake
                                               :done nil)))))
                  (setq last-chunk-time (+ last-chunk-time chunk-delay))
                  (setq chunk-count (1+ chunk-count)))))
            
            ;; Schedule completion callback
            (let ((completion-delay (if chunks
                                        (max delay last-chunk-time)
                                      delay)))
              (register completion-delay
                        (lambda ()
                          (let ((payload (benedict-provider-fake--success-payload
                                          request entry start-time delay)))
                            (if (functionp on-complete)
                                (funcall on-complete payload)
                              (when (functionp on-success)
                                (funcall on-success payload)))))))))))
    
    ;; Return handle with timers for cancellation
    (list :request request
          :entry entry
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
  :capabilities '(:streaming t :tools nil)
  :cancel #'benedict-provider-fake--cancel))

(provide 'benedict-provider-fake)
;;; benedict-provider-fake.el ends here
