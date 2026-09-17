;;; lint-packages.el --- Lint Benedict artifacts in package context  -*- lexical-binding: t; -*-

;;; Commentary:
;; Root Eask covers aggregate checkdoc.  This checks each source file against
;; the main file and dependency header of the artifact that actually ships it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'package)
(require 'package-lint)
(require 'benedict-packages)

(defconst benedict-package-lint-root
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))))

(defun benedict-package-lint--main-file (spec)
  "Return the artifact main source file named by SPEC."
  (let ((name (symbol-name (car spec))))
    (or (seq-find (lambda (relative)
                    (equal (file-name-base relative) name))
                  (plist-get (cdr spec) :files))
        (error "No main source file for %s" name))))

(defun benedict-package-lint-batch ()
  "Lint every manifest source file in its package context, then exit."
  (package-initialize)
  (dolist (spec benedict-packages)
    (push (list (car spec)
                (package-desc-create
                 :name (car spec) :version '(0 1 0)
                 :summary "Benedict first-party package"
                 :reqs (plist-get (cdr spec) :requires)
                 :kind 'tar :archive "benedict-local"))
          package-archive-contents))
  (let* ((success t)
         (text-quoting-style 'grave)
         (requirements
          (delete-dups
           (apply #'append
                  (mapcar (lambda (spec) (copy-tree (plist-get (cdr spec) :requires)))
                          benedict-packages))))
         ;; AGENTS.md establishes one repo-wide `benedict-' namespace even
         ;; though artifact names are narrower.  Keep package-lint's normal
         ;; checks and whitelist exactly that documented prefix exception.
         (package-lint--sane-prefixes
          (concat "\\(?:\\`benedict-\\|" package-lint--sane-prefixes "\\)")))
    (dolist (requirement requirements)
      (unless (or (eq (car requirement) 'emacs)
                  (assq (car requirement) package-archive-contents)
                  (assq (car requirement) package-alist))
        (push (list (car requirement)
                    (package-desc-create
                     :name (car requirement)
                     :version (version-to-list (cadr requirement))
                     :summary "Declared artifact dependency"
                     :reqs nil :kind 'tar :archive "benedict-lint"))
              package-archive-contents)))
    (dolist (spec benedict-packages)
      (let ((package-lint-main-file
             (expand-file-name (benedict-package-lint--main-file spec)
                               benedict-package-lint-root)))
        (dolist (relative (plist-get (cdr spec) :files))
          (when (string-suffix-p ".el" relative)
            (let ((file (expand-file-name relative benedict-package-lint-root)))
              (with-temp-buffer
                (insert-file-contents file)
                (setq buffer-file-name file)
                (emacs-lisp-mode)
                (dolist (issue (package-lint-buffer))
                  (setq success nil)
                  (message "%s:%d:%d: %s: %s"
                           relative (nth 0 issue) (nth 1 issue)
                           (nth 2 issue) (nth 3 issue)))))))))
    (kill-emacs (if success 0 1))))

(provide 'lint-packages)
;;; lint-packages.el ends here
