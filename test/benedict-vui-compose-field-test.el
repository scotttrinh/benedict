;;; benedict-vui-compose-field-test.el --- Tests for VUI compose field -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI compose field component.

;;; Code:

(require 'ert)
(require 'benedict-vui-compose-field)

(ert-deftest benedict-vui-compose-field--handle-change-calls-callback ()
  "Handle change calls the on-change callback with value."
  (let ((called-with nil))
    (vui-component 'benedict-vui-compose-field--handle-change "test input" (lambda (v) (setq called-with v)))
    (should (equal called-with "test input"))))

(ert-deftest benedict-vui-compose-field--handle-change-nil-callback ()
  "Handle change doesn't error with nil callback."
  (should (vui-component 'benedict-vui-compose-field--handle-change "test" nil)))

(ert-deftest benedict-vui-compose-field--handle-submit-calls-callback ()
  "Handle submit calls the on-submit callback with value."
  (let ((called-with nil))
    (vui-component 'benedict-vui-compose-field--handle-submit "test input" (lambda (v) (setq called-with v)))
    (should (equal called-with "test input"))))

(ert-deftest benedict-vui-compose-field--handle-submit-nil-callback ()
  "Handle submit doesn't error with nil callback."
  (should (vui-component 'benedict-vui-compose-field--handle-submit "test" nil)))

(ert-deftest benedict-vui-compose-field--navigate-history-prev ()
  "Navigate to previous history item."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index -1))
    (let ((new-index (vui-component 'benedict-vui-compose-field--navigate-history
                      :prev initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (equal called-with "third")))))

(ert-deftest benedict-vui-compose-field--navigate-history-next ()
  "Navigate to next history item."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index 1))
    (let ((new-index (vui-component 'benedict-vui-compose-field--navigate-history
                      :next initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (equal called-with "third")))))

(ert-deftest benedict-vui-compose-field--navigate-history-boundaries ()
  "Navigate history respects boundaries."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index 0))
    (let ((new-index (vui-component 'benedict-vui-compose-field--navigate-history
                      :prev initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index -1))
      (should (null called-with)))))

(ert-deftest benedict-vui-compose-field--navigate-history-from-empty ()
  "Navigate from -1 index starts at end of history."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index -1))
    (let ((new-index (vui-component 'benedict-vui-compose-field--navigate-history
                      :prev initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (equal called-with "third")))))

(ert-deftest benedict-vui-compose-field--navigate-history-next-bounds ()
  "Navigate next doesn't exceed history length."
  (let ((history '("first" "second" "third"))
        (called-with nil)
        (initial-index 2))
    (let ((new-index (vui-component 'benedict-vui-compose-field--navigate-history
                      :next initial-index history (lambda (v) (setq called-with v)))))
      (should (equal new-index 2))
      (should (null called-with)))))

(provide 'test/benedict-vui-compose-field-test)
;;; benedict-vui-compose-field-test.el ends here
