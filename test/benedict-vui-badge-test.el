;;; benedict-vui-badge-test.el --- Tests for VUI badge -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI status badge component helpers.

;;; Code:

(require 'ert)
(require 'benedict-vui-badge)

(defun benedict-vui-badge-test--face-member-p (face value)
  "Return non-nil when FACE is present in VALUE."
  (cond
   ((null value) nil)
   ((eq value face) t)
   ((listp value) (memq face value))
   (t nil)))

(ert-deftest benedict-vui-badge-labels-for-statuses ()
  "Badge labels match known status values."
  (should (equal (vui-component 'benedict-vui-badge--label 'user) "USER"))
  (should (equal (vui-component 'benedict-vui-badge--label 'assistant) "ASSISTANT"))
  (should (equal (vui-component 'benedict-vui-badge--label 'system) "SYSTEM"))
  (should (equal (vui-component 'benedict-vui-badge--label 'streaming) "STREAMING"))
  (should (equal (vui-component 'benedict-vui-badge--label 'error) "ERROR"))
  (should (equal (vui-component 'benedict-vui-badge--label 'running) "RUNNING"))
  (should (equal (vui-component 'benedict-vui-badge--label 'success) "SUCCESS"))
  (should (equal (vui-component 'benedict-vui-badge--label 'failure) "FAILURE")))

(ert-deftest benedict-vui-badge-face-mapping ()
  "Badge faces map to known statuses."
  (let ((text (vui-component 'benedict-vui-badge--propertize
               (vui-component 'benedict-vui-badge--label 'user)
               (vui-component 'benedict-vui-badge--face 'user nil))))
    (should (vui-component 'benedict-vui-badge-test--face-member-p
             'benedict-chat-user
             (get-text-property 0 'face text)))))

(ert-deftest benedict-vui-badge-unknown-status ()
  "Unknown statuses render with fallback label and face."
  (let* ((label (vui-component 'benedict-vui-badge--label 'mystery))
         (face (vui-component 'benedict-vui-badge--face 'mystery nil))
         (text (vui-component 'benedict-vui-badge--propertize label face)))
    (should (equal label "MYSTERY"))
    (should (vui-component 'benedict-vui-badge-test--face-member-p
             'benedict-chat-header
             (get-text-property 0 'face text)))))

(provide 'test/benedict-vui-badge-test)
;;; benedict-vui-badge-test.el ends here
