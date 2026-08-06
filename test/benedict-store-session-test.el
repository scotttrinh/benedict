;;; benedict-store-session-test.el --- The store, wired to a live session  -*- lexical-binding: t; -*-

;;; Commentary:

;; P3 says the transcript is append-only and durable per entry, and the whole
;; justification is that `eval' runs in-process: the agent can break its own
;; runtime, so a corrupted image must lose at most the turn in flight.  That
;; claim is only worth anything end to end, which is what this file checks --
;; run a session against the fake provider, throw the session away, reload the
;; log from disk, and assert the tree and the head came back identical.
;;
;; The store subscribes through two ordinary hooks and the kernel never touches
;; the filesystem, so this is also the test that the persistence boundary of
;; SPEC-001 3.3 is real rather than asserted.

;;; Code:

(require 'ert)
(require 'test-helper)

(defmacro benedict-store-session-test--installed (&rest body)
  "Evaluate BODY with the store subscribed to the kernel's hooks."
  (declare (indent 0) (debug body))
  `(unwind-protect (progn (benedict-store-install) ,@body)
     (benedict-store-uninstall)))

(defun benedict-store-session-test--tool ()
  "Register and return a tool that echoes its argument."
  (benedict-deftool benedict-test-echo
    :description "Echo the text given to it."
    :parameters '((text :type string :required t :description "Text."))
    :sync t
    :handler (lambda (invocation)
               (benedict-tool-result
                :content (benedict-tool-arg invocation :text)))))

;;;; The round trip

