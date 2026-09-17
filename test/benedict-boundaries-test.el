;;; benedict-boundaries-test.el --- Layer dependency boundaries  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 12.2 declares package boundaries that are meant to be real in the
;; dependency graph well before they are real in any package manifest, and 12.5
;; asks for a test that asserts them.  This is that test.
;;
;; It constrains `require' only.  `declare-function' and an `autoload' cookie
;; pointing at a higher layer create no load-time dependency and are the
;; intended way for a lower layer to name something above it -- the store does
;; exactly that for the session accessor it will need in Phase 2.  Do not
;; "fix" those by adding a `require'; that is the thing this test exists to
;; prevent.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst benedict-boundaries-layer-dependencies
  '(("core")
    ("support" "core")
    ("api" "core" "support")
    ("providers" "core" "support" "api")
    ("ext" "core" "support" "api" "providers")
    ("ui" "core" "support" "ext")
    ("distro" "core" "support" "api" "providers" "ext" "ui"))
  "Alist of LAYER to the layers LAYER may `require' from, itself excluded.

Dependency direction is strictly downward.  The kernel in core/ requires
nothing above it, so `benedict-core' plus a fake provider is a complete,
testable runtime with no tools and no UI.  ui/ deliberately cannot reach
api/ or providers/: a frontend that needs to know about a wire protocol
has found a hole in the kernel API, and the API is what should grow.")

(defun benedict-boundaries--files (layer)
  "Return the absolute paths of the Elisp files in LAYER."
  (let ((directory (expand-file-name layer benedict-test-root)))
    (when (file-directory-p directory)
      (directory-files directory t "\\.el\\'"))))

(defun benedict-boundaries--feature-layers ()
  "Return a hash table mapping each project feature symbol to its layer."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (layer benedict-test-layers table)
      (dolist (file (benedict-boundaries--files layer))
        (puthash (intern (file-name-base file)) layer table)))))

(defun benedict-boundaries--walk (form collect)
  "Call COLLECT with the feature of every `require' form inside FORM.

Walks the whole tree rather than only top-level forms, so a `require'
tucked inside `eval-when-compile', `eval-and-compile',
`with-eval-after-load', or a conditional is found too.  Those are exactly
the places a boundary violation hides.

The traversal walks cons cells by hand rather than with `dolist' because
a source file is full of improper lists -- every alist literal ends in a
dotted pair -- and `dolist' signals on one.  A file containing an alist
would otherwise fail this test with a `wrong-type-argument' rather than
being checked."
  (when (consp form)
    (when (and (eq (car form) 'require)
               (consp (cadr form))
               (eq (car (cadr form)) 'quote))
      (funcall collect (cadr (cadr form))))
    (let ((rest form))
      (while (consp rest)
        (benedict-boundaries--walk (car rest) collect)
        (setq rest (cdr rest))))))

(defun benedict-boundaries--required-features (file)
  "Return the features FILE requires, in order."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((features nil))
      (condition-case nil
          (while t
            (benedict-boundaries--walk
             (read (current-buffer))
             (lambda (feature) (push feature features))))
        (end-of-file nil))
      (nreverse features))))

(ert-deftest benedict-boundaries-requires-point-downward ()
  "No file may `require' a project feature from a layer above its own."
  (let ((feature-layers (benedict-boundaries--feature-layers)))
    (pcase-dolist (`(,layer . ,allowed) benedict-boundaries-layer-dependencies)
      (dolist (file (benedict-boundaries--files layer))
        (dolist (feature (benedict-boundaries--required-features file))
          (when-let* ((required-layer (gethash feature feature-layers)))
            (ert-info ((format "%s requires %s" (file-name-nondirectory file) feature))
              (should (member required-layer (cons layer allowed))))))))))

(ert-deftest benedict-boundaries-every-layer-is-covered ()
  "`benedict-boundaries-layer-dependencies' must not fall behind the tree."
  (should (equal (mapcar #'car benedict-boundaries-layer-dependencies)
                 benedict-test-layers)))

(ert-deftest benedict-boundaries-files-use-lexical-binding ()
  (dolist (layer benedict-test-layers)
    (dolist (file (benedict-boundaries--files layer))
      (ert-info ((file-name-nondirectory file))
        (with-temp-buffer
          (insert-file-contents file nil 0 500)
          (goto-char (point-min))
          (should (re-search-forward "-\\*-.*lexical-binding: *t.*-\\*-"
                                     (line-end-position) t)))))))

(ert-deftest benedict-boundaries-files-provide-their-own-feature ()
  "A file that does not `provide' its own name cannot be required by name."
  (dolist (layer benedict-test-layers)
    (dolist (file (benedict-boundaries--files layer))
      (ert-info ((file-name-nondirectory file))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (should (re-search-forward
                   (format "^(provide '%s)$" (regexp-quote (file-name-base file)))
                   nil t)))))))

(provide 'benedict-boundaries-test)

;;; benedict-boundaries-test.el ends here
