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
  (should (equal (benedict-vui-badge--label 'user) "USER"))
  (should (equal (benedict-vui-badge--label 'assistant) "ASSISTANT"))
  (should (equal (benedict-vui-badge--label 'system) "SYSTEM"))
  (should (equal (benedict-vui-badge--label 'streaming) "STREAMING"))
  (should (equal (benedict-vui-badge--label 'error) "ERROR"))
  (should (equal (benedict-vui-badge--label 'running) "RUNNING"))
  (should (equal (benedict-vui-badge--label 'success) "SUCCESS"))
  (should (equal (benedict-vui-badge--label 'failure) "FAILURE")))

(ert-deftest benedict-vui-badge-face-mapping ()
  "Badge faces map to known statuses."
  (let ((text (benedict-vui-badge--propertize
               (benedict-vui-badge--label 'user)
               (benedict-vui-badge--face 'user nil))))
    (should (benedict-vui-badge-test--face-member-p
             'benedict-chat-user
             (get-text-property 0 'face text)))))

(ert-deftest benedict-vui-badge-unknown-status ()
  "Unknown statuses render with fallback label and face."
  (let* ((label (benedict-vui-badge--label 'mystery))
         (face (benedict-vui-badge--face 'mystery nil))
         (text (benedict-vui-badge--propertize label face)))
    (should (equal label "MYSTERY"))
    (should (benedict-vui-badge-test--face-member-p
             'benedict-chat-header
             (get-text-property 0 'face text)))))

(ert-deftest benedict-vui-badge-render-test ()
  "Badge renders directly to buffer."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-badge :status 'user :theme nil)
       buffer-name)
      ;; Verify content
      (should (string-match-p "USER" (buffer-string)))
      ;; Verify face property is preserved in buffer
      (goto-char (point-min))
      (let* ((text (buffer-string))
             (face (get-text-property 0 'face text)))
        (should (benedict-vui-badge-test--face-member-p
                 'benedict-chat-user face))))))

(provide 'test/benedict-vui-badge-test)
;;; benedict-vui-badge-test.el ends here
