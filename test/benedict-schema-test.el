;;; benedict-schema-test.el --- Tests for the parameter DSL compiler  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every fixture is asserted twice: once against the expected plist, and once
;; through `json-serialize' to the expected JSON.  The second assertion is the
;; one that earns its keep -- a symbol where a string belongs, or a list where a
;; vector belongs, produces a plist that satisfies `equal' and then signals at
;; request time, a long way from here.

;;; Code:

(require 'ert)
(require 'benedict-schema)

(defconst benedict-schema-test-cases
  '(("a required and an optional parameter"
     ((form :type string :required t :description "A single Emacs Lisp form.")
      (quiet :type boolean))
     (:type "object"
      :properties (:form (:type "string" :description "A single Emacs Lisp form.")
                   :quiet (:type "boolean"))
      :required ["form"])
     "{\"type\":\"object\",\"properties\":{\"form\":{\"type\":\"string\",\"description\":\"A single Emacs Lisp form.\"},\"quiet\":{\"type\":\"boolean\"}},\"required\":[\"form\"]}")

    ("no parameters at all"
     ()
     (:type "object" :properties nil)
     "{\"type\":\"object\",\"properties\":{}}")

    ("nothing required omits the key entirely"
     ((path :type string))
     (:type "object" :properties (:path (:type "string")))
     "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}")

    ("required preserves declaration order"
     ((b :type string :required t)
      (a :type string)
      (c :type integer :required t))
     (:type "object"
      :properties (:b (:type "string") :a (:type "string") :c (:type "integer"))
      :required ["b" "c"])
     "{\"type\":\"object\",\"properties\":{\"b\":{\"type\":\"string\"},\"a\":{\"type\":\"string\"},\"c\":{\"type\":\"integer\"}},\"required\":[\"b\",\"c\"]}")

    ("enum members given as symbols become strings"
     ((mode :type string :enum (fast slow)))
     (:type "object" :properties (:mode (:type "string" :enum ["fast" "slow"])))
     "{\"type\":\"object\",\"properties\":{\"mode\":{\"type\":\"string\",\"enum\":[\"fast\",\"slow\"]}}}")

    ("enum given as a vector of strings and numbers"
     ((level :type number :enum ["low" 2]))
     (:type "object" :properties (:level (:type "number" :enum ["low" 2])))
     "{\"type\":\"object\",\"properties\":{\"level\":{\"type\":\"number\",\"enum\":[\"low\",2]}}}")

    ("array of scalars"
     ((tags :type array :items (:type string)))
     (:type "object" :properties (:tags (:type "array" :items (:type "string"))))
     "{\"type\":\"object\",\"properties\":{\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}")

    ("array of objects, with the object's own required array"
     ((edits :type array
             :required t
             :items (:type object
                     :properties ((old :type string :required t)
                                  (new :type string :required t)))))
     (:type "object"
      :properties (:edits (:type "array"
                           :items (:type "object"
                                   :properties (:old (:type "string")
                                                :new (:type "string"))
                                   :required ["old" "new"])))
      :required ["edits"])
     "{\"type\":\"object\",\"properties\":{\"edits\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"old\":{\"type\":\"string\"},\"new\":{\"type\":\"string\"}},\"required\":[\"old\",\"new\"]}}},\"required\":[\"edits\"]}")

    ("nested object required does not escape to the top level"
     ((config :type object
              :properties ((host :type string :required t)
                           (port :type integer))))
     (:type "object"
      :properties (:config (:type "object"
                            :properties (:host (:type "string")
                                         :port (:type "integer"))
                            :required ["host"])))
     "{\"type\":\"object\",\"properties\":{\"config\":{\"type\":\"object\",\"properties\":{\"host\":{\"type\":\"string\"},\"port\":{\"type\":\"integer\"}},\"required\":[\"host\"]}}}")

    ("an object with no declared properties is unconstrained"
     ((bag :type object))
     (:type "object" :properties (:bag (:type "object")))
     "{\"type\":\"object\",\"properties\":{\"bag\":{\"type\":\"object\"}}}")

    ("unrecognized keys pass through in declaration order"
     ((limit :type integer :minimum 1 :maximum 100)
      (name :type string :minLength 3))
     (:type "object"
      :properties (:limit (:type "integer" :minimum 1 :maximum 100)
                   :name (:type "string" :minLength 3)))
     "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100},\"name\":{\"type\":\"string\",\"minLength\":3}}}"))
  "Fixtures of (LABEL PARAMETERS EXPECTED-PLIST EXPECTED-JSON).")

