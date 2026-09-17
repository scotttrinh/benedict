;;; benedict-extension-contract-test.el --- Public extension contracts  -*- lexical-binding: t; -*-

;;; Commentary:

;; Executable examples showing that advanced clients can be built entirely on
;; Benedict's published interfaces.  Functions named
;; `benedict-contract-client-*' are the client boundary; ERT scaffolding may use
;; the shared deterministic scheduler and fake provider.

;;; Code:

(defconst benedict-extension-contract-test--file
  (or load-file-name buffer-file-name)
  "Source path used by the structural client scanner.")
(require 'ert)
(unless (bound-and-true-p benedict-extension-contract-test--minimal-load)
  (require 'test-helper))

(defun benedict-contract-client-approval-router (invocation next)
  "Apply the current session's approval policy to INVOCATION, then call NEXT."
  (pcase (plist-get (benedict-invocation-arguments invocation) :action)
    ('hold
     (benedict-session-put
      benedict-current-session :contract-approval
      (lambda () (funcall next invocation))))
    ('deny
     (funcall next (benedict-tool-blocked invocation "Denied by contract policy")))
    ('reroute
     (funcall next
              (benedict-invocation-with
               invocation
               :tool (benedict-session-get benedict-current-session
                                           :contract-routed-tool))))
    (_ (funcall next invocation))))

(ert-deftest benedict-extension-contract-approvals-and-routing ()
  "Public dispatch hooks support hold, deny, reroute, and stale approval safety."
  (benedict-test-with-clean-registries
    (let ((executions nil))
      (benedict-deftool benedict-contract-source
        :description "Exercise approval policy."
        :parameters '((action :type string :required t))
        :sync t
        :handler (lambda (invocation)
                   (push (benedict-invocation-arguments invocation) executions)
                   (benedict-tool-result :content "source")))
      (let ((routed
             (benedict-tool-create
              :id 'benedict-contract-routed
              :description "Execute approved work elsewhere."
              :parameters nil :sync t
              :handler (lambda (invocation)
                         (push (list :routed
                                     (benedict-invocation-arguments invocation))
                               executions)
                         (benedict-tool-result :content "routed")))))
        (benedict-test-with-manual-defer
          (let ((session
                 (benedict-test-session
                  '(((:tool-call benedict-contract-source (:action hold)))
                    ((:text "done")))
                  :tools '(benedict-contract-source))))
            (benedict-session-put session :contract-routed-tool routed)
            (benedict-session-add-hook
             session 'benedict-tool-dispatch-functions
             #'benedict-contract-client-approval-router)
            (benedict-session-submit session "hold")
            (benedict-test-drain)
            (let ((approval (benedict-session-get session :contract-approval)))
              (should (functionp approval))
              (funcall approval)
              (benedict-test-drain)
              (should (equal (car executions) '(:action hold))))
            (setq executions nil)
            (let ((stale
                   (benedict-test-session
                    '(((:tool-call benedict-contract-source (:action hold)))
                      ((:text "done")))
                    :tools '(benedict-contract-source))))
              (benedict-session-put stale :contract-routed-tool routed)
              (benedict-session-add-hook
               stale 'benedict-tool-dispatch-functions
               #'benedict-contract-client-approval-router)
              (benedict-session-submit stale "stale")
              (benedict-test-drain)
              (let ((approval (benedict-session-get stale :contract-approval)))
                (should (functionp approval))
                (benedict-session-abort stale)
                (benedict-test-drain)
                (funcall approval)
                (benedict-test-drain)
                (should-not executions))))
          (dolist (case '((deny "Denied by contract policy" nil)
                          (reroute "routed" (:routed (:action reroute)))))
            (let* ((action (nth 0 case))
                   (session
                    (benedict-test-session
                     `(((:tool-call benedict-contract-source
                                    (:action ,action)))
                       ((:text "done")))
                     :tools '(benedict-contract-source))))
              (setq executions nil)
              (benedict-session-put session :contract-routed-tool routed)
              (benedict-session-add-hook
               session 'benedict-tool-dispatch-functions
               #'benedict-contract-client-approval-router)
              (benedict-session-submit session (symbol-name action))
              (benedict-test-drain)
              (let* ((result-entry (seq-find
                                    (lambda (entry)
                                      (eq (benedict-entry-role entry) 'tool-result))
                                    (benedict-session-path session)))
                     (block (car (benedict-entry-content result-entry))))
                (should (equal (plist-get block :content) (nth 1 case))))
              (should (equal (car executions) (nth 2 case))))))))))

(defun benedict-contract-client-final-operation-gate (invocation next)
  "Route INVOCATION, then retain approval for that exact operation."
  (let* ((route (benedict-session-get benedict-current-session :contract-route))
         (final (if route (funcall route invocation) invocation)))
    (benedict-session-put benedict-current-session :contract-approved-operation final)
    (benedict-session-put
     benedict-current-session :contract-final-approval
     (lambda (allow)
       (funcall next
                (if allow final
                  (benedict-tool-blocked final "Denied final operation")))))))

