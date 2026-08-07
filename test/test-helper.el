;;; test-helper.el --- Shared setup for the Benedict test suites  -*- lexical-binding: t; -*-

;;; Commentary:

;; ert-runner loads this file before any test file, so it is the one place
;; load-path and shared fixtures need to be set up.
;;
;; The load-path setup duplicates Eask's `load-paths' directive on purpose: it
;; keeps
;;
;;   emacs -Q --batch -l test/test-helper.el -l test/benedict-store-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; working without Eask in the picture, which matters when bisecting a failure
;; or reproducing one outside the nix shell.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst benedict-test-root
  (file-name-as-directory
   (expand-file-name
    (locate-dominating-file
     (or load-file-name buffer-file-name default-directory)
     "Eask")))
  "Absolute path to the Benedict project root.")

(defconst benedict-test-layers
  '("core" "support" "api" "providers" "ext" "ui")
  "Source layer directories, in dependency order.
Each may only require from itself and the layers before it; see
`benedict-boundaries-test.el'.")

(dolist (layer benedict-test-layers)
  (add-to-list 'load-path (expand-file-name layer benedict-test-root)))

(require 'benedict)
(require 'benedict-message)
(require 'benedict-schema)
(require 'benedict-tool)
(require 'benedict-provider)
(require 'benedict-session)
(require 'benedict-core)
(require 'benedict-log)
(require 'benedict-http)
(require 'benedict-auth)
(require 'benedict-api-transform)
(require 'benedict-api-stream)
(require 'benedict-api-openai-responses)
(require 'benedict-provider-fake)
(require 'benedict-provider-vercel)
(require 'benedict-store)
(require 'benedict-eval)
(require 'benedict-chat-widgets)
(require 'benedict-chat-blocks)
(require 'benedict-chat-render)
(require 'benedict-chat)
(require 'benedict-headless)

(defun benedict-test-entry (role text &rest meta)
  "Return an unappended entry with ROLE, a single text block TEXT, and META."
  (benedict-entry-create :role role :content text :meta meta))

(defmacro benedict-test-with-quiet-log (&rest body)
  "Evaluate BODY with `benedict-log' recording nothing and echoing nothing.

Wrap anything that logs at `error', which is echoed by default.  A suite
whose expected failures print to the runner trains its reader to skim
output that is sometimes real."
  (declare (indent 0) (debug body))
  `(let ((benedict-log-level nil)
         (benedict-log-echo-level nil))
     ,@body))

;;;; Recorded wire fixtures

;; Real captured bytes, per SPEC-001 12.5.  Read literally and decoded by hand
;; rather than through `insert-file-contents', which would apply end-of-line
;; conversion -- a fixture whose CRLFs became LFs on the way in is no longer
;; the bytes the service sent, which is the whole claim these files make.

(defconst benedict-test-fixture-directory
  (expand-file-name "test/fixtures" benedict-test-root)
  "Directory holding recorded wire fixtures.
See its README for what produced each file and how to re-capture it.")

(defun benedict-test-fixture (name)
  "Return the absolute path of the recorded fixture NAME."
  (expand-file-name name benedict-test-fixture-directory))

(defun benedict-test-fixture-contents (name)
  "Return the recorded fixture NAME as a string, byte for byte."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally (benedict-test-fixture name))
    (decode-coding-string (buffer-string) 'utf-8 t)))

;;;; Models without a session

;; Lowering is pure data transformation, so its tests want a model record and
;; never a transport.  The fake provider is still the way to get one: it is the
;; only thing that can claim an arbitrary provider/api/model triple, which is
;; what makes cross-model degradation testable in both directions.

(defun benedict-test-model (&rest keys)
  "Return a fake model with KEYS, replaying an empty script.
KEYS are passed to `benedict-provider-fake-model'.  Use this when a test
needs a model to lower for and will never open a stream through it."
  (apply #'benedict-provider-fake-model
         (benedict-provider-fake-script nil) keys))

