;;; benedict-core-abort-test.el --- Aborting a run  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 14 Phase 2 exits on "an abort mid-stream that produces a well-formed
;; terminal entry".  The property under test is P3's: because `eval' runs
;; in-process, a session must never be left holding a half-written entry, so a
;; stream that is cut off still reaches the transcript with a stop reason and
;; whatever content had arrived.

;;; Code:

(require 'ert)
(require 'test-helper)

(defconst benedict-core-abort-test--stream
  '(((:type :start)
     (:type :block-start :index 0 :block-type text)
     (:type :block-delta :index 0 :delta "Half ")
     (:type :block-delta :index 0 :delta "a thought")
     (:type :block-end :index 0)
     (:type :done :reason stop)))
  "A one-turn script whose text arrives in two deltas.
Written as raw events rather than script sugar so that a test can stop
the stream between them.")

;;;; Exit criterion: abort mid-stream

(ert-deftest benedict-core-abort-mid-stream-produces-a-terminal-entry ()
  "Cutting a stream off still appends the partial entry, marked aborted."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session benedict-core-abort-test--stream))
             (states (benedict-test-record-states session))
             (ended nil))
        (benedict-session-add-hook session 'benedict-entry-end-functions
                                   (lambda (_session entry) (push entry ended)))
        (benedict-session-submit session "hi")
        (should (benedict-test-run-until
                 (lambda ()
                   (when-let* ((partial (benedict-session-streaming-entry session)))
                     (equal (benedict-entry-text partial) "Half ")))))

        (benedict-session-abort session)
        (should (eq (benedict-session-state session) 'stopping))
        (benedict-test-drain)

        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'aborted))
        (should (equal (benedict-test-states states)
                       '(provider-wait stopping idle)))

        (let ((entry (car (last (benedict-session-path session)))))
          (should (benedict-entry-assistant-p entry))
          (should (benedict-entry-id entry))
          ;; What had arrived is kept.  The rest of the stream never lands,
          ;; which is what makes this an abort rather than a truncation.
          (should (equal (benedict-entry-text entry) "Half "))
          (should (eq (benedict-entry-meta-get entry :stop-reason) 'aborted))
          (should (benedict-entry-meta-get entry :error-message))
          (should (equal (benedict-entry-origin entry)
                         '(:provider fake :api fake :model "fake-model")))
          ;; Appended exactly once, however many late events the provider sends.
          (should (equal (seq-count (lambda (candidate) (eq candidate entry)) ended)
                         1)))))))

(ert-deftest benedict-core-abort-discards-later-stream-events ()
  "Events arriving after an abort change nothing."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session benedict-core-abort-test--stream)))
        (benedict-session-submit session "hi")
        (should (benedict-test-run-until
                 (lambda ()
                   (when-let* ((partial (benedict-session-streaming-entry session)))
                     (equal (benedict-entry-text partial) "Half ")))))
        (benedict-session-abort session)
        (benedict-test-drain)
        (let ((entries (benedict-session-path session)))
          (should (equal (length entries) 2))
          (should (equal (benedict-entry-text (nth 1 entries)) "Half ")))))))

(ert-deftest benedict-core-abort-cancels-the-provider-stream ()
  "The kernel calls the cancel thunk the provider returned."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((cancelled 0)
             (script (benedict-provider-fake-script benedict-core-abort-test--stream))
             (model (benedict-provider-fake-model script :provider 'benedict-test-wrap))
             (session nil))
        (unwind-protect
            (progn
              ;; A provider that speaks through the fake but hands the kernel a
              ;; cancel thunk of its own, so the call can be counted.
              (benedict-defprovider benedict-test-wrap
                :name "Cancel observer"
                :stream (lambda (model request handler)
                          (let ((cancel (benedict-provider-fake--stream
                                         model request handler)))
                            (lambda () (cl-incf cancelled) (funcall cancel))))
                :models (lambda (&optional _force) (list model)))
              (setq session (benedict-session-create :model model))
              (benedict-session-submit session "hi")
              (should (benedict-test-run-until
                       (lambda () (benedict-session-streaming-entry session))))
              (benedict-session-abort session)
              (benedict-test-drain)
              (should (equal cancelled 1))
              ;; The fake stops emitting once cancelled, so the queue drains to
              ;; nothing rather than delivering the rest of the script.
              (should (null benedict-test-defer-queue)))
          (benedict-provider-unregister 'benedict-test-wrap))))))

;;;; Aborting elsewhere in the machine

(ert-deftest benedict-core-abort-while-idle-does-nothing ()
  "Aborting a session with no run is a no-op, not an error."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "hi"))))))
        (should (eq (benedict-session-abort session) 'idle))
        (should (null benedict-test-defer-queue))))))