(ert-deftest benedict-extension-contract-approval-covers-final-routed-operation ()
  "A cooperating policy composes routing before approval of one snapshot."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((executed nil)
             (source (benedict-tool-create
                      :id 'contract-source :parameters nil :sync t
                      :handler (lambda (_invocation)
                                 (setq executed 'source)
                                 (benedict-tool-result :content "source"))))
             (routed (benedict-tool-create
                      :id 'contract-routed :parameters nil :sync t
                      :handler (lambda (_invocation)
                                 (setq executed 'routed)
                                 (benedict-tool-result :content "routed"))))
             (session (benedict-test-session
                       '(((:tool-call contract-source nil)) ((:text "done")))
                       :tools (list source))))
        (benedict-session-put
         session :contract-route
         (lambda (invocation)
           (benedict-invocation-with invocation :tool routed)))
        (benedict-session-add-hook
         session 'benedict-tool-dispatch-functions
         #'benedict-contract-client-final-operation-gate)
        (benedict-session-submit session "go")
        (benedict-test-drain)
        (let ((approved (benedict-session-get
                         session :contract-approved-operation)))
          (should (eq (benedict-invocation-tool approved) routed)))
        (funcall (benedict-session-get session :contract-final-approval) t)
        (benedict-test-drain)
        (should (eq executed 'routed))))))

(defun benedict-contract-client-on-state (session _old new)
  "Cancel SESSION's test-owned work when NEW is stopping."
  (when (eq new 'stopping)
    (when-let* ((cancel (benedict-session-get session :contract-cancel)))
      (benedict-session-put session :contract-cancel nil)
      (funcall cancel))))

(defun benedict-contract-client-shape-result (result _invocation)
  "Shape RESULT without changing its call identity."
  (benedict-tool-result
   :content (substring (benedict-tool-result-value-content result) 0 4)
   :meta (list :contract-shaped t
               :original-length (length (benedict-tool-result-value-content result)))))

(defun benedict-contract-client-change-request (request _model _session)
  "Add a request-local marker without changing stored history."
  (plist-put (copy-sequence request) :contract-marker "changed"))


(defun benedict-contract-client-adapt-build (request model base)
  "Compose BASE's public builder with a request-local option."
  (let ((body (json-parse-string
               (funcall (benedict-api-build base) request model)
               :object-type 'plist :array-type 'array
               :false-object :false :null-object nil)))
    (setq body (plist-put body :contract-option
                          (plist-get request :contract-option)))
    (json-serialize body :false-object :false :null-object nil)))
(defun benedict-contract-client-compact-filter (entries session)
  "Reconstruct compacted context without changing SESSION."
  (if-let ((note
            (seq-find
             (lambda (entry)
               (benedict-entry-meta-get entry :contract-compaction))
             entries)))
      (let* ((meta (benedict-entry-meta-get note :contract-compaction))
             (suffix-ids (plist-get meta :suffix-ids))
             (note-ids (plist-get meta :note-ids))
             (suffix (delq nil
                           (mapcar (lambda (id)
                                     (benedict-session-entry session id))
                                   suffix-ids)))
             (notes (delq nil
                          (mapcar (lambda (id)
                                    (benedict-session-entry session id))
                                  note-ids)))
             (notes (seq-filter #'benedict-entry-context-p notes))
             (known-note-ids (mapcar #'benedict-entry-id notes))
             (notes (append
                     notes
                     (seq-remove
                      (lambda (entry)
                        (or (not (benedict-entry-note-p entry))
                            (member (benedict-entry-id entry)
                                    known-note-ids)))
                      entries)))
             (live (seq-remove
                    (lambda (entry)
                      (or (benedict-entry-note-p entry)
                          (member (benedict-entry-id entry) suffix-ids)))
                    entries)))
        (append notes suffix live))
    entries))

(defun benedict-contract-client-compact (entries session)
  "Fork before a range and append a deterministic context summary."
  (let* ((range (or (benedict-session-get session :contract-range) 0))
         (path (benedict-session-path session))
         (count (min range (length path)))
         (suffix (nthcdr count path))
         (durable-notes
          (seq-filter
           (lambda (entry)
             (and (benedict-entry-note-p entry)
                  (benedict-entry-context-p entry)))
           path)))
    (while (and (> count 0)
                (benedict-entry-tool-result-p (car suffix)))
      (setq count (1- count)
            suffix (nthcdr count path)))
    (let ((parent (and (> count 0)
                       (benedict-entry-parent (car path)))))
      (benedict-session-fork session parent)
      (let* ((note (benedict-session-note
                    session "Summary: compacted"
                    `(:context t
                      :contract-compaction
                      (:version 1
                       :note-ids ,(mapcar #'benedict-entry-id durable-notes)
                       :suffix-ids ,(mapcar #'benedict-entry-id suffix)))))
             (new-meta (benedict-entry-meta note)))
        (benedict-session-put session :contract-compaction
                              (plist-get new-meta :contract-compaction))
        (append durable-notes (list note) suffix)))))

(ert-deftest benedict-extension-contract-background-cleanup-exactly-once ()
  "A property-owned cleanup runs once, late work is ignored, and B is untouched."
  (benedict-test-with-clean-registries
    (let ((pending nil) (a-cancelled 0) (b-cancelled 0))
      (benedict-deftool benedict-contract-held-tool
        :description "Hold test-owned work."
        :parameters nil
        :handler (lambda (_invocation done) (setq pending done)))
      (benedict-test-with-manual-defer
        (let ((a (benedict-test-session
                  '(((:tool-call benedict-contract-held-tool nil)))
                  :tools '(benedict-contract-held-tool)))
              (b (benedict-session-create)))
          (benedict-session-put a :contract-cancel
                                (lambda () (cl-incf a-cancelled)))
          (benedict-session-put b :contract-cancel
                                (lambda () (cl-incf b-cancelled)))
          (benedict-session-add-hook a 'benedict-state-change-functions
                                     #'benedict-contract-client-on-state)
          (benedict-session-submit a "hold")
          (benedict-test-drain)
          (should pending)
          (benedict-session-abort a)
          (benedict-test-drain)
          (should (= a-cancelled 1))
          (should (= b-cancelled 0))
          (funcall pending (benedict-tool-result :content "late"))
          (benedict-test-drain)
          (should (= a-cancelled 1))
          (should (= (length (seq-filter #'benedict-entry-tool-result-p
                                         (benedict-session-path a))) 0))
          (benedict-session-abort a)
          (should (= a-cancelled 1)))))))

(ert-deftest benedict-extension-contract-result-shaping-preserves-identity ()
  "A result filter exposes truncation and metadata without duplicate entries."
  (benedict-test-with-clean-registries
    (benedict-deftool benedict-contract-shape-tool
      :description "Shape this result." :parameters nil :sync t
      :handler (lambda (_invocation) (benedict-tool-result :content "long text")))
    (benedict-test-with-manual-defer
      (let ((seen nil)
            (session (benedict-test-session
                      '(((:tool-call benedict-contract-shape-tool nil)))
                      :tools '(benedict-contract-shape-tool))))
        (benedict-session-add-hook session 'benedict-tool-result-filter-functions
                                   #'benedict-contract-client-shape-result)
        (benedict-session-add-hook
         session 'benedict-tool-end-functions
         (lambda (_session _invocation result) (setq seen result)))
        (benedict-session-submit session "shape")
        (benedict-test-drain)
        (should (equal (benedict-tool-result-value-content seen) "long"))
        (should (plist-get (benedict-tool-result-value-meta seen) :contract-shaped))
        (let* ((assistant (seq-find #'benedict-entry-assistant-p
                                    (benedict-session-path session)))
               (call (seq-find
                      (lambda (block)
                        (eq (benedict-block-type block) 'tool-call))
                      (benedict-entry-content assistant)))
               (result (seq-find #'benedict-entry-tool-result-p
                                 (benedict-session-path session)))
               (result-block
                (seq-find
                 (lambda (block)
                   (eq (benedict-block-type block) 'tool-result))
                 (benedict-entry-content result))))
          (should (equal (plist-get result-block :id)
                         (plist-get call :id)))
          (should (= 1 (length (seq-filter #'benedict-entry-tool-result-p
                                           (benedict-session-path session))))))))))

(ert-deftest benedict-extension-contract-model-change-retains-origin ()
  "A restored model change keeps origin, selects its provider, and appends."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
      (benedict-test-with-manual-defer
        (let* ((old-script (benedict-provider-fake-script nil))
               (old (benedict-provider-fake-model old-script :id "old-model"))
               (new-script (benedict-provider-fake-script nil))
               (new (benedict-provider-fake-model new-script :id "new-model"))
               (session (benedict-session-create
                         :id "contract-model" :model old))
               (old-request '(:entries nil :system-prompt nil))
               (store (benedict-store-open "contract-model"
                                           :directory directory)))
          (benedict-session-append
           session (benedict-entry-create
                    :role 'assistant :content "old"
                    :meta (benedict-test-origin-meta old)))
          (setf (benedict-session-model session) new)
          (benedict-session-note session "model changed"
                                 '(:contract-change t))
          (let ((changed (benedict-contract-client-change-request
                          old-request new session)))
            (should (equal (plist-get changed :contract-marker) "changed"))
            (should-not (plist-member old-request :contract-marker)))
          (should (equal (benedict-entry-origin
                          (car (benedict-session-path session)))
                         (benedict-test-origin-meta old)))
          (should-not (benedict-entry-context-p
                       (car (last (benedict-session-path session)))))
          (benedict-store-install)
          (unwind-protect
              (progn
                ;; Persist the existing tree before attaching the live store:
                ;; an attached note whose parent was not stored would be invalid.
                (dolist (entry (benedict-session-entries session))
                  (benedict-store-append store entry))
                (benedict-store-attach session store)
                (benedict-session-note session "persisted change"
                                       '(:contract-change t))
                (benedict-store-close store (benedict-session-head session))
                (let ((warnings nil)
                      (loaded nil))
                  (cl-letf (((symbol-function 'display-warning)
                             (lambda (_type message &rest _)
                               (push message warnings))))
                    (setq loaded (benedict-store-load
                                  "contract-model" :directory directory)))
                  (should-not warnings)
                  (let* ((reopened (benedict-store-open
                                    "contract-model" :directory directory))
                         (resume-script
                          (benedict-provider-fake-script '(((:text "resumed")))))
                       (resume-model
                        (benedict-provider-fake-model
                         resume-script :id "new-model"))
                       (resumed (benedict-session-create
                                 :transcript loaded
                                 :model "fake/new-model"
                                 :store reopened)))
                  (benedict-session-add-hook
                   resumed 'benedict-request-filter-functions
                   #'benedict-contract-client-change-request)
                  (benedict-session-submit resumed "after")
                  (benedict-test-drain)
                  (let ((request
                         (benedict-provider-fake-last-request resume-script)))
                    (should (eq (plist-get request :model) resume-model))
                    (should (equal (plist-get request :contract-marker)
                                   "changed"))
                    (should (equal
                             (benedict-entry-text
                              (car (last (plist-get request :entries))))
                             "after"))
                    (should-not
                     (seq-some
                      (lambda (entry)
                        (benedict-entry-meta-get entry :contract-change))
                      (plist-get request :entries))))
                  (should (equal
                           (mapcar #'benedict-entry-id
                                   (benedict-session-path resumed))
                           '("contract-model-e0001"
                             "contract-model-e0002"
                             "contract-model-e0003"
                             "contract-model-e0004"
                             "contract-model-e0005")))
                  (should (= 2 (length
                                (seq-filter
                                 (lambda (entry)
                                   (benedict-entry-meta-get
                                    entry :contract-change))
                                 (benedict-session-entries resumed)))))
                  (benedict-store-close reopened
                                        (benedict-session-head resumed))))
            (benedict-store-uninstall))))))))

(defun benedict-contract-client-skill-request (request _model session)
  "Inject a session-local skill description into REQUEST."
  (plist-put (copy-sequence request) :system-prompt
             (concat (or (plist-get request :system-prompt) "")
                     "\n" (or (benedict-session-get session :contract-skill) ""))))

(defun benedict-contract-client-read-skill (_invocation)
  "Read the calling session's local skill description."
  (benedict-tool-result
   :content (benedict-session-get benedict-current-session :contract-skill)))

(defun benedict-contract-client-root-tool (root)
  "Return a tool handler lexically capturing ROOT."
  (lambda (_invocation)
    (benedict-tool-result :content root)))

(defun benedict-contract-client-deferred-credentials (model request callback)
  "Acquire made-up credentials through a fixture-owned deferred callback."
  (funcall callback model request "in-memory-contract-secret"))

(cl-defun benedict-contract-client-fresh-resume (transcript model &optional store)
  "Reconstruct extension state from TRANSCRIPT's durable configuration note."
  (let* ((note (seq-find
                (lambda (entry)
                  (and (benedict-entry-note-p entry)
                       (equal (benedict-entry-text entry)
                              "Contract extension configuration")))
                (reverse (benedict-transcript-path transcript))))
         (config (benedict-entry-meta-get note :contract-extension))
         (session (benedict-session-create
                   :transcript transcript
                   :model model
                   :system-prompt (plist-get config :system-prompt)
                   :store store)))
    (benedict-session-put session :project-root
                          (plist-get config :project-root))
    (benedict-session-add-hook
     session 'benedict-request-filter-functions
     #'benedict-contract-client-change-request)
    session))

(ert-deftest benedict-extension-contract-skills-are-session-local ()
  "Two sessions compose distinct skills through request and tool hooks."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((script-a
              (benedict-provider-fake-script
               '(((:tool-call benedict-contract-read-a nil :id "call-a"))
                 ((:text "a")))))
             (script-b
              (benedict-provider-fake-script
               '(((:tool-call benedict-contract-read-b nil :id "call-b"))
                 ((:text "b")))))
             (tool-a (benedict-tool-create
                      :id 'benedict-contract-read-a :parameters nil :sync t
                      :handler #'benedict-contract-client-read-skill))
             (tool-b (benedict-tool-create
                      :id 'benedict-contract-read-b :parameters nil :sync t
                      :handler #'benedict-contract-client-read-skill))
             (a (benedict-session-create
                 :model (benedict-provider-fake-model script-a :id "a")
                 :system-prompt "base" :tools (list tool-a)))
             (b (benedict-session-create
                 :model (benedict-provider-fake-model script-b :id "b")
                 :system-prompt "base" :tools (list tool-b))))
        (benedict-session-put a :contract-skill "skill-a")
        (benedict-session-put b :contract-skill "skill-b")
        (benedict-session-add-hook
         a 'benedict-request-filter-functions #'benedict-contract-client-skill-request)
        (benedict-session-add-hook
         b 'benedict-request-filter-functions #'benedict-contract-client-skill-request)
        (should (equal (mapcar #'benedict-tool-id
                               (benedict-session-tool-list a))
                       '(benedict-contract-read-a)))
        (should (equal (mapcar #'benedict-tool-id
                               (benedict-session-tool-list b))
                       '(benedict-contract-read-b)))
        (benedict-session-submit a "go")
        (benedict-session-submit b "go")
        (benedict-test-drain)
        (should (equal
                 (plist-get (benedict-provider-fake-last-request script-a)
                            :system-prompt)
                 "base\nskill-a"))
        (should (equal
                 (plist-get (benedict-provider-fake-last-request script-b)
                            :system-prompt)
                 "base\nskill-b"))
        (let* ((result-a
                (seq-find #'benedict-entry-tool-result-p
                          (benedict-session-path a)))
               (result-b
                (seq-find #'benedict-entry-tool-result-p
                          (benedict-session-path b))))
          (should (equal (plist-get (car (benedict-entry-content result-a))
                                    :content)
                         "skill-a"))
          (should (equal (plist-get (car (benedict-entry-content result-b))
                                    :content)
                         "skill-b")))
        (should (equal (benedict-session-system-prompt a) "base"))
        (should (equal (benedict-session-system-prompt b) "base"))
        (dolist (session (list a b))
          (should-not
           (seq-some (lambda (entry)
                       (member (benedict-entry-text entry)
                               '("skill-a" "skill-b")))
                     (benedict-session-path session))))))))

(ert-deftest benedict-extension-contract-project-root-is-captured ()
  "A lexical project tool survives ambient context changes in a run."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let* ((root "/captured/project")
             (tool (benedict-tool-create
                    :id 'benedict-contract-root-tool :parameters nil :sync t
                    :handler (benedict-contract-client-root-tool root)))
             (session (benedict-test-session
                       '(((:tool-call benedict-contract-root-tool nil))
                         ((:text "done")))
                       :tools (list tool))))
        (benedict-session-submit session "go")
        (with-temp-buffer
          (setq default-directory "/other/")
          (benedict-test-drain))
        (let ((result (car (last
                            (seq-filter #'benedict-entry-tool-result-p
                                        (benedict-session-path session))))))
          (should (equal
                   (plist-get (car (benedict-entry-content result)) :content)
                   "/captured/project")))
        (should (benedict-session-path session))))))
(ert-deftest benedict-extension-contract-adapter-composes-public-accessors ()
  "An adapter delegates public slots and leaves its base registration unchanged."
  (benedict-test-with-clean-registries
    (let ((endpoint-called 0) (headers-called 0) (parser-called 0))
      (benedict-defapi contract-base
        :name "Base"
        :endpoint (lambda (_model _auth)
                    (cl-incf endpoint-called)
                    "contract://base")
        :headers (lambda (_model _auth)
                   (cl-incf headers-called)
                   '(:x "base"))
        :make-parser (lambda () (cl-incf parser-called) #'ignore)
        :build (lambda (_request _model) "{\"input\":[],\"stream\":true}"))
      (let* ((base (benedict-api-get 'contract-base))
             (original-request '(:contract-option "x"))
             (request-copy (copy-tree original-request))
             (original (funcall (benedict-api-build base) nil nil))
             (original-endpoint (benedict-api-endpoint base))
             (original-headers (benedict-api-headers base))
             (original-parser (benedict-api-make-parser base)))
        (benedict-defapi contract-adapter
          :name "Adapter" :endpoint (benedict-api-endpoint base)
          :headers (benedict-api-headers base)
          :make-parser (benedict-api-make-parser base)
          :build (lambda (request model)
                   (benedict-contract-client-adapt-build request model base)))
        (let* ((adapter (benedict-api-get 'contract-adapter))
               (body (json-parse-string
                      (funcall (benedict-api-build adapter)
                               original-request nil)
                      :object-type 'plist :array-type 'array)))
          (should (equal (plist-get body :contract-option) "x"))
          (should (equal (plist-get body :input) []))
          (should (equal (funcall (benedict-api-endpoint adapter) nil nil)
                         "contract://base"))
          (should (equal (funcall (benedict-api-headers adapter) nil nil)
                         '(:x "base")))
          (should (functionp (funcall (benedict-api-make-parser adapter))))
          (should (= endpoint-called 1))
          (should (= headers-called 1))
          (should (= parser-called 1))
          (should (equal request-copy original-request))
          (let ((base-after (benedict-api-get 'contract-base)))
            (should (eq base-after base))
            (should (eq (benedict-api-build base-after)
                        (benedict-api-build base))))
          (should (eq original-endpoint (benedict-api-endpoint base)))
          (should (eq original-headers (benedict-api-headers base)))
          (should (eq original-parser (benedict-api-make-parser base)))
          (should (equal original (funcall (benedict-api-build base) nil nil))))))))

(ert-deftest benedict-extension-contract-provider-credentials-are-deferred ()
  "A fixture-owned deferred credential enables two turns and terminal auth errors."
  (benedict-test-with-clean-registries
    (benedict-deftool benedict-contract-provider-tool
      :description "Complete the subscription round trip."
      :parameters nil :sync t
      :handler (lambda (_invocation)
                 (benedict-tool-result :content "tool-result")))
    (let ((handlers nil) (credential nil) (turn 0) (sent 0)
          (cancelled nil) (model nil))
      (benedict-defapi contract-stream-wire
        :name "Contract stream wire"
        :endpoint (lambda (_model _auth) "contract://local")
        :headers (lambda (_model _auth) nil)
        :make-parser (lambda () #'ignore)
        :build (lambda (_request _model) "{}"))
      (benedict-defprovider contract-subscription
        :name "Contract subscription"
        :stream
        (lambda (_model _request handler)
          (push handler handlers)
          (benedict-test--defer
           (lambda ()
             (unless cancelled
               (if (plist-get (benedict-model-meta _model) :auth-failure)
                 (funcall handler '(:type :error :reason error
                                    :message "in-memory credential rejected"))
               (benedict-contract-client-deferred-credentials
                _model _request
                (lambda (resolved-model _resolved-request _secret)
                  (setq credential resolved-model)
                  (cl-incf sent)
                  (if (= turn 0)
                      (progn
                        (setq turn 1)
                        (funcall handler '(:type :start))
                        (funcall handler '(:type :block-start :index 0
                                           :block-type tool-call :id "call_1"
                                           :name benedict-contract-provider-tool))
                        (funcall handler '(:type :block-delta :index 0
                                           :delta "nil"))
                        (funcall handler '(:type :block-end :index 0
                                           :arguments nil))
                        (funcall handler '(:type :done :reason tool-use)))
                    (funcall handler '(:type :start))
                    (funcall handler '(:type :block-start :index 0
                                       :block-type text))
                    (funcall handler '(:type :block-delta :index 0
                                       :delta "second turn"))
                    (funcall handler '(:type :block-end :index 0))
                    (funcall handler '(:type :done :reason stop)))))))))
          (lambda () (setq cancelled t))))
      (let ((round-trip
             (benedict-session-create
              :model (setq model
                           (benedict-model-create
                            :id "m" :provider 'contract-subscription
                            :api 'contract-stream-wire))
              :tools '(benedict-contract-provider-tool))))
        (benedict-test-with-manual-defer
          (benedict-session-submit round-trip "go")
          (should-not credential)
          (benedict-test-drain)
          (should credential)
          (should (= sent 2))
          (should (equal (mapcar #'benedict-entry-role
                                 (benedict-session-path round-trip))
                         '(user assistant tool-result assistant)))
          (let ((result (car (seq-filter #'benedict-entry-tool-result-p
                                         (benedict-session-path round-trip)))))
            (should (equal (plist-get (car (benedict-entry-content result)) :content)
                           "tool-result"))))
      (let ((cancel-session
             (benedict-session-create :model model
                                      :tools '(benedict-contract-provider-tool))))
        (setq handlers nil)
        (benedict-test-with-manual-defer
          (benedict-session-submit cancel-session "cancel")
          (while (and (null handlers) (benedict-test-step)))
          (should handlers)
          (benedict-session-abort cancel-session)
          (benedict-test-drain)
          (should cancelled)
          (should (= sent 2)))
      (setq cancelled nil)
      (let ((failure-session
             (benedict-session-create
              :model (benedict-model-create
                      :id "auth-failure" :provider 'contract-subscription
                      :api 'contract-stream-wire :meta '(:auth-failure t))
              :tools '(benedict-contract-provider-tool))))
        (benedict-test-with-manual-defer
          (benedict-session-submit failure-session "auth")
          (benedict-test-drain)
          (should (eq (benedict-session-state failure-session) 'idle))
          (should (eq (benedict-session-stop-reason failure-session) 'error)))))))))
(ert-deftest benedict-extension-contract-compaction-preserves-suffix-and-branches ()
  "Compaction forks before a pair and restores its suffix after reload."
  (benedict-test-with-clean-registries
    (benedict-store-uninstall)
    (benedict-test-with-store-dir directory
      (benedict-test-with-manual-defer
        (let* ((script
                (benedict-provider-fake-script
                 (cl-loop repeat 10 collect '((:text "provider")))))
               (model (benedict-provider-fake-model
                       script :id "fake-model"))
               (session (benedict-session-create
                         :id "contract-compact" :model model))
               (remember (benedict-session-note
                          session "Remember contract context" '(:context t)))
               (one (benedict-session-append
                     session (benedict-entry-create :role 'user
                                                    :content (make-string 1000 ?x))))
               (call (benedict-session-append
                      session
                      (benedict-entry-create
                       :role 'assistant
                       :content (list (benedict-block-tool-call
                                       "call-1" 'contract-tool nil)))))
               (result (benedict-session-append
                        session
                        (benedict-entry-create
                         :role 'tool-result
                         :content (list (benedict-block-tool-result
                                         "call-1" 'contract-tool "ok")))))
               (tail (benedict-session-append
                      session (benedict-entry-create :role 'user
                                                     :content "tail")))
               (baseline
                (copy-tree
                 (seq-filter #'benedict-entry-context-p
                             (benedict-session-path session))))
               (old-head (benedict-entry-id tail))
               (snapshot
                (let (rows)
                  (dolist (entry (benedict-session-entries session))
                    (push (list (benedict-entry-id entry)
                                (benedict-entry-parent entry)
                                (benedict-entry-role entry)
                                (copy-tree (benedict-entry-content entry))
                                (copy-tree (benedict-entry-meta entry)))
                          rows))
                  (nreverse rows))))
        ;; Replace the context note and first user entry.  The tool pair starts
        ;; the suffix, so no call/result boundary is split.
        (benedict-session-put session :contract-range 3)
        (let* ((out (benedict-contract-client-compact
                     (benedict-session-path session) session))
               (summary-id (benedict-session-head session))
               (summary (benedict-session-entry session summary-id)))
          (should (equal (mapcar #'benedict-entry-text
                                 (seq-filter #'benedict-entry-note-p out))
                         '("Remember contract context" "Summary: compacted")))
          (should (equal (mapcar #'benedict-entry-role
                                 (seq-remove #'benedict-entry-note-p out))
                         '(assistant tool-result user)))
          (should (equal (plist-get
                          (benedict-entry-meta-get
                           summary :contract-compaction)
                          :suffix-ids)
                         (list (benedict-entry-id call)
                               (benedict-entry-id result)
                               (benedict-entry-id tail))))
          (should-not (benedict-entry-parent summary))
          (should (equal (benedict-entry-parent call)
                         (benedict-entry-id one)))
          (should (equal (benedict-entry-parent result)
                         (benedict-entry-id call)))
          (dolist (row snapshot)
            (let ((entry (benedict-session-entry session (car row))))
              (should (equal
                       row
                       (list (benedict-entry-id entry)
                             (benedict-entry-parent entry)
                             (benedict-entry-role entry)
                             (copy-tree (benedict-entry-content entry))
                             (copy-tree (benedict-entry-meta entry)))))))
          (benedict-session-add-hook
           session 'benedict-context-filter-functions
           #'benedict-contract-client-compact-filter)
          (benedict-session-submit session "next")
          (benedict-test-drain)
          (let ((request (benedict-provider-fake-last-request script)))
            (should (equal (mapcar #'benedict-entry-role
                                   (plist-get request :entries))
                           '(note note assistant tool-result user user)))
            (should (equal (mapcar #'benedict-entry-text
                                   (seq-filter #'benedict-entry-note-p
                                               (plist-get request :entries)))
                           '("Remember contract context" "Summary: compacted")))
            (should (< (length (prin1-to-string
                                (butlast (plist-get request :entries))))
                       (length (prin1-to-string baseline))))
            (should (equal
                     (mapcar #'benedict-entry-id
                             (seq-filter
                              (lambda (entry)
                                (memq (benedict-entry-role entry)
                                      '(assistant tool-result user)))
                              (plist-get request :entries)))
                     (list (benedict-entry-id call)
                           (benedict-entry-id result)
                           (benedict-entry-id tail)
                           (benedict-entry-id
                            (car (last (plist-get request :entries))))))))
          (benedict-session-fork session old-head)
          (should (equal (mapcar #'benedict-entry-id
                                 (benedict-session-path session))
                         (mapcar #'car snapshot)))
          (benedict-session-submit session "old branch")
          (benedict-test-drain)
          (let ((request (benedict-provider-fake-last-request script)))
            (should (equal
                     (mapcar #'benedict-entry-id
                             (butlast (plist-get request :entries)))
                     (mapcar #'car snapshot))))
          (benedict-session-fork session summary-id)
          (let ((store (benedict-store-open "contract-compact"
                                            :directory directory)))
            (unwind-protect
                (progn
                  (dolist (entry (benedict-session-entries session))
                    (benedict-store-append store entry))
                  (benedict-store-close store summary-id)
                  (let* ((loaded
                          (let ((benedict-store-strict-load t))
                            (benedict-store-load
                             "contract-compact" :directory directory)))
                         (reopened (benedict-store-open
                                    "contract-compact" :directory directory))
                         (resume-script
                          (benedict-provider-fake-script '(((:text "resumed")))))
                         (resume-model
                          (benedict-provider-fake-model
                           resume-script :id "fake-model"))
                         (resumed (benedict-session-create
                                   :transcript loaded
                                   :model resume-model)))
                    (should (equal
                             (benedict-entry-meta-get
                              (benedict-session-entry resumed summary-id)
                              :contract-compaction)
                             (benedict-entry-meta-get
                              summary :contract-compaction)))
                    (benedict-session-add-hook
                     resumed 'benedict-context-filter-functions
                     #'benedict-contract-client-compact-filter)
                    (benedict-session-submit resumed "resume")
                    (benedict-test-drain)
                    (let ((request
                           (benedict-provider-fake-last-request resume-script)))
                      (should (equal (mapcar #'benedict-entry-role
                                             (plist-get request :entries))
                                     '(note note assistant tool-result user user)))
                      (should (equal (mapcar #'benedict-entry-text
                                             (seq-filter #'benedict-entry-note-p
                                                         (plist-get request :entries)))
                                     '("Remember contract context"
                                       "Summary: compacted")))
                      (should (equal
                               (mapcar #'benedict-entry-id
                                       (seq-filter
                                        (lambda (entry)
                                          (memq (benedict-entry-role entry)
                                                '(assistant tool-result user)))
                                        (plist-get request :entries)))
                               (list (benedict-entry-id call)
                                     (benedict-entry-id result)
                                     (benedict-entry-id tail)
                                     (benedict-entry-id
                                      (car (last (plist-get request :entries))))))))
                    (dolist (row snapshot)
                      (let ((entry (benedict-session-entry resumed (car row))))
                        (should (equal
                                 row
                                 (list (benedict-entry-id entry)
                                       (benedict-entry-parent entry)
                                       (benedict-entry-role entry)
                                       (copy-tree (benedict-entry-content entry))
                                       (copy-tree (benedict-entry-meta entry))))))
                    (benedict-store-close reopened nil))
              (ignore-errors (benedict-store-close store nil)))))
        ;; A nil-root compaction still creates a durable context replacement.
        (let ((empty (benedict-session-create :id "contract-empty")))
          (benedict-session-put empty :contract-range 0)
          (let ((out (benedict-contract-client-compact nil empty)))
            (should (equal (mapcar #'benedict-entry-text out)
                           '("Summary: compacted")))
            (should-not (benedict-entry-parent
                         (car out))))))))))))

(ert-deftest benedict-extension-contract-fresh-process-resume-uses-public-load ()
  "A fresh -Q child loads, resumes, and durably appends a session."
  (benedict-test-with-clean-registries
    (benedict-test-with-store-dir directory
    (benedict-test-with-manual-defer
      (let* ((session-id "contract-fresh")
             (store (benedict-store-open session-id :directory directory))
             (script (benedict-provider-fake-script '(((:text "parent")))))
             (model (benedict-provider-fake-model script :id "fake-model"))
             (session (benedict-session-create :id session-id :model model
                                               :store store))
             (child-file (make-temp-file "benedict-contract-child-" nil ".el"))
             (output (generate-new-buffer " *contract-child*"))
             (process nil))
        (benedict-store-install)
        (unwind-protect
            (progn
              (benedict-session-note
               session "Contract extension configuration"
               '(:contract-extension
                 (:version 1 :model "fake/fake-model"
                  :project-root "/contract/project/"
                  :system-prompt "Contract instructions")))
              (benedict-session-submit session "before")
              (benedict-test-drain)
              (benedict-store-close store (benedict-session-head session))
              (with-temp-file child-file
                (insert
                 (format
                  "(progn
                     (require 'benedict)
                     (require 'benedict-message)
                     (require 'benedict-tool)
                     (require 'benedict-provider)
                     (require 'benedict-session)
                     (require 'benedict-core)
                     (require 'benedict-provider-fake)
                     (require 'benedict-store)
                     (benedict-store-install)
                     (let ((queue nil)
                           (benedict-core-defer-function
                            (lambda (thunk)
                              (setq queue (append queue (list thunk))))))
                       (let* ((loaded (benedict-store-load %S :directory %S))
                              (child-store (benedict-store-open %S :directory %S))
                              (child-script
                               (benedict-provider-fake-script '(((:text \"child\")))))
                              (child-model
                               (benedict-provider-fake-model
                                child-script :id \"fake-model\"))
                              (resumed
                               (benedict-contract-client-fresh-resume
                                loaded child-model child-store)))
                         (benedict-session-submit resumed \"after\")
                         (while queue
                           (funcall (pop queue)))
                         (let ((request
                                (benedict-provider-fake-last-request child-script)))
                         (unless (and (equal (plist-get request :system-prompt)
                                             \"Contract instructions\")
                                      (equal (benedict-entry-text
                                              (car (last (plist-get request :entries))))
                                             \"after\")
                                      (equal
                                       (mapcar #'benedict-entry-id
                                               (benedict-session-path resumed))
                                       '(\"contract-fresh-e0001\"
                                         \"contract-fresh-e0002\"
                                         \"contract-fresh-e0003\"
                                         \"contract-fresh-e0004\"
                                         \"contract-fresh-e0005\")))
                           (error \"child resume assertions failed\"))
                       (benedict-store-close
                        child-store (benedict-session-head resumed))
                       (princ \"contract-child-resumed\")))))"
                  session-id directory session-id directory)))
              (let ((args
                     (list "-Q" "--batch"
                           "-L" (expand-file-name "core" benedict-test-root)
                           "-L" (expand-file-name "support" benedict-test-root)
                           "-L" (expand-file-name "api" benedict-test-root)
                           "-L" (expand-file-name "providers" benedict-test-root)
                           "-L" (expand-file-name "ext" benedict-test-root)
                           "-L" (expand-file-name "test" benedict-test-root)
                           "--eval"
                           "(setq benedict-extension-contract-test--minimal-load t)"
                           "-l" benedict-extension-contract-test--file
                           "-l" child-file)))
                (setq process
                      (apply #'start-process
                             "benedict-contract-child" output
                             (expand-file-name invocation-name
                                                invocation-directory)
                             args))
                (while (process-live-p process)
                  (accept-process-output process 0.05))
                (let ((status (process-exit-status process)))
                  (should (= status 0))
                  (with-current-buffer output
                    (should (string-match-p "contract-child-resumed"
                                            (buffer-string)))))
                (let ((loaded (benedict-store-load session-id
                                                   :directory directory)))
                  (should (equal
                           (mapcar #'benedict-entry-id
                                   (benedict-transcript-entries loaded))
                           '("contract-fresh-e0001"
                             "contract-fresh-e0002"
                             "contract-fresh-e0003"
                             "contract-fresh-e0004"
                             "contract-fresh-e0005"))))))
          (when (and process (process-live-p process))
            (delete-process process))
          (ignore-errors (delete-file child-file))
          (kill-buffer output)
          (benedict-store-uninstall)))))))

(defun benedict-contract-collect-symbols (form)
  "Return symbols occurring in FORM, including quoted client data."
  (let (symbols)
    (cl-labels ((walk (value)
                  (cond
                   ((symbolp value) (push value symbols))
                   ((consp value) (walk (car value)) (walk (cdr value))))))
      (walk form))
    symbols))

(defun benedict-contract-forms (&optional source all)
  "Read SOURCE and return client declarations, or every form when ALL.

SOURCE is a temporary string for structural canaries, or nil for this file."
  (with-temp-buffer
    (if source
        (insert source)
      (insert-file-contents benedict-extension-contract-test--file))
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (or all
                        (and (memq (car-safe form) '(defun cl-defun))
                             (string-prefix-p
                              "benedict-contract-client-"
                              (symbol-name (cadr form)))))
                (push form forms))))
        (end-of-file nil))
      (nreverse forms))))

(defun benedict-contract-redefinition-p (form)
  "Return non-nil when FORM redefines a production Benedict symbol."
  (let* ((head (car-safe form))
         (target (pcase head
                   ((or 'defun 'cl-defun 'defsubst) (cadr form))
                   ((or 'defalias 'fset) (cadr form))
                   (_ nil)))
         (target (if (and (consp target) (eq (car target) 'quote))
                     (cadr target)
                   target)))
    (and (symbolp target)
         (string-prefix-p "benedict-" (symbol-name target))
         (not (string-prefix-p "benedict-contract-client-"
                               (symbol-name target))))))
(defun benedict-contract-redefinition-in-form-p (form)
  "Return non-nil when FORM or any nested form redefines Benedict code."
  (or (benedict-contract-redefinition-p form)
      (and (consp form)
           (or (benedict-contract-redefinition-in-form-p (car form))
               (benedict-contract-redefinition-in-form-p (cdr form))))))


(defun benedict-contract-forbidden-symbol-p (symbol)
  "Return non-nil when SYMBOL is outside the published client surface."
  (let ((text (symbol-name symbol)))
    (or (string-match-p "--" text)
        (memq symbol '(benedict-session-run advice-add advice-remove))
        (string-match-p "\\`benedict-.*registry" text))))

(ert-deftest benedict-extension-contract-structural-canary-is-rejected ()
  "The structural checker rejects temporary private client violations."
  (let ((private-canary
         "(cl-defun benedict-contract-client-canary (x)
            (benedict-session-run x))")
        (redefinition-canary
         "(defun benedict-contract-client-canary ()
            (defalias 'benedict-session-submit #'ignore))"))
    (unwind-protect
        (progn
          (should
           (seq-some
            (lambda (form)
              (seq-some #'benedict-contract-forbidden-symbol-p
                        (benedict-contract-collect-symbols (cdddr form))))
            (benedict-contract-forms private-canary)))
          (should
           (seq-some #'benedict-contract-redefinition-in-form-p
                     (benedict-contract-forms redefinition-canary))))
      (setq private-canary nil
            redefinition-canary nil))
    (should-not (benedict-contract-forbidden-symbol-p 'benedict-session-put))
    (should-not (benedict-contract-redefinition-p
                 '(defun benedict-contract-client-ok () t)))))


(ert-deftest benedict-extension-contract-client-bodies-use-public-interfaces ()
  "Named client bodies do not reach private kernel implementation details."
  (dolist (form (benedict-contract-forms))
    (should-not (benedict-contract-redefinition-in-form-p form))
    (dolist (symbol (benedict-contract-collect-symbols (cdddr form)))
      (should-not (benedict-contract-forbidden-symbol-p symbol)))))
(provide 'benedict-extension-contract-test)
;;; benedict-extension-contract-test.el ends here
