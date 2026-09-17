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

(defvar benedict-m5-reconstruction-tool-calls 0
  "Number of times the M5 reconstruction tool handler was invoked.")

(defun benedict-m5-reconstruction-tool-handler (_invocation _done)
  "Count an asynchronous reconstruction tool invocation without answering it."
  (cl-incf benedict-m5-reconstruction-tool-calls))

(defun benedict-m5-reconstruction-hook (session)
  "Mark SESSION as having run its reconstructed named hook."
  (benedict-session-put session :m5-hook-ran t))

(defun benedict-m5-reconstruction-test--register-tool ()
  "Register the named local tool used by reconstruction tests."
  (benedict-tool-register
   (benedict-tool-create
    :id 'benedict-m5-reconstruction-tool
    :description "A tool whose invocation can be held for reconstruction tests."
    :parameters nil
    :sync nil
    :handler #'benedict-m5-reconstruction-tool-handler)))

(defun benedict-m5-reconstruction-local-tool-handler (_invocation)
  "Return a result for the reconstructed session's local tool."
  (benedict-tool-result :content "local"))

(defun benedict-m5-reconstruction-test--local-tool ()
  "Create the unregistered tool reattached to a reconstructed session."
  (benedict-tool-create
   :id 'benedict-m5-reconstruction-local-tool
   :description "A session-local reconstruction tool."
   :parameters nil
   :sync t
   :handler #'benedict-m5-reconstruction-local-tool-handler))

(defun benedict-m5-reconstruction--config (transcript)
  "Return the latest applicable extension configuration note on TRANSCRIPT."
  (seq-find
   (lambda (entry)
     (and (benedict-entry-note-p entry)
          (equal (benedict-entry-text entry)
                 "Contract extension configuration")
          (plist-member (benedict-entry-meta entry) :contract-extension)))
   (reverse (benedict-transcript-path transcript))))

(cl-defun benedict-m5-reconstruct-session (transcript script &key store tools)
  "Construct a fresh session from TRANSCRIPT and serializable extension state.

SCRIPT supplies the in-memory fake model fixture.  STORE, when non-nil, is
passed to the new session; TOOLS defaults to a newly constructed local tool.
The transcript never supplies executable state."
  (let* ((note (benedict-m5-reconstruction--config transcript))
         (config (plist-get (benedict-entry-meta note) :contract-extension))
         (model-id (plist-get config :model))
         (model-name (cadr (split-string model-id "/" t)))
         (model (benedict-provider-fake-model script :id model-name))
         (session (benedict-session-create
                   :transcript transcript
                   :model (benedict-model-resolve model-id)
                   :system-prompt (plist-get config :system-prompt)
                   :tools (or tools
                              (list (benedict-m5-reconstruction-test--local-tool)))
                   :store store)))
    (should (eq model (benedict-session-model session)))
    (benedict-session-put session :project-root (plist-get config :project-root))
    (benedict-session-add-hook session 'benedict-run-start-functions
                               #'benedict-m5-reconstruction-hook)
    session))

(defun benedict-m5-reconstruction-note (session)
  "Append the serializable contract configuration note required by M5."
  (benedict-session-note
   session "Contract extension configuration"
   '(:contract-extension (:version 1 :model "fake/fake-model"
                         :project-root "/contract/project/"
                         :system-prompt "Contract instructions"))))

(defun benedict-m5-reconstruction-request-assertions
    (session script &optional expected-tools)
  "Assert reconstructed settings on SESSION's next request from SCRIPT."
  (let* ((request (benedict-provider-fake-last-request script))
         (model (benedict-session-model session))
         (expected-tools (or expected-tools
                             '(benedict-m5-reconstruction-local-tool))))
    (should (equal (plist-get request :system-prompt)
                   "Contract instructions"))
    (should (eq (plist-get request :model) model))
    (should (equal (mapcar #'benedict-tool-id (plist-get request :tools))
                   expected-tools))
    (should (benedict-session-get session :m5-hook-ran))
    request))

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

(ert-deftest benedict-store-session-a-note-survives-a-restart ()
  "A note written with `benedict-session-note' is on disk after the image is gone.

This is the claim that makes notes worth having -- §9.3 offers them as
how an extension keeps state across restarts, and §10.3 as how a session
explains why the running image no longer matches its sources.  Both
depend on the note reaching the store, which it does only because
`benedict-session-note' announces rather than merely appending."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (let* ((store (benedict-store-open "benedict-test-note"
                                             :directory directory))
                 (session (benedict-test-session '(((:text "noted")))
                                                 :id "benedict-test-note"
                                                 :store store)))
            (benedict-session-note session "(defun my/thing () t)" '(:context t))
            (benedict-session-submit session "go")
            (benedict-test-drain)
            (benedict-store-close store (benedict-session-head session))

            (let* ((reloaded (benedict-store-load "benedict-test-note"
                                                  :directory directory))
                   (note (car (benedict-transcript-path reloaded))))
              (should (equal (mapcar #'benedict-entry-role
                                     (benedict-transcript-path reloaded))
                             '(note user assistant)))
              (should (eq (benedict-entry-role note) 'note))
              (should (equal (benedict-entry-text note) "(defun my/thing () t)"))
              ;; The flag has to survive too, or the note comes back as
              ;; something only a human ever sees again.
              (should (benedict-entry-meta-get note :context)))))))))

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

(ert-deftest benedict-store-session-detach-stops-slot-persistence ()
  "Detaching a session created with `:store' removes its persistence fallback."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (let* ((store (benedict-store-open "benedict-test-detach"
                                           :directory directory))
               (session (benedict-session-create :id "benedict-test-detach"
                                                 :store store)))
          ;; Required regression: both attachment sources must be gone.
          (should (eq store (benedict-store-detach session)))
          (should-not (benedict-store-for-session session))
          (should-not (benedict-session-store session))
          (should-not (benedict-store-detach session))
          (benedict-session-note
           session "detached note" '(:context t))
          (benedict-store-close store nil)
          (should-not (benedict-transcript-entries
                       (benedict-store-load "benedict-test-detach"
                                            :directory directory))))))))

(ert-deftest benedict-store-session-detach-clears-weak-override-and-slot ()
  "Detaching a real session clears both weak and slot store attachments."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (let* ((slot-store (benedict-store-open "benedict-test-slot"
                                              :directory directory))
             (override-store (benedict-store-open "benedict-test-override"
                                                  :directory directory))
             (session (benedict-session-create :store slot-store)))
        (benedict-store-attach session override-store)
        (should (eq override-store (benedict-store-for-session session)))
        (should (eq override-store (benedict-store-detach session)))
        (should-not (benedict-store-for-session session))
        (should-not (benedict-session-store session))
        (should-not (benedict-store-detach session))))))