(ert-deftest benedict-store-session-survives-a-round-trip ()
  "A run with tool calls reloads from disk as the same tree with the same head."
  (benedict-test-with-clean-registries
    (benedict-store-session-test--tool)
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (let* ((store (benedict-store-open "benedict-test-round-trip"
                                             :directory directory))
                 (session (benedict-test-session
                           '(((:text "Checking.")
                              (:tool-call benedict-test-echo (:text "pong")))
                             ((:text "It said pong.")))
                           :id "benedict-test-round-trip"
                           :tools '(benedict-test-echo)
                           :store store)))
            (benedict-session-submit session "ping")
            (benedict-test-drain)
            (should (eq (benedict-session-state session) 'idle))
            (benedict-store-close store (benedict-session-head session))

            (let ((reloaded (benedict-store-load "benedict-test-round-trip"
                                                 :directory directory)))
              (should (benedict-transcript-equal-p
                       reloaded (benedict-session-transcript session)))
              (should (equal (benedict-transcript-head reloaded)
                             (benedict-session-head session)))
              (should (equal (mapcar #'benedict-entry-role
                                     (benedict-transcript-path reloaded))
                             '(user assistant tool-result assistant)))
              ;; Origin metadata is load-bearing, so it has to survive the log
              ;; as Lisp rather than as something a JSON round trip flattened.
              (let ((assistant (nth 1 (benedict-transcript-path reloaded))))
                (should (equal (benedict-entry-origin assistant)
                               '(:provider fake :api fake :model "fake-model")))
                (should (eq (benedict-entry-meta-get assistant :stop-reason)
                            'tool-use))))))))))

(ert-deftest benedict-store-session-fork-reloads-on-the-right-branch ()
  "A session that ends on a fork comes back where it left off, not at its tip."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (let* ((store (benedict-store-open "benedict-test-fork"
                                             :directory directory))
                 (session (benedict-test-session
                           '(((:text "first")) ((:text "second")))
                           :id "benedict-test-fork"
                           :store store)))
            (benedict-session-submit session "hello")
            (benedict-test-drain)
            (let ((fork-point (benedict-entry-id
                               (car (benedict-session-path session)))))
              (benedict-session-fork session fork-point)
              (benedict-session-submit session nil)
              (benedict-test-drain)
              ;; Abandon the second branch and end the session on the first.
              (benedict-session-fork session fork-point)
              (benedict-store-close store (benedict-session-head session))

              (let ((reloaded (benedict-store-load "benedict-test-fork"
                                                   :directory directory)))
                (should (equal (benedict-transcript-head reloaded) fork-point))
                (should (equal (length (benedict-transcript-entries reloaded)) 3))
                (should (equal (length (benedict-transcript-children
                                        reloaded fork-point))
                               2))))))))))

(ert-deftest benedict-store-session-resumes-and-keeps-appending ()
  "Reloading a transcript into a new session continues its id sequence."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (let* ((store (benedict-store-open "benedict-test-resume"
                                             :directory directory))
                 (first (benedict-test-session '(((:text "one")))
                                               :id "benedict-test-resume"
                                               :store store)))
            (benedict-session-submit first "hello")
            (benedict-test-drain)
            (benedict-store-close store (benedict-session-head first))

            (let* ((transcript (benedict-store-load "benedict-test-resume"
                                                    :directory directory))
                   (reopened (benedict-store-open "benedict-test-resume"
                                                  :directory directory))
                   (second (benedict-test-session '(((:text "two")))
                                                  :transcript transcript
                                                  :store reopened)))
              (benedict-session-submit second "again")
              (benedict-test-drain)
              (benedict-store-close reopened (benedict-session-head second))
              (let ((ids (mapcar #'benedict-entry-id
                                 (benedict-session-path second))))
                (should (equal ids '("benedict-test-resume-e0001"
                                     "benedict-test-resume-e0002"
                                     "benedict-test-resume-e0003"
                                     "benedict-test-resume-e0004")))))))))))

;;;; The boundary itself

(ert-deftest benedict-store-session-without-a-store-writes-nothing ()
  "The handlers are installed globally and no-op for a session that has none."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (let ((session (benedict-test-session '(((:text "hi"))))))
            (benedict-session-submit session "hello")
            (benedict-test-drain)
            (should (eq (benedict-session-state session) 'idle))
            (should (null (directory-files directory nil "\\.eld\\'")))))))))

(ert-deftest benedict-store-install-is-idempotent ()
  "Reloading the store file must not subscribe anything twice."
  (benedict-test-with-clean-registries
    (benedict-store-session-test--installed
      (benedict-store-install)
      (should (equal (seq-count (lambda (f) (eq f #'benedict-store-on-entry-end))
                                benedict-entry-end-functions)
                     1))
      (should (equal (seq-count (lambda (f) (eq f #'benedict-store-on-head-change))
                                benedict-head-change-functions)
                     1)))))

(ert-deftest benedict-store-session-an-aborted-turn-is-still-durable ()
  "The entry an abort produced reaches the log like any other."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (let* ((store (benedict-store-open "benedict-test-abort"
                                             :directory directory))
                 (session (benedict-test-session
                           '(((:type :start)
                              (:type :block-start :index 0 :block-type text)
                              (:type :block-delta :index 0 :delta "Half ")
                              (:type :block-delta :index 0 :delta "a thought")
                              (:type :block-end :index 0)
                              (:type :done :reason stop)))
                           :id "benedict-test-abort"
                           :store store)))
            (benedict-session-submit session "hi")
            (should (benedict-test-run-until
                     (lambda ()
                       (when-let* ((partial (benedict-session-streaming-entry session)))
                         (equal (benedict-entry-text partial) "Half ")))))
            (benedict-session-abort session)
            (benedict-test-drain)
            (benedict-store-close store (benedict-session-head session))

            (let* ((reloaded (benedict-store-load "benedict-test-abort"
                                                  :directory directory))
                   (entry (car (last (benedict-transcript-path reloaded)))))
              (should (equal (benedict-entry-text entry) "Half "))
              (should (eq (benedict-entry-meta-get entry :stop-reason) 'aborted)))))))))

(provide 'benedict-store-session-test)

;;; benedict-store-session-test.el ends here
