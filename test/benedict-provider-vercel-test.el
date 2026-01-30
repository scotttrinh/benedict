;;; test/benedict-provider-vercel-test.el --- Tests for Vercel provider -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-provider-vercel)
(require 'benedict-credentials)

(ert-deftest benedict-provider-vercel-resolve-from-file ()
  "Vercel resolves credentials from the filesystem store."
  (let ((temp-dir (make-temp-file "benedict-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'xdg-config-home) (lambda () temp-dir))
                  ((symbol-function 'getenv) (lambda (_) nil))
                  ((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
          (benedict-credentials-set 'vercel 'api '(:token "vercel-token-456"))
          (let ((cred (benedict-provider-vercel--resolve-credential)))
            (should (equal (plist-get cred :token) "vercel-token-456"))
            (should (eq (plist-get cred :source) 'file))))
      (delete-directory temp-dir t))))

(provide 'test/benedict-provider-vercel-test)
;;; benedict-provider-vercel-test.el ends here
