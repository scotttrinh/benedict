;;; benedict-core-dispatch-test.el --- The tool dispatch chain  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 6.4 makes one mechanism carry approval, permission policy, path
;; protection, sandbox routing, and worker delegation: a continuation-passing
;; filter chain around tool dispatch.  The Phase 2 exit criterion is the hardest
;; of those five -- a filter that SUSPENDS a run and later resumes it -- which
;; is `benedict-core-dispatch-filter-suspends-and-resumes'.  The others are here
;; too, because the claim is that they are all the same mechanism and a test
;; that only exercises one does not check that claim.

;;; Code:

(require 'ert)
(require 'test-helper)

(defun benedict-core-dispatch-test--tool ()
  "Register and return a tool that reports the argument it was given."
  (benedict-deftool benedict-test-say
    :description "Return the text it is given."
    :parameters '((text :type string :required t :description "Text."))
    :sync t
    :handler (lambda (invocation)
               (benedict-tool-result
                :content (format "said %s" (benedict-tool-arg invocation :text))))))

(defun benedict-core-dispatch-test--session ()
  "Return a session that calls `benedict-test-say' once, then stops."
  (benedict-test-session
   '(((:tool-call benedict-test-say (:text "hello")))
     ((:text "done")))
   :tools '(benedict-test-say)))

(defun benedict-core-dispatch-test--result-contents (session)
  "Return the content of each tool-result entry on SESSION's path."
  (mapcar (lambda (entry) (plist-get (car (benedict-entry-content entry)) :content))
          (seq-filter #'benedict-entry-tool-result-p
                      (benedict-session-path session))))

;;;; Exit criterion: suspend and resume

(ert-deftest benedict-core-dispatch-filter-suspends-and-resumes ()
  "A filter that holds its continuation parks the run until it is called."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (held nil)
            (held-invocation nil))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (setq held-invocation invocation)
           (setq held next)))
        (benedict-session-submit session "go")
        (benedict-test-drain)

        ;; The chain never called `next', so the run is parked with the queue
        ;; empty -- a suspended run is exactly one whose continuation is
        ;; outstanding.  There is no approval state in the kernel to inspect.
        (should (eq (benedict-session-state session) 'tool-wait))
        (should held)
        (should (equal (benedict-invocation-name held-invocation) 'benedict-test-say))
        (should (null benedict-test-defer-queue))
        (should (equal (benedict-test-entry-roles session) '(user assistant)))

        ;; Resuming is calling the continuation.  There is no resume entry
        ;; point, and the kernel needed no notification that a wait had begun.
        (funcall held held-invocation)
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("said hello")))
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant tool-result assistant)))))))

(ert-deftest benedict-core-dispatch-suspended-call-survives-an-abort ()
  "Resuming a continuation after an abort appends nothing to a finished run."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (held nil)
            (held-invocation nil))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (setq held-invocation invocation)
           (setq held next)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'tool-wait))

        (benedict-session-abort session)
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))

        ;; The approval finally comes back, long after the run gave up on it.
        (funcall held held-invocation)
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (equal (benedict-test-entry-roles session) '(user assistant)))))))

;;;; The other four things the chain is

(ert-deftest benedict-core-dispatch-filter-can-allow ()
  "A filter that passes the invocation through changes nothing."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (seen nil))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (push (benedict-invocation-name invocation) seen)
           (funcall next invocation)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal seen '(benedict-test-say)))
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("said hello")))))))

(ert-deftest benedict-core-dispatch-filter-can-rewrite-arguments ()
  "A filter may hand `next' a modified invocation."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session)))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (funcall next (benedict-invocation-with invocation
                                                   :arguments '(:text "rewritten")))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("said rewritten")))))))

