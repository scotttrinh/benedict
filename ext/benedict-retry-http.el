;;; benedict-retry-http.el --- HTTP classification for visible retry  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;;; Commentary:

;; Converts completed HTTP failures into persistence-safe, transport-neutral
;; retry metadata, then installs the visible session retry extension.

;;; Code:

(require 'subr-x)
(require 'benedict-http)
(require 'benedict-retry)

(defvar benedict-retry-http--installed nil
  "Non-nil while HTTP retry classification is installed.")

(defun benedict-retry-http--transient-p (result)
  "Return non-nil when RESULT describes a transient HTTP failure."
  (let ((status (plist-get result :status)))
    (if status
        (or (>= status 500) (memq status '(408 425 429)))
      (and (eq (plist-get result :reason) 'process)
           (memq (plist-get result :exit) benedict-http-retry-exit-codes)))))

(defun benedict-retry-http--retry-after (result)
  "Return RESULT's numeric Retry-After value, or nil."
  (when-let* ((value (alist-get "retry-after" (plist-get result :headers)
                                nil nil #'equal))
              (trimmed (string-trim value)))
    (and (string-match-p "\\`[0-9]+\\'" trimmed)
         (string-to-number trimmed))))

(defun benedict-retry-http-classify (result)
  "Return RESULT with safe retry metadata when its failure is transient.

The attached `:error-data' contains only a transient flag and, when present, a
numeric delay.  This function never copies a response body, headers, diagnostic
message, authorization value, or credential into persistent metadata."
  (if (not (benedict-retry-http--transient-p result))
      result
    (let* ((delay (benedict-retry-http--retry-after result))
           (classification (append (list :transient t)
                                   (when delay (list :delay delay))))
           (error-data (copy-sequence (plist-get result :error-data))))
      (plist-put result :error-data
                 (plist-put error-data :benedict-retry classification)))))

(defun benedict-retry-http-install ()
  "Install HTTP classification and visible session retry idempotently."
  (unless benedict-retry-http--installed
    (add-hook 'benedict-http-result-filter-functions
              #'benedict-retry-http-classify)
    (setq benedict-retry-http--installed t))
  (benedict-retry-install)
  t)

(defun benedict-retry-http-uninstall ()
  "Uninstall HTTP classification and visible session retry idempotently."
  (when benedict-retry-http--installed
    (remove-hook 'benedict-http-result-filter-functions
                 #'benedict-retry-http-classify)
    (setq benedict-retry-http--installed nil))
  (benedict-retry-uninstall)
  t)

(provide 'benedict-retry-http)
;;; benedict-retry-http.el ends here
