;;; benedict-core-test.el --- The reducer  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 14 Phase 2 exits on a multi-turn run with tool calls, driven
;; entirely by the fake provider, with assertions on the state transition
;; sequence.  That is `benedict-core-multi-turn-run-with-tool-calls'; the rest
;; of this file covers the pieces it depends on.
;;
;; Every test here runs with the reducer stepped by hand, so nothing depends on
;; a timer firing and a stuck machine fails with a step count rather than a
;; hang.

;;; Code:

(require 'ert)
(require 'test-helper)

(defun benedict-core-test--echo-tool ()
  "Register and return a synchronous tool that echoes its argument."
  (benedict-deftool benedict-test-echo
    :description "Echo the text given to it."
    :parameters '((text :type string :required t :description "Text to echo."))
    :sync t
    :handler (lambda (invocation)
               (benedict-tool-result
                :content (benedict-tool-arg invocation :text)))))

;;;; Exit criterion: a multi-turn run with tool calls

(ert-deftest benedict-core-multi-turn-run-with-tool-calls ()
  "A scripted run spanning three turns produces the specified transitions."
  (benedict-test-with-clean-registries
    (benedict-core-test--echo-tool)
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session
                       '(((:text "Let me check."))
                         ((:tool-call benedict-test-echo (:text "pong")))
                         ((:text "It said pong.")))
                       :tools '(benedict-test-echo)))
             (states (benedict-test-record-states session))
             ;; A text-only turn stops by default, so the run only spans three
             ;; turns because a follow-up keeps it alive past the first.
             (_ (benedict-session-follow-up session "Now call the tool.")))
        (benedict-session-submit session "Hello")
        (benedict-test-drain)

        (should (eq (benedict-session-state session) 'idle))
        ;; Turn 2 begins without a transition of its own: the run never left
        ;; `provider-wait' after turn 1, and a no-op move is not announced.
        ;; Turn boundaries are what the turn hooks are for.
        (should (equal (benedict-test-states states)
                       '(provider-wait          ; turn 1: text only
                         tool-dispatch          ; turn 2: the model asked for a tool
                         tool-wait
                         tool-dispatch          ; result appended, nothing left
                         provider-wait          ; turn 3: the model sees it
                         idle)))
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant user assistant tool-result assistant)))))))

