;;; test/benedict-flywire-test.el --- Tests for benedict-flywire  -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-flywire)

(ert-deftest benedict-flywire-session-lifecycle ()
  "Session creates and tears down cleanly in headless mode."
  (let ((session (benedict-flywire-session-create :headless t)))
    (should session)
    (should (flywire-session-p session))
    (should (member session benedict-flywire--sessions))
    (benedict-flywire-session-teardown session)
    (should-not (member session benedict-flywire--sessions))))

(ert-deftest benedict-flywire-session-run-headless ()
  "Session can execute thunks in headless mode."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (let ((result (benedict-flywire-session-run session
                        (lambda () (+ 1 2 3)))))
          (should (= result 6)))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-headless-env ()
  "Headless env can be created without a frame."
  (let ((env (benedict-flywire-env-create-headless)))
    (should env)
    (should (flywire-session-env-p env))
    (should (equal (flywire-session-env-name env) "benedict-headless"))
    (let ((result (funcall (flywire-session-env-run env)
                           (lambda () (* 2 21)))))
      (should (= result 42)))))

(ert-deftest benedict-flywire-snapshot-headless ()
  "Headless session can take snapshots."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (let ((snapshot (benedict-flywire-snapshot session)))
          (should snapshot)
          (should (plist-get snapshot :buffer-info)))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-multiple-sessions ()
  "Multiple sessions can coexist."
  (let ((s1 (benedict-flywire-session-create :headless t))
        (s2 (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (progn
          (should (= (length benedict-flywire--sessions) 2))
          (should (member s1 benedict-flywire--sessions))
          (should (member s2 benedict-flywire--sessions))
          (benedict-flywire-session-teardown s1)
          (should (= (length benedict-flywire--sessions) 1))
          (should-not (member s1 benedict-flywire--sessions))
          (should (member s2 benedict-flywire--sessions)))
      (benedict-flywire-session-teardown s1)
      (benedict-flywire-session-teardown s2))))

;;; File operation tests

(ert-deftest benedict-flywire-read-file-basic ()
  "Read entire file returns line-numbered content."
  (let* ((test-dir (make-temp-file "benedict-flywire-test-" t))
         (file (expand-file-name "test.txt" test-dir))
         (session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line one\nline two\nline three\n"))
          (let ((result (benedict-flywire-read-file session file)))
            (should (string-match-p "^1 | line one" result))
            (should (string-match-p "2 | line two" result))
            (should (string-match-p "3 | line three" result))))
      (benedict-flywire-session-teardown session)
      (delete-directory test-dir t))))

(ert-deftest benedict-flywire-read-file-slice ()
  "Read file slice returns only requested lines."
  (let* ((test-dir (make-temp-file "benedict-flywire-test-" t))
         (file (expand-file-name "test.txt" test-dir))
         (session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line 1\nline 2\nline 3\nline 4\nline 5\n"))
          (let ((result (benedict-flywire-read-file session file
                          :start-line 2 :end-line 4)))
            (should (string-match-p "^2 | line 2" result))
            (should (string-match-p "3 | line 3" result))
            (should (string-match-p "4 | line 4" result))
            (should-not (string-match-p "1 | line 1" result))
            (should-not (string-match-p "5 | line 5" result))))
      (benedict-flywire-session-teardown session)
      (delete-directory test-dir t))))

(ert-deftest benedict-flywire-update-file-replace ()
  "Update file replaces specified line range."
  (let* ((test-dir (make-temp-file "benedict-flywire-test-" t))
         (file (expand-file-name "test.txt" test-dir))
         (session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line 1\nline 2\nline 3\nline 4\n"))
          (let ((result (benedict-flywire-update-file session file
                          :start-line 2 :end-line 3
                          :content "new line A\nnew line B\n")))
            (should (plist-get result :success))
            (let ((contents (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string))))
              (should (string-match-p "line 1" contents))
              (should (string-match-p "new line A" contents))
              (should (string-match-p "new line B" contents))
              (should (string-match-p "line 4" contents))
              (should-not (string-match-p "line 2\n" contents))
              (should-not (string-match-p "line 3\n" contents)))))
      (benedict-flywire-session-teardown session)
      (delete-directory test-dir t))))

(ert-deftest benedict-flywire-update-file-insert ()
  "Update file with same start and end replaces single line."
  (let* ((test-dir (make-temp-file "benedict-flywire-test-" t))
         (file (expand-file-name "test.txt" test-dir))
         (session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line 1\nline 2\nline 3\n"))
          (let ((result (benedict-flywire-update-file session file
                          :start-line 2
                          :content "replaced line 2")))
            (should (plist-get result :success))
            (let ((contents (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string))))
              (should (string-match-p "line 1" contents))
              (should (string-match-p "replaced line 2" contents))
              (should (string-match-p "line 3" contents))
              (should-not (string-match-p "^line 2$" contents)))))
      (benedict-flywire-session-teardown session)
      (delete-directory test-dir t))))