(ert-deftest benedict-schema-compiles-the-fixture-table ()
  (pcase-dolist (`(,label ,parameters ,expected ,_json) benedict-schema-test-cases)
    (ert-info (label)
      (should (equal (benedict-schema-compile parameters) expected)))))

(ert-deftest benedict-schema-fixtures-serialize-to-the-expected-json ()
  "The compiled plist must survive `json-serialize' unchanged in meaning."
  (pcase-dolist (`(,label ,parameters ,_expected ,json) benedict-schema-test-cases)
    (ert-info (label)
      (let ((serialized (benedict-schema-serialize
                         (benedict-schema-compile parameters))))
        (should (equal serialized json))
        ;; And it parses back to something with the same shape.
        (should (json-parse-string serialized))))))

(ert-deftest benedict-schema-the-eval-elisp-golden-case ()
  "The example from SPEC-001 6.1 compiles to exactly this."
  (should (equal (benedict-schema-serialize
                  (benedict-schema-compile
                   '((form :type string :required t
                           :description "A single Emacs Lisp form."))))
                 (concat "{\"type\":\"object\",\"properties\":{\"form\":"
                         "{\"type\":\"string\",\"description\":"
                         "\"A single Emacs Lisp form.\"}},\"required\":[\"form\"]}"))))

(ert-deftest benedict-schema-omits-required-rather-than-emitting-nil ()
  "An emitted nil would serialize to \"required\":{}, which is invalid."
  (let ((schema (benedict-schema-compile '((path :type string)))))
    ;; plist-get cannot tell these apart; plist-member can, which is the point.
    (should-not (plist-member schema :required))
    (should (plist-member schema :properties))))

(ert-deftest benedict-schema-booleans-use-the-json-representations ()
  (let ((schema (benedict-schema-compile
                 '((strict :type boolean :default :false)
                   (loose :type boolean :default t)))))
    (should (equal (benedict-schema-serialize schema)
                   (concat "{\"type\":\"object\",\"properties\":"
                           "{\"strict\":{\"type\":\"boolean\",\"default\":false},"
                           "\"loose\":{\"type\":\"boolean\",\"default\":true}}}")))))

(ert-deftest benedict-schema-fragment-compiles-a-bare-node ()
  (should (equal (benedict-schema-compile-fragment '(:type string))
                 '(:type "string")))
  (should (equal (benedict-schema-compile-fragment
                  '(:type array :items (:type integer)))
                 '(:type "array" :items (:type "integer")))))

;;;; Rejected input

(ert-deftest benedict-schema-rejects-a-missing-or-unknown-type ()
  (should-error (benedict-schema-compile '((a :description "no type")))
                :type 'benedict-schema-error)
  (should-error (benedict-schema-compile '((a :type int)))
                :type 'benedict-schema-error)
  (should-error (benedict-schema-compile '((a :type "string")))
                :type 'benedict-schema-error))

(ert-deftest benedict-schema-rejects-malformed-parameter-lists ()
  (should-error (benedict-schema-compile 'not-a-list)
                :type 'benedict-schema-error)
  (should-error (benedict-schema-compile '("name" :type string))
                :type 'benedict-schema-error)
  (should-error (benedict-schema-compile '((a :type string :required)))
                :type 'benedict-schema-error))

(ert-deftest benedict-schema-rejects-an-array-without-items ()
  (should-error (benedict-schema-compile '((tags :type array)))
                :type 'benedict-schema-error))

(ert-deftest benedict-schema-rejects-misplaced-keys ()
  (should-error (benedict-schema-compile '((a :type string :items (:type string))))
                :type 'benedict-schema-error)
  (should-error (benedict-schema-compile '((a :type string :properties ((b :type string)))))
                :type 'benedict-schema-error))

(ert-deftest benedict-schema-rejects-uncoercible-enum-members ()
  (should-error (benedict-schema-compile '((a :type string :enum (nil))))
                :type 'benedict-schema-error)
  (should-error (benedict-schema-compile '((a :type string :enum ((nested list)))))
                :type 'benedict-schema-error))

(provide 'benedict-schema-test)

;;; benedict-schema-test.el ends here