(ert-deftest benedict-core-tool-result-is-its-own-entry ()
  "Each completed tool call appends an entry of its own, in call order."
  (benedict-test-with-clean-registries
    (benedict-core-test--echo-tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-echo (:text "first") :id "a")
                         (:tool-call benedict-test-echo (:text "second") :id "b"))
                        ((:text "Both done.")))
                      :tools '(benedict-test-echo))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant tool-result tool-result assistant)))
        (let ((results (seq-filter #'benedict-entry-tool-result-p
                                   (benedict-session-path session))))
          (should (equal (mapcar (lambda (entry)
                                   (plist-get (car (benedict-entry-content entry))
                                              :content))
                                 results)
                         '("first" "second")))
          (should (equal (mapcar (lambda (entry)
                                   (plist-get (car (benedict-entry-content entry)) :id))
                                 results)
                         '("a" "b"))))))))

(ert-deftest benedict-core-assistant-entries-record-their-origin ()
  "Every assistant entry names the provider, API, and model that produced it."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "hi"))))))
        (benedict-session-submit session "hello")
        (benedict-test-drain)
        (let ((entry (car (last (benedict-session-path session)))))
          (should (benedict-entry-assistant-p entry))
          (should (equal (benedict-entry-origin entry)
                         '(:provider fake :api fake :model "fake-model")))
          (should (eq (benedict-entry-meta-get entry :stop-reason) 'stop)))))))

(ert-deftest benedict-core-runs-on-real-timers-too ()
  "The default deferral works, not just the queue every other test binds.

Every other test here steps the reducer by hand, which is what makes the
transition assertions deterministic -- and would also hide a broken
`benedict-core-defer-function' default from the entire suite.  This one
runs the machine the way it actually runs, on `run-at-time'."
  (benedict-test-with-clean-registries
    (benedict-core-test--echo-tool)
    (let ((session (benedict-test-session
                    '(((:tool-call benedict-test-echo (:text "pong")))
                      ((:text "It said pong.")))
                    :tools '(benedict-test-echo)))
          (deadline (+ (float-time) 5)))
      (should (eq benedict-core-defer-function #'benedict-core--defer-with-timer))
      (benedict-session-submit session "ping")
      (while (and (not (eq (benedict-session-state session) 'idle))
                  (< (float-time) deadline))
        (sit-for 0.001))
      (should (eq (benedict-session-state session) 'idle))
      (should (equal (benedict-test-entry-roles session)
                     '(user assistant tool-result assistant))))))

;;;; Streaming

(ert-deftest benedict-core-streaming-entry-accumulates-in-place ()
  "Deltas mutate the streaming entry, which has no id until it is appended."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      ;; Raw events rather than the script sugar, so the deltas arrive one
      ;; step at a time and the partial entry can be inspected between them.
      (let* ((session (benedict-test-session
                       '(((:type :start)
                          (:type :block-start :index 0 :block-type text)
                          (:type :block-delta :index 0 :delta "Hel")
                          (:type :block-delta :index 0 :delta "lo")
                          (:type :block-end :index 0)
                          (:type :done :reason stop)))))
             (seen nil)
             (started nil))
        (benedict-session-add-hook session 'benedict-entry-start-functions
                                  (lambda (_session entry) (push entry started)))
        (benedict-session-add-hook
         session 'benedict-entry-update-functions
         (lambda (_session entry index delta)
           (push (list index delta (benedict-entry-text entry)) seen)))
        (benedict-session-submit session "hi")
        (should (benedict-test-run-until
                 (lambda ()
                   (when-let* ((partial (benedict-session-streaming-entry session)))
                     (equal (benedict-entry-text partial) "Hel")))))
        ;; Mid-stream: the entry exists, has content, and has no id yet.
        (let ((partial (benedict-session-streaming-entry session)))
          (should partial)
          (should (null (benedict-entry-id partial)))
          (should (equal (benedict-entry-text partial) "Hel"))
          (should (memq partial started)))
        (benedict-test-drain)
        (let ((entry (car (last (benedict-session-path session)))))
          (should (benedict-entry-id entry))
          (should (equal (benedict-entry-text entry) "Hello")))
        (should (equal (reverse (mapcar #'cadr seen)) '("" "Hel" "lo" "")))))))

(ert-deftest benedict-core-thinking-blocks-keep-their-signature ()
  "A reasoning block's provider-opaque signature survives to the transcript."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:thinking "weighing options" :signature "sig-1")
                         (:text "Done."))))))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (let* ((entry (car (last (benedict-session-path session))))
               (thinking (car (benedict-blocks-of-type
                               (benedict-entry-content entry) 'thinking))))
          (should (equal (plist-get thinking :thinking) "weighing options"))
          (should (equal (plist-get thinking :signature) "sig-1"))
          (should (equal (benedict-entry-text entry) "Done.")))))))

(ert-deftest benedict-core-tool-call-arguments-are-parsed-not-raw ()
  "A tool-call block carries decoded arguments and no scratch JSON."
  (benedict-test-with-clean-registries
    (benedict-core-test--echo-tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-echo (:text "hi")))
                        ((:text "done")))
                      :tools '(benedict-test-echo))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (let* ((entry (nth 1 (benedict-session-path session)))
               (call (car (benedict-entry-tool-calls entry))))
          (should (equal (plist-get call :arguments) '(:text "hi")))
          (should-not (plist-member call :arguments-json)))))))

;;;; Stream failure

(ert-deftest benedict-core-stream-error-still-produces-an-entry ()
  "A failed stream ends the run and leaves a terminal entry behind."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "partial")
                         (:error :reason error :message "upstream exploded"))))))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (let ((entry (car (last (benedict-session-path session)))))
          (should (benedict-entry-assistant-p entry))
          (should (equal (benedict-entry-text entry) "partial"))
          (should (eq (benedict-entry-meta-get entry :stop-reason) 'error))
          (should (equal (benedict-entry-meta-get entry :error-message)
                         "upstream exploded")))))))

(ert-deftest benedict-core-stores-error-data-on-the-terminal-entry ()
  "The reducer persists opaque safe metadata without interpreting it."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:error :reason error :message "busy"
                                  :error-data (:benedict-retry-http
                                               (:transient t :retry-after 3))))))))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (should (equal
                 (benedict-entry-meta-get
                  (car (last (benedict-session-path session))) :error-data)
                 '(:benedict-retry-http (:transient t :retry-after 3))))))))

(ert-deftest benedict-core-a-signalling-filter-does-not-wedge-the-session ()
  "A broken extension ends the run with a reason and preserves its condition."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "unreachable"))))))
        (benedict-session-add-hook session 'benedict-context-filter-functions
                                   (lambda (_entries _session)
                                     (error "Filter is broken")))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (should (equal (benedict-session-last-error session)
                       '(error "Filter is broken")))
        (let ((entry (car (last (benedict-session-path session)))))
          (should (benedict-entry-assistant-p entry))
          (should (string-match-p "Filter is broken"
                                  (benedict-entry-meta-get entry :error-message))))))))