(ert-deftest benedict-m5-reconstructs-a-plain-resume ()
  "A fresh transcript session restores settings and continues entry ids."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (benedict-m5-reconstruction-test--register-tool)
          (let* ((store (benedict-store-open "benedict-m5-plain"
                                             :directory directory))
                 (script (benedict-provider-fake-script '(((:text "first")))))
                 (model (benedict-provider-fake-model script))
                 (session (benedict-session-create
                           :id "benedict-m5-plain"
                           :model model
                           :tools (list (benedict-m5-reconstruction-test--local-tool))
                           :store store)))
            (benedict-m5-reconstruction-note session)
            (benedict-session-submit session "before")
            (benedict-test-drain)
            (benedict-store-close store (benedict-session-head session))
            (let* ((transcript (benedict-store-load "benedict-m5-plain"
                                                    :directory directory))
                   (reopened (benedict-store-open "benedict-m5-plain"
                                                  :directory directory))
                   (next-script
                    (benedict-provider-fake-script '(((:text "resumed")))))
                   (resumed (benedict-m5-reconstruct-session
                             transcript next-script :store reopened)))
              (should (equal (benedict-session-get resumed :project-root)
                             "/contract/project/"))
              (benedict-session-submit resumed "after")
              (benedict-test-drain)
              (benedict-m5-reconstruction-request-assertions resumed next-script)
              (should (equal
                       (mapcar #'benedict-entry-id
                               (benedict-session-path resumed))
                       '("benedict-m5-plain-e0001"
                         "benedict-m5-plain-e0002"
                         "benedict-m5-plain-e0003"
                         "benedict-m5-plain-e0004"
                         "benedict-m5-plain-e0005")))
              (benedict-store-close reopened
                                    (benedict-session-head resumed)))))))))

