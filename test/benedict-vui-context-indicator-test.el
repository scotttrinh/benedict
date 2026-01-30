;;; benedict-vui-context-indicator-test.el --- Tests for VUI context indicator -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI context indicator component.

;;; Code:

(require 'ert)
(require 'benedict-vui-context-indicator)

(ert-deftest benedict-vui-context-indicator-summary-empty ()
  "Summary shows no context when slices list is empty."
  (should (equal (vui-component 'benedict-vui-context-indicator--summary nil)
                 "No context")))

(ert-deftest benedict-vui-context-indicator-summary-one-slice ()
  "Summary shows one slice with size."
  (let ((slices (list (benedict-context-make-slice
                       :kind 'buffer
                       :label "test.el"
                       :content "hello"
                       :id 1))))
    (should (string-match-p "1 slice" (vui-component 'benedict-vui-context-indicator--summary slices)))
    (should (string-match-p "5B" (vui-component 'benedict-vui-context-indicator--summary slices)))))

(ert-deftest benedict-vui-context-indicator-summary-multiple-slices ()
  "Summary shows multiple slices with total size."
  (let ((slices (list (benedict-context-make-slice
                       :kind 'buffer
                       :label "test.el"
                       :content "hello"
                       :id 1)
                      (benedict-context-make-slice
                       :kind 'region
                       :label "region"
                       :content "world"
                       :id 2))))
    (should (string-match-p "2 slices" (vui-component 'benedict-vui-context-indicator--summary slices)))
    (should (string-match-p "10B" (vui-component 'benedict-vui-context-indicator--summary slices)))))

(ert-deftest benedict-vui-context-indicator-slice-label-basic ()
  "Slice label shows kind and label."
  (let ((slice (benedict-context-make-slice
                :kind 'buffer
                :label "test.el"
                :content "hello"
                :id 1)))
    (should (string-match-p "test.el" (vui-component 'benedict-vui-context-indicator--slice-label slice)))
    (should (string-match-p "\\[BUFFER\\]" (vui-component 'benedict-vui-context-indicator--slice-label slice)))))

(ert-deftest benedict-vui-context-indicator-slice-label-with-handle ()
  "Slice label includes handle when present."
  (let ((slice (benedict-context-make-slice
                :kind 'buffer
                :label "test.el"
                :content "hello"
                :handle "foo"
                :id 1)))
    (should (string-match-p "<<foo>>" (vui-component 'benedict-vui-context-indicator--slice-label slice)))
    (should (string-match-p "test.el" (vui-component 'benedict-vui-context-indicator--slice-label slice)))))

(ert-deftest benedict-vui-context-indicator-slice-label-truncated ()
  "Slice label shows truncated flag when content is truncated."
  (let ((slice (benedict-context-make-slice
                :kind 'buffer
                :label "test.el"
                :content "hello world, this is a long string that will be truncated"
                :max-bytes 10
                :id 1)))
    (should (string-match-p "(truncated)" (vui-component 'benedict-vui-context-indicator--slice-label slice)))))

(provide 'test/benedict-vui-context-indicator-test)
;;; benedict-vui-context-indicator-test.el ends here