(ert-deftest benedict-core-entry-observer-failure-stops-terminally ()
  "A durability observer failure stops once and preserves the first condition."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "answer")))))
            (terminal-observers 0))
        (benedict-session-add-hook
         session 'benedict-entry-end-functions
         (lambda (_session entry)
           (when (benedict-entry-assistant-p entry)
             (error "durability failed"))))
        (benedict-session-add-hook
         session 'benedict-run-end-functions
         (lambda (_session) (error "first terminal observer failed")))
        (benedict-session-add-hook
         session 'benedict-run-end-functions
         (lambda (_session) (cl-incf terminal-observers)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (should (equal (benedict-session-last-error session)
                       '(error "durability failed")))
        (should (= terminal-observers 1))))))

(ert-deftest benedict-core-run-start-resubmission-queues-steering ()
  "A run-start resubmission does not replace or recursively start the run."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "first")) ((:text "second")))))
            (starts 0))
        (benedict-session-add-hook
         session 'benedict-run-start-functions
         (lambda (current)
           (cl-incf starts)
           (when (= starts 1)
             (benedict-session-submit current "queued"))))
        (benedict-session-submit session "initial")
        (benedict-test-drain)
        (should (= starts 1))
        (should (eq (benedict-session-state session) 'idle))
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant user assistant)))))))

(ert-deftest benedict-core-run-start-abort-prevents-provider-dispatch ()
  "Aborting from run-start prevents the provider request from opening."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session '(((:text "never")))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session))))
        (benedict-session-add-hook
         session 'benedict-run-start-functions
         (lambda (current) (benedict-session-abort current)))
        (benedict-session-submit session "initial")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (null (benedict-provider-fake-requests script)))
        (should (eq (benedict-session-stop-reason session) 'aborted))))))

(ert-deftest benedict-core-context-filter-abort-prevents-provider-dispatch ()
  "Aborting from a context filter prevents the provider request from opening."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session '(((:text "never")))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session))))
        (benedict-session-add-hook
         session 'benedict-context-filter-functions
         (lambda (entries current)
           (benedict-session-abort current)
           entries))
        (benedict-session-submit session "initial")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (null (benedict-provider-fake-requests script)))
        (should (eq (benedict-session-stop-reason session) 'aborted))))))

(ert-deftest benedict-core-run-end-observers-continue-after-failure ()
  "A failing run-end observer does not suppress later terminal observers."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "done")))))
            (later 0))
        (benedict-session-add-hook
         session 'benedict-run-end-functions
         (lambda (_session) (error "run-end failed")))
        (benedict-session-add-hook
         session 'benedict-run-end-functions
         (lambda (_session) (cl-incf later)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (should (equal (benedict-session-last-error session)
                       '(error "run-end failed")))
        (should (= later 1))))))

(ert-deftest benedict-core-run-start-observer-failure-is-terminal ()
  "A run-start observer failure stops the run and preserves its condition."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "never")))))
            (requests 0))
        (benedict-session-add-hook
         session 'benedict-run-start-functions
         (lambda (_session) (error "run-start failed")))
        (benedict-session-add-hook
         session 'benedict-entry-start-functions
         (lambda (_session entry)
           (when (benedict-entry-assistant-p entry)
             (cl-incf requests))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (should (equal (benedict-session-last-error session)
                       '(error "run-start failed")))
        (should (= requests 0))))))
(ert-deftest benedict-core-a-missing-transport-ends-the-run ()
  "A provider with no way to send ends the run instead of signalling out."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (unwind-protect
          (progn
            (benedict-defprovider benedict-test-mute :name "Mute" :api 'nowhere)
            (let* ((model (benedict-model-create :id "m" :provider 'benedict-test-mute
                                                 :api 'nowhere))
                   (session (benedict-session-create :model model)))
              (benedict-session-submit session "hi")
              (benedict-test-drain)
              (should (eq (benedict-session-state session) 'idle))
              (should (eq (benedict-session-stop-reason session) 'error))))
        (benedict-provider-unregister 'benedict-test-mute)))))

(ert-deftest benedict-core-exhausted-script-fails-loudly ()
  "An unscripted extra request is an error event, not a silent stop."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session nil)))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (should (eq (benedict-session-stop-reason session) 'error))))))

;;;; Turn and run hooks

(ert-deftest benedict-core-turn-end-carries-the-entry-and-results ()
  "`benedict-turn-end-functions' sees the assistant entry and its results."
  (benedict-test-with-clean-registries
    (benedict-core-test--echo-tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-echo (:text "x")))
                        ((:text "fin")))
                      :tools '(benedict-test-echo)))
            (turns nil))
        (benedict-session-add-hook
         session 'benedict-turn-end-functions
         (lambda (_session entry results)
           (push (cons (benedict-entry-role entry)
                       (mapcar #'benedict-tool-result-value-content results))
                 turns)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (reverse turns)
                       '((assistant . ("x"))
                         (assistant . nil))))))))

(ert-deftest benedict-core-turn-end-observers-continue-after-first-signals ()
  "A signalling turn-end observer does not suppress later observers."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "done")))))
            (later 0))
        (benedict-session-add-hook
         session 'benedict-turn-end-functions
         (lambda (&rest _) (error "first turn-end failed")))
        (benedict-session-add-hook
         session 'benedict-turn-end-functions
         (lambda (&rest _) (cl-incf later)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (should (equal (benedict-session-last-error session)
                       '(error "first turn-end failed")))
        (should (= later 1))))))
(ert-deftest benedict-core-run-hooks-bracket-the-whole-run ()
  "Run start and end fire once each, around every turn."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "a")))))
            (events nil))
        (benedict-session-add-hook session 'benedict-run-start-functions
                                   (lambda (_s) (push 'run-start events)))
        (benedict-session-add-hook session 'benedict-run-end-functions
                                   (lambda (_s) (push 'run-end events)))
        (benedict-session-add-hook session 'benedict-turn-start-functions
                                   (lambda (_s) (push 'turn-start events)))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (should (equal (reverse events) '(run-start turn-start run-end)))))))

(ert-deftest benedict-core-state-transition-failure-is-terminal ()
  "A provider-wait observer failure cannot wedge the active run."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "never")))))
            (requests 0))
        (benedict-session-add-hook
         session 'benedict-state-change-functions
         (lambda (_session old new)
           (when (and (eq old 'idle) (eq new 'provider-wait))
             (error "transition failed"))))
        (benedict-session-add-hook
         session 'benedict-entry-start-functions
         (lambda (_session entry)
           (when (benedict-entry-assistant-p entry)
             (cl-incf requests))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'error))
        (should (equal (benedict-session-last-error session)
                       '(error "transition failed")))
        (should (= requests 0))))))

