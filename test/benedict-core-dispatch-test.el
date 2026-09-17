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
  "Resuming a continuation after an abort executes no tool-side effects."
  (benedict-test-with-clean-registries
    (let ((ran 0))
      (benedict-deftool benedict-test-held
        :description "Counts stale execution."
        :parameters nil
        :sync t
        :handler (lambda (_invocation)
                   (cl-incf ran)
                   (benedict-tool-result :content "must not run")))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-held nil)))
                        :tools '(benedict-test-held)))
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
          (should (= ran 0))
          (should (equal (benedict-test-entry-roles session) '(user assistant))))))))

(ert-deftest benedict-core-dispatch-next-is-consumed-once ()
  "Calling a held NEXT twice executes only one tool operation."
  (benedict-test-with-clean-registries
    (let ((ran 0))
      (benedict-deftool benedict-test-next-twice
        :description "Counts duplicate NEXT execution."
        :parameters nil :sync t
        :handler (lambda (_invocation)
                   (cl-incf ran)
                   (benedict-tool-result :content "once")))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-next-twice nil))
                          ((:text "done")))
                        :tools '(benedict-test-next-twice))))
          (benedict-session-add-hook
           session 'benedict-tool-dispatch-functions
           (lambda (invocation next)
             (funcall next invocation)
             (funcall next invocation)))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (should (= ran 1))
          (should (equal (benedict-core-dispatch-test--result-contents session)
                         '("once"))))))))

(ert-deftest benedict-core-dispatch-duplicate-tool-use-done-does-not-finish-early ()
  "A duplicate terminal event cannot finish before queued tools run."
  (benedict-test-with-clean-registries
    (let ((tool-runs 0)
          (requests 0)
          (model (benedict-model-create :id "held" :provider 'duplicate-done
                                        :api 'contract)))
      (benedict-deftool benedict-test-duplicate-done
        :description "Counts tool execution."
        :parameters nil
        :sync t
        :handler (lambda (_invocation)
                   (cl-incf tool-runs)
                   (benedict-tool-result :content "ran")))
      (unwind-protect
          (progn
            (benedict-defprovider duplicate-done
              :stream
              (lambda (_model _request callback)
                (cl-incf requests)
                (if (= requests 1)
                    (dolist (event '((:type :block-start :index 0
                                              :block-type tool-call
                                              :name benedict-test-duplicate-done)
                                     (:type :block-end :index 0
                                            :arguments nil)
                                     (:type :done :reason tool-use)
                                     (:type :done :reason tool-use)))
                      (funcall callback event))
                  (funcall callback '(:type :done :reason stop)))
                (lambda () nil)))
            (let ((session (benedict-session-create
                            :model model
                            :tools '(benedict-test-duplicate-done))))
              (benedict-test-with-manual-defer
                (benedict-session-submit session "go")
                (benedict-test-drain)
                (should (= tool-runs 1))
                (should (eq (benedict-session-state session) 'idle)))))
        (benedict-provider-unregister 'duplicate-done)))))

(ert-deftest benedict-core-dispatch-done-is-consumed-once ()
  "Calling a tool DONE twice records one result and no extra progression."
  (benedict-test-with-clean-registries
    (let ((done nil))
      (benedict-deftool benedict-test-done-twice
        :description "Holds its completion callback."
        :parameters nil
        :handler (lambda (_invocation callback) (setq done callback)))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-done-twice nil))
                          ((:text "done")))
                        :tools '(benedict-test-done-twice))))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (should (eq (benedict-session-state session) 'tool-wait))
          (funcall done (benedict-tool-result :content "once"))
          (funcall done (benedict-tool-result :content "twice"))
          (benedict-test-drain)
          (should (equal (benedict-core-dispatch-test--result-contents session)
                         '("once"))))))))

(ert-deftest benedict-core-dispatch-result-filter-failure-is-terminal ()
  "A result filter failure does not become a second tool result."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session)))
        (benedict-session-add-hook
         session 'benedict-tool-result-filter-functions
         (lambda (_result _invocation) (error "result filter failed")))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (should (equal (benedict-session-last-error session)
                       '(error "result filter failed")))
        (should-not (benedict-core-dispatch-test--result-contents session))))))

(ert-deftest benedict-core-dispatch-stale-next-skips-later-filter-during-new-run ()
  "A stale NEXT from A cannot execute a later filter while B streams."
  (benedict-test-with-clean-registries
    (let ((later-filter-runs 0)
          (handler-runs 0))
      (benedict-deftool benedict-test-cross-run
        :description "Counts stale execution."
        :parameters nil :sync t
        :handler (lambda (_invocation)
                   (cl-incf handler-runs)
                   (benedict-tool-result :content "stale")))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-cross-run nil))
                          ((:text "B partial")))
                        :tools '(benedict-test-cross-run)))
              (held nil)
              (held-invocation nil))
          (benedict-session-add-hook
           session 'benedict-tool-dispatch-functions
           (lambda (invocation next)
             (setq held-invocation invocation held next))
           0)
          (benedict-session-add-hook
           session 'benedict-tool-dispatch-functions
           (lambda (invocation next)
             (cl-incf later-filter-runs)
             (funcall next invocation))
           10)
          (benedict-session-submit session "A")
          (benedict-test-drain)
          (benedict-session-abort session)
          (benedict-test-drain)
          (benedict-session-submit session "B")
          (should (benedict-test-run-until
                   (lambda ()
                     (when-let ((entry (benedict-session-streaming-entry session)))
                       (equal (benedict-entry-text entry) "B partial")))))
          (let ((partial (benedict-session-streaming-entry session))
                (roles (benedict-test-entry-roles session)))
            (funcall held held-invocation)
            (should (= later-filter-runs 0))
            (should (= handler-runs 0))
            (should (eq (benedict-session-state session) 'provider-wait))
            (should (eq partial (benedict-session-streaming-entry session)))
            (should (equal roles (benedict-test-entry-roles session)))))))))

(ert-deftest benedict-core-dispatch-late-done-cannot-mutate-new-run ()
  "A late tool DONE from A cannot mutate B after B opens."
  (benedict-test-with-clean-registries
    (let ((old-done nil)
          (tool-ends 0))
      (benedict-deftool benedict-test-late-done
        :description "Retains DONE."
        :parameters nil
        :handler (lambda (_invocation done) (setq old-done done)))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-late-done nil))
                          ((:text "B partial")))
                        :tools '(benedict-test-late-done))))
          (benedict-session-add-hook
           session 'benedict-tool-end-functions
           (lambda (&rest _) (cl-incf tool-ends)))
          (benedict-session-submit session "A")
          (benedict-test-drain)
          (benedict-session-abort session)
          (benedict-test-drain)
          (benedict-session-submit session "B")
          (should (benedict-test-run-until
                   (lambda ()
                     (when-let ((entry (benedict-session-streaming-entry session)))
                       (equal (benedict-entry-text entry) "B partial")))))
          (let ((partial (benedict-session-streaming-entry session))
                (roles (benedict-test-entry-roles session)))
            (funcall old-done (benedict-tool-result :content "late"))
            (should (= tool-ends 0))
            (should (eq (benedict-session-state session) 'provider-wait))
            (should (eq partial (benedict-session-streaming-entry session)))
            (should (equal roles (benedict-test-entry-roles session)))
            (benedict-test-drain)
            (should (eq (benedict-session-state session) 'idle))
            (should (= tool-ends 0))
            (should-not (benedict-core-dispatch-test--result-contents session))))))))

(ert-deftest benedict-core-dispatch-old-second-done-does-not-advance-next-tool ()
  "An old DONE cannot progress the next tool in the same turn."
  (benedict-test-with-clean-registries
    (let ((first-done nil)
          (second-done nil))
      (benedict-deftool benedict-test-first-held
        :description "Retains first DONE." :parameters nil
        :handler (lambda (_invocation done) (setq first-done done)))
      (benedict-deftool benedict-test-second-held
        :description "Retains second DONE." :parameters nil
        :handler (lambda (_invocation done) (setq second-done done)))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-first-held nil)
                           (:tool-call benedict-test-second-held nil)))
                        :tools '(benedict-test-first-held benedict-test-second-held))))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (funcall first-done (benedict-tool-result :content "first"))
          (benedict-test-drain)
          (should second-done)
          (funcall first-done (benedict-tool-result :content "duplicate"))
          (benedict-test-drain)
          (should (eq (benedict-session-state session) 'tool-wait))
          (should (equal (benedict-core-dispatch-test--result-contents session)
                         '("first"))))))))

(ert-deftest benedict-core-dispatch-done-then-handler-error-records-once ()
  "A handler that calls DONE then signals records only its completed result."
  (benedict-test-with-clean-registries
    (benedict-deftool benedict-test-done-then-error
      :description "Completes then signals." :parameters nil
      :handler (lambda (_invocation done)
                 (funcall done (benedict-tool-result :content "complete"))
                 (error "after DONE")))
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-done-then-error nil))
                        ((:text "continued")))
                      :tools '(benedict-test-done-then-error))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("complete")))))))

(ert-deftest benedict-core-dispatch-async-result-filter-failure-is-terminal ()
  "A result-filter failure from asynchronous DONE terminates without a result."
  (benedict-test-with-clean-registries
    (let ((done nil))
      (benedict-deftool benedict-test-async-filter
        :description "Completes asynchronously." :parameters nil
        :handler (lambda (_invocation callback) (setq done callback)))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-async-filter nil)))
                        :tools '(benedict-test-async-filter))))
          (benedict-session-add-hook
           session 'benedict-tool-result-filter-functions
           (lambda (_result _invocation) (error "async result filter failed")))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (funcall done (benedict-tool-result :content "unused"))
          (benedict-test-drain)
          (should (eq (benedict-session-state session) 'idle))
          (should (equal (benedict-session-last-error session)
                         '(error "async result filter failed")))
          (should-not (benedict-core-dispatch-test--result-contents session)))))))
(ert-deftest benedict-core-dispatch-abort-from-tool-start-skips-chain ()
  "Aborting in a tool-start observer prevents dispatch extension work."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (filter-runs 0))
        (benedict-session-add-hook
         session 'benedict-tool-start-functions
         (lambda (observed _invocation) (benedict-session-abort observed)))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (cl-incf filter-runs)
           (funcall next invocation)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (= filter-runs 0))
        (should (eq (benedict-session-state session) 'idle))
        (should-not (benedict-core-dispatch-test--result-contents session))))))

(ert-deftest benedict-core-dispatch-abort-from-result-filter-skips-result-effects ()
  "Aborting in a result filter prevents tool-end and transcript effects."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session))
            (tool-ends 0))
        (benedict-session-add-hook
         session 'benedict-tool-result-filter-functions
         (lambda (result _invocation)
           (benedict-session-abort session)
           result))
        (benedict-session-add-hook
         session 'benedict-tool-end-functions
         (lambda (&rest _) (cl-incf tool-ends)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (= tool-ends 0))
        (should-not (benedict-core-dispatch-test--result-contents session))
        (should (eq (benedict-session-state session) 'idle))))))

(ert-deftest benedict-core-dispatch-abort-from-tool-end-skips-result-effects ()
  "Aborting in a tool-end observer prevents transcript and reducer effects."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-core-dispatch-test--session)))
        (benedict-session-add-hook
         session 'benedict-tool-end-functions
         (lambda (observed _invocation _result)
           (benedict-session-abort observed)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should-not (benedict-core-dispatch-test--result-contents session))
        (should (eq (benedict-session-state session) 'idle))))))

(ert-deftest benedict-core-dispatch-error-before-next-is-terminal ()
  "A dispatch error before NEXT prevents handler execution."
  (benedict-test-with-clean-registries
    (let ((handler-runs 0))
      (benedict-deftool benedict-test-before-next
        :description "Must not execute." :parameters nil :sync t
        :handler (lambda (_invocation)
                   (cl-incf handler-runs)
                   (benedict-tool-result :content "unexpected")))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-before-next nil)))
                        :tools '(benedict-test-before-next))))
          (benedict-session-add-hook
           session 'benedict-tool-dispatch-functions
           (lambda (_invocation _next) (error "before NEXT")))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (should (= handler-runs 0))
          (should (eq (benedict-session-stop-reason session) 'error))
          (should (equal (benedict-session-last-error session)
                         '(error "before NEXT"))))))))

(ert-deftest benedict-core-dispatch-error-after-next-does-not-duplicate-result ()
  "A dispatch error after synchronous NEXT cannot complete the tool twice."
  (benedict-test-with-clean-registries
    (let ((handler-runs 0))
      (benedict-deftool benedict-test-after-next
        :description "Completes synchronously." :parameters nil :sync t
        :handler (lambda (_invocation)
                   (cl-incf handler-runs)
                   (benedict-tool-result :content "complete")))
      (benedict-test-with-manual-defer
        (let ((session (benedict-test-session
                        '(((:tool-call benedict-test-after-next nil)))
                        :tools '(benedict-test-after-next))))
          (benedict-session-add-hook
           session 'benedict-tool-dispatch-functions
           (lambda (invocation next)
             (funcall next invocation)
             (error "after NEXT")))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (should (= handler-runs 1))
          (should (equal (benedict-core-dispatch-test--result-contents session)
                         '("complete"))))))))

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
  "A filter substitutes the tool, and the work runs somewhere the kernel cannot see.

This is what a sandbox package does, minus the subordinate Emacs: the
stand-in receives the invocation the model produced, answers with a
result, and the reducer appends a tool-result entry indistinguishable
from a local one.  Nothing in the kernel is told that execution moved,
which is the property the design is after."
  (benedict-test-with-clean-registries
    (benedict-core-dispatch-test--tool)
    (benedict-test-with-manual-defer
      (let* ((routed nil)
             (session (benedict-core-dispatch-test--session))
             (elsewhere (benedict-tool-create
                         :id 'benedict-test-elsewhere :parameters nil :sync t
                         :handler (lambda (invocation)
                                    (push (benedict-invocation-name invocation) routed)
                                    (benedict-tool-result :content "ran elsewhere")))))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (funcall next (benedict-invocation-with invocation :tool elsewhere))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal routed '(benedict-test-say)))
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("ran elsewhere")))
        ;; The stand-in was never registered, so it was reachable only through
        ;; the filter that installed it.
        (should-not (benedict-tool-get 'benedict-test-elsewhere))))))

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

(ert-deftest benedict-core-dispatch-executes-selected-local-tool ()
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((ran nil)
             (tool (benedict-tool-create
                    :id 'contract-local :sync t
                    :handler (lambda (_invocation)
                               (setq ran t)
                               (benedict-tool-result :content "local result"))))
             (session (benedict-test-session
                       '(((:tool-call contract-local nil)) ((:text "done")))
                       :tools (list tool)))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should ran)
        (should-not (benedict-tool-get 'contract-local))
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant tool-result assistant)))
        (let* ((requests (benedict-provider-fake-requests script))
               (second-entries (plist-get (nth 1 requests) :entries))
               (assistant-entry (nth 1 (benedict-session-path session)))
               (call-id (plist-get
                         (car (benedict-entry-tool-calls assistant-entry)) :id))
               (result-entry (seq-find #'benedict-entry-tool-result-p
                                       second-entries))
               (result (car (benedict-entry-tool-results result-entry))))
          (should (equal (plist-get result :content) "local result"))
          (should (equal (plist-get result :id) call-id)))))))

(ert-deftest benedict-core-dispatch-prefers-offered-definition-over-global-replacement ()
  "A request executes its offered object even when the registry differs."
  (benedict-test-with-clean-registries
    (benedict-deftool contract-same-id
      :description "global" :parameters nil :sync t
      :handler (lambda (_invocation)
                 (benedict-tool-result :content "global")))
    (benedict-test-with-manual-defer
      (let* ((local (benedict-tool-create
                     :id 'contract-same-id :sync t
                     :handler (lambda (_invocation)
                                (benedict-tool-result :content "local"))))
             (session (benedict-test-session
                       '(((:tool-call contract-same-id nil)) ((:text "done")))
                       :tools (list local))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("local")))))))

(ert-deftest benedict-core-dispatch-normalizes-duplicate-offered-ids-first-wins ()
  "Duplicate offered ids execute the first borrowed definition."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((first-ran nil)
             (second-ran nil)
             (first (benedict-tool-create
                     :id 'contract-duplicate :sync t
                     :handler (lambda (_invocation)
                                (setq first-ran t)
                                (benedict-tool-result :content "first"))))
             (second (benedict-tool-create
                      :id 'contract-duplicate :sync t
                      :handler (lambda (_invocation)
                                 (setq second-ran t)
                                 (benedict-tool-result :content "second"))))
             (session (benedict-test-session
                       '(((:tool-call contract-duplicate nil)) ((:text "done")))
                       :tools (list first second))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should first-ran)
        (should-not second-ran)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("first")))))))

(ert-deftest benedict-core-dispatch-isolates-local-same-id-definitions ()
  "Two sessions execute their own borrowed definition for one id."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((first-tool (benedict-tool-create
                          :id 'contract-shared :sync t
                          :handler (lambda (_invocation)
                                     (benedict-tool-result :content "first"))))
             (second-tool (benedict-tool-create
                           :id 'contract-shared :sync t
                           :handler (lambda (_invocation)
                                      (benedict-tool-result :content "second"))))
             (first-session (benedict-test-session
                             '(((:tool-call contract-shared nil)))
                             :tools (list first-tool)))
             (second-session (benedict-test-session
                              '(((:tool-call contract-shared nil)))
                              :tools (list second-tool))))
        (benedict-session-submit first-session "go")
        (benedict-session-submit second-session "go")
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents first-session)
                       '("first")))
        (should (equal (benedict-core-dispatch-test--result-contents second-session)
                       '("second")))))))

(ert-deftest benedict-core-dispatch-filter-reroutes-unresolved-call ()
  "A dispatch filter may explicitly supply a handler for an unresolved call."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((rerouted (benedict-tool-create
                        :id 'contract-rerouted :sync t
                        :handler (lambda (_invocation)
                                   (benedict-tool-result :content "rerouted"))))
             (session (benedict-test-session
                       '(((:tool-call contract-missing nil)))
                       :tools nil)))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (funcall next (benedict-invocation-with invocation :tool rerouted))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("rerouted")))))))

(ert-deftest benedict-core-dispatch-keeps-offered-tool-after-registry-replacement ()
  "An in-flight call uses its offered object; the next request sees replacement."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((held nil)
             (old-tool (benedict-tool-create
                        :id 'contract-reload
                        :handler (lambda (_invocation done)
                                   (setq held done))))
             (new-tool (benedict-tool-create
                        :id 'contract-reload :sync t
                        :handler (lambda (_invocation)
                                   (benedict-tool-result :content "new"))))
             (session (benedict-test-session
                       '(((:tool-call contract-reload nil))
                         ((:tool-call contract-reload nil)))
                       :tools (lambda (_session)
                                (list (benedict-tool-get 'contract-reload)))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session))))
        (benedict-tool-register old-tool)
        (benedict-session-submit session "go")
        (should (benedict-test-step))
        (should (equal (length (benedict-provider-fake-requests script)) 1))
        (benedict-tool-register new-tool)
        (benedict-test-drain)
        (should held)
        (funcall held (benedict-tool-result :content "old"))
        (benedict-test-drain)
        (should (equal (benedict-core-dispatch-test--result-contents session)
                       '("old" "new")))))))

(ert-deftest benedict-core-dispatch-two-sessions-rebind-resumed-chain-and-handler ()
  "Each suspended session resumes its chain and handler under its own binding.

This locks the asynchronous scope contract at both extension boundaries:
the post-suspension filter and the tool handler observe the session whose
continuation was resumed, even when two sessions share one global chain."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((held nil)
            (seen nil))
        (benedict-deftool benedict-test-session-aware
          :description "Record the dynamically bound session."
          :parameters nil
          :sync t
          :handler (lambda (_invocation)
                     (push (list 'handler
                                 (benedict-session-id benedict-current-session))
                           seen)
                     (benedict-tool-result :content "handled")))
        (let* ((first (benedict-test-session
                       '(((:tool-call benedict-test-session-aware nil))
                         ((:text "done")))
                       :tools '(benedict-test-session-aware)))
               (second (benedict-test-session
                        '(((:tool-call benedict-test-session-aware nil))
                          ((:text "done")))
                        :tools '(benedict-test-session-aware))))
          ;; Add the post-filter first: Emacs puts the suspending filter in
          ;; front, so resuming NEXT enters POST while the chain binds SESSION.
          (let ((post (lambda (invocation next)
                        (push (list 'post
                                    (benedict-session-id benedict-current-session))
                              seen)
                        (funcall next invocation)))
                (suspend (lambda (invocation next)
                           (push (list benedict-current-session invocation next)
                                 held))))
            (add-hook 'benedict-tool-dispatch-functions post)
            (add-hook 'benedict-tool-dispatch-functions suspend)
            (benedict-session-submit first "first")
            (benedict-session-submit second "second")
            (benedict-test-drain)
            (should (= (length held) 2))
            (dolist (session (list first second))
              (let ((entry (assq session held)))
                (should entry)
                (funcall (nth 2 entry) (nth 1 entry))
                (benedict-test-drain)))
            (should (equal seen
                           (list (list 'handler (benedict-session-id second))
                                 (list 'post (benedict-session-id second))
                                 (list 'handler (benedict-session-id first))
                                 (list 'post (benedict-session-id first)))))))))))

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
