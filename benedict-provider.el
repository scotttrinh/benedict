;;; benedict-provider.el --- Provider registry and helpers -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provides a minimal registry for provider implementations and helper
;; functions that dispatch requests to the active provider.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'lgr)
(require 'benedict-message)

(defgroup benedict-provider nil
  "Shared customization for Benedict providers."
  :group 'benedict
  :prefix "benedict-provider-")

(cl-defstruct (benedict-provider
               (:constructor benedict-provider--create))
  "Structure describing a provider implementation."
  id name send capabilities cancel)

(cl-defstruct (benedict-provider-result
               (:constructor benedict-provider-result--create))
  "Strict provider response decoded from provider wire data."
  provider model text thinking tool-calls usage latency metadata raw)

(defvar benedict-provider--registry (make-hash-table :test 'eq)
  "Internal registry of available Benedict providers keyed by ID symbol.")

(defun benedict-provider-register (provider)
  "Register PROVIDER (a `benedict-provider' struct) and return it."
  (puthash (benedict-provider-id provider) provider benedict-provider--registry)
  provider)

(defun benedict-provider-lookup (id)
  "Return provider struct registered under ID, or nil."
  (gethash id benedict-provider--registry))

(defun benedict-provider-list-ids ()
  "Return a list of all registered provider ID symbols."
  (let (ids)
    (maphash (lambda (id _provider) (push id ids)) benedict-provider--registry)
    (sort ids (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

;;; Canonical Message Accessors

(defun benedict-provider--require-message (message)
  "Return canonical MESSAGE or signal a provider-boundary error."
  (unless (benedict-message-p message)
    (error "Provider request messages must be canonical benedict-message values: %S"
           message))
  message)

(defun benedict-provider-message-role (message)
  "Return canonical MESSAGE role for provider serialization."
  (benedict-message-role (benedict-provider--require-message message)))

(defun benedict-provider-message-content (message)
  "Return canonical MESSAGE textual content for provider serialization."
  (let* ((canonical (benedict-provider--require-message message))
         (role (benedict-message-role canonical)))
    (or (benedict-message-text canonical)
        (and (eq role 'tool)
             (when-let ((block (benedict-message--tool-result-block-data canonical)))
               (plist-get block :content)))
        "")))

(defun benedict-provider-message-tool-calls (message)
  "Return canonical MESSAGE tool-call data for provider serialization."
  (benedict-message-tool-calls (benedict-provider--require-message message)))

(defun benedict-provider-message-tool-result-id (message)
  "Return canonical MESSAGE tool-result call ID for provider serialization."
  (benedict-message-tool-result-id (benedict-provider--require-message message)))

(defun benedict-provider-message-tool-result-name (message)
  "Return canonical MESSAGE tool-result name for provider serialization."
  (benedict-message-tool-result-name (benedict-provider--require-message message)))

(defun benedict-provider-request-messages (request provider-name)
  "Return canonical messages from REQUEST for PROVIDER-NAME.
Signal when REQUEST does not carry a non-empty canonical transcript."
  (let ((messages (plist-get request :messages)))
    (unless (and (listp messages) messages)
      (error "%s request requires a non-empty :messages list" provider-name))
    (mapcar #'benedict-provider--require-message messages)))

(cl-defun benedict-provider-result-create
    (&key provider model text thinking tool-calls usage latency metadata raw)
  "Create a strict provider result.
PROVIDER and MODEL identify the backend response.  TEXT is assistant text.
THINKING is provider-normalized reasoning data.  TOOL-CALLS is
provider-decoded canonical tool-call data.  USAGE, LATENCY, and METADATA carry
normalized response metadata.  RAW may preserve the provider response for
debugging and must not be used as transcript source."
  (unless (or (null text) (stringp text))
    (error "Provider result :text must be a string or nil"))
  (unless (or (null tool-calls) (listp tool-calls))
    (error "Provider result :tool-calls must be a list or nil"))
  (benedict-provider-result--create
   :provider provider
   :model model
   :text (or text "")
   :thinking thinking
   :tool-calls (copy-tree tool-calls)
   :usage usage
   :latency latency
   :metadata metadata
   :raw raw))

(defun benedict-provider-require-result (result)
  "Return strict provider RESULT or signal a boundary error."
  (unless (benedict-provider-result-p result)
    (error "Provider callbacks must return benedict-provider-result values: %S"
           result))
  result)

(defun benedict-provider-display-name (provider-id)
  "Return a human-readable name for PROVIDER-ID.
Falls back to capitalized ID if provider is not registered."
  (if-let ((provider (benedict-provider-lookup provider-id)))
      (benedict-provider-name provider)
    (when provider-id
      (capitalize (symbol-name provider-id)))))

(defun benedict-provider-current ()
  "Return the currently configured provider struct.
Signals an error when `benedict-provider' is not registered."
  (let ((provider (benedict-provider-lookup benedict-provider)))
    (unless provider
      (error "Provider %S is not registered" benedict-provider))
    provider))

(defun benedict-provider--resolve (provider-id)
  "Return provider struct for PROVIDER-ID or the current provider.
Signals an error when the resolved provider is not registered."
  (if provider-id
      (or (benedict-provider-lookup provider-id)
          (error "Provider %S is not registered" provider-id))
    (benedict-provider-current)))

(cl-defun benedict-provider-dispatch
    (request &key on-success on-error on-delta on-complete)
  "Send REQUEST to the resolved provider.
REQUEST is provider-specific data (typically a plist).
Callbacks:
- ON-SUCCESS: invoked with the final payload (non-streaming or fallback).
- ON-ERROR: invoked when the provider fails to service the request.
- ON-DELTA: optional streaming chunk callback (called zero or more times).
- ON-COMPLETE: optional final callback for streaming providers; when nil the
  provider should fall back to ON-SUCCESS."
  (let ((provider (benedict-provider--resolve (plist-get request :provider))))
    (funcall (benedict-provider-send provider)
             provider request
             :on-success on-success
             :on-error on-error
             :on-delta on-delta
             :on-complete on-complete)))

(defun benedict-provider-abort (handle)
  "Ask HANDLE's provider to cancel it.
Fall back to the current provider when HANDLE does not carry provider metadata."
  (when handle
    (let* ((provider (benedict-provider--resolve (plist-get handle :provider)))
           (cancel-fn (benedict-provider-cancel provider)))
      (when (functionp cancel-fn)
        (funcall cancel-fn provider handle)))))

(provide 'benedict-provider)
;;; benedict-provider.el ends here
