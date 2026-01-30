;;; benedict-tool-schema-test.el --- Tests for tool schema encoding -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'propcheck)
(require 'cl-lib)
(require 'seq)

(require 'benedict-tools)

;;; Helpers

(defun benedict-tool-schema-test--tool-spec (id)
  "Return registry spec for tool ID or error."
  (or (cl-find id (benedict-tools-list) :key (lambda (spec) (plist-get spec :id)))
      (error "Unknown tool id: %S" id)))

(defun benedict-tool-schema-test--tool-schema (id)
  "Return :schema plist for tool ID."
  (plist-get (benedict-tool-schema-test--tool-spec id) :schema))

(defun benedict-tool-schema-test--json-get (alist key)
  "Return value for string KEY inside ALIST."
  (alist-get key alist nil nil #'string=))

(defun benedict-tool-schema-test--json-key-present-p (alist key)
  "Return non-nil when KEY appears in ALIST."
  (assoc key alist #'string=))

(defun benedict-tool-schema-test--vector->list (maybe-vector)
  "Convert MAYBE-VECTOR to a list, tolerating nil."
  (when (vectorp maybe-vector)
    (append maybe-vector nil)))

(defun benedict-tool-schema-test--target-properties (tool-id)
  "Return encoded target property alist for TOOL-ID."
  (let* ((schema (benedict-tool-schema-test--tool-schema tool-id))
         (encoded (benedict-tool-schema->json-parameters schema))
         (properties (benedict-tool-schema-test--json-get encoded "properties")))
    (benedict-tool-schema-test--json-get properties "target")))

;;; Unit tests for schema encoding

(ert-deftest benedict-tool-schema-write-encodes-as-json-object ()
  "Write tool schema encodes to JSON-Schema shape."
  (let* ((schema (benedict-tool-schema-test--tool-schema 'write))
         (encoded (benedict-tool-schema->json-parameters schema))
         (properties (benedict-tool-schema-test--json-get encoded "properties"))
         (target (benedict-tool-schema-test--json-get properties "target")))
    (should (equal "object" (benedict-tool-schema-test--json-get encoded "type")))
    (should (benedict-tool-schema-test--json-key-present-p properties "content"))
    (should (benedict-tool-schema-test--json-key-present-p properties "create_if_missing"))
    (should (equal '("target" "content")
                   (benedict-tool-schema-test--vector->list
                    (benedict-tool-schema-test--json-get encoded "required"))))
    (should (equal "object" (benedict-tool-schema-test--json-get target "type")))
    (let ((target-props (benedict-tool-schema-test--json-get target "properties")))
      (should (benedict-tool-schema-test--json-key-present-p target-props "kind"))
      (should (benedict-tool-schema-test--json-key-present-p target-props "path"))
      (should (benedict-tool-schema-test--json-key-present-p target-props "buffer_name")))))

(ert-deftest benedict-tool-schema-edit-encodes-nested-target ()
  "Edit tool schema encodes nested target object."
  (let* ((schema (benedict-tool-schema-test--tool-schema 'edit))
         (encoded (benedict-tool-schema->json-parameters schema))
         (properties (benedict-tool-schema-test--json-get encoded "properties"))
         (target (benedict-tool-schema-test--json-get properties "target")))
    (should (equal '("target" "old_text" "new_text")
                   (benedict-tool-schema-test--vector->list
                    (benedict-tool-schema-test--json-get encoded "required"))))
    (should (equal "object" (benedict-tool-schema-test--json-get target "type")))
    (let ((target-props (benedict-tool-schema-test--json-get target "properties")))
      (should (benedict-tool-schema-test--json-key-present-p target-props "kind"))
      (should (benedict-tool-schema-test--json-key-present-p target-props "path"))
      (should (benedict-tool-schema-test--json-key-present-p target-props "buffer_name")))))

(ert-deftest benedict-tool-schema-project-search-requires-query ()
  "Project search requires query parameter."
  (let* ((schema (benedict-tool-schema-test--tool-schema 'project-search))
         (encoded (benedict-tool-schema->json-parameters schema))
         (required (benedict-tool-schema-test--vector->list
                    (benedict-tool-schema-test--json-get encoded "required")))
         (properties (benedict-tool-schema-test--json-get encoded "properties")))
    (should (equal '("query") required))
    (should (equal "string"
                   (benedict-tool-schema-test--json-get
                    (benedict-tool-schema-test--json-get properties "query")
                    "type")))))

(ert-deftest benedict-tool-schema-read-file-has-optional-line-range ()
  "Read-file schema marks only path as required."
  (let* ((schema (benedict-tool-schema-test--tool-schema 'read-file))
         (encoded (benedict-tool-schema->json-parameters schema))
         (required (benedict-tool-schema-test--vector->list
                    (benedict-tool-schema-test--json-get encoded "required")))
         (properties (benedict-tool-schema-test--json-get encoded "properties")))
    (should (equal '("path") required))
    (should (equal "integer"
                   (benedict-tool-schema-test--json-get
                    (benedict-tool-schema-test--json-get properties "start-line")
                    "type")))
    (should (equal "integer"
                   (benedict-tool-schema-test--json-get
                    (benedict-tool-schema-test--json-get properties "end-line")
                    "type")))))

(ert-deftest benedict-tool-schema-find-files-has-optional-path ()
  "Find-files schema marks pattern required and path optional."
  (let* ((schema (benedict-tool-schema-test--tool-schema 'find-files))
         (encoded (benedict-tool-schema->json-parameters schema))
         (required (benedict-tool-schema-test--vector->list
                    (benedict-tool-schema-test--json-get encoded "required")))
         (properties (benedict-tool-schema-test--json-get encoded "properties")))
    (should (equal '("pattern") required))
    (should (equal "string"
                   (benedict-tool-schema-test--json-get
                    (benedict-tool-schema-test--json-get properties "pattern")
                    "type")))
    (should (equal "string"
                   (benedict-tool-schema-test--json-get
                    (benedict-tool-schema-test--json-get properties "path")
                    "type")))))

(ert-deftest benedict-tool-schema-exec-elisp-requires-code ()
  "Exec-elisp schema requires only the code argument."
  (let* ((schema (benedict-tool-schema-test--tool-schema 'exec-elisp))
         (encoded (benedict-tool-schema->json-parameters schema))
         (properties (benedict-tool-schema-test--json-get encoded "properties"))
         (code (benedict-tool-schema-test--json-get properties "code")))
    (should (equal '("code")
                   (benedict-tool-schema-test--vector->list
                    (benedict-tool-schema-test--json-get encoded "required"))))
    (should (equal "string"
                   (benedict-tool-schema-test--json-get code "type")))))

;;; Type normalization tests

(ert-deftest benedict-tool-type->json-type-mapping ()
  "Type coercion handles known symbols."
  (should (equal "string" (benedict-tool-type->json-type 'string)))
  (should (equal "integer" (benedict-tool-type->json-type 'integer)))
  (should (equal "number" (benedict-tool-type->json-type 'number)))
  (should (equal "boolean" (benedict-tool-type->json-type 'boolean)))
  (should (equal "object" (benedict-tool-type->json-type 'object)))
  (should (equal "integer" (benedict-tool-type->json-type 'int)))
  (should (equal "number" (benedict-tool-type->json-type 'float)))
  (should (equal "boolean" (benedict-tool-type->json-type 'bool)))
  (should-error (benedict-tool-type->json-type 'unknown))
  (should-error (benedict-tool-type->json-type "string")))

;;; Argument encoding tests

(ert-deftest benedict-tool-args->alist-normalizes-plist ()
  "Plist input normalizes to string-keyed alist."
  (let* ((input '(:foo 1 :bar "two"))
         (result (benedict-tool-args->alist input)))
    (should (equal '(("foo" . 1)
                     ("bar" . "two"))
                   result))))

(ert-deftest benedict-tool-args->alist-normalizes-alist ()
  "Alist keys become strings preserving order."
  (let* ((input '((foo . 1)
                  (:bar . 2)
                  ("baz" . 3)))
         (result (benedict-tool-args->alist input)))
    (should (equal '(("foo" . 1)
                     ("bar" . 2)
                     ("baz" . 3))
                   result))))

(ert-deftest benedict-tool-encode-args-json-roundtrips ()
  "JSON encoding round-trips through `json-parse-string`."
  (let* ((value '(:foo 1 :bar "two" :baz t))
         (json (benedict-tool-encode-args-json value))
         (decoded (json-parse-string json :object-type 'alist)))
    (should (equal 1 (alist-get "foo" decoded nil nil #'string=)))
    (should (equal "two" (alist-get "bar" decoded nil nil #'string=)))
    (should (eq t (alist-get "baz" decoded nil nil #'string=)))))

;;; Property-based tests

(defun benedict-tool-schema-test--random-prop-name (prefix index)
  "Return a keyword like :PREFIX-INDEX using PREFIX and INDEX."
  (intern (format ":%s-%d" prefix index)))

(defun benedict-tool-schema-test--random-scalar-type ()
  "Return random scalar type symbol."
  (elt '(string integer number boolean)
       (propcheck-generate-integer "scalar-type" :min 0 :max 3)))

(defun benedict-tool-schema-test--random-property-schema (&optional depth)
  "Generate random schema plist with DEPTH limit 1."
  (let ((choose-object (and (< (or depth 0) 1)
                            (cl-oddp (propcheck-generate-integer
                                      (format "object-depth-%d" (or depth 0))
                                      :min 0 :max 1)))))
    (if choose-object
        (let* ((child-count (propcheck-generate-integer "child-count" :min 1 :max 3))
               (child-keys (cl-loop for idx below child-count
                                    collect (benedict-tool-schema-test--random-prop-name
                                             "inner" idx)))
               (child-props nil))
          (dolist (key child-keys)
            (setq child-props (plist-put child-props key
                                         (list :type (benedict-tool-schema-test--random-scalar-type)))))
          (let ((schema (list :type 'object :properties child-props)))
            (when (and child-keys
                       (cl-oddp (propcheck-generate-integer "child-required" :min 0 :max 1)))
              (let ((required (cl-loop for key in child-keys
                                       when (cl-oddp (propcheck-generate-integer
                                                      (symbol-name key)
                                                      :min 0 :max 1))
                                       collect key)))
                (when required
                  (setq schema (plist-put schema :required required)))))
            schema))
      (list :type (benedict-tool-schema-test--random-scalar-type)))))

(defun benedict-tool-schema-test--random-schema ()
  "Return plist describing random top-level schema and metadata."
  (let* ((prop-count (propcheck-generate-integer "prop-count" :min 1 :max 5))
         (keys (cl-loop for idx below prop-count
                        collect (benedict-tool-schema-test--random-prop-name "arg" idx)))
         (props nil))
    (dolist (key keys)
      (setq props (plist-put props key
                              (benedict-tool-schema-test--random-property-schema 0))))
    (let ((schema (list :type 'object :properties props)))
      (when (and keys (cl-oddp (propcheck-generate-integer "top-required" :min 0 :max 1)))
        (let ((required (cl-loop for key in keys
                                 when (cl-oddp (propcheck-generate-integer
                                                (format "required-%s" key)
                                                :min 0 :max 1))
                                 collect key)))
          (when required
            (setq schema (plist-put schema :required required)))))
      (list :schema schema :keys keys))))

(defun benedict-tool-schema-test--json-property-names (encoded)
  "Return string keys present in ENCODED schema properties."
  (mapcar #'car (benedict-tool-schema-test--json-get encoded "properties")))

(defun benedict-tool-schema-test--valid-property-types-p (encoded)
  "Return non-nil when every property in ENCODED has an allowed type string."
  (let ((allowed '("string" "integer" "number" "boolean" "object")))
    (cl-labels ((validate (schema)
                  (let ((type (benedict-tool-schema-test--json-get schema "type")))
                    (and (member type allowed)
                         (if (string= type "object")
                             (let ((props (benedict-tool-schema-test--json-get schema "properties")))
                               (and (listp props)
                                    (cl-every (lambda (pair)
                                                (validate (cdr pair))) props)))
                           t)))))
      (validate encoded))))

(propcheck-deftest benedict-prop-tool-schema-encoding-invariants ()
  "Random schemas always encode to valid JSON objects."
  (let* ((fixture (benedict-tool-schema-test--random-schema))
         (schema (plist-get fixture :schema))
         (keys (plist-get fixture :keys))
         (encoded (benedict-tool-schema->json-parameters schema))
         (required (benedict-tool-schema-test--vector->list
                    (benedict-tool-schema-test--json-get encoded "required")))
         (has-required (plist-member schema :required)))
    (propcheck-should (equal "object" (benedict-tool-schema-test--json-get encoded "type")))
    (propcheck-should (listp (benedict-tool-schema-test--json-get encoded "properties")))
    (propcheck-should (benedict-tool-schema-test--valid-property-types-p encoded))
    (propcheck-should
     (or (not has-required)
         (benedict-tool-schema-test--json-key-present-p encoded "required")))
    (when required
      (propcheck-should (cl-every (lambda (name)
                                    (member name
                                            (benedict-tool-schema-test--json-property-names encoded)))
                                  required))
      (propcheck-should (equal (length required)
                               (length (delete-dups (copy-sequence required))))))
    (when (not has-required)
      (propcheck-should (not (benedict-tool-schema-test--json-key-present-p encoded "required"))))))

(provide 'benedict-tool-schema-test)
;;; benedict-tool-schema-test.el ends here
