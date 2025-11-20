;;; test/run-lint.el --- Batch linter for Benedict  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Checks for coding style (checkdoc), packaging issues (package-lint),
;; and compilation errors (byte-compile).

;;; Code:

(require 'seq)
(require 'checkdoc)
(require 'package-lint)
(require 'bytecomp)

(defvar benedict-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Absolute path to the Benedict repository root.")

(defvar benedict-files
  (directory-files benedict-root t "^benedict.*\\.el$")
  "List of benedict source files to lint.")

(defvar lint-errors nil
  "List of error messages collected during linting.")

(defun report-error (fmt &rest args)
  "Format an error message and add it to `lint-errors`."
  (let ((msg (apply #'format fmt args)))
    (push msg lint-errors)
    (message "ERROR: %s" msg)))

;; 1. Checkdoc
(message "Running checkdoc...")
(dolist (file benedict-files)
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (setq buffer-file-name file)
    (let ((checkdoc-errors nil))
      (let ((checkdoc-create-error-function
             (lambda (text start end &optional unfixable)
               (push (format "%s:%d: %s" 
                             (file-name-nondirectory file)
                             (line-number-at-pos start)
                             text)
                     checkdoc-errors)
               nil)))
        (checkdoc-current-buffer t))
      (when checkdoc-errors
        (report-error "Checkdoc failed for %s:" (file-name-nondirectory file))
        (dolist (err (nreverse checkdoc-errors))
          (message "  %s" err))))))

;; 2. Package-lint
(message "Running package-lint...")
(dolist (file benedict-files)
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (setq buffer-file-name file)
    (let ((errors (package-lint-buffer))
          (has-error nil))
      (dolist (err errors)
        (let ((line (nth 0 err))
              (col (nth 1 err))
              (type (nth 2 err))
              (msg (nth 3 err)))
          (unless (and (eq type 'warning)
                       (string-match-p "redundant" msg))
            (unless has-error
              (setq has-error t)
              (report-error "Package-lint failed for %s:" (file-name-nondirectory file)))
            (message "  %s:%d:%d: %s: %s" 
                     (file-name-nondirectory file)
                     line col type msg)))))))

;; 3. Byte-compile
(message "Running byte-compile...")
(setq byte-compile-error-on-warn t)

;; Create a separate directory for byte-compiled files
(defvar byte-compile-dest (make-temp-file "benedict-byte-compile" t))

;; Copy files to temp dir to avoid polluting source tree and to ensure clean compilation
(dolist (file benedict-files)
  (copy-file file (expand-file-name (file-name-nondirectory file) byte-compile-dest) t))

(add-to-list 'load-path byte-compile-dest)

(dolist (file benedict-files)
  (let ((target (expand-file-name (file-name-nondirectory file) byte-compile-dest)))
    (condition-case err
        (unless (byte-compile-file target)
          (report-error "Byte-compilation failed for %s" (file-name-nondirectory file)))
      (error
       (report-error "Byte-compilation error for %s: %s" (file-name-nondirectory file) err)))))

;; Cleanup
(delete-directory byte-compile-dest t)

;; Final Report
(if lint-errors
    (progn
      (message "\nLinting FAILED with %d error(s)." (length lint-errors))
      ;; Exit code 1 for CI/strict mode
      ;; In development, use `LINT_WARNINGS_ONLY=1 nix run .#lint` to allow warnings
      (let ((strict-mode (not (getenv "LINT_WARNINGS_ONLY"))))
        (if strict-mode
            (kill-emacs 1)
          (message "Continuing (LINT_WARNINGS_ONLY set)...")
          (kill-emacs 0))))
  (message "\nLinting PASSED.")
  (kill-emacs 0))

;;; run-lint.el ends here
