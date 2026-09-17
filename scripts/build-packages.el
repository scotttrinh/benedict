;;; build-packages.el --- Build Benedict package tarballs  -*- lexical-binding: t; -*-

;;; Commentary:
;; Batch entry point: emacs -Q --batch -L packages -l scripts/build-packages.el
;;                    -f benedict-package-build-all [OUTPUT-DIRECTORY]

;;; Code:

(require 'cl-lib)
(require 'package)
(require 'benedict-packages)

(defconst benedict-package-version "0.1.0")

(defconst benedict-package-root
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root captured while this build script is loaded.")

(defun benedict-package--descriptor (name requires)
  (format "(define-package %S %S %S '%S)\n"
          (symbol-name name) benedict-package-version
          "Benedict first-party package" requires))

(defun benedict-package-build (spec output-directory)
  "Build installable package tarball from manifest SPEC in OUTPUT-DIRECTORY."
  (let* ((name (car spec))
         (plist (cdr spec))
         (root benedict-package-root)
         (temporary (make-temp-file "benedict-package-" t))
         (base (format "%s-%s" name benedict-package-version))
         (stage (expand-file-name base temporary))
         (artifact (expand-file-name (concat base ".tar") output-directory)))
    (unwind-protect
        (progn
          (make-directory stage t)
          (dolist (relative (plist-get plist :files))
            (copy-file (expand-file-name relative root)
                       (expand-file-name (file-name-nondirectory relative) stage)))
          (with-temp-file (expand-file-name (format "%s-pkg.el" name) stage)
            (insert (benedict-package--descriptor name (plist-get plist :requires))))
          (make-directory output-directory t)
          (let ((process-environment
                 (cons "COPYFILE_DISABLE=1" process-environment)))
            (unless (zerop (call-process "tar" nil nil nil
                                         "-cf" artifact "-C" temporary base))
              (error "tar failed for %s" name)))
          artifact)
      (delete-directory temporary t))))

(defun benedict-package-build-all (&optional output-directory)
  "Build every package, printing one artifact path per line.
OUTPUT-DIRECTORY defaults to the first remaining command-line argument, then
to dist/ under the repository root."
  (let ((output (expand-file-name
                 (or output-directory (car command-line-args-left) "dist")
                 benedict-package-root)))
    (dolist (spec benedict-packages)
      (princ (concat (benedict-package-build spec output) "\n")))))

(provide 'build-packages)
;;; build-packages.el ends here