(ert-deftest benedict-m5-reconstructs-after-a-fork ()
  "Reconstruction follows the active branch and preserves abandoned entries."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (benedict-m5-reconstruction-test--register-tool)
          (let* ((store (benedict-store-open "benedict-m5-fork"
                                             :directory directory))
                 (script (benedict-provider-fake-script
                          '(((:text "first")) ((:text "branch")))))
                 (model (benedict-provider-fake-model script))
                 (session (benedict-session-create
                           :id "benedict-m5-fork" :model model
                           :tools (list (benedict-m5-reconstruction-test--local-tool))
                           :store store)))
            (benedict-m5-reconstruction-note session)
            (benedict-session-submit session "root")
            (benedict-test-drain)
            (let ((fork-point (benedict-entry-id
                               (nth 1 (benedict-session-path session)))))
              (benedict-session-fork session fork-point)
              (benedict-session-submit session "branch")
              (benedict-test-drain)
              (benedict-session-fork session fork-point)
              (benedict-store-close store (benedict-session-head session))
              (let* ((transcript (benedict-store-load "benedict-m5-fork"
                                                      :directory directory))
                     (reopened (benedict-store-open "benedict-m5-fork"
                                                    :directory directory))
                     (next-script
                      (benedict-provider-fake-script '(((:text "resumed")))))
                     (resumed (benedict-m5-reconstruct-session
                               transcript next-script :store reopened)))
                (benedict-session-submit resumed "after-fork")
                (benedict-test-drain)
                (benedict-m5-reconstruction-request-assertions resumed
                                                                next-script)
                (should (= (length (benedict-session-entries resumed)) 7))
                (should (equal
                         (mapcar #'benedict-entry-id
                                 (benedict-session-path resumed))
                         '("benedict-m5-fork-e0001"
                           "benedict-m5-fork-e0002"
                           "benedict-m5-fork-e0006"
                           "benedict-m5-fork-e0007")))
                (benedict-store-close reopened
                                      (benedict-session-head resumed))))))))))

(ert-deftest benedict-m5-reconstructs-after-aborted-unanswered-tool-call ()
  "Lowering repairs an aborted orphan without executing its old tool call."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-store-session-test--installed
        (benedict-test-with-manual-defer
          (benedict-m5-reconstruction-test--register-tool)
          (setq benedict-m5-reconstruction-tool-calls 0)
          (let* ((store (benedict-store-open "benedict-m5-abort"
                                             :directory directory))
                 (script (benedict-provider-fake-script
                          '(((:tool-call benedict-m5-reconstruction-tool
                                         (:value 1) :id "old-call")))))
                 (model (benedict-provider-fake-model script))
                 (session (benedict-session-create
                           :id "benedict-m5-abort" :model model
                           :tools (list (benedict-m5-reconstruction-test--local-tool)
                                        'benedict-m5-reconstruction-tool)
                           :store store)))
            (benedict-m5-reconstruction-note session)
            (benedict-session-submit session "start")
            (benedict-test-drain)
            (should (eq (benedict-session-state session) 'tool-wait))
            (should (= benedict-m5-reconstruction-tool-calls 1))
            (benedict-session-abort session)
            (benedict-test-drain)
            (benedict-store-close store (benedict-session-head session))
            (let* ((transcript (benedict-store-load "benedict-m5-abort"
                                                    :directory directory))
                   (reopened (benedict-store-open "benedict-m5-abort"
                                                  :directory directory))
                   (next-script
                    (benedict-provider-fake-script '(((:text "repaired")))))
                   (resumed (benedict-m5-reconstruct-session
                             transcript next-script :store reopened
                             :tools (list (benedict-m5-reconstruction-test--local-tool)
                                          'benedict-m5-reconstruction-tool))))
              (benedict-session-submit resumed "repair")
              (benedict-test-drain)
              (let ((request (benedict-m5-reconstruction-request-assertions
                              resumed next-script
                              '(benedict-m5-reconstruction-local-tool
                                benedict-m5-reconstruction-tool))))
                (let ((lowered (benedict-api-lower
                                (plist-get request :entries)
                                (plist-get request :model))))
                  (should (equal (mapcar #'benedict-entry-role lowered)
                                 '(user assistant tool-result user)))
                  (should (equal
                           (plist-get (car (benedict-entry-content
                                            (nth 2 lowered))) :id)
                           "old-call"))))
              (should (= benedict-m5-reconstruction-tool-calls 1))
              (should (equal
                       (mapcar #'benedict-entry-id
                               (benedict-session-path resumed))
                       '("benedict-m5-abort-e0001"
                         "benedict-m5-abort-e0002"
                         "benedict-m5-abort-e0003"
                         "benedict-m5-abort-e0004"
                         "benedict-m5-abort-e0005")))
              (benedict-store-close reopened
                                    (benedict-session-head resumed)))))))))

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
