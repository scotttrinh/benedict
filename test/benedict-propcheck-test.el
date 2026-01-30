;;; benedict-propcheck-test.el --- Property-based tests using propcheck  -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'propcheck)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-context)

;; Property test: context slices size-bytes field exists and is a number
(propcheck-deftest benedict-prop-context-slice-has-valid-size ()
  "Slicing context should always produce a numeric size-bytes field."
  (let ((content (propcheck-generate-string "content"))
        (max-bytes (propcheck-generate-integer "max" :min 10 :max 10000)))
    (let ((slice (benedict-context-make-slice :content content :max-bytes max-bytes)))
      (propcheck-should (numberp (plist-get slice :size-bytes))))))

;; Property test: context slices have valid truncation flags
(propcheck-deftest benedict-prop-context-slice-truncation-valid ()
  "Slicing should produce boolean truncation flags."
  (let ((content (propcheck-generate-string "content")))
    (let ((slice (benedict-context-make-slice :content content :max-bytes 50)))
      (propcheck-should (or (eq (plist-get slice :truncated-p) t)
                            (eq (plist-get slice :truncated-p) nil))))))

;; Property test: context total size sums correctly
(propcheck-deftest benedict-prop-context-total-size-accumulates ()
  "Total size should be sum of individual slice sizes."
  (let ((slices (mapcar (lambda (c)
                          (benedict-context-make-slice :content c))
                        (list "foo" "bar" "baz"))))
    (let ((total (benedict-context-total-size slices))
          (sum (apply #'+ (mapcar (lambda (s)
                                    (plist-get s :size-bytes))
                                  slices))))
      (propcheck-should (= total sum)))))

;; Property test: formatting slices always produces string output
(propcheck-deftest benedict-prop-context-format-produces-string ()
  "Formatting slices should always produce a string."
  (let ((content (propcheck-generate-string "content"))
        (label (propcheck-generate-string "label")))
    (let ((slice (benedict-context-make-slice :content content
                                              :label label
                                              :kind 'buffer)))
      (let ((formatted (benedict-context-format-for-compose (list slice))))
        (propcheck-should (stringp formatted))))))

(provide 'benedict-propcheck-test)
;;; benedict-propcheck-test.el ends here
