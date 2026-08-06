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

(provide 'benedict-core-abort-test)

;;; benedict-core-abort-test.el ends here