(ert-deftest benedict-core-abort-between-turns-ends-the-run ()
  "An abort after a completed turn ends the run without inventing an entry."
  (benedict-test-with-clean-registries
    (benedict-deftool benedict-test-slow
      :description "Never finishes."
      :parameters nil
      :handler (lambda (_invocation _done) nil))
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call benedict-test-slow nil))
                        ((:text "unreachable")))
                      :tools '(benedict-test-slow))))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        ;; The tool never called `done', so the run is parked in `tool-wait'
        ;; with the assistant entry already durable.
        (should (eq (benedict-session-state session) 'tool-wait))
        (should (equal (benedict-test-entry-roles session) '(user assistant)))

        (benedict-session-abort session)
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (eq (benedict-session-stop-reason session) 'aborted))
        ;; The orphaned tool call stays orphaned.  Repairing it belongs to the
        ;; lowering pass, which is what keeps this transcript replayable
        ;; without the kernel knowing anything about wire formats.
        (should (equal (benedict-test-entry-roles session) '(user assistant)))
        (should (benedict-entry-tool-calls
                 (nth 1 (benedict-session-path session))))))))

(ert-deftest benedict-core-aborting-twice-ends-the-run-once ()
  "A second abort must not schedule a second drain."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session benedict-core-abort-test--stream))
            (ends 0))
        (benedict-session-add-hook session 'benedict-run-end-functions
                                   (lambda (_session) (cl-incf ends)))
        (benedict-session-submit session "hi")
        (should (benedict-test-run-until
                 (lambda () (benedict-session-streaming-entry session))))
        (benedict-session-abort session)
        (should (eq (benedict-session-abort session) 'stopping))
        (benedict-test-drain)
        (should (equal ends 1))
        (should (equal (length (benedict-session-path session)) 2))))))

(ert-deftest benedict-core-abort-fires-run-end-exactly-once ()
  "An aborted run still ends properly, so observers are not left hanging."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session benedict-core-abort-test--stream))
            (ends 0)
            (turn-ends 0))
        (benedict-session-add-hook session 'benedict-run-end-functions
                                   (lambda (_session) (cl-incf ends)))
        (benedict-session-add-hook session 'benedict-turn-end-functions
                                   (lambda (&rest _) (cl-incf turn-ends)))
        (benedict-session-submit session "hi")
        (should (benedict-test-run-until
                 (lambda () (benedict-session-streaming-entry session))))
        (benedict-session-abort session)
        (benedict-test-drain)
        (should (equal ends 1))
        (should (equal turn-ends 1))))))

(ert-deftest benedict-core-cancel-failure-ends-run-with-first-error ()
  "A cancellation thunk failure is terminal and visible through last-error."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((model (benedict-model-create :id "held" :provider 'contract-cancel
                                          :api 'contract))
            (handler nil)
            (cancel-calls 0))
        (unwind-protect
            (progn
              (benedict-defprovider contract-cancel
                :stream (lambda (_model _request callback)
                          (setq handler callback)
                          (lambda ()
                            (cl-incf cancel-calls)
                            (error "cancel failed"))))
              (setf (benedict-model-provider model) 'contract-cancel)
              (let ((session (benedict-session-create :model model)))
                (benedict-session-submit session "go")
                (benedict-test-step)
                (should handler)
                (benedict-session-abort session)
                (benedict-test-drain)
                (funcall handler '(:type :done :reason stop))
                (benedict-test-drain)
                (should (eq (benedict-session-state session) 'idle))
                (should (eq (benedict-session-stop-reason session) 'error))
                (should (equal (benedict-session-last-error session)
                               '(error "cancel failed")))
                (should (= cancel-calls 1))))
          (benedict-provider-unregister 'contract-cancel))))))

(ert-deftest benedict-core-abort-discards-late-held-provider-event ()
  "A completion from run A cannot mutate run B after replacement."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((handlers nil)
            (cancelled nil)
            (model (benedict-model-create :id "held" :provider 'contract-held
                                           :api 'contract)))
        (unwind-protect
            (progn
              ;; Provider fixture protocol: retain HANDLER and return a cancel
              ;; thunk that intentionally does not suppress later events.
              (benedict-defprovider contract-held
                :stream (lambda (_model _request handler)
                          (push handler handlers)
                          (lambda () (setq cancelled t))))
              (let ((session (benedict-session-create :model model))
                    (ends 0))
                (benedict-session-add-hook
                 session 'benedict-entry-end-functions
                 (lambda (_session _entry) (cl-incf ends)))
                (benedict-session-submit session "A")
                (benedict-test-step)
                (let ((old-handler (car handlers)))
                  (benedict-session-abort session)
                  (benedict-test-drain)
                  (benedict-session-submit session "B")
                  (benedict-test-step)
                  (let ((roles (benedict-test-entry-roles session))
                        (ended ends)
                        (partial (benedict-session-streaming-entry session)))
                    (funcall old-handler '(:type :done :reason stop))
                    (benedict-test-drain)
                    (should cancelled)
                    (should (eq (benedict-session-state session) 'provider-wait))
                    (should (equal (benedict-test-entry-roles session) roles))
                    (should (eq (benedict-session-streaming-entry session) partial))
                    (should (= ends ended))))))
          (benedict-provider-unregister 'contract-held))))))

(ert-deftest benedict-core-abort-during-provider-start-cancels-immediately ()
  "A provider invalidated synchronously during startup is cancelled at once."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session nil)
            (cancel-calls 0)
            (model (benedict-model-create :id "held"
                                          :provider 'sync-abort
                                          :api 'contract)))
        (unwind-protect
            (progn
              (benedict-defprovider sync-abort
                :stream
                (lambda (_model _request _callback)
                  (benedict-session-abort session)
                  (lambda () (cl-incf cancel-calls))))
              (setq session (benedict-session-create :model model))
              (benedict-session-submit session "go")
              (benedict-test-step)
              (should (= cancel-calls 1))
              (benedict-test-drain)
              (should (eq (benedict-session-state session) 'idle)))
          (benedict-provider-unregister 'sync-abort))))))
(ert-deftest benedict-core-abort-retains-queued-steering ()
  "Aborting a run does not restart queued steering implicitly."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((session (benedict-test-session '(((:text "partial")))))
             (script (benedict-provider-fake-script-of
                      (benedict-session-model session))))
        (benedict-session-submit session "initial")
        (benedict-test-step)
        (benedict-session-steer session "keep me")
        (benedict-session-abort session)
        (benedict-test-drain)
        (should (= (length (benedict-provider-fake-requests script)) 1))
        (should (equal (benedict-session-steer-queue session)
                       '("keep me")))
        (should (eq (benedict-session-state session) 'idle))))))

(provide 'benedict-core-abort-test)

;;; benedict-core-abort-test.el ends here
