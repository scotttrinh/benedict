;;; benedict-retry-test.el --- Visible request retry tests  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'benedict-retry)
(require 'benedict-retry-http)

(ert-deftest benedict-retry-http-classifies-only-transient-failures-safely ()
  "HTTP classification retains no body, headers, or credential-bearing data."
  (dolist (result '((:status 408) (:status 425) (:status 429)
                    (:status 500) (:status 503)
                    (:error "network detail" :reason process :exit 6)
                    (:error "network detail" :reason process :exit 56)))
    (let* ((classified (benedict-retry-http-classify
                        (append result '(:headers (("authorization" . "secret"))
                                         :body "private"))))
           (data (plist-get classified :error-data)))
      (should (equal (plist-get data :benedict-retry) '(:transient t)))
      (should-not (string-match-p "secret\|private\|network detail"
                                  (prin1-to-string data)))))
  (dolist (result '((:status 400) (:status 401) (:status 404)
                    (:error "certificate" :reason process :exit 60)))
    (should-not (plist-get (benedict-retry-http-classify result) :error-data))))

(ert-deftest benedict-retry-http-preserves-numeric-retry-after-as-a-delay ()
  "Only delta-seconds crosses into persistence-safe retry metadata."
  (should (equal
           (plist-get
            (benedict-retry-http-classify
             '(:status 429 :headers (("retry-after" . " 7 ")) :body "private"))
            :error-data)
           '(:benedict-retry (:transient t :delay 7))))
  (should (equal
           (plist-get
            (benedict-retry-http-classify
             '(:status 429 :headers (("retry-after" . "tomorrow"))))
            :error-data)
           '(:benedict-retry (:transient t)))))

(ert-deftest benedict-retry-default-policy-limits-and-caps-automatic-retries ()
  "Two transient retries are allowed and a service delay cannot exceed the cap."
  (let ((entry (benedict-entry-create
                :role 'assistant
                :meta '(:stop-reason error
                        :error-data (:benedict-retry (:transient t :delay 600)))))
        (benedict-retry-limit 2)
        (benedict-retry-max-seconds 20))
    (should (= (benedict-retry-default-policy nil entry 0) 20))
    (should (= (benedict-retry-default-policy nil entry 1) 20))
    (should-not (benedict-retry-default-policy nil entry 2))))

(defmacro benedict-retry-test--with-timers (&rest body)
  "Run BODY with retry timers captured in `timers' instead of scheduled."
  (declare (indent 0) (debug body))
  `(let ((timers nil)
         (cancelled nil))
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (delay _repeat callback &rest _args)
                  (let ((timer (list :delay delay :callback callback)))
                    (setq timers (append timers (list timer)))
                    timer)))
               ((symbol-function 'cancel-timer)
                (lambda (timer) (push timer cancelled))))
       ,@body)))

(defun benedict-retry-test--fire (timer)
  "Invoke captured TIMER's callback."
  (funcall (plist-get timer :callback)))

(ert-deftest benedict-retry-failure-then-success-keeps-both-attempts-visible ()
  "An automatic retry is a second run and a second assistant entry."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (benedict-retry-test--with-timers
        (let* ((session (benedict-test-session
                         '(((:text "partial")
                            (:error :reason error :message "busy"
                                    :error-data (:benedict-retry-http
                                                 (:transient t))))
                           ((:text "complete")))))
               (starts 0)
               (ends 0)
               (benedict-retry-policy-function (lambda (_session _entry _attempt) 1)))
          (add-hook 'benedict-run-start-functions (lambda (_session) (cl-incf starts)))
          (add-hook 'benedict-run-end-functions (lambda (_session) (cl-incf ends)))
          (benedict-retry-install)
          (unwind-protect
              (progn
                (benedict-session-submit session "go")
                (benedict-test-drain)
                (should (benedict-retry-pending-p session))
                (should (= starts 1))
                (should (= ends 1))
                (benedict-retry-test--fire (car timers))
                (benedict-test-drain)
                (let ((assistants (seq-filter #'benedict-entry-assistant-p
                                              (benedict-session-path session))))
                  (should (equal (mapcar #'benedict-entry-text assistants)
                                 '("partial" "complete"))))
                (should (= starts 2))
                (should (= ends 2))
                (should-not (benedict-retry-pending-p session)))
            (benedict-retry-uninstall)))))))

(ert-deftest benedict-retry-now-retries-nil-and-resets-the-automatic-budget ()
  "Manual retry works after exhaustion and its failure is automatic attempt zero."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session
                       '(((:error :reason error :message "first"))
                         ((:error :reason error :message "manual")))))
             attempts
             (benedict-retry-policy-function
              (lambda (_session _entry attempt)
                (push attempt attempts)
                nil)))
        (benedict-retry-install)
        (unwind-protect
            (progn
              (benedict-session-submit session "go")
              (benedict-test-drain)
              (should (benedict-retry-eligible-p session))
              (benedict-retry-now session)
              (benedict-test-drain)
              (should (equal (nreverse attempts) '(0 0)))
              (should (= (length (benedict-session-path session)) 3)))
          (benedict-retry-uninstall))))))

(ert-deftest benedict-retry-drops-a-stale-timer-after-new-input ()
  "A delayed retry cannot run after the user has advanced the head."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (benedict-retry-test--with-timers
        (let* ((session (benedict-test-session
                         '(((:error :reason error :message "first"))
                           ((:text "user run")))))
               (benedict-retry-policy-function (lambda (&rest _) 1)))
          (benedict-retry-install)
          (unwind-protect
              (progn
                (benedict-session-submit session "one")
                (benedict-test-drain)
                (let ((stale (car timers)))
                  (benedict-session-submit session "two")
                  (benedict-test-drain)
                  (benedict-retry-test--fire stale)
                  (benedict-test-drain)
                  (should (= (length (benedict-session-path session)) 4))
                  (should-not (benedict-retry-pending-p session))))
            (benedict-retry-uninstall)))))))

(ert-deftest benedict-retry-uninstall-cancels-pending-and-is-idempotent ()
  "Repeated lifecycle calls neither duplicate hooks nor leave delayed work."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (benedict-retry-test--with-timers
        (let* ((session (benedict-test-session
                         '(((:error :reason error :message "first")))))
               (benedict-retry-policy-function (lambda (&rest _) 1)))
          (benedict-retry-install)
          (benedict-retry-install)
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (should (= (length timers) 1))
          (benedict-retry-uninstall)
          (benedict-retry-uninstall)
          (should (= (length cancelled) 1))
          (should-not (benedict-retry-pending-p session)))))))

(provide 'benedict-retry-test)
;;; benedict-retry-test.el ends here