(ert-deftest benedict-core-failure-cleanup-attempts-turn-end-once ()
  "Failure cleanup closes a started turn before ending its run."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "never")))))
            (turn-ends 0))
        (benedict-session-add-hook
         session 'benedict-turn-start-functions
         (lambda (_session) (error "turn start failed")))
        (benedict-session-add-hook
         session 'benedict-turn-end-functions
         (lambda (&rest _) (cl-incf turn-ends)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (= turn-ends 1))
        (should (equal (benedict-session-last-error session)
                       '(error "turn start failed")))))))

(ert-deftest benedict-core-persistence-failure-stops-tool-follow-up-work ()
  "Durability failure stops later provider work and is visible to run-end."
  (benedict-test-with-clean-registries
    (let ((tool-runs 0)
          (observed-error nil))
      (benedict-deftool benedict-test-persist-tool
        :description "Counts tool work." :parameters nil :sync t
        :handler (lambda (_invocation)
                   (cl-incf tool-runs)
                   (benedict-tool-result :content "tool done")))
      (benedict-test-with-manual-defer
        (let* ((session (benedict-test-session
                         '(((:tool-call benedict-test-persist-tool nil))
                           ((:text "next turn")))
                         :tools '(benedict-test-persist-tool)))
               (script (benedict-provider-fake-script-of
                        (benedict-session-model session))))
          (benedict-session-add-hook
           session 'benedict-entry-end-functions
           (lambda (_session entry)
             (when (benedict-entry-tool-result-p entry)
               (error "persistence failed"))))
          (benedict-session-add-hook
           session 'benedict-run-end-functions
           (lambda (current)
             (setq observed-error (benedict-session-last-error current))))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (should (eq (benedict-session-state session) 'idle))
          (should (equal observed-error '(error "persistence failed")))
          (should (= tool-runs 1))
          (should (= (length (benedict-provider-fake-requests script)) 1)))))))

(ert-deftest benedict-core-secondary-persistence-failure-is-visible ()
  "A terminal append failure is visible without replacing the primary error."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "partial")))))
            (warnings nil))
        (benedict-session-add-hook
         session 'benedict-entry-update-functions
         (lambda (&rest _) (error "primary stream observer failed")))
        (benedict-session-add-hook
         session 'benedict-entry-end-functions
         (lambda (_session entry)
           (when (benedict-entry-assistant-p entry)
             (error "terminal append failed"))))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _)
                     (push message warnings))))
          (benedict-session-submit session "go")
          (benedict-test-drain))
        (should (equal (benedict-session-last-error session)
                       '(error "primary stream observer failed")))
        (should (seq-some (lambda (message)
                            (string-match-p "terminal append failed" message))
                          warnings))))))

