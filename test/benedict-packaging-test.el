;;; benedict-packaging-test.el --- Installable package artifacts  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'benedict-packages)
(load (expand-file-name "scripts/build-packages.el" benedict-test-root) nil t)

(defun benedict-packaging-test--emacs (&rest arguments)
  "Run a fresh Emacs with ARGUMENTS and return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let* ((process-environment
            (seq-remove (lambda (entry)
                          (string-prefix-p "EMACSLOADPATH=" entry))
                        process-environment))
           (status (apply #'call-process
                          (expand-file-name invocation-name invocation-directory)
                          nil t nil "-Q" "--batch" arguments)))
      (cons status (buffer-string)))))

(defun benedict-packaging-test--should-succeed (result)
  "Assert fresh-process RESULT succeeded, displaying its output on failure."
  (ert-info ((cdr result)) (should (zerop (car result)))))

(defun benedict-packaging-test--spec (name)
  (assq name benedict-packages))

(defun benedict-packaging-test--dependency-closure (spec)
  "Return SPEC and its internal dependency specs in manifest order."
  (let ((wanted (list (car spec)))
        (changed t))
    (while changed
      (setq changed nil)
      (dolist (name (copy-sequence wanted))
        (dolist (requirement (plist-get (cdr (benedict-packaging-test--spec name))
                                        :requires))
          (when (and (benedict-packaging-test--spec (car requirement))
                     (not (memq (car requirement) wanted)))
            (push (car requirement) wanted)
            (setq changed t)))))
    (seq-filter (lambda (candidate) (memq (car candidate) wanted))
                benedict-packages)))

(ert-deftest benedict-packaging-manifest-matches-main-file-headers ()
  "Artifact dependency data and package headers must not drift."
  (dolist (spec benedict-packages)
    (let* ((name (symbol-name (car spec)))
           (main (seq-find
                  (lambda (relative) (equal (file-name-base relative) name))
                  (plist-get (cdr spec) :files))))
      (should main)
      (with-temp-buffer
        (insert-file-contents (expand-file-name main benedict-test-root))
        (let ((description (package-buffer-info)))
          (should (equal (package-desc-reqs description)
                         (mapcar (lambda (requirement)
                                   (list (car requirement)
                                         (version-to-list (cadr requirement))))
                                 (plist-get (cdr spec) :requires)))))))))

(ert-deftest benedict-packaging-kernel-tar-installs-alone ()
  "The actual benedict artifact installs and loads with no sibling package."
  (let ((output (make-temp-file "benedict-artifacts-" t))
        (user-dir (make-temp-file "benedict-package-user-" t)))
    (unwind-protect
        (let ((artifact (benedict-package-build (car benedict-packages) output)))
          (benedict-packaging-test--should-succeed
           (benedict-packaging-test--emacs
            "--eval"
            (format
             "(progn (require 'package) (setq package-user-dir %S package-check-signature nil) (package-install-file %S) (require 'benedict-core) (let ((session (benedict-session-create :id \"artifact\"))) (unless (and (equal (benedict-session-id session) \"artifact\") (null (benedict-session-path session))) (kill-emacs 3))) (unless (and (null (locate-library \"benedict-http\")) (null (locate-library \"benedict-chat\"))) (kill-emacs 2)))"
             user-dir artifact))))
      (delete-directory output t)
      (delete-directory user-dir t))))

(ert-deftest benedict-packaging-artifacts-load-from-declared-files ()
  "Every first-party feature loads from staged artifact contents only."
  (let ((output (make-temp-file "benedict-artifacts-" t))
        (unpacked (make-temp-file "benedict-unpacked-" t)))
    (unwind-protect
        (let ((directories nil))
          (dolist (spec benedict-packages)
            (let ((artifact (benedict-package-build spec output)))
              (should (zerop (call-process "tar" nil nil nil
                                           "-xf" artifact "-C" unpacked)))
              (push (cons (car spec)
                          (expand-file-name
                           (format "%s-%s" (car spec) benedict-package-version)
                           unpacked))
                    directories)))
          (dolist (spec benedict-packages)
            (let ((arguments nil)
                  (closure (benedict-packaging-test--dependency-closure spec)))
              (dolist (dependency closure)
                (setq arguments
                      (append arguments
                              (list "-L" (cdr (assq (car dependency) directories))))))
              ;; Add external libraries only when they occur in the declared
              ;; transitive dependency closure.
              (dolist (library '(vui markdown-mode))
                (when (seq-some
                       (lambda (dependency)
                         (assq library (plist-get (cdr dependency) :requires)))
                       closure)
                  (when-let ((file (locate-library (symbol-name library))))
                    (setq arguments
                          (append arguments
                                  (list "-L" (file-name-directory file)))))))
              (setq arguments
                    (append arguments
                            (list "--eval"
                                  (format "(require '%s)"
                                          (plist-get (cdr spec) :feature)))))
              (benedict-packaging-test--should-succeed
               (apply #'benedict-packaging-test--emacs arguments)))))
      (delete-directory output t)
      (delete-directory unpacked t))))

(provide 'benedict-packaging-test)
;;; benedict-packaging-test.el ends here