(defun benedict-test-origin-meta (model)
  "Return the entry metadata that makes an entry same-origin with MODEL.
The inverse of `benedict-entry-origin'; splice it into an entry's meta to
mark the entry as produced by MODEL."
  (list :provider (benedict-model-provider model)
        :api (benedict-model-api model)
        :model (benedict-model-id model)))

(defmacro benedict-test-with-store-dir (var &rest body)
  "Bind VAR to a fresh temporary session directory and evaluate BODY.

`benedict-store-directory' is bound to the same directory, so store calls
that do not name one land there.  The directory is removed afterwards
even if BODY signals.

`write-region-inhibit-fsync' is bound back to t for the duration: the
store deliberately clears it so that writes are durable, but durability
is not what these tests are checking and fsync per entry is slow."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((,var (file-name-as-directory (make-temp-file "benedict-store-" t)))
          (benedict-store-directory ,var)
          (write-region-inhibit-fsync t))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

;;;; Driving the reducer

;; The kernel re-enters itself only through `benedict-core-defer-function', and
;; the fake provider paces its events through the same variable.  Binding it to
;; a queue therefore takes both off the wall clock: a test runs the machine one
;; transition at a time and asserts on what it finds in between.

(defvar benedict-test-defer-queue nil
  "Thunks the reducer and the fake provider have deferred, oldest first.")

(defconst benedict-test-step-limit 500
  "Most steps `benedict-test-drain' will run before declaring a runaway.
A reducer that will not settle has to fail loudly rather than hang the
suite until the runner's own timeout.")

(defun benedict-test--defer (thunk)
  "Queue THUNK for `benedict-test-step' instead of running it on a timer."
  (setq benedict-test-defer-queue
        (append benedict-test-defer-queue (list thunk))))

(defmacro benedict-test-with-manual-defer (&rest body)
  "Evaluate BODY with the reducer and the fake provider stepped by hand.
The queue starts empty and any thunks left in it are discarded, so one
test cannot leak work into the next."
  (declare (indent 0) (debug body))
  `(let ((benedict-test-defer-queue nil)
         (benedict-core-defer-function #'benedict-test--defer))
     ,@body))

(defun benedict-test-step ()
  "Run one deferred thunk.  Return non-nil when there was one to run."
  (when-let* ((thunk (pop benedict-test-defer-queue)))
    (funcall thunk)
    t))

(defun benedict-test-drain (&optional limit)
  "Run deferred thunks until none remain.  Return the number run.

Signals when more than LIMIT steps run, defaulting to
`benedict-test-step-limit', because a reducer that never settles is a
bug this suite should name rather than a hang the runner reports."
  (let ((limit (or limit benedict-test-step-limit))
        (steps 0))
    (while (benedict-test-step)
      (cl-incf steps)
      (when (> steps limit)
        (error "Reducer ran %d steps without settling" steps)))
    steps))

(defun benedict-test-run-until (predicate &optional limit)
  "Step the reducer until PREDICATE returns non-nil.  Return its value.

Returns nil when the queue empties or LIMIT steps pass first, so a caller
that needs the condition met should assert on the return value."
  (let ((limit (or limit benedict-test-step-limit))
        (steps 0)
        (result (funcall predicate)))
    (while (and (not result) (< steps limit) (benedict-test-step))
      (cl-incf steps)
      (setq result (funcall predicate)))
    result))

;;;; Sessions on the fake provider

(cl-defun benedict-test-session (turns &key tools system-prompt store
                                       exhausted-action id transcript)
  "Return a session whose model replays TURNS.

TURNS is a fake-provider script; see `benedict-provider-fake-script'.
TOOLS, SYSTEM-PROMPT, STORE, ID, and TRANSCRIPT are passed to
`benedict-session-create'.  The model is reachable afterwards through
`benedict-session-model', and its script through
`benedict-provider-fake-script-of'."
  (let* ((script (benedict-provider-fake-script
                  turns :exhausted-action exhausted-action))
         (model (benedict-provider-fake-model script)))
    (benedict-session-create :id id
                             :model model
                             :tools tools
                             :system-prompt system-prompt
                             :store store
                             :transcript transcript)))

(defun benedict-test-record-states (session)
  "Record SESSION's state transitions into a list and return the list cell.

The returned cons has the transitions in order in its cdr, so a test
reads them with (cdr CELL) after the run.  A session-local hook is used
so that concurrent sessions in one test do not pollute each other."
  (let ((cell (list 'states)))
    (benedict-session-add-hook
     session 'benedict-state-change-functions
     (lambda (_session _old new) (setcdr cell (append (cdr cell) (list new)))))
    cell))

(defun benedict-test-states (cell)
  "Return the states recorded into CELL by `benedict-test-record-states'."
  (cdr cell))

(defun benedict-test-entry-roles (session)
  "Return the roles of the entries on SESSION's current path, in order."
  (mapcar #'benedict-entry-role (benedict-session-path session)))

(defun benedict-test-reset ()
  "Clear global registries and hooks between tests.

Tools, fake models, and every kernel hook are global, so a test that
registers one has to be prevented from changing the next test's meaning."
  (benedict-provider-fake-reset)
  (dolist (hook '(benedict-run-start-functions
                  benedict-run-end-functions
                  benedict-turn-start-functions
                  benedict-turn-end-functions
                  benedict-entry-start-functions
                  benedict-entry-update-functions
                  benedict-entry-end-functions
                  benedict-head-change-functions
                  benedict-tool-start-functions
                  benedict-tool-end-functions
                  benedict-state-change-functions
                  benedict-continue-predicate-functions
                  benedict-context-filter-functions
                  benedict-request-filter-functions
                  benedict-tool-result-filter-functions
                  benedict-tool-dispatch-functions))
    (set hook nil)))

(defmacro benedict-test-with-clean-registries (&rest body)
  "Evaluate BODY with global hooks and the fake catalog reset before and after."
  (declare (indent 0) (debug body))
  `(unwind-protect (progn (benedict-test-reset) ,@body)
     (benedict-test-reset)))

(provide 'test-helper)

;;; test-helper.el ends here
