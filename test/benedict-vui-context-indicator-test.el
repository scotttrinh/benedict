;;; benedict-vui-context-indicator-test.el --- Tests for VUI context indicator -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI context indicator component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-badge)
(require 'benedict-vui-collapsible)
(require 'benedict-vui-context-indicator)

(defun benedict-vui-context-indicator-test--slice (id &rest props)
  "Create a context slice with ID and PROPS."
  (let ((plist (list :id id :kind 'buffer :label "test.el" :content "hello")))
    (while props
      (setq plist (plist-put plist (pop props) (pop props))))
    (apply #'benedict-context-make-slice plist)))

(vui-defcomponent benedict-vui-context-indicator-test--harness (slices on-remove)
  :render
  (vui-component 'benedict-vui-context-indicator
                 :slices slices
                 :on-remove on-remove))

(ert-deftest benedict-vui-context-indicator-mount-empty-shows-no-context ()
  "Mounted context indicator shows no-context summary with empty slices."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-context-indicator-test--harness
                      :slices nil
                      :on-remove nil)
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "CONTEXT" text))
        (should (string-match-p "No context" text))))))

(ert-deftest benedict-vui-context-indicator-mount-slices-collapsed-by-default ()
  "Mounted context indicator shows summary and collapsed indicator initially."
  (with-temp-buffer
    (let* ((buffer-name (buffer-name))
           (slices (list (benedict-vui-context-indicator-test--slice 1)
                         (benedict-vui-context-indicator-test--slice 2 :content "world"))))
      (vui-mount
       (vui-component 'benedict-vui-context-indicator-test--harness
                      :slices slices
                      :on-remove nil)
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p (regexp-quote "▶") text))
        (should (string-match-p "2 slices" text))
        (should-not (string-match-p "test.el" text))))))

(ert-deftest benedict-vui-context-indicator-mount-toggle-shows-slice-labels ()
  "Clicking toggle reveals slice labels in mounted context indicator."
  (with-temp-buffer
    (let* ((buffer-name (buffer-name))
           (slices (list (benedict-vui-context-indicator-test--slice 1))))
      (vui-mount
       (vui-component 'benedict-vui-context-indicator-test--harness
                      :slices slices
                      :on-remove nil)
       buffer-name)
      (vui-flush-sync)
      (should-not (string-match-p "test.el" (buffer-string)))
      (benedict-vui-test--click-button-at (point-min))
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p (regexp-quote "▼") text))
        (should (string-match-p "test.el" text))
        (should (string-match-p "\\[BUFFER\\]" text))))))

(ert-deftest benedict-vui-context-indicator-mount-remove-calls-on-remove ()
  "Clicking remove invokes callback with slice id."
  (with-temp-buffer
    (let* ((buffer-name (buffer-name))
           (removed-id nil)
           (slices (list (benedict-vui-context-indicator-test--slice 42))))
      (vui-mount
       (vui-component 'benedict-vui-context-indicator-test--harness
                      :slices slices
                      :on-remove (lambda (id) (setq removed-id id)))
       buffer-name)
      (vui-flush-sync)
      (benedict-vui-test--click-button-at (point-min))
      (vui-flush-sync)
      (benedict-vui-test--click-button-labeled "×")
      (vui-flush-sync)
      (should (equal removed-id 42)))))

(ert-deftest benedict-vui-context-indicator-mount-shows-handle-kind-and-truncated ()
  "Expanded view includes handle, kind, and truncated marker in slice label."
  (with-temp-buffer
    (let* ((buffer-name (buffer-name))
           (slices (list (benedict-vui-context-indicator-test--slice
                          9
                          :kind 'region
                          :label "snippet"
                          :content "hello world, this is long"
                          :handle "foo"
                          :max-bytes 5))))
      (vui-mount
       (vui-component 'benedict-vui-context-indicator-test--harness
                      :slices slices
                      :on-remove nil)
       buffer-name)
      (vui-flush-sync)
      (benedict-vui-test--click-button-at (point-min))
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should (string-match-p "<<foo>>" text))
        (should (string-match-p "snippet" text))
        (should (string-match-p "\\[REGION\\]" text))
        (should (string-match-p (regexp-quote "(truncated)") text))))))

(provide 'test/benedict-vui-context-indicator-test)
;;; benedict-vui-context-indicator-test.el ends here
