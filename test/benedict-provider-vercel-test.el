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

(ert-deftest benedict-provider-vercel-send-logs-http-request ()
  "Vercel send emits structured debug logs through lgr."
  (let ((logged nil))
    (cl-letf (((symbol-function 'lgr-get-threshold) (lambda (&rest _) 600))
              ((symbol-function 'lgr-log)
               (lambda (_lgr level msg &rest args)
                 (when (= level 500)
                   (push (cons msg args) logged))))
              ((symbol-function 'benedict-http-request)
               (lambda (&rest _) nil))
              ((symbol-function 'benedict-provider-vercel--resolve-credential)
               (lambda () (list :token "secret-token" :source 'env))))
      (benedict-provider-vercel--send
       nil
       (list :messages (list (list :role 'user :content "hi")) :stream nil))
      (let ((request-log (assoc "Vercel HTTP request" logged)))
        (should request-log)
        (let* ((args (cdr request-log))
               (headers (plist-get args :headers))
               (auth (cdr (assoc "Authorization" headers))))
          (should (equal (plist-get args :credential-source) 'env))
          (should (equal (plist-get args :streaming) nil))
          (should auth)
          (should-not (string-match-p "secret-token" auth)))))))

(ert-deftest benedict-provider-vercel-process-http-response-logs-completion ()
  "Successful HTTP responses emit completion logs through lgr."
  (let ((logged nil))
    (cl-letf (((symbol-function 'lgr-get-threshold) (lambda (&rest _) 600))
              ((symbol-function 'lgr-log)
               (lambda (_lgr _level msg &rest args)
                 (push (cons msg args) logged))))
      (benedict-provider-vercel--state-create
       :id "req-1"
       :start-time (current-time))
      (benedict-provider-vercel--process-http-response
       (list :request-id "req-1" :attempt 1 :start-time (current-time))
       200
       "{\"model\":\"v-model\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}]}")
      (let ((completion-log (assoc "Vercel completion" logged)))
        (should completion-log)
        (let ((args (cdr completion-log)))
          (should (equal (plist-get args :request-id) "req-1"))
          (should (equal (plist-get args :status) 200))
          (should (equal (plist-get args :model) "v-model"))
          (should-not (plist-get args :empty-response)))))))

(provide 'test/benedict-provider-vercel-test)
;;; benedict-provider-vercel-test.el ends here
