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

(defun benedict-provider-fake--dispatch (request on-success on-error entry start-time delay)
  "Deliver either success or error for REQUEST using ENTRY.
ON-SUCCESS/ON-ERROR are callbacks. START-TIME/DELAY track timing."
  (if (eq (plist-get entry :type) 'error)
      (when (functionp on-error)
        (funcall on-error (benedict-provider-fake--error-payload entry)))
    (when (functionp on-success)
      (funcall on-success
               (benedict-provider-fake--success-payload
                request entry start-time delay)))))

(cl-defun benedict-provider-fake--send (_provider request &key on-success on-error)
  "Dispatch REQUEST through the fake provider.
ON-SUCCESS/ON-ERROR mirror `benedict-provider-dispatch'."
  (let* ((entry (or (benedict-provider-fake--next-script)
                    (list :type 'success)))
         (start-time (current-time))
         (delay (or (plist-get entry :delay) benedict-provider-fake-latency-seconds)))
    (run-at-time delay nil #'benedict-provider-fake--dispatch
                 request on-success on-error entry start-time delay)
    (list :request request :entry entry)))

(benedict-provider-register
 (benedict-provider--create
  :id 'fake
  :name "Fake (echo)"
  :send #'benedict-provider-fake--send
  :capabilities '(:streaming nil :tools nil)
  :cancel #'ignore))

(provide 'benedict-provider-fake)
;;; benedict-provider-fake.el ends here
