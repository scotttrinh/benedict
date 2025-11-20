;;; run-tests.el --- Batch test runner with dependencies  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Bootstraps package.el into a project-local directory, makes sure all
;; development dependencies are present, loads every *-test.el file, and
;; executes the ERT suite.

;;; Code:

(require 'package)
(require 'seq)

(defconst benedict-test-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Absolute path to the Benedict repository root.")

(setq package-user-dir (expand-file-name ".elpa" benedict-test-root)
      package-archives '(("gnu"   . "https://elpa.gnu.org/packages/")
                         ("melpa" . "https://melpa.org/packages/"))
      package-archive-priorities '(("melpa" . 5)
                                   ("gnu"   . 3)))
(setq load-prefer-newer t)

(package-initialize)

(defun benedict--ensure-packages (packages)
  "Install every symbol in PACKAGES unless it is already present."
  (let ((missing (seq-filter (lambda (pkg)
                               (not (package-installed-p pkg)))
                             packages)))
    (when missing
      (unless package-archive-contents
        (package-refresh-contents))
      (mapc #'package-install missing))))

(benedict--ensure-packages '(ert-async))

(add-to-list 'load-path benedict-test-root)

(require 'ert)
(require 'propcheck)

(defconst benedict-test-directory
  (expand-file-name "test" benedict-test-root))

(dolist (file (directory-files benedict-test-directory t "-test\\.el\\'"))
  (load file nil nil t))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
