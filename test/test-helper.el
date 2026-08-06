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
(require 'benedict-store)

(defun benedict-test-entry (role text &rest meta)
  "Return an unappended entry with ROLE, a single text block TEXT, and META."
  (benedict-entry-create :role role :content text :meta meta))

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

(provide 'test-helper)

;;; test-helper.el ends here
