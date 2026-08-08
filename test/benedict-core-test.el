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
  "A broken extension ends the run with a reason rather than parking it."
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
        (let ((entry (car (last (benedict-session-path session)))))
          (should (benedict-entry-assistant-p entry))
          (should (string-match-p "Filter is broken"
                                  (benedict-entry-meta-get entry :error-message))))))))

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

(provide 'benedict-core-test)

;;; benedict-core-test.el ends here
