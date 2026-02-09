;;; benedict-vui-test-utils-test.el --- Tests for VUI test helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; Helper-focused tests for behavior that is hard to cover via downstream component tests.

;;; Code:

(require 'ert)
(require 'test/benedict-vui-test-utils)
(require 'benedict-session)

(ert-deftest benedict-vui-test-utils-wait-until-succeeds-before-timeout ()
  "Wait helper returns non-nil when predicate eventually succeeds."
  (let ((attempts 0))
    (should (benedict-vui-test--wait-until
             (lambda ()
               (setq attempts (1+ attempts))
               (>= attempts 3))
             :timeout 0.2
             :interval 0.01))
    (should (>= attempts 3))))

(ert-deftest benedict-vui-test-utils-wait-until-times-out ()
  "Wait helper returns nil when predicate never succeeds."
  (let ((attempts 0))
    (should-not (benedict-vui-test--wait-until
                 (lambda ()
                   (setq attempts (1+ attempts))
                   nil)
                 :timeout 0.05
                 :interval 0.01))
    (should (> attempts 0))))

(ert-deftest benedict-vui-test-utils-wait-for-request-finished-immediate ()
  "Request wait helper succeeds immediately for idle sessions."
  (let* ((benedict-session--registry (make-hash-table :test #'equal))
         (session (benedict-session-create :title "test"
                                           :provider 'fake
                                           :model "model")))
    (should (benedict-vui-test--wait-for-request-finished session 0.1))))

(ert-deftest benedict-vui-test-utils-wait-for-request-finished-eventual ()
  "Request wait helper succeeds once an active request is cleared."
  (let* ((benedict-session--registry (make-hash-table :test #'equal))
         (session (benedict-session-create :title "test"
                                           :provider 'fake
                                           :model "model")))
    (benedict-session-start-request session :fake)
    (should (benedict-session-request-active-p session))
    (run-at-time 0.02 nil (lambda () (benedict-session-clear-request session)))
    (should (benedict-vui-test--wait-for-request-finished session 0.2))
    (should-not (benedict-session-request-active-p session))))

(ert-deftest benedict-vui-test-utils-wait-for-request-finished-timeout ()
  "Request wait helper times out when request stays active."
  (let* ((benedict-session--registry (make-hash-table :test #'equal))
         (session (benedict-session-create :title "test"
                                           :provider 'fake
                                           :model "model")))
    (benedict-session-start-request session :fake)
    (should-not (benedict-vui-test--wait-for-request-finished session 0.05))
    (benedict-session-clear-request session)
    (should-not (benedict-session-request-active-p session))))

(provide 'test/benedict-vui-test-utils-test)
;;; benedict-vui-test-utils-test.el ends here
