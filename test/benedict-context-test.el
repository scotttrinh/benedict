;;; benedict-context-test.el --- Tests for context helpers -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-context)

(ert-deftest benedict-context-make-slice-truncates ()
  "Context slices record original size and flag truncation."
  (let* ((benedict-context-max-bytes-per-slice 8)
         (raw "0123456789")
         (slice (benedict-context-make-slice
                 :kind 'region :label "sample" :origin "buffer" :content raw)))
    (should (= (plist-get slice :size-bytes) (string-bytes raw)))
    (should (plist-get slice :truncated-p))
    (should (string-match-p "truncated" (plist-get slice :content)))))

(ert-deftest benedict-context-format-for-send-prefixes-context ()
  "Formatted context strings start with a Context: header."
  (let* ((slice (benedict-context-make-slice :kind 'buffer
                                             :label "buf"
                                             :origin "test"
                                             :content "hello"))
         (text (benedict-context-format-for-send (list slice))))
    (should (string-prefix-p "Context:" text))
    (should (string-match-p "hello" text))
    (should (string-match-p "buf" text))))

(ert-deftest benedict-context-format-includes-handle ()
  "Context formatting includes anchors when :handle is present."
  (let* ((slice (benedict-context-make-slice :kind 'region
                                             :label "region"
                                             :origin "test"
                                             :content "hi"
                                             :handle "foo"))
         (text (benedict-context-format-for-send (list slice))))
    (should (string-match-p "<<foo>>" text))
    (should (string-match-p "\\[REGION\\]" text))))

(ert-deftest benedict-context-make-slice-empty-string ()
  "Slices with empty string should have valid size-bytes."
  (let ((slice (benedict-context-make-slice :content "")))
    (should (plist-member slice :size-bytes))
    (should (= 0 (plist-get slice :size-bytes)))))

(ert-deftest benedict-context-make-slice-nil-content ()
  "Slices with nil content should have valid size-bytes."
  (let ((slice (benedict-context-make-slice :content nil)))
    (should (plist-member slice :size-bytes))
    (should (= 0 (plist-get slice :size-bytes)))))

(provide 'benedict-context-test)
;;; benedict-context-test.el ends here
