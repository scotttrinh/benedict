;;; benedict-vui-input-area-test.el --- Tests for VUI input area -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI input area component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'widget)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-input-area)

(defun benedict-vui-input-area-test--slice (id &rest props)
  "Create a context slice with ID and PROPS."
  (let ((plist (list :id id :kind 'buffer :label "test.el" :content "hello")))
    (while props
      (setq plist (plist-put plist (pop props) (pop props))))
    (apply #'benedict-context-make-slice plist)))

(ert-deftest benedict-vui-input-area-mount-renders-no-context-and-field ()
  "Mounted input area shows no-context summary and compose field widget."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-input-area
                     :slices nil
                     :input-text ""
                     :on-input-change #'ignore
                     :on-submit #'ignore
                     :on-slice-remove #'ignore
                     :history nil
                     :placeholder "Ask Benedict..."
                     :size 40
                     :field-key 'input-area-test)
    (let ((text (buffer-string)))
      (should (string-match-p "CONTEXT" text))
      (should (string-match-p "No context" text))
      (should widget-field-list))))

(ert-deftest benedict-vui-input-area-mount-field-change-calls-on-input-change ()
  "Changing the mounted compose field calls the input change callback."
  (let ((changed-value nil))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-input-area
                       :slices nil
                       :input-text ""
                       :on-input-change (lambda (value)
                                          (setq changed-value value))
                       :on-submit #'ignore
                       :on-slice-remove #'ignore
                       :history nil
                       :placeholder "Ask Benedict..."
                       :size 40
                       :field-key 'input-area-change-test)
      (benedict-vui-test--set-first-field "hello from input area")
      (vui-flush-sync)
      (should (equal changed-value "hello from input area")))))

(ert-deftest benedict-vui-input-area-mount-remove-slice-calls-on-slice-remove ()
  "Removing a slice via mounted context controls calls on-slice-remove."
  (let* ((removed-id nil)
         (slices (list (benedict-vui-input-area-test--slice 42))))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-input-area
                       :slices slices
                       :input-text ""
                       :on-input-change #'ignore
                       :on-submit #'ignore
                       :on-slice-remove (lambda (id)
                                          (setq removed-id id))
                       :history nil
                       :placeholder "Ask Benedict..."
                       :size 40
                       :field-key 'input-area-remove-test)
      (should-not (string-match-p "test.el" (buffer-string)))
      (benedict-vui-test--click-button-at (point-min))
      (vui-flush-sync)
      (should (string-match-p "test.el" (buffer-string)))
      (benedict-vui-test--click-button-labeled "×")
      (vui-flush-sync)
      (should (equal removed-id 42)))))

(provide 'test/benedict-vui-input-area-test)
;;; benedict-vui-input-area-test.el ends here
