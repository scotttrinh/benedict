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

;;;; Global registration state

;; Everything an extension touches is process-global: the tool, provider, and
;; API registries, the fake model catalog, and the kernel hook variables.
;; `benedict-test-with-clean-registries' snapshots that state and restores it
;; by identity, so a test that replaces a registration under an existing id,
;; signals, or nests cannot change what the next lookup finds.

(defconst benedict-test-global-hooks
  '(benedict-run-start-functions
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
    benedict-tool-dispatch-functions
    benedict-http-result-filter-functions)
  "Global hook variables the test helpers restore.

Restored by setting the default value, so a buffer-local value a test
installed on purpose survives; see `benedict-test-reset'.")

(defvar benedict-test--baseline nil
  "Global registration state present before any test ran.

Captured during suite setup rather than on the first helper use, so a
test cannot make its own pre-entry changes part of the baseline.
Registrations made as load-time side effects -- `eval-elisp' is the one
that matters -- are part of the image every test expects.")

(defvar benedict-test--snapshot nil
  "Global registration state the enclosing helper use restores on exit.

Bound dynamically by `benedict-test-with-clean-registries', which is
what makes nested uses restore in the right order.")

(defun benedict-test--snapshot-registrations ()
  "Return the global registration state as a snapshot plist.

Registries are captured through their public list functions, hooks by
value, and the fake model catalog by its exact list identity.  The
captured objects are not copied, so restoring the snapshot puts back the
very objects registered when it was taken."
  (list :tools (benedict-tool-list)
        :providers (benedict-provider-list)
        :apis (benedict-api-list)
        :models benedict-provider-fake--models
        :hooks (mapcar (lambda (hook)
                         (cons hook (default-value hook)))
                       benedict-test-global-hooks)))

(defun benedict-test--restore-registry
    (snapshot current-function id-function unregister-function
              register-function)
  "Restore one registry to SNAPSHOT through its public functions.

CURRENT-FUNCTION returns the objects registered now.  ID-FUNCTION gets
an object's id, UNREGISTER-FUNCTION removes that id, and
REGISTER-FUNCTION restores each captured object.  Re-registering the
captured objects restores replacements by identity."
  (dolist (object (funcall current-function))
    (funcall unregister-function (funcall id-function object)))
  (dolist (object snapshot)
    (funcall register-function object)))

(defun benedict-test--restore-registrations (snapshot)
  "Put the global registration state back to SNAPSHOT, by identity.

Registry entries are put back as the same objects through their public
register functions, so replacements and added ids disappear.  Hook
variables are restored with `set-default', which does not touch
buffer-local values.  The fake model catalog is cleared through its
public cleanup function before the captured catalog is restored by
identity."
  (benedict-test--restore-registry
   (plist-get snapshot :tools)
   #'benedict-tool-list #'benedict-tool-id
   #'benedict-tool-unregister #'benedict-tool-register)
  (benedict-test--restore-registry
   (plist-get snapshot :providers)
   #'benedict-provider-list #'benedict-provider-id
   #'benedict-provider-unregister #'benedict-provider-register)
  (benedict-test--restore-registry
   (plist-get snapshot :apis)
   #'benedict-api-list #'benedict-api-id
   #'benedict-api-unregister #'benedict-api-register)
  (benedict-provider-fake-reset)
  (setq benedict-provider-fake--models (plist-get snapshot :models))
  (dolist (binding (plist-get snapshot :hooks))
    (set-default (car binding) (cdr binding))))

(defun benedict-test--uninstall-retry ()
  "Uninstall loaded retry extensions and cancel their pending state."
  (cond
   ((fboundp 'benedict-retry-http-uninstall)
    (benedict-retry-http-uninstall))
   ((fboundp 'benedict-retry-uninstall)
    (benedict-retry-uninstall))))

;; All production libraries required by the suite have loaded before this
;; point, while no test body has run.  Capture the baseline here rather than
;; lazily in `benedict-test-reset': tests may intentionally change global
;; values before entering the helper.
(unless benedict-test--baseline
  (setq benedict-test--baseline (benedict-test--snapshot-registrations)))

(defun benedict-test-reset ()
  "Restore global registrations and hooks to the suite baseline.

Tools, providers, APIs, fake models, and global hooks are process-wide,
so a test that changes one has to be prevented from changing the next
test's meaning.  The baseline was captured during suite setup, after
the production libraries loaded and before any test body ran."
  (benedict-test--uninstall-retry)
  (benedict-test--restore-registrations benedict-test--baseline))

(defmacro benedict-test-with-clean-registries (&rest body)
  "Evaluate BODY against the baseline registrations, then restore what was found.

On entry the global registries and default hook values are reset to the
baseline every suite starts from.  On exit -- through normal return, a
signal, or a nested use -- retry work created by BODY is cancelled and
the state this use found on entry is restored by identity.  A nested use
also restores the retry installation flags associated with its restored
hooks."
  (declare (indent 0) (debug body))
  `(let ((benedict-test--snapshot (benedict-test--snapshot-registrations))
         (benedict-test--retry-loaded (boundp 'benedict-retry--installed))
         (benedict-test--retry-installed
          (and (boundp 'benedict-retry--installed)
               (symbol-value 'benedict-retry--installed)))
         (benedict-test--retry-http-loaded
          (boundp 'benedict-retry-http--installed))
         (benedict-test--retry-http-installed
          (and (boundp 'benedict-retry-http--installed)
               (symbol-value 'benedict-retry-http--installed))))
     (unwind-protect
         (progn (benedict-test-reset) ,@body)
       (benedict-test--uninstall-retry)
       (benedict-test--restore-registrations benedict-test--snapshot)
       (when benedict-test--retry-loaded
         (set 'benedict-retry--installed benedict-test--retry-installed))
       (when benedict-test--retry-http-loaded
         (set 'benedict-retry-http--installed
              benedict-test--retry-http-installed)))))

(provide 'test-helper)

;;; test-helper.el ends here
