;;; benedict-session-test.el --- Sessions, scoping, and queues  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 D5 makes hook scoping a Phase 2 concern rather than a frontend one,
;; because it shapes the hook-running helpers themselves.  The Phase 2 exit
;; criterion is two concurrent sessions where a session-local dispatch filter
;; fires for one and not the other, and a global filter discriminates via
;; `benedict-current-session'.  That is
;; `benedict-session-scoping-separates-two-sessions'.
;;
;; The rest of this file covers the session surface those two sessions are
;; built from: transcript delegation, forking, queues, and properties.

;;; Code:

(require 'ert)
(require 'test-helper)

(defun benedict-session-test--tool ()
  "Register and return a tool that reports which session ran it."
  (benedict-deftool benedict-test-whoami
    :description "Report the calling session."
    :parameters nil
    :sync t
    :handler (lambda (_invocation)
               (benedict-tool-result
                :content (benedict-session-id benedict-current-session)))))

(defun benedict-session-test--calling-session ()
  "Return a session that calls `benedict-test-whoami' once, then stops."
  (benedict-test-session
   '(((:tool-call benedict-test-whoami nil))
     ((:text "done")))
   :tools '(benedict-test-whoami)))

;;;; Exit criterion: two concurrent sessions

(ert-deftest benedict-session-scoping-separates-two-sessions ()
  "A session-local filter fires for its own session and no other."
  (benedict-test-with-clean-registries
    (benedict-session-test--tool)
    (benedict-test-with-manual-defer
      (let ((guarded (benedict-session-test--calling-session))
            (open (benedict-session-test--calling-session))
            (fired nil))
        ;; Only the guarded session gets the policy.  The other coexists in the
        ;; same image with the same tool and the same global hooks.
        (benedict-session-add-hook
         guarded 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (push (benedict-session-id benedict-current-session) fired)
           (funcall next (benedict-tool-blocked invocation "Denied here"))))

        (benedict-session-submit guarded "go")
        (benedict-session-submit open "go")
        (benedict-test-drain)

        (should (equal fired (list (benedict-session-id guarded))))
        (should (equal (benedict-session-test--results guarded) '("Denied here")))
        (should (equal (benedict-session-test--results open)
                       (list (benedict-session-id open))))))))

(ert-deftest benedict-session-global-filter-discriminates-by-current-session ()
  "A globally registered filter tells sessions apart via the dynamic variable."
  (benedict-test-with-clean-registries
    (benedict-session-test--tool)
    (benedict-test-with-manual-defer
      (let ((trusted (benedict-session-test--calling-session))
            (untrusted (benedict-session-test--calling-session)))
        (benedict-session-put trusted :trusted t)
        ;; This is the SPEC-001 4.4.1 example: one global function, no session
        ;; argument in its signature, discriminating anyway.
        (add-hook 'benedict-tool-dispatch-functions
                  (lambda (invocation next)
                    (if (benedict-session-get benedict-current-session :trusted)
                        (funcall next invocation)
                      (funcall next (benedict-tool-blocked invocation "Untrusted")))))
        (benedict-session-submit trusted "go")
        (benedict-session-submit untrusted "go")
        (benedict-test-drain)
        (should (equal (benedict-session-test--results trusted)
                       (list (benedict-session-id trusted))))
        (should (equal (benedict-session-test--results untrusted) '("Untrusted")))))))

(ert-deftest benedict-session-current-session-is-bound-in-every-hook-kind ()
  "Observation, veto, filter, and dispatch hooks all see the running session."
  (benedict-test-with-clean-registries
    (benedict-session-test--tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-session-test--calling-session))
            (seen nil))
        (benedict-session-add-hook
         session 'benedict-context-filter-functions
         (lambda (entries _session)
           (push (cons 'context (eq benedict-current-session session)) seen)
           entries))
        (benedict-session-add-hook
         session 'benedict-tool-result-filter-functions
         (lambda (result _invocation)
           (push (cons 'result (eq benedict-current-session session)) seen)
           result))
        (benedict-session-add-hook
         session 'benedict-continue-predicate-functions
         (lambda (_session)
           (push (cons 'continue (eq benedict-current-session session)) seen)
           nil))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         (lambda (invocation next)
           (push (cons 'dispatch (eq benedict-current-session session)) seen)
           (funcall next invocation)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (seq-every-p #'cdr seen))
        (should (equal (sort (delete-dups (mapcar #'car seen)) #'string<)
                       '(context continue dispatch result)))))))

(ert-deftest benedict-session-local-hooks-do-not-leak-across-sessions ()
  "Session-local lists are per session, and removal takes effect."
  (benedict-test-with-clean-registries
    (let ((a (benedict-session-create))
          (b (benedict-session-create))
          (fn (lambda (&rest _) nil)))
      (benedict-session-add-hook a 'benedict-run-start-functions fn)
      (should (equal (benedict-session-hook-functions a 'benedict-run-start-functions)
                     (list fn)))
      (should (null (benedict-session-hook-functions b 'benedict-run-start-functions)))
      (should (benedict-session-remove-hook a 'benedict-run-start-functions fn))
      (should (null (benedict-session-hook-functions a 'benedict-run-start-functions)))
      (should-not (benedict-session-remove-hook a 'benedict-run-start-functions fn)))))

(ert-deftest benedict-session-adding-a-hook-twice-moves-it ()
  "Re-adding a function changes its depth rather than duplicating it."
  (benedict-test-with-clean-registries
    (let ((session (benedict-session-create))
          (early (lambda (&rest _) 'early))
          (late (lambda (&rest _) 'late)))
      (benedict-session-add-hook session 'benedict-run-start-functions late 10)
      (benedict-session-add-hook session 'benedict-run-start-functions early 20)
      (benedict-session-add-hook session 'benedict-run-start-functions early -10)
      (should (equal (benedict-session-hook-functions session
                                                      'benedict-run-start-functions)
                     (list early late))))))

(ert-deftest benedict-session-hook-functions-puts-global-first ()
  "The combined list is global then local, and drops `add-hook''s t marker."
  (benedict-test-with-clean-registries
    (let ((session (benedict-session-create))
          (global (lambda (&rest _) 'global))
          (local (lambda (&rest _) 'local)))
      (add-hook 'benedict-run-start-functions global)
      (setq benedict-run-start-functions (append benedict-run-start-functions '(t)))
      (benedict-session-add-hook session 'benedict-run-start-functions local)
      (should (equal (benedict-session-hook-functions session
                                                      'benedict-run-start-functions)
                     (list global local))))))

(defun benedict-session-test--global-tie-first (&rest _)
  "Named no-op hook function used to observe Emacs global tie order."
  nil)

(defun benedict-session-test--global-tie-second (&rest _)
  "Named no-op hook function used to observe Emacs global tie order."
  nil)


(defun benedict-session-test--local-tie-first (&rest _)
  "Named no-op hook function used to observe local tie order."
  nil)

(defun benedict-session-test--local-tie-second (&rest _)
  "Named no-op hook function used to observe local tie order."
  nil)
(ert-deftest benedict-session-hook-functions-accepts-singleton-global-value ()
  "A singleton default global hook value still runs for a session.

This locks the legal `run-hooks' value shape where a global hook variable
holds one function rather than a list; session-local scope still composes
after it."
  (benedict-test-with-clean-registries
    (let* ((seen nil)
           (function (lambda (&rest _)
                       (setq seen t)))
           (session (benedict-session-create)))
      (setq-default benedict-run-start-functions function)
      (benedict-hook-run session 'benedict-run-start-functions)
      (should seen))))

(ert-deftest benedict-session-hook-order-is-global-then-local ()
  "Global hooks precede local hooks, regardless of their relative depths.

This locks the cross-scope contract: DEPTH orders functions within each
scope, but a global routing function at depth 90 still precedes a
session-local approval function at depth -90."
  (benedict-test-with-clean-registries
    (let* ((session (benedict-session-create))
           (seen nil)
           (global-approval (lambda (&rest _) (push 'global-approval seen)))
           (global-routing (lambda (&rest _) (push 'global-routing seen)))
           (local-observation (lambda (&rest _) (push 'local-observation seen)))
           (local-approval (lambda (&rest _) (push 'local-approval seen))))
      (add-hook 'benedict-run-start-functions global-routing 90)
      (add-hook 'benedict-run-start-functions global-approval 0)
      (benedict-session-add-hook session 'benedict-run-start-functions
                                 local-observation -90)
      (benedict-session-add-hook session 'benedict-run-start-functions
                                 local-approval 0)
      (benedict-hook-run session 'benedict-run-start-functions)
      (should (equal (nreverse seen)
                     '(global-approval global-routing
                       local-observation local-approval))))))

(ert-deftest benedict-session-global-hook-keeps-emacs-tie-and-registration-behavior ()
  "Global equal-depth ties retain Emacs ordering and named registration rules.

This locks the contract without claiming that global `add-hook' ties are
insertion-ordered: repeated named registration stays deduplicated, and the
observed equal-depth order remains the order supplied by Emacs."
  (benedict-test-with-clean-registries
    (add-hook 'benedict-run-start-functions
              #'benedict-session-test--global-tie-first 0)
    (add-hook 'benedict-run-start-functions
              #'benedict-session-test--global-tie-second 0)
    (add-hook 'benedict-run-start-functions
              #'benedict-session-test--global-tie-first 0)
    (let ((functions (benedict-session-hook-functions
                      nil 'benedict-run-start-functions)))
      (should (= (cl-count #'benedict-session-test--global-tie-first functions)
                 1))
      (should (= (cl-count #'benedict-session-test--global-tie-second functions)
                 1))
      (should (equal functions
                     (list #'benedict-session-test--global-tie-second
                           #'benedict-session-test--global-tie-first))))))

(ert-deftest benedict-session-local-equal-depth-is-insertion-ordered ()
  "Session-local equal depths preserve insertion order after sorting.

This locks the session scope's tie behavior independently of Emacs global
hook ties: named re-registration replaces and re-inserts rather than
duplicating the function."
  (benedict-test-with-clean-registries
    (let* ((session (benedict-session-create))
           (first #'benedict-session-test--local-tie-first)
           (second #'benedict-session-test--local-tie-second))
      (benedict-session-add-hook session 'benedict-run-start-functions first 0)
      (benedict-session-add-hook session 'benedict-run-start-functions second 0)
      (should (equal (benedict-session-local-hook-functions
                      session 'benedict-run-start-functions)
                     (list first second)))
      (benedict-session-add-hook session 'benedict-run-start-functions first 0)
      (should (equal (benedict-session-local-hook-functions
                      session 'benedict-run-start-functions)
                     (list second first))))))

(ert-deftest benedict-session-hooks-ignore-buffer-local-values ()
  "Hook collection uses the default global list, not the active buffer.

This locks buffer independence across deferred steps and the `t' marker
contract: a buffer-local hook value must neither run nor alter session hooks."
  (benedict-test-with-clean-registries
    (let* ((session (benedict-test-session
                     '(((:tool-call benedict-test-whoami nil)))))
           (seen nil)
           (global (lambda (invocation next)
                     (push 'global seen)
                     (funcall next invocation)))
           (local (lambda (invocation next)
                    (push 'local seen)
                    (funcall next invocation)))
           (buffer (generate-new-buffer " *benedict-hook-scope-test*")))
      (unwind-protect
          (progn
            (add-hook 'benedict-tool-dispatch-functions global)
            (benedict-session-add-hook
             session 'benedict-tool-dispatch-functions local)
            (benedict-test-with-manual-defer
              (benedict-session-submit session "go")
              ;; Open the stream before switching to a buffer carrying an
              ;; incidental local value; collection happens on a later tick.
              (should (benedict-test-step))
              (with-current-buffer buffer
                (setq-local benedict-tool-dispatch-functions
                            (list (lambda (&rest _)
                                    (error "buffer-local hook ran"))
                                  t))
                (should (benedict-test-step))
                (benedict-test-drain))
              (should (equal seen '(local global)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

;;;; Creation

(ert-deftest benedict-session-create-resolves-models-and-tools ()
  "A session resolves a model spec string and a list of tool ids."
  (benedict-test-with-clean-registries
    (benedict-deftool benedict-test-noop
      :description "Does nothing."
      :parameters nil
      :sync t
      :handler (lambda (_invocation) (benedict-tool-result :content "")))
    (let* ((script (benedict-provider-fake-script nil))
           (model (benedict-provider-fake-model script))
           (session (benedict-session-create :model "fake/fake-model"
                                             :tools '(benedict-test-noop))))
      (should (eq (benedict-session-model session) model))
      (should (eq (benedict-session-provider session) 'fake))
      (should (equal (mapcar #'benedict-tool-id (benedict-session-tool-list session))
                     '(benedict-test-noop)))
      (should (eq (benedict-session-state session) 'idle)))))

(ert-deftest benedict-session-create-accepts-a-separate-provider ()
  "A bare model id resolves when the provider is given alongside it."
  (benedict-test-with-clean-registries
    (benedict-provider-fake-model (benedict-provider-fake-script nil))
    (let ((session (benedict-session-create :provider 'fake :model "fake-model")))
      (should (equal (benedict-model-id (benedict-session-model session))
                     "fake-model")))))

(ert-deftest benedict-session-create-adopts-a-transcript ()
  "Adopting a transcript keeps its session id, so later ids stay consistent."
  (benedict-test-with-clean-registries
    (let* ((transcript (benedict-transcript-create :session-id "adopted"))
           (session (benedict-session-create :id "ignored" :transcript transcript)))
      (should (equal (benedict-session-id session) "adopted"))
      (should (eq (benedict-session-transcript session) transcript)))))

(ert-deftest benedict-session-submit-without-a-model-signals ()
  (benedict-test-with-clean-registries
    (let ((session (benedict-session-create)))
      (should-error (benedict-session-submit session "hi")
                    :type 'benedict-session-error))))

(ert-deftest benedict-session-unknown-tool-id-signals ()
  (benedict-test-with-clean-registries
    (should-error (benedict-session-create :tools '(benedict-test-absent))
                  :type 'benedict-tool-unknown)))

;;;; The tool selection

(defun benedict-session-test--deftool (id)
  "Register and return a do-nothing tool named ID."
  (benedict-tool-register
   (benedict-tool-create :id id :parameters nil :sync t
                         :handler (lambda (_invocation)
                                    (benedict-tool-result :content "")))))

(ert-deftest benedict-session-tool-list-resolves-a-list-per-call ()
  "A list selection is fixed, but its ids resolve fresh on every call.

The distinction is what makes reloading an extension file take effect in
a session created before the reload: the selection names which tools are
offered, not which structs."
  (benedict-test-with-clean-registries
    (benedict-session-test--deftool 'benedict-test-a)
    (let* ((session (benedict-session-create :tools '(benedict-test-a)))
           (first (car (benedict-session-tool-list session))))
      (should (eq first (benedict-tool-get 'benedict-test-a)))
      (let ((replacement (benedict-session-test--deftool 'benedict-test-a)))
        (should-not (eq first replacement))
        (should (eq (car (benedict-session-tool-list session)) replacement))))))

(ert-deftest benedict-session-tool-list-follows-a-function-selection ()
  "A function selection is called per resolution, so later registrations appear.

Asserted as a delta rather than against the whole registry, which also
holds whatever tools the image loaded -- `eval-elisp' among them."
  (benedict-test-with-clean-registries
    (benedict-session-test--deftool 'benedict-test-a)
    (let* ((session (benedict-session-create
                     :tools (lambda (_session) (benedict-tool-list))))
           (before (mapcar #'benedict-tool-id (benedict-session-tool-list session))))
      (should (memq 'benedict-test-a before))
      (should-not (memq 'benedict-test-b before))
      (benedict-session-test--deftool 'benedict-test-b)
      (let ((after (mapcar #'benedict-tool-id (benedict-session-tool-list session))))
        (should (memq 'benedict-test-b after))
        (should (equal (seq-difference after before) '(benedict-test-b)))))))

(ert-deftest benedict-session-tool-list-passes-the-session-to-a-selection ()
  "A selection function receives its session, so it can read session state."
  (benedict-test-with-clean-registries
    (benedict-session-test--deftool 'benedict-test-a)
    (let ((session (benedict-session-create
                    :tools (lambda (session)
                             (and (benedict-session-get session :allowed)
                                  '(benedict-test-a))))))
      (should-not (benedict-session-tool-list session))
      (benedict-session-put session :allowed t)
      (should (equal (mapcar #'benedict-tool-id (benedict-session-tool-list session))
                     '(benedict-test-a))))))

(ert-deftest benedict-session-tool-list-offers-an-unregistered-tool ()
  "A selection may carry a tool struct that was never registered.

This is the whole of session scoping: the registry is image-wide, so a
tool that must reach one session only stays out of it."
  (benedict-test-with-clean-registries
    (let* ((scoped (benedict-tool-create
                    :id 'benedict-test-scoped :parameters nil :sync t
                    :handler (lambda (_invocation) (benedict-tool-result :content ""))))
           (session (benedict-session-create :tools (list scoped))))
      (should (equal (benedict-session-tool-list session) (list scoped)))
      (should-not (benedict-tool-get 'benedict-test-scoped)))))

(ert-deftest benedict-session-tool-list-signals-for-an-id-that-went-away ()
  "Unregistering a selected tool signals rather than silently shortening the list."
  (benedict-test-with-clean-registries
    (benedict-session-test--deftool 'benedict-test-a)
    (let ((session (benedict-session-create :tools '(benedict-test-a))))
      (should (benedict-session-tool-list session))
      (benedict-tool-unregister 'benedict-test-a)
      (should-error (benedict-session-tool-list session)
                    :type 'benedict-tool-unknown))))

(ert-deftest benedict-session-create-does-not-call-a-selection-function ()
  "A function selection is not validated at creation; there is no session yet."
  (benedict-test-with-clean-registries
    (let ((called nil))
      (benedict-session-create :tools (lambda (_session) (setq called t) nil))
      (should-not called))))

;;;; Transcript delegation and forking

(ert-deftest benedict-session-fork-announces-the-head-move ()
  "`benedict-session-fork' runs the head-change hook; appending does not."
  (benedict-test-with-clean-registries
    (let ((session (benedict-session-create))
          (moves nil))
      (benedict-session-add-hook
       session 'benedict-head-change-functions
       (lambda (_session old new) (push (cons old new) moves)))
      (let ((a (benedict-session-append session (benedict-test-entry 'user "a")))
            (b (benedict-session-append session (benedict-test-entry 'user "b"))))
        (should (null moves))
        (should (equal (benedict-session-head session) (benedict-entry-id b)))
        (benedict-session-fork session (benedict-entry-id a))
        (should (equal moves (list (cons (benedict-entry-id b)
                                         (benedict-entry-id a)))))
        ;; Forking to where head already is announces nothing.
        (benedict-session-fork session (benedict-entry-id a))
        (should (equal (length moves) 1))
        (let ((c (benedict-session-append session (benedict-test-entry 'user "c"))))
          (should (equal (mapcar #'benedict-entry-id
                                 (benedict-session-children
                                  session (benedict-entry-id a)))
                         (list (benedict-entry-id b) (benedict-entry-id c))))
          (should (equal (mapcar #'benedict-entry-text
                                 (benedict-session-path session))
                         '("a" "c"))))))))

(ert-deftest benedict-session-fork-and-resume-branches-the-transcript ()
  "Forking then submitting nil resumes from the fork without a new message."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "first")) ((:text "second"))))))
        (benedict-session-submit session "hello")
        (benedict-test-drain)
        (let ((fork-point (benedict-entry-id (nth 0 (benedict-session-path session)))))
          (should (equal (mapcar #'benedict-entry-text
                                 (benedict-session-path session))
                         '("hello" "first")))
          (benedict-session-fork session fork-point)
          (benedict-session-submit session nil)
          (benedict-test-drain)
          (should (equal (mapcar #'benedict-entry-text
                                 (benedict-session-path session))
                         '("hello" "second")))
          ;; Both answers are still in the tree, and both are reachable.
          (should (equal (length (benedict-session-children session fork-point)) 2))
          (should (equal (length (benedict-session-entries session)) 3)))))))

;;;; Queues

(ert-deftest benedict-session-steering-drains-one-message-per-boundary ()
  "The default drain mode injects a single queued message at a time."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "1")) ((:text "2")) ((:text "3"))))))
        (benedict-session-steer session "second")
        (benedict-session-steer session "third")
        (benedict-session-submit session "first")
        (benedict-test-drain)
        (should (equal (mapcar #'benedict-entry-text (benedict-session-path session))
                       '("first" "1" "second" "2" "third" "3")))))))

(ert-deftest benedict-session-drain-mode-all-injects-everything ()
  "`all' puts every queued message in at one boundary, for scripted use."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((benedict-queue-drain-mode 'all)
            (session (benedict-test-session '(((:text "1")) ((:text "2"))))))
        (benedict-session-steer session "second")
        (benedict-session-steer session "third")
        (benedict-session-submit session "first")
        (benedict-test-drain)
        (should (equal (mapcar #'benedict-entry-text (benedict-session-path session))
                       '("first" "1" "second" "third" "2")))))))

(ert-deftest benedict-session-steering-drains-before-follow-ups ()
  "Steering is taken first; a follow-up waits for the next boundary."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "1")) ((:text "2")) ((:text "3"))))))
        (benedict-session-follow-up session "later")
        (benedict-session-steer session "sooner")
        (benedict-session-submit session "first")
        (benedict-test-drain)
        (should (equal (mapcar #'benedict-entry-text (benedict-session-path session))
                       '("first" "1" "sooner" "2" "later" "3")))))))

(ert-deftest benedict-session-queued-message-outranks-a-veto ()
  "A predicate veto stops the model's own momentum, not a human's message."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "1")) ((:text "2"))))))
        (benedict-session-add-hook session 'benedict-continue-predicate-functions
                                   (lambda (_session) 'enough))
        (benedict-session-follow-up session "one more thing")
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (should (equal (mapcar #'benedict-entry-text (benedict-session-path session))
                       '("hi" "1" "one more thing" "2")))
        (should (eq (benedict-session-state session) 'idle))))))

(ert-deftest benedict-session-submit-during-a-run-steers ()
  "Submitting while busy queues rather than starting a second run."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "1")) ((:text "2"))))))
        (benedict-session-submit session "first")
        (should (benedict-test-run-until
                 (lambda () (benedict-session-streaming-entry session))))
        (should (eq (benedict-session-submit session "interrupting") 'steered))
        (benedict-test-drain)
        (should (equal (mapcar #'benedict-entry-text (benedict-session-path session))
                       '("first" "1" "interrupting" "2")))))))

;;;; Properties

(ert-deftest benedict-session-properties-round-trip ()
  (benedict-test-with-clean-registries
    (let ((session (benedict-session-create)))
      (should (eq (benedict-session-get session :missing 'fallback) 'fallback))
      (benedict-session-put session :trusted t)
      (should (eq (benedict-session-get session :trusted) t))
      (benedict-session-put session :trusted nil)
      (should (null (benedict-session-get session :trusted 'fallback)))
      ;; A nil session is the case a global hook hits outside any run.
      (should (eq (benedict-session-get nil :trusted 'fallback) 'fallback)))))

;;;; Helpers

(defun benedict-session-test--results (session)
  "Return the content of each tool-result entry on SESSION's path."
  (mapcar (lambda (entry) (plist-get (car (benedict-entry-content entry)) :content))
          (seq-filter #'benedict-entry-tool-result-p
                      (benedict-session-path session))))

(provide 'benedict-session-test)

;;; benedict-session-test.el ends here
