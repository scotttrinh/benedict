;;; run-tests.el --- Batch test runner with dependencies  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Bootstraps package.el into a project-local directory, makes sure all
;; development dependencies are present, loads every *-test.el file, and
;; executes the ERT suite.

;;; Code:

(require 'package)
(require 'seq)
(require 'lgr)

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

;; Logging: surface Benedict messages during batch test runs.
(setq benedict-logging-threshold lgr-level-info
      benedict-logging-configure-function #'benedict-logging-configure-default)
(require 'benedict-logging)
(benedict-logging-setup)
(let ((test-logger (lgr-get-logger "run-tests")))
  (lgr-set-threshold test-logger lgr-level-info)
  (lgr-reset-appenders test-logger)
  (let ((appender (lgr-appender)))
    (lgr-set-threshold appender lgr-level-info)
    (lgr-add-appender test-logger appender)))

(require 'ert)
(require 'propcheck)

(defconst benedict-test-directory
  (expand-file-name "test" benedict-test-root))

;; Make test helpers available to test files via `require'.
(add-to-list 'load-path benedict-test-directory)

(dolist (file (directory-files benedict-test-directory t "-test\\.el\\'"))
  (load file nil nil t))

(let ((selector (if command-line-args-left
                    (pop command-line-args-left)
                  t))
      (lgr (lgr-get-logger "run-tests")))
  (lgr-info lgr "Running tests"
             :selector selector)
  (ert-run-tests-batch-and-exit selector))

;;; run-tests.el ends here
