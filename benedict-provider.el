;;; benedict-provider.el --- Provider registry and helpers -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provides a minimal registry for provider implementations and helper
;; functions that dispatch requests to the active provider.

;;; Code:

(require 'cl-lib)

(cl-defstruct (benedict-provider
               (:constructor benedict-provider--create))
  "Structure describing a provider implementation."
  id name send capabilities cancel)

(defvar benedict-provider--registry (make-hash-table :test 'eq)
  "Internal registry of available Benedict providers keyed by ID symbol.")

(defun benedict-provider-register (provider)
  "Register PROVIDER (a `benedict-provider' struct) and return it."
  (puthash (benedict-provider-id provider) provider benedict-provider--registry)
  provider)

(defun benedict-provider-lookup (id)
  "Return provider struct registered under ID, or nil."
  (gethash id benedict-provider--registry))

(defun benedict-provider-current ()
  "Return the currently configured provider struct.
Signals an error when `benedict-provider' is not registered."
  (let ((provider (benedict-provider-lookup benedict-provider)))
    (unless provider
      (error "Provider %S is not registered" benedict-provider))
    provider))

(cl-defun benedict-provider-dispatch
    (request &key on-success on-error on-delta on-complete)
  "Send REQUEST to the active provider.
REQUEST is provider-specific data (typically a plist).
Callbacks:
- ON-SUCCESS: invoked with the final payload (non-streaming or fallback).
- ON-ERROR: invoked when the provider fails to service the request.
- ON-DELTA: optional streaming chunk callback (called zero or more times).
- ON-COMPLETE: optional final callback for streaming providers; when nil the
  provider should fall back to ON-SUCCESS."
  (let ((provider (benedict-provider-current)))
    (funcall (benedict-provider-send provider)
             provider request
             :on-success on-success
             :on-error on-error
             :on-delta on-delta
             :on-complete on-complete)))

(defun benedict-provider-abort (handle)
  "Ask the active provider to cancel HANDLE (a provider-specific token)."
  (when handle
    (let* ((provider (benedict-provider-current))
           (cancel-fn (benedict-provider-cancel provider)))
      (when (functionp cancel-fn)
        (funcall cancel-fn provider handle)))))

(provide 'benedict-provider)
;;; benedict-provider.el ends here