(ert-deftest benedict-core-dispatch-filter-can-deny ()
  "A denied call becomes an error result the model can see and recover from."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (ended nil))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (funcall next (benedict-tool-blocked invocation "Denied by policy"))))
        (benedict-session-add-hook
         session 'benedict-tool-end-functions
         (lambda (_session _invocation result) (push result ended)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("Denied by policy")))
        (should (benedict-tool-result-value-error-p (car ended)))
        ;; A denial is history, not a failure: the run carried on to the turn
        ;; where the model gets to react.
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant tool-result assistant)))
        (let ((block (car (benedict-entry-content
                           (nth 2 (benedict-session-path session))))))
          (should (plist-get block :error-p)))))))

(ert-deftest benedict-core-dispatch-filter-can-reroute ()
  "A retargeted call runs on the registered executor instead of locally."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (routed nil))
        (unwind-protect
            (progn
              (benedict-tool-register-executor
               'benedict-test-elsewhere
               (lambda (invocation done)
                 (push (benedict-invocation-name invocation) routed)
                 (funcall done (benedict-tool-result :content "ran elsewhere"))))
              (benedict-session-add-hook
               session 'benedict-tool-dispatch-functions
               (lambda (invocation next)
                 (funcall next (benedict-tool-retarget
                                invocation 'benedict-test-elsewhere))))
              (benedict-session-submit session "go")
              (benedict-test-drain)
              (should (equal routed '(benedict-test-say)))
              (should (equal (benedict-core-dispatch-test--result-contents session)
                             '("ran elsewhere"))))
          (benedict-tool-unregister-executor 'benedict-test-elsewhere))))))

;;;; Ordering and observation

(ert-deftest benedict-core-dispatch-runs-global-before-session-local ()
  "Global filters see a call before session-local ones at equal depth."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (order nil))
        (add-hook 'benedict-tool-dispatch-functions
                  (lambda (invocation next)
                    (push 'global order)
                    (funcall next invocation)))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (push 'local order)
           (funcall next invocation)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (reverse order) '(global local)))))))

(ert-deftest benedict-core-dispatch-depth-orders-within-a-scope ()
  "`DEPTH' orders session-local filters the way it orders global ones."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (order nil))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next) (push 'routing order) (funcall next invocation))
         90)
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next) (push 'approval order) (funcall next invocation))
         0)
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next) (push 'observer order) (funcall next invocation))
         -90)
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (reverse order) '(observer approval routing)))))))

(ert-deftest benedict-core-dispatch-observers-see-denied-calls ()
  "`benedict-tool-start-functions' fires before the chain, so nothing hides."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (started nil))
        (benedict-session-add-hook
         session 'benedict-tool-start-functions
         (lambda (_session invocation)
           (push (benedict-invocation-name invocation) started)))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (funcall next (benedict-tool-blocked invocation "no"))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal started '(benedict-test-say)))))))

(ert-deftest benedict-core-dispatch-result-filter-rewrites-the-result ()
  "`benedict-tool-result-filter-functions' replaces what reaches the model."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session)))
        (benedict-session-add-hook
         session 'benedict-tool-result-filter-functions
         (lambda (result _invocation)
           (benedict-tool-result
            :content (upcase (benedict-tool-result-value-content result)))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("SAID HELLO")))))))

;;;; Failure modes that must reach the model rather than the stack

(ert-deftest benedict-core-dispatch-unknown-tool-becomes-an-error-result ()
  "A call to a tool that is not registered is answered, not signalled."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-nonexistent (:x 1)))
                        ((:text "oh"))))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("No such tool: benedict-test-nonexistent")))))))

(ert-deftest benedict-core-dispatch-a-signalling-handler-becomes-an-error-result ()
  "A tool that breaks does not take the run with it."
  (benedict-test-with-clean-registries
    (benedict-deftool benedict-test-broken
      :description "Always fails."
      :parameters nil
      :sync t
      :handler (lambda (_invocation) (error "Deliberate failure")))
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-broken nil))
                        ((:text "noted")))
                      :tools '(benedict-test-broken))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (string-match-p "Deliberate failure"
                                (car (benedict-core-dispatch-test--result-contents
                                      session))))))))

(provide 'benedict-core-dispatch-test)

;;; benedict-core-dispatch-test.el ends here
