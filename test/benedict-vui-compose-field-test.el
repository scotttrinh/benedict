;;; benedict-vui-compose-field-test.el --- Tests for VUI compose field -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI compose field component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'widget)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-compose-field)

(vui-defcomponent benedict-vui-compose-field-test--harness (history on-submit-callback)
  :state ((value ""))
  :render
  (vui-vstack
   (vui-component 'benedict-vui-compose-field
                  :value value
                  :on-change (lambda (next-value)
                               (vui-set-state :value next-value))
                  :on-submit on-submit-callback
                  :history history
                  :placeholder "Ask Benedict..."
                  :size 40
                  :key 'compose-field-test)
   (vui-text (format "Value: %s" value))))

(ert-deftest benedict-vui-compose-field--handle-change-calls-callback ()
  "Handle change calls the on-change callback with value."
  (let ((called-with nil))
    (benedict-vui-compose-field--handle-change "test input" (lambda (v) (setq called-with v)))
    (should (equal called-with "test input"))))

(ert-deftest benedict-vui-compose-field--handle-change-nil-callback ()
  "Handle change doesn't error with nil callback."
  (should (benedict-vui-compose-field--handle-change "test" nil)))

(ert-deftest benedict-vui-compose-field--handle-submit-calls-callback ()
  "Handle submit calls the on-submit callback with value."
  (let ((called-with nil))
    (benedict-vui-compose-field--handle-submit "test input" (lambda (v) (setq called-with v)))
    (should (equal called-with "test input"))))

(ert-deftest benedict-vui-compose-field--handle-submit-nil-callback ()
  "Handle submit doesn't error with nil callback."
  (should (benedict-vui-compose-field--handle-submit "test" nil)))

(ert-deftest benedict-vui-compose-field--navigate-history-prev ()
  "Navigate to previous history item."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index -1))
    (let ((new-index (benedict-vui-compose-field--navigate-history
                      :prev initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (equal called-with "third")))))

(ert-deftest benedict-vui-compose-field--navigate-history-next ()
  "Navigate to next history item."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index 1))
    (let ((new-index (benedict-vui-compose-field--navigate-history
                      :next initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (equal called-with "third")))))

(ert-deftest benedict-vui-compose-field--navigate-history-boundaries ()
  "Navigate history respects boundaries."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index 0))
    (let ((new-index (benedict-vui-compose-field--navigate-history
                      :prev initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index -1))
      (should (null called-with)))))

(ert-deftest benedict-vui-compose-field--navigate-history-from-empty ()
  "Navigate from -1 index starts at end of history."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index -1))
    (let ((new-index (benedict-vui-compose-field--navigate-history
                      :prev initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (equal called-with "third")))))

(ert-deftest benedict-vui-compose-field--navigate-history-next-bounds ()
  "Navigate next doesn't exceed history length."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index 2))
    (let ((new-index (benedict-vui-compose-field--navigate-history
                      :next initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (null called-with)))))

(ert-deftest benedict-vui-compose-field-mount-change-updates-value ()
  "Typing in the mounted field updates the controlled value."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-compose-field-test--harness
                     :history '("first" "second" "third")
                     :on-submit-callback #'ignore)
    (benedict-vui-test--set-first-field "hello from field")
    (vui-flush-sync)
    (should (string-match-p "Value: hello from field" (buffer-string)))))

(ert-deftest benedict-vui-compose-field-mount-submit-calls-callback ()
  "Submit command calls callback with the current field value."
  (let ((submitted nil))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-compose-field-test--harness
                       :history '("first" "second" "third")
                       :on-submit-callback (lambda (value)
                                             (setq submitted value)))
      (benedict-vui-test--set-first-field "ship it")
      (vui-flush-sync)
      (call-interactively #'benedict-vui-compose-field-submit)
      (vui-flush-sync)
      (should (equal submitted "ship it")))))

(ert-deftest benedict-vui-compose-field-unmount-cleans-buffer-local-state ()
  "Unmount clears compose field buffer-local callback and history bindings."
  (skip-unless (fboundp 'vui-unmount))
  (with-temp-buffer
    (let* ((buffer-name (buffer-name))
           (mount (vui-mount
                   (vui-component 'benedict-vui-compose-field-test--harness
                                  :history '("first" "second" "third")
                                  :on-submit-callback #'ignore)
                   buffer-name)))
      (vui-flush-sync)
      (should benedict-vui-compose-field--field-key)
      (should (functionp benedict-vui-compose-field--on-submit))
      (should (functionp benedict-vui-compose-field--on-change))
      (should (equal benedict-vui-compose-field--history '("first" "second" "third")))
      (vui-unmount mount)
      (vui-flush-sync)
      (should-not benedict-vui-compose-field--field-key)
      (should-not benedict-vui-compose-field--on-submit)
      (should-not benedict-vui-compose-field--on-change)
      (should-not benedict-vui-compose-field--history)
      (should (equal benedict-vui-compose-field--history-index -1)))))

(provide 'test/benedict-vui-compose-field-test)
;;; benedict-vui-compose-field-test.el ends here
