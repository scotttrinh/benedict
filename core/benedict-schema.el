;;; benedict-schema.el --- Parameter DSL to JSON Schema  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tools declare their arguments in a small Lisp DSL; providers want JSON
;; Schema.  This file is the compiler between them.
;;
;; The output is a plist with keyword keys, which `json-serialize' accepts
;; directly.  Four properties of `json-serialize' shape the whole design and are
;; each easy to get wrong:
;;
;;   - Object keys must be symbols.  An alist with string keys signals, even
;;     though the older `json-encode' accepted one.
;;   - JSON arrays must be vectors.  A list serializes as a nested object, or
;;     signals, depending on its contents.
;;   - Symbols are not values.  A `:type' of `string' signals; it has to be the
;;     string "string".
;;   - nil serializes to an empty object, not to null and not to an empty array.
;;     So an emitted `:required nil' becomes "required":{}, which is invalid
;;     JSON Schema -- the key has to be absent instead.
;;
;; Every one of those produces a plist that looks correct under `equal' and
;; fails at request time, which is why the tests round-trip each fixture through
;; `json-serialize'.
;;
;; See SPEC-001 6.1.

;;; Code:

(require 'cl-lib)
(require 'benedict)

(define-error 'benedict-schema-error
  "Invalid Benedict parameter schema"
  'benedict-error)

(defconst benedict-schema-types '(string integer number boolean array object)
  "Parameter types the DSL accepts.

Deliberately exactly the JSON Schema primitives, with no aliases: the DSL
is documented by `describe-function', so it is worth more that the
documented set is the whole set than that `int' also happens to work.")

(defconst benedict-schema--known-keys
  '(:type :description :enum :items :properties :required)
  "Keys the compiler interprets.  Everything else passes through verbatim.")

(defun benedict-schema--type-string (type)
  "Return TYPE as its JSON Schema string.
Signal `benedict-schema-error' unless TYPE is in `benedict-schema-types'.
A missing type lands here as nil and is rejected: a typeless property is
unusable by a provider's strict-tool mode."
  (unless (memq type benedict-schema-types)
    (signal 'benedict-schema-error (list "Unknown parameter type" type)))
  (symbol-name type))

(defun benedict-schema--enum-member (member)
  "Return MEMBER coerced to a JSON-serializable enum value.
Strings and numbers pass through, t and `:false' are the JSON booleans,
and any other symbol becomes its name -- symbols are not JSON values, so
an uncoerced one would signal deep inside `json-serialize'.  Signal
`benedict-schema-error' for anything else, nil included, since nil in an
enum is as likely to mean null as to mean the symbol."
  (cond
   ((stringp member) member)
   ((numberp member) member)
   ((eq member t) t)
   ((eq member :false) :false)
   ((and member (symbolp member)) (symbol-name member))
   (t (signal 'benedict-schema-error
              (list "Enum member is not JSON-serializable" member)))))

(defun benedict-schema--enum (members)
  "Return MEMBERS, a list or vector, as a vector of JSON enum values."
  (vconcat (mapcar #'benedict-schema--enum-member (append members nil))))

(defun benedict-schema--check-plist (plist context)
  "Signal `benedict-schema-error' unless PLIST has an even length.
CONTEXT is included in the error data to locate the offending form."
  (unless (and (listp plist) (cl-evenp (length plist)))
    (signal 'benedict-schema-error (list "Malformed schema plist" context))))

(defun benedict-schema-compile-fragment (spec)
  "Compile SPEC, a nameless schema plist, into a JSON Schema fragment.

This is the compiler for a single schema node: the value of an `:items'
key, and recursively each entry of a `:properties' table.  Use
`benedict-schema-compile' for a tool's whole parameter list.

SPEC must carry a `:type' from `benedict-schema-types'.  It may also
carry `:description', `:enum', `:items' (required when the type is
`array'), and `:properties' (only when the type is `object').  Any other
key is copied to the output verbatim in declaration order, so
`:minimum 1' and `:minLength 3' work with no support from this file --
`json-serialize' strips the leading colon from a keyword.  Pass-through
values are not validated or converted, so they must already be
JSON-shaped: vectors for arrays, `:false' for false.

SPEC's own `:required' is not emitted here.  It is a statement about
SPEC's place in its parent object, and the parent hoists it into that
object's \"required\" array.

Signal `benedict-schema-error' on a malformed or contradictory SPEC."
  (benedict-schema--check-plist spec spec)
  (let* ((type (plist-get spec :type))
         (out (list :type (benedict-schema--type-string type))))
    (when-let* ((description (plist-get spec :description)))
      (setq out (plist-put out :description description)))
    (when (plist-member spec :enum)
      (setq out (plist-put out :enum (benedict-schema--enum (plist-get spec :enum)))))
    ;; An array without :items is almost always an oversight, and providers
    ;; running strict tool schemas reject it, so refuse it here where the error
    ;; names the parameter.
    (cond
     ((eq type 'array)
      (unless (plist-member spec :items)
        (signal 'benedict-schema-error (list "Array parameter has no :items" spec)))
      (setq out (plist-put out :items
                           (benedict-schema-compile-fragment (plist-get spec :items)))))
     ((plist-member spec :items)
      (signal 'benedict-schema-error (list ":items on a non-array parameter" spec))))
    ;; Nested properties recurse through the same DSL, so a nested :required t
    ;; collects into this object's own "required" array rather than escaping to
    ;; the top level.
    (cond
     ((eq type 'object)
      (when (plist-member spec :properties)
        (let ((nested (benedict-schema-compile (plist-get spec :properties))))
          (setq out (plist-put out :properties (plist-get nested :properties)))
          (when (plist-member nested :required)
            (setq out (plist-put out :required (plist-get nested :required)))))))
     ((plist-member spec :properties)
      (signal 'benedict-schema-error (list ":properties on a non-object parameter" spec))))
    (let ((rest spec))
      (while rest
        (let ((key (car rest))
              (value (cadr rest)))
          (unless (memq key benedict-schema--known-keys)
            (setq out (plist-put out key value))))
        (setq rest (cddr rest))))
    out))

(defun benedict-schema-compile (parameters)
  "Compile PARAMETERS into a JSON Schema object suitable for `json-serialize'.

PARAMETERS is the `:parameters' DSL of a tool definition: a list of
\(NAME . SPEC) forms, where NAME is a symbol and SPEC is a schema plist
as described by `benedict-schema-compile-fragment'.  A SPEC carrying a
non-nil `:required' has its name collected into the object's \"required\"
array, in declaration order.

For example,

  (benedict-schema-compile
   \\='((form :type string :required t :description \"An Elisp form.\")
     (mode :type string :enum (fast slow))
     (tags :type array :items (:type string))))

returns

  (:type \"object\"
   :properties (:form (:type \"string\" :description \"An Elisp form.\")
                :mode (:type \"string\" :enum [\"fast\" \"slow\"])
                :tags (:type \"array\" :items (:type \"string\")))
   :required [\"form\"])

which serializes to

  {\"type\":\"object\",
   \"properties\":{
     \"form\":{\"type\":\"string\",\"description\":\"An Elisp form.\"},
     \"mode\":{\"type\":\"string\",\"enum\":[\"fast\",\"slow\"]},
     \"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},
   \"required\":[\"form\"]}

`:properties' is always emitted, so a tool with no parameters compiles to
{\"type\":\"object\",\"properties\":{}}.  `:required' is omitted entirely
when nothing is required, because an emitted nil would serialize to
\"required\":{} and no provider accepts that.

Signal `benedict-schema-error' when PARAMETERS is not a list of named
schema plists, or when any SPEC is malformed."
  (unless (listp parameters)
    (signal 'benedict-schema-error (list "Parameters are not a list" parameters)))
  (let ((properties nil)
        (required nil))
    (dolist (parameter parameters)
      (unless (and (consp parameter)
                   (car parameter)
                   (symbolp (car parameter)))
        (signal 'benedict-schema-error (list "Invalid parameter" parameter)))
      (let ((name (car parameter))
            (spec (cdr parameter)))
        (benedict-schema--check-plist spec parameter)
        (when (plist-get spec :required)
          (push (symbol-name name) required))
        (setq properties
              (plist-put properties
                         (intern (concat ":" (symbol-name name)))
                         (benedict-schema-compile-fragment spec)))))
    (append (list :type "object" :properties properties)
            (when required (list :required (vconcat (nreverse required)))))))

(defun benedict-schema-serialize (schema)
  "Return SCHEMA, a compiled schema plist, as a JSON string."
  (json-serialize schema))

(provide 'benedict-schema)

;;; benedict-schema.el ends here
