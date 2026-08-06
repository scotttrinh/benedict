;;; benedict-tool-test.el --- Tools, the registry, and invocations  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tool layer, tested with no session and no reducer -- it requires only
;; the schema compiler, and staying testable in isolation is the check that it
;; has not quietly grown a dependency on the machinery that calls it.

;;; Code:

(require 'ert)
(require 'test-helper)

(defmacro benedict-tool-test--with-tools (&rest body)
  "Evaluate BODY, unregistering any tool it defines afterwards."
  (declare (indent 0) (debug body))
  `(unwind-protect (progn ,@body)
     (dolist (id '(benedict-test-a benedict-test-b benedict-test-echo))
       (benedict-tool-unregister id))))

;;;; Definition

(ert-deftest benedict-tool-deftool-compiles-its-parameters ()
  "The DSL is compiled at definition time and serializes as JSON Schema."
  (benedict-tool-test--with-tools
    (let ((tool (benedict-deftool benedict-test-a
                  :label "Test A"
                  :description "A test tool."
                  :parameters '((form :type string :required t
                                      :description "An Elisp form.")
                                (limit :type integer :minimum 1))
                  :sync t
                  :handler (lambda (_invocation) (benedict-tool-result :content "")))))
      (should (eq (benedict-tool-id tool) 'benedict-test-a))
      (should (equal (benedict-tool-label tool) "Test A"))
      (should (equal (benedict-schema-serialize (benedict-tool-schema tool))
                     (concat "{\"type\":\"object\",\"properties\":{"
                             "\"form\":{\"type\":\"string\","
                             "\"description\":\"An Elisp form.\"},"
                             "\"limit\":{\"type\":\"integer\",\"minimum\":1}},"
                             "\"required\":[\"form\"]}"))))))

(ert-deftest benedict-tool-label-defaults-to-the-id ()
  (benedict-tool-test--with-tools
    (let ((tool (benedict-deftool benedict-test-a
                  :description "d"
                  :parameters nil
                  :sync t
                  :handler #'ignore)))
      (should (equal (benedict-tool-label tool) "benedict-test-a")))))

(ert-deftest benedict-tool-a-malformed-dsl-fails-at-definition ()
  "A bad parameter spec signals when the tool is defined, not at request time."
  (benedict-tool-test--with-tools
    (should-error (benedict-tool-create :id 'benedict-test-a
                                        :parameters '((x :type notatype))
                                        :handler #'ignore)
                  :type 'benedict-schema-error)
    ;; SPEC-001 D8: a missing :type is an error, not an open schema.
    (should-error (benedict-tool-create :id 'benedict-test-a
                                        :parameters '((x :description "no type"))
                                        :handler #'ignore)
                  :type 'benedict-schema-error)))

(ert-deftest benedict-tool-create-rejects-a-non-function-handler ()
  (should-error (benedict-tool-create :id 'benedict-test-a :handler "nope")
                :type 'benedict-tool-error))

;;;; The registry

(ert-deftest benedict-tool-registration-is-idempotent ()
  "Re-defining a tool replaces it, which is what makes `load-file' the reload."
  (benedict-tool-test--with-tools
    (benedict-deftool benedict-test-a
      :description "first" :parameters nil :sync t :handler #'ignore)
    (benedict-deftool benedict-test-a
      :description "second" :parameters nil :sync t :handler #'ignore)
    (should (equal (benedict-tool-description (benedict-tool-get 'benedict-test-a))
                   "second"))
    (should (equal (length (seq-filter
                            (lambda (tool) (eq (benedict-tool-id tool) 'benedict-test-a))
                            (benedict-tool-list)))
                   1))))

(ert-deftest benedict-tool-list-is-sorted-by-id ()
  "A stable order keeps a provider's prompt cache warm across restarts."
  (benedict-tool-test--with-tools
    (benedict-deftool benedict-test-b
      :description "b" :parameters nil :sync t :handler #'ignore)
    (benedict-deftool benedict-test-a
      :description "a" :parameters nil :sync t :handler #'ignore)
    (let ((ids (seq-filter (lambda (id) (memq id '(benedict-test-a benedict-test-b)))
                           (mapcar #'benedict-tool-id (benedict-tool-list)))))
      (should (equal ids '(benedict-test-a benedict-test-b))))))

(ert-deftest benedict-tool-resolve-mixes-ids-and-structs ()
  (benedict-tool-test--with-tools
    (let ((tool (benedict-deftool benedict-test-a
                  :description "a" :parameters nil :sync t :handler #'ignore)))
      (should (equal (benedict-tool-resolve (list 'benedict-test-a tool))
                     (list tool tool)))
      (should-error (benedict-tool-resolve '(benedict-test-absent))
                    :type 'benedict-tool-unknown))))

;;;; Invocations

(ert-deftest benedict-tool-invocation-from-a-tool-call-block ()
  (benedict-tool-test--with-tools
    (benedict-deftool benedict-test-a
      :description "a" :parameters nil :sync t :handler #'ignore)
    (let ((invocation (benedict-invocation-from-block
                       (benedict-block-tool-call "call_1" 'benedict-test-a
                                                 '(:text "hi")))))
      (should (equal (benedict-invocation-id invocation) "call_1"))
      (should (eq (benedict-invocation-name invocation) 'benedict-test-a))
      (should (eq (benedict-invocation-tool invocation)
                  (benedict-tool-get 'benedict-test-a)))
      (should (eq (benedict-invocation-target invocation) 'local))
      (should (equal (benedict-tool-arg invocation :text) "hi"))
      (should (eq (benedict-tool-arg invocation :missing 'fallback) 'fallback)))))

(ert-deftest benedict-tool-invocation-with-does-not-mutate ()
  "Rewriting an invocation copies it, so filters that already ran are unaffected."
  (let* ((original (benedict-invocation-create :id "a" :name 'x :arguments '(:v 1)))
         (rewritten (benedict-invocation-with original :arguments '(:v 2))))
    (should (equal (benedict-invocation-arguments original) '(:v 1)))
    (should (equal (benedict-invocation-arguments rewritten) '(:v 2)))
    (should (equal (benedict-invocation-id rewritten) "a"))
    (should-error (benedict-invocation-with original :nonsense 1)
                  :type 'benedict-tool-error)
    (should-error (benedict-invocation-with original :id)
                  :type 'benedict-tool-error)))

(ert-deftest benedict-tool-blocked-and-retarget-return-copies ()
  (let ((original (benedict-invocation-create :id "a" :name 'x)))
    (should-not (benedict-invocation-blocked-p original))
    (let ((blocked (benedict-tool-blocked original "because")))
      (should (benedict-invocation-blocked-p blocked))
      (should (equal (benedict-invocation-blocked-reason blocked) "because"))
      (should-not (benedict-invocation-blocked-p original)))
    (let ((rerouted (benedict-tool-retarget original 'sandbox)))
      (should (eq (benedict-invocation-target rerouted) 'sandbox))
      (should (eq (benedict-invocation-target original) 'local)))))

;;;; Execution

(ert-deftest benedict-tool-sync-handlers-satisfy-the-async-contract ()
  "`:sync t' is sugar; the kernel still calls one code path."
  (benedict-tool-test--with-tools
    (benedict-deftool benedict-test-a
      :description "a"
      :parameters '((n :type integer :required t :description "A number."))
      :sync t
      :handler (lambda (invocation)
                 (benedict-tool-result
                  :content (number-to-string (* 2 (benedict-tool-arg invocation :n))))))
    (let ((result nil))
      (benedict-tool-execute
       (benedict-invocation-create :id "1" :name 'benedict-test-a :arguments '(:n 21))
       (lambda (value) (setq result value)))
      (should (equal (benedict-tool-result-value-content result) "42"))
      (should-not (benedict-tool-result-value-error-p result)))))

(ert-deftest benedict-tool-an-async-handler-may-answer-later ()
  "A handler that has not called `done' has simply not finished."
  (benedict-tool-test--with-tools
    (let ((pending nil))
      (benedict-deftool benedict-test-a
        :description "a"
        :parameters nil
        :handler (lambda (_invocation done) (setq pending done)))
      (let ((result 'unset))
        (benedict-tool-execute
         (benedict-invocation-create :id "1" :name 'benedict-test-a)
         (lambda (value) (setq result value)))
        (should (eq result 'unset))
        (funcall pending (benedict-tool-result :content "eventually"))
        (should (equal (benedict-tool-result-value-content result) "eventually"))))))

(ert-deftest benedict-tool-execute-answers-rather-than-signals ()
  "Blocked, unknown, and unroutable calls all become results the model sees."
  (benedict-tool-test--with-tools
    (benedict-deftool benedict-test-a
      :description "a" :parameters nil :sync t
      :handler (lambda (_invocation) (benedict-tool-result :content "ok")))
    (let ((invocation (benedict-invocation-create :id "1" :name 'benedict-test-a)))
      (dolist (case (list (cons (benedict-tool-blocked invocation "denied") "denied")
                          (cons (benedict-invocation-create :id "2" :name 'benedict-test-gone)
                                "No such tool: benedict-test-gone")
                          (cons (benedict-tool-retarget invocation 'nowhere)
                                "No executor for target nowhere")))
        (let ((result nil))
          (benedict-tool-execute (car case) (lambda (value) (setq result value)))
          (should (benedict-tool-result-value-error-p result))
          (should (equal (benedict-tool-result-value-content result) (cdr case))))))))

(ert-deftest benedict-tool-executors-are-replaceable ()
  (benedict-tool-test--with-tools
    (benedict-deftool benedict-test-a
      :description "a" :parameters nil :sync t
      :handler (lambda (_invocation) (benedict-tool-result :content "local")))
    (unwind-protect
        (progn
          (benedict-tool-register-executor
           'benedict-test-target
           (lambda (_invocation done) (funcall done (benedict-tool-result :content "one"))))
          (benedict-tool-register-executor
           'benedict-test-target
           (lambda (_invocation done) (funcall done (benedict-tool-result :content "two"))))
          (let ((result nil))
            (benedict-tool-execute
             (benedict-tool-retarget
              (benedict-invocation-create :id "1" :name 'benedict-test-a)
              'benedict-test-target)
             (lambda (value) (setq result value)))
            (should (equal (benedict-tool-result-value-content result) "two"))))
      (benedict-tool-unregister-executor 'benedict-test-target))))

(ert-deftest benedict-tool-result-block-pairs-with-its-call ()
  "The result block carries the call's id, which is what pairs them on the wire."
  (let* ((invocation (benedict-invocation-create :id "call_7" :name 'thing))
         (block (benedict-tool-result-block
                 invocation (benedict-tool-result-error "went wrong"))))
    (should (equal (plist-get block :id) "call_7"))
    (should (eq (plist-get block :name) 'thing))
    (should (equal (plist-get block :content) "went wrong"))
    (should (eq (plist-get block :error-p) t))))

(provide 'benedict-tool-test)

;;; benedict-tool-test.el ends here