(ert-deftest benedict-flywire-exec-elisp-success ()
  "Exec elisp returns result on success."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (let ((result (benedict-flywire-exec-elisp session "(+ 1 1)")))
          (should (plist-get result :success))
          (should (equal (plist-get result :result) "2")))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-exec-elisp-complex ()
  "Exec elisp handles complex expressions."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (let ((result (benedict-flywire-exec-elisp session
                        "(mapcar #'1+ '(1 2 3))")))
          (should (plist-get result :success))
          (should (equal (plist-get result :result) "(2 3 4)")))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-exec-elisp-error ()
  "Exec elisp returns error on failure."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (let ((result (benedict-flywire-exec-elisp session "(/ 1 0)")))
          (should-not (plist-get result :success))
          (should (plist-get result :error))
          (should (string-match-p "arith-error" (plist-get result :error))))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-exec-elisp-syntax-error ()
  "Exec elisp handles syntax errors."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (let ((result (benedict-flywire-exec-elisp session "(defun incomplete")))
          (should-not (plist-get result :success))
          (should (plist-get result :error)))
      (benedict-flywire-session-teardown session))))

;;; Event tests

(ert-deftest benedict-flywire-event-callback-registration ()
  "Event callbacks can be registered and removed."
  (let ((session (benedict-flywire-session-create :headless t))
        (events nil))
    (unwind-protect
        (let ((unsubscribe (benedict-flywire-session-on-event
                            session
                            (lambda (event) (push event events)))))
          (should (functionp unsubscribe))
          (should (gethash session benedict-flywire--session-callbacks))
          (funcall unsubscribe)
          (should-not (gethash session benedict-flywire--session-callbacks)))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-event-emission ()
  "Events are emitted to registered callbacks."
  (let ((session (benedict-flywire-session-create :headless t))
        (events nil))
    (unwind-protect
        (progn
          (benedict-flywire-session-on-event
           session
           (lambda (event) (push event events)))
          (benedict-flywire--emit-event session '(:type :test :data "hello"))
          (should (= (length events) 1))
          (should (eq (plist-get (car events) :type) :test))
          (should (equal (plist-get (car events) :data) "hello")))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-event-multiple-callbacks ()
  "Multiple callbacks receive the same event."
  (let ((session (benedict-flywire-session-create :headless t))
        (events-a nil)
        (events-b nil))
    (unwind-protect
        (progn
          (benedict-flywire-session-on-event
           session
           (lambda (event) (push event events-a)))
          (benedict-flywire-session-on-event
           session
           (lambda (event) (push event events-b)))
          (benedict-flywire--emit-event session '(:type :multi))
          (should (= (length events-a) 1))
          (should (= (length events-b) 1))
          (should (eq (plist-get (car events-a) :type) :multi))
          (should (eq (plist-get (car events-b) :type) :multi)))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-enable-events-headless ()
  "Headless sessions can enable events."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (progn
          (benedict-flywire-session-enable-events session)
          (should (gethash session benedict-flywire--event-state))
          (should (plist-get (gethash session benedict-flywire--event-state) :headless)))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-teardown-cleans-events ()
  "Session teardown cleans up event state."
  (let ((session (benedict-flywire-session-create :headless t)))
    (benedict-flywire-session-on-event session #'ignore)
    (benedict-flywire-session-enable-events session)
    (should (gethash session benedict-flywire--event-state))
    (should (gethash session benedict-flywire--session-callbacks))
    (benedict-flywire-session-teardown session)
    (should-not (gethash session benedict-flywire--event-state))
    (should-not (gethash session benedict-flywire--session-callbacks))))

(ert-deftest benedict-flywire-event-callback-error-handling ()
  "Errors in callbacks don't break event emission."
  (let ((session (benedict-flywire-session-create :headless t))
        (good-events nil))
    (unwind-protect
        (progn
          (benedict-flywire-session-on-event
           session
           (lambda (_event) (error "Intentional test error")))
          (benedict-flywire-session-on-event
           session
           (lambda (event) (push event good-events)))
          (benedict-flywire--emit-event session '(:type :test))
          (should (= (length good-events) 1)))
      (benedict-flywire-session-teardown session))))

;;; Safety policy tests

(ert-deftest benedict-flywire-policy-allowed-default ()
  "Default policy allows commands in the allowlist."
  (should (benedict-flywire-command-allowed-p 'forward-char))
  (should (benedict-flywire-command-allowed-p 'save-buffer))
  (should (benedict-flywire-command-allowed-p 'find-file)))

(ert-deftest benedict-flywire-policy-denied-default ()
  "Default policy denies commands not in the allowlist."
  (should-not (benedict-flywire-command-allowed-p 'delete-file))
  (should-not (benedict-flywire-command-allowed-p 'shell-command))
  (should-not (benedict-flywire-command-allowed-p 'some-unknown-command)))

(ert-deftest benedict-flywire-policy-session-custom ()
  "Sessions can have custom safety policies."
  (let ((session (benedict-flywire-session-create
                  :headless t
                  :safety-policy (lambda (cmd) (eq cmd 'my-special-command)))))
    (unwind-protect
        (progn
          (should (benedict-flywire-command-allowed-p 'my-special-command session))
          (should-not (benedict-flywire-command-allowed-p 'forward-char session))
          (should-not (benedict-flywire-command-allowed-p 'delete-file session)))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-policy-session-set ()
  "Session policy can be set after creation."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (progn
          (should (benedict-flywire-command-allowed-p 'forward-char session))
          (benedict-flywire-session-set-policy
           session
           (lambda (cmd) (eq cmd 'custom-cmd)))
          (should (benedict-flywire-command-allowed-p 'custom-cmd session))
          (should-not (benedict-flywire-command-allowed-p 'forward-char session))
          (benedict-flywire-session-set-policy session nil)
          (should (benedict-flywire-command-allowed-p 'forward-char session)))
      (benedict-flywire-session-teardown session))))

(ert-deftest benedict-flywire-policy-teardown-cleanup ()
  "Session teardown cleans up policy."
  (let ((session (benedict-flywire-session-create
                  :headless t
                  :safety-policy #'ignore)))
    (should (gethash session benedict-flywire--session-policies))
    (benedict-flywire-session-teardown session)
    (should-not (gethash session benedict-flywire--session-policies))))

(provide 'test/benedict-flywire-test)
;;; benedict-flywire-test.el ends here

(ert-deftest benedict-flywire-exec-elisp-output ()
  "Exec elisp captures standard output."
  (let ((session (benedict-flywire-session-create :headless t)))
    (unwind-protect
        (let ((result (benedict-flywire-exec-elisp session "(print \"flywire hello\")")))
          (should (plist-get result :success))
          (should (string-match-p "flywire hello" (or (plist-get result :output) ""))))
      (benedict-flywire-session-teardown session))))
