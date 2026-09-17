;;; benedict-provider-fake-test.el --- The scripted provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 7.7 makes the fake provider a first-class deliverable, so it gets
;; tests of its own rather than being trusted because the reducer's tests pass.
;; If the fake is wrong, every other suite in this repository is asserting the
;; wrong thing quietly.

;;; Code:

(require 'ert)
(require 'test-helper)

(defun benedict-provider-fake-test--events (turn)
  "Return the normalized events the fake produces for TURN."
  (benedict-provider-fake--turn-events turn))

;;;; Script expansion

(ert-deftest benedict-provider-fake-expands-text-into-block-events ()
  (should (equal (benedict-provider-fake-test--events '((:text "hello")))
                 '((:type :start)
                   (:type :block-start :index 0 :block-type text)
                   (:type :block-delta :index 0 :delta "hello")
                   (:type :block-end :index 0)
                   (:type :done :reason stop)))))

(ert-deftest benedict-provider-fake-infers-tool-use-as-the-stop-reason ()
  "A turn that called a tool ends with `tool-use', which is what the reducer
branches on."
  (let ((events (benedict-provider-fake-test--events
                 '((:text "Looking.") (:tool-call do-thing (:x 1))))))
    (should (equal (car (last events)) '(:type :done :reason tool-use)))
    ;; Block indexes stay contiguous across steps.
    (should (equal (seq-filter #'identity
                               (mapcar (lambda (event)
                                         (when (eq (plist-get event :type) :block-start)
                                           (plist-get event :index)))
                                       events))
                   '(0 1)))))

(ert-deftest benedict-provider-fake-delivers-parsed-tool-arguments ()
  "Arguments arrive at block end, already decoded, as an adapter must deliver."
  (let* ((events (benedict-provider-fake-test--events
                  '((:tool-call do-thing (:form "(+ 1 2)") :id "call_x"))))
         (start (nth 1 events))
         (end (nth 3 events)))
    (should (equal (plist-get start :block-type) 'tool-call))
    (should (equal (plist-get start :id) "call_x"))
    (should (eq (plist-get start :name) 'do-thing))
    (should (equal (plist-get end :arguments) '(:form "(+ 1 2)")))))

(ert-deftest benedict-provider-fake-passes-raw-events-through ()
  "A step that is already an event is not rewritten, so any stream is writable."
  (should (equal (benedict-provider-fake-test--events
                  '((:type :block-start :index 4 :block-type text)
                    (:type :done :reason length)))
                 '((:type :start)
                   (:type :block-start :index 4 :block-type text)
                   (:type :done :reason length)))))

(ert-deftest benedict-provider-fake-rejects-a-step-it-cannot-read ()
  (should-error (benedict-provider-fake-test--events '((:nonsense "x")))
                :type 'benedict-provider-error))

;;;; Pacing and cancellation

(ert-deftest benedict-provider-fake-emits-one-event-per-step ()
  "Pacing is what makes aborting mid-stream deterministic rather than a race."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((script (benedict-provider-fake-script '(((:text "hi")))))
             (model (benedict-provider-fake-model script))
             (events nil))
        (benedict-provider-fake--stream model nil (lambda (e) (push e events)))
        (should (null events))
        (benedict-test-step)
        (should (equal (length events) 1))
        (benedict-test-step)
        (should (equal (length events) 2))
        (benedict-test-drain)
        (should (equal (length events) 5))))))

(ert-deftest benedict-provider-fake-cancel-stops-emission ()
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((script (benedict-provider-fake-script '(((:text "hi")))))
             (model (benedict-provider-fake-model script))
             (events nil)
             (cancel (benedict-provider-fake--stream
                      model nil (lambda (e) (push e events)))))
        (benedict-test-step)
        (funcall cancel)
        (benedict-test-drain)
        (should (equal (length events) 1))))))

;;;; Turns, exhaustion, and recording

(ert-deftest benedict-provider-fake-consumes-one-turn-per-request ()
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((script (benedict-provider-fake-script '(((:text "one")) ((:text "two")))))
             (model (benedict-provider-fake-model script))
             (texts nil)
             (collect (lambda (event)
                        (when (eq (plist-get event :type) :block-delta)
                          (push (plist-get event :delta) texts)))))
        (benedict-provider-fake--stream model '(:n 1) collect)
        (benedict-test-drain)
        (benedict-provider-fake--stream model '(:n 2) collect)
        (benedict-test-drain)
        (should (equal (reverse texts) '("one" "two")))
        (should (equal (benedict-provider-fake-requests script)
                       '((:n 1) (:n 2))))
        (should (equal (benedict-provider-fake-last-request script) '(:n 2)))))))

(ert-deftest benedict-provider-fake-exhaustion-is-loud-by-default ()
  "An unscripted request is a bug in the test, so it fails rather than passes."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((script (benedict-provider-fake-script nil))
             (model (benedict-provider-fake-model script))
             (events nil))
        (benedict-provider-fake--stream model nil (lambda (e) (push e events)))
        (benedict-test-drain)
        (should (eq (plist-get (car events) :type) :error))))))

(ert-deftest benedict-provider-fake-exhaustion-can-stop-quietly ()
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((script (benedict-provider-fake-script nil :exhausted-action 'stop))
             (model (benedict-provider-fake-model script))
             (events nil))
        (benedict-provider-fake--stream model nil (lambda (e) (push e events)))
        (benedict-test-drain)
        (should (equal (car events) '(:type :done :reason stop)))))))

;;;; Impersonation

(ert-deftest benedict-provider-fake-impersonates-any-triple ()
  "Claiming another provider/api/model is what makes lowering testable."
  (benedict-test-with-clean-registries
    (let ((model (benedict-provider-fake-model
                  (benedict-provider-fake-script nil)
                  :provider 'vercel-ai-gateway
                  :api 'openai-responses
                  :id "openai/gpt-5"
                  :reasoning-p t)))
      (should (equal (benedict-model-triple model)
                     '(vercel-ai-gateway openai-responses "openai/gpt-5")))
      (should (benedict-model-reasoning-p model))
      ;; Two impersonated models are foreign to each other, which is the
      ;; comparison every degradation rule turns on.
      (let ((other (benedict-provider-fake-model (benedict-provider-fake-script nil))))
        (should-not (benedict-model-same-origin-p
                     model (benedict-entry-origin
                            (benedict-entry-create
                             :role 'assistant :content "x"
                             :meta (list :provider (benedict-model-provider other)
                                         :api (benedict-model-api other)
                                         :model (benedict-model-id other))))))))))

(ert-deftest benedict-provider-fake-reset-clears-the-catalog ()
  "One test's models must not resolve in the next."
  (benedict-test-with-clean-registries
    (benedict-provider-fake-model (benedict-provider-fake-script nil) :id "gone")
    (should (benedict-model-resolve "fake/gone"))
    (benedict-provider-fake-reset)
    (should-error (benedict-model-resolve "fake/gone") :type 'benedict-model-unknown)))

(provide 'benedict-provider-fake-test)

;;; benedict-provider-fake-test.el ends here