(ert-deftest benedict-core-failure-retains-queued-input ()
  "Failure cleanup does not silently drain steering or follow-up queues."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session '(((:text "never")))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session))))
        (benedict-session-add-hook
         session 'benedict-request-filter-functions
         (lambda (_request _model _session)
           (error "request persistence boundary failed")))
        (benedict-session-submit session "go")
        (benedict-session-steer session "queued steering")
        (benedict-session-follow-up session "queued follow-up")
        (let ((steer (copy-tree (benedict-session-steer-queue session)))
              (follow (copy-tree (benedict-session-follow-up-queue session))))
          (benedict-test-drain)
          (should (= (length (benedict-provider-fake-requests script)) 0))
          (should (equal (benedict-session-steer-queue session) steer))
          (should (equal (benedict-session-follow-up-queue session) follow))
          (should (eq (benedict-session-state session) 'idle)))))))

(ert-deftest benedict-core-run-end-resubmission-starts-after-ending-run ()
  "A run-end resubmission starts only after the ending run is cleared."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "done")) ((:text "second")))))
            (requests 0)
            (ends 0)
            (submit-result nil))
        (benedict-session-add-hook
         session 'benedict-entry-start-functions
         (lambda (_session entry)
           (when (benedict-entry-assistant-p entry)
             (cl-incf requests))))
        (benedict-session-add-hook
         session 'benedict-run-end-functions
         (lambda (current)
           (cl-incf ends)
           (when (= ends 1)
             (setq submit-result
                   (benedict-session-submit current "reentrant")))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq submit-result 'steered))
        (should (= ends 2))
        (should (= requests 2))
        (should (null (benedict-session-steer-queue session)))
        (should (eq (benedict-session-state session) 'idle))))))

(ert-deftest benedict-core-idle-restart-is-owned-by-its-session ()
  "Another session cannot invalidate a clean run's queued-input restart."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session-a (benedict-test-session
                         '(((:text "A done")) ((:text "A restarted")))))
             (script-a (benedict-provider-fake-script-of
                        (benedict-session-model session-a)))
             (session-b (benedict-test-session '(((:text "B waiting")))))
             (script-b (benedict-provider-fake-script-of
                        (benedict-session-model session-b)))
             (resubmit
              (lambda (current)
                (benedict-session-submit current "queued by A"))))
        (benedict-session-add-hook
         session-a 'benedict-run-end-functions resubmit)
        (benedict-session-submit session-a "A")
        (should
         (benedict-test-run-until
          (lambda ()
            (and (eq (benedict-session-state session-a) 'idle)
                 benedict-test-defer-queue))))
        (let ((idle-restart (pop benedict-test-defer-queue)))
          (benedict-session-remove-hook
           session-a 'benedict-run-end-functions resubmit)
          (benedict-session-submit session-b "B")
          (should
           (benedict-test-run-until
            (lambda ()
              (= (length (benedict-provider-fake-requests script-b)) 1))))
          (should (= (length (benedict-provider-fake-requests script-a)) 1))
          (funcall idle-restart)
          (benedict-test-drain)
          (let* ((requests (benedict-provider-fake-requests script-a))
                 (entries (plist-get (cadr requests) :entries)))
            (should (= (length requests) 2))
            (should
             (seq-some
              (lambda (entry)
                (and (benedict-entry-user-p entry)
                     (equal (benedict-entry-text entry) "queued by A")))
              entries))))))))

(ert-deftest benedict-core-stale-idle-thunk-cannot-revive-after-later-failure ()
  "Run A's idle advance cannot restart input retained by failed run B."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session
                       '(((:text "A done")) ((:text "must not open")))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session)))
             (run-end-resubmit
              (lambda (current)
                (benedict-session-submit current "queued by A")))
             (fail-request
              (lambda (_request _model _session)
                (error "run B failed"))))
        (benedict-session-add-hook
         session 'benedict-run-end-functions run-end-resubmit)
        (benedict-session-submit session "A")
        (should
         (benedict-test-run-until
          (lambda ()
            (and (eq (benedict-session-state session) 'idle)
                 benedict-test-defer-queue))))
        (let ((stale-idle-thunk (pop benedict-test-defer-queue)))
          (benedict-session-remove-hook
           session 'benedict-run-end-functions run-end-resubmit)
          (benedict-session-add-hook
           session 'benedict-request-filter-functions fail-request)
          (benedict-session-submit session "B")
          (benedict-session-steer session "retained after B")
          (benedict-test-drain)
          (let ((requests (length (benedict-provider-fake-requests script)))
                (steer (copy-tree (benedict-session-steer-queue session)))
                (error (copy-tree (benedict-session-last-error session))))
            (benedict-session-remove-hook
             session 'benedict-request-filter-functions fail-request)
            (funcall stale-idle-thunk)
            (benedict-test-drain)
            (should (= (length (benedict-provider-fake-requests script))
                       requests))
            (should (equal (benedict-session-steer-queue session) steer))
            (should (equal (benedict-session-last-error session) error))
            (should (null (benedict-session-run session)))
            (should (eq (benedict-session-state session) 'idle))))))))


(ert-deftest benedict-core-abort-from-run-end-observer-is-a-no-op ()
  "Aborting during terminal notification cannot wedge the ended session."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session '(((:text "done")))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session)))
             (ends 0)
             (abort-result nil))
        (benedict-session-add-hook
         session 'benedict-run-end-functions
         (lambda (current)
           (cl-incf ends)
           (setq abort-result (benedict-session-abort current))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq abort-result 'idle))
        (should (= ends 1))
        (should (= (length (benedict-provider-fake-requests script)) 1))
        (should (null benedict-test-defer-queue))
        (should (null (benedict-session-run session)))
        (should (eq (benedict-session-state session) 'idle))))))

(ert-deftest benedict-core-idle-observer-abort-cannot-wedge-session ()
  "Aborting from the idle transition observer leaves the session idle."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "done")) ((:text "second")))))
            (abort-result nil))
        (benedict-session-add-hook
         session 'benedict-state-change-functions
         (lambda (current _old new)
           (when (eq new 'idle)
             (setq abort-result (benedict-session-abort current)))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq abort-result 'idle))
        (should (eq (benedict-session-state session) 'idle))
        (should (null (benedict-session-run session)))
        (should (null benedict-test-defer-queue))
        (benedict-session-submit session "again")
        (benedict-test-drain)
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant user assistant)))))))

;;;; Notes

(ert-deftest benedict-session-note-appends-and-announces ()
  "A note reaches the transcript AND both entry hooks.

The second half is the whole point of the function: `benedict-session-append'
moves the tree and fires nothing, so an entry written through it is
invisible to the store and to every renderer."
  (benedict-test-with-clean-registries
    (let ((session (benedict-session-create))
          (started nil)
          (ended nil))
      (benedict-session-add-hook session 'benedict-entry-start-functions
                                 (lambda (_session entry) (push entry started)))
      (benedict-session-add-hook session 'benedict-entry-end-functions
                                 (lambda (_session entry) (push entry ended)))
      (let ((entry (benedict-session-note session "the image was extended")))
        (should (eq (benedict-entry-role entry) 'note))
        (should (equal started (list entry)))
        (should (equal ended (list entry)))
        (should (eq (benedict-session-entry session (benedict-entry-id entry)) entry))
        (should (equal (benedict-session-head session) (benedict-entry-id entry)))))))

(ert-deftest benedict-session-note-written-from-a-tool-lands-before-the-result ()
  "A note written mid-call sits between the call and the result answering it.

This is the placement a renderer has to cope with, and it is deliberate:
recording when the image changed beats waiting for a tidy turn boundary.
It is also the shape of the intended use -- a tool that modified the
running image saying so, from inside the call that did it."
  (benedict-test-with-clean-registries
    (benedict-deftool benedict-test-noting
      :description "Write a note, then answer."
      :parameters nil
      :sync t
      :handler (lambda (_invocation)
                 (benedict-session-note benedict-current-session "(setq x 1)")
                 (benedict-tool-result :content "done")))
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-noting nil))
                        ((:text "ok")))
                      :tools '(benedict-test-noting))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant note tool-result assistant)))))))

;;;; Context and request filters

(ert-deftest benedict-core-notes-are-out-of-context-unless-flagged ()
  "A plain note is withheld from the provider; a `:context' note is sent."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "ok"))))))
        (benedict-session-note session "internal only")
        (benedict-session-note session "remember ISO dates" '(:context t))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (let* ((script (benedict-provider-fake-script-of
                        (benedict-session-model session)))
               (entries (plist-get (benedict-provider-fake-last-request script)
                                   :entries)))
          (should (equal (mapcar #'benedict-entry-text entries)
                         '("remember ISO dates" "hi"))))))))

(ert-deftest benedict-core-request-filter-can-rewrite-the-request ()
  "`benedict-request-filter-functions' sees and replaces the request plist."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "ok")))
                                            :system-prompt "original")))
        (benedict-session-add-hook
         session 'benedict-request-filter-functions
         (lambda (request _model _session)
           (plist-put (copy-sequence request) :system-prompt "rewritten")))
        (benedict-session-submit session "hi")
        (benedict-test-drain)
        (let ((script (benedict-provider-fake-script-of
                       (benedict-session-model session))))
          (should (equal (plist-get (benedict-provider-fake-last-request script)
                                    :system-prompt)
                         "rewritten")))))))

(ert-deftest benedict-core-request-filter-replaces-model-and-tools-authoritatively ()
  "A final request's model and tools drive transport, origin, and execution."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((ran nil)
             (tool (benedict-tool-create
                    :id 'benedict-test-filter-tool :sync t
                    :parameters '((value :type string))
                    :handler (lambda (_invocation)
                               (setq ran t)
                               (benedict-tool-result :content "filtered"))))
             (model (benedict-provider-fake-model
                     (benedict-provider-fake-script
                      '(((:tool-call benedict-test-filter-tool (:value "x")))
                        ((:text "done"))))
                     :id "filtered-model"))
             (session (benedict-test-session '(((:text "unused")))))
             (script (benedict-provider-fake-script-of model)))
        (benedict-session-add-hook
         session 'benedict-request-filter-functions
         (lambda (request _model _session)
           (plist-put (plist-put (copy-sequence request)
                                 :model model)
                      :tools (list tool))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should ran)
        (should (equal (benedict-entry-origin
                        (nth 1 (benedict-session-path session)))
                       '(:provider fake :api fake :model "filtered-model")))
        (let ((request (benedict-provider-fake-last-request script)))
          (should (eq (plist-get request :model) model))
          (should (eq (car (plist-get request :tools)) tool))
          (let ((schema (benedict-tool-schema (car (plist-get request :tools)))))
            (should (equal (plist-get schema :type) "object"))
            (should (equal (plist-get schema :properties)
                           '(:value (:type "string"))))))))))
(ert-deftest benedict-core-veto-run-end-resubmission-restarts ()
  "Queued input after a clean vetoed run is not stranded."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session
                       '(((:text "first")) ((:text "second")))))
             (starts 0)
             (ends 0)
             (submit-result nil))
        (benedict-session-add-hook
         session 'benedict-continue-predicate-functions
         (lambda (_session) 'budget-exhausted))
        (benedict-session-add-hook
         session 'benedict-run-start-functions
         (lambda (_session) (cl-incf starts)))
        (benedict-session-add-hook
         session 'benedict-run-end-functions
         (lambda (current)
           (cl-incf ends)
           (when (= ends 1)
             (setq submit-result
                   (benedict-session-submit current "queued after veto")))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq submit-result 'steered))
        (should (= starts 2))
        (should (= ends 2))
        (should (null (benedict-session-steer-queue session)))
        (should (eq (benedict-session-state session) 'idle))))))

;;;; The continue predicate

(ert-deftest benedict-core-continue-predicate-stops-a-tool-loop ()
  "A veto stops the run at the next boundary and records its reason."
  (benedict-test-with-clean-registries
    (benedict-core-test--echo-tool)
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-echo (:text "x")))
                        ((:text "never reached")))
                      :tools '(benedict-test-echo))))
        (benedict-session-add-hook session 'benedict-continue-predicate-functions
                                   (lambda (_session) 'budget-exhausted))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'budget-exhausted))
        ;; The tool ran and its result is history; the run simply stopped there.
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant tool-result)))))))

(ert-deftest benedict-core-rejects-malformed-filtered-request-before-provider ()
  "A malformed filtered model becomes a visible failed attempt."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "never"))))))
        (benedict-session-add-hook
         session 'benedict-request-filter-functions
         (lambda (request _model _session)
           (plist-put (copy-sequence request) :model nil)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-entry-meta-get
                     (nth 1 (benedict-session-path session)) :stop-reason)
                    'error))
        (should-not (benedict-provider-fake-last-request
                     (benedict-provider-fake-script-of
                      (benedict-session-model session))))))))

(ert-deftest benedict-core-rejects-invalid-session-and-tools-before-provider ()
  "Invalid session and tool fields become visible failures without transport."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (dolist (case '((:session . bad-session)
                      (:tools . ("not-a-tool"))
                      (:tools . "not-a-tool")
                      (:tools . (not-a-tool))))
        (let* ((session (benedict-test-session '(((:text "never")))))
               (script (benedict-provider-fake-script-of
                        (benedict-session-model session)))
               (key (car case))
               (value (cdr case)))
          (benedict-session-add-hook
           session 'benedict-request-filter-functions
           (lambda (request _model _session)
             (plist-put (copy-sequence request) key value)))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (should (eq (benedict-session-state session) 'idle))
          (should (eq (benedict-entry-meta-get
                       (nth 1 (benedict-session-path session)) :stop-reason)
                      'error))
          (should-not (benedict-provider-fake-requests script)))))))

(ert-deftest benedict-core-preserves-unknown-request-extension-keys ()
  "Unknown canonical request keys reach the provider unchanged."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session '(((:text "ok")))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session))))
        (benedict-session-add-hook
         session 'benedict-request-filter-functions
         (lambda (request _model _session)
           (plist-put (copy-sequence request)
                      :extension-key 'extension-value)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (should (equal (plist-get (benedict-provider-fake-last-request script)
                                  :extension-key)
                       'extension-value))))))

(ert-deftest benedict-core-failed-later-request-does-not-reuse-prior-origin ()
  "A request-build failure cannot inherit the previous turn's origin."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((calls 0)
             (tool (benedict-tool-create
                    :id 'benedict-test-next-request :sync t
                    :handler (lambda (_invocation)
                               (benedict-tool-result :content "continue"))))
             (session (benedict-test-session
                       '(((:tool-call benedict-test-next-request nil)))
                       :tools (list tool))))
        (benedict-session-add-hook
         session 'benedict-request-filter-functions
         (lambda (request _model _session)
           (cl-incf calls)
           (if (= calls 2)
               (plist-put (copy-sequence request) :model nil)
             request)))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (let ((failed (car (last (benedict-session-path session)))))
          (should (eq (benedict-entry-meta-get failed :stop-reason) 'error))
          (should (equal (benedict-entry-origin failed)
                         '(:provider nil :api nil :model nil))))))))

(ert-deftest benedict-core-captures-origin-before-mid-stream-model-switch ()
  "A model change during a stream affects only the next request."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((model-a (benedict-provider-fake-model
                       (benedict-provider-fake-script '(((:text "A"))))
                       :id "model-a"))
             (model-b (benedict-provider-fake-model
                       (benedict-provider-fake-script '(((:text "B"))))
                       :id "model-b"))
             (session (benedict-session-create :model model-a)))
        (benedict-session-submit session "go")
        (should
         (benedict-test-run-until
          (lambda ()
            (when-let ((entry (benedict-session-streaming-entry session)))
              (equal (benedict-entry-text entry) "A")))))
        (setf (benedict-model-id model-a) "mutated-a")
        (setf (benedict-session-model session) model-b)
        (benedict-test-drain)
        (should (equal (benedict-entry-origin
                        (nth 1 (benedict-session-path session)))
                       '(:provider fake :api fake :model "model-a")))
        (benedict-session-submit session "next")
        (benedict-test-drain)
        (should (equal (benedict-entry-origin
                        (nth 3 (benedict-session-path session)))
                       '(:provider fake :api fake :model "model-b")))))))

(ert-deftest benedict-core-discards-terminal-event-from-an-older-run ()
  "A terminal event from a prior run cannot complete a newer run."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "one")) ((:text "two")))))
            (old-generation nil))
        (benedict-session-add-hook
         session 'benedict-entry-start-functions
         (lambda (current _entry)
           (when-let ((run (benedict-session-run current)))
             (unless old-generation
               (setq old-generation (benedict-run-generation run))))))
        (benedict-session-submit session "first")
        (benedict-test-drain)
        (benedict-session-submit session "second")
        (should (benedict-test-run-until
                 (lambda () (benedict-session-streaming-entry session))))
        (benedict-core--receive session old-generation
                                '(:type :done :reason stop))
        (should (benedict-session-streaming-entry session))
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))))))

(ert-deftest benedict-core-abort-keeps-dispatched-origin-and-lowers-foreign-signature ()
  "Aborting after a model switch keeps origin and strips foreign signatures."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((model-a
              (benedict-provider-fake-model
               (benedict-provider-fake-script
                '(((:thinking "A" :signature "opaque"))))
               :id "abort-a"))
             (model-b-script
              (benedict-provider-fake-script '(((:text "B")))))
             (model-b (benedict-provider-fake-model model-b-script
                                                    :id "abort-b"))
             (session (benedict-session-create :model model-a))
             (entry nil))
        (benedict-session-submit session "go")
        (should (benedict-test-run-until
                 (lambda ()
                   (when-let ((candidate (benedict-session-streaming-entry session)))
                     (when (seq-some (lambda (block) (plist-get block :signature))
                                     (benedict-entry-content candidate))
                       (setq entry candidate))))))
        (setf (benedict-session-model session) model-b)
        (benedict-session-abort session)
        (benedict-test-drain)
        (should (eq (benedict-entry-meta-get entry :stop-reason) 'aborted))
        (should (equal (benedict-entry-origin entry)
                       '(:provider fake :api fake :model "abort-a")))
        (benedict-session-submit session "next")
        (benedict-test-drain)
        (let* ((requests (benedict-provider-fake-requests model-b-script))
               (request (car requests))
               (request-entries (plist-get request :entries))
               (replayed (seq-find (lambda (candidate)
                                     (eq (benedict-entry-role candidate) 'assistant))
                                   request-entries))
               (lowered (benedict-api-lower request-entries model-b))
               (replayable-entries
                (mapcar (lambda (candidate)
                          (if (eq candidate entry)
                              (benedict-entry-with-meta
                               candidate :stop-reason nil)
                            candidate))
                        request-entries))
               (lowered-replayable
                (benedict-api-lower replayable-entries model-b))
               (replayed-lowered
                (seq-find #'benedict-entry-assistant-p lowered-replayable))
               (block (car (benedict-entry-content replayed-lowered))))
          (should (equal (length requests) 1))
          (should (eq (benedict-entry-meta-get replayed :stop-reason) 'aborted))
          (should (eq replayed entry))
          (should-not (memq entry lowered))
          (should (equal (benedict-entry-text replayed-lowered) "A"))
          (should (eq (plist-get block :type) 'text))
          (should (equal (plist-get block :text) "A"))
          (should-not (plist-get block :signature)))))))

(provide 'benedict-core-test)

;;; benedict-core-test.el ends here
