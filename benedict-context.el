;;; benedict-context.el --- Context slice helpers for compose flow -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Utilities for constructing and formatting context slices (buffers, regions,
;; diffs, etc.) that will be inserted into a compose buffer and ultimately sent
;; along with user prompts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup benedict-context nil
  "Settings for Benedict context slices."
  :group 'benedict
  :prefix "benedict-context-")

(defcustom benedict-context-max-bytes-per-slice 4000
  "Maximum number of bytes to retain from a single context slice.
When content exceeds this limit it is truncated and flagged."
  :type 'integer
  :group 'benedict-context)

(defvar benedict-context--id-counter 0
  "Internal counter for generating unique slice identifiers.")

(defun benedict-context--next-id ()
  "Return a fresh identifier for a context slice."
  (cl-incf benedict-context--id-counter))

(defun benedict-context--truncate-content (content limit)
  "Return CONTENT possibly truncated to LIMIT bytes.
The return value is a plist (:content :truncated-p :size-bytes)."
  (let* ((text (or content ""))
         (size (string-bytes text)))
    (if (or (<= size limit) (<= limit 0))
        (list :content text :truncated-p nil :size-bytes size)
      (let* ((cut (substring text 0 (min (length text) limit)))
             (annotated (concat cut "\n… [truncated]")))
        (list :content annotated :truncated-p t :size-bytes size)))))

(cl-defun benedict-context-make-slice (&key kind label origin content id max-bytes handle)
  "Construct a context slice plist.
KIND is a symbol such as 'buffer, 'region, or 'git-diff.
LABEL is a human-readable description. ORIGIN notes where the slice came from.
CONTENT holds the text that will be sent. ID may be provided, otherwise a new
identifier is allocated. HANDLE is an optional user-visible identifier used
for prompt references. MAX-BYTES overrides `benedict-context-max-bytes-per-slice'."
  (let* ((limit (or max-bytes benedict-context-max-bytes-per-slice))
         (result (benedict-context--truncate-content content limit)))
    (list :id (or id (benedict-context--next-id))
          :kind kind
          :label (or label (format "%s" kind))
          :origin origin
          :handle handle
          :content (plist-get result :content)
          :size-bytes (plist-get result :size-bytes)
          :truncated-p (plist-get result :truncated-p))))

(defun benedict-context-total-size (slices)
  "Return the sum of :size-bytes across SLICES."
  (if slices
      (apply #'+ (mapcar (lambda (slice) (or (plist-get slice :size-bytes) 0))
                         slices))
    0))

(defun benedict-context--format-size (slice)
  "Return a short size string for SLICE."
  (let ((bytes (or (plist-get slice :size-bytes) 0)))
    (format "%dB" bytes)))

(defun benedict-context--format-one (slice)
  "Render SLICE as a labeled string for compose buffers."
  (let* ((kind (upcase (format "%s" (plist-get slice :kind))))
         (handle (plist-get slice :handle))
         (label (or (plist-get slice :label) "Context"))
         (origin (plist-get slice :origin))
         (truncated (plist-get slice :truncated-p))
         (size (benedict-context--format-size slice))
         (content (or (plist-get slice :content) "")))
    (string-join
     (delq nil
           (list (format "%s[%s] %s (%s%s)%s"
                         (if handle (format "<<%s>> " handle) "")
                         kind
                         label
                         size
                         (if truncated "+" "")
                         (if origin (format " — %s" origin) ""))
                 content))
     "\n")))

(defun benedict-context-format-for-compose (slices)
  "Return formatted text for SLICES for insertion into compose buffers."
  (string-join (mapcar #'benedict-context--format-one slices) "\n\n"))

(defun benedict-context-format-for-send (slices)
  "Return a context section string derived from SLICES for outgoing messages."
  (when slices
    (concat "Context:\n"
            (benedict-context-format-for-compose slices)
            "\n\n")))

(defun benedict-context-summary (slices)
  "Return a short human-readable summary for SLICES."
  (let ((count (length slices))
        (bytes (benedict-context-total-size slices)))
    (format "%d slice%s · ~%dB" count (if (= count 1) "" "s") bytes)))

(provide 'benedict-context)
;;; benedict-context.el ends here
