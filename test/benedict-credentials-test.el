;;; test/benedict-credentials-test.el --- Tests for benedict-credentials -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-credentials)

(ert-deftest benedict-credentials-path-resolution ()
  "Test that credentials path uses xdg-config-home and app name."
  (let ((temp-dir (make-temp-file "benedict-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'xdg-config-home) (lambda () temp-dir)))
          (let ((expected-dir (expand-file-name "benedict" temp-dir)))
            (should (equal (benedict-credentials--config-dir) expected-dir))
            (should (file-directory-p expected-dir))
            (should (equal (benedict-credentials--file)
                           (expand-file-name "auth.json" expected-dir)))))
      (delete-directory temp-dir t))))

(ert-deftest benedict-credentials-read-write-all ()
  "Test basic read/write of all credentials."
  (let ((temp-dir (make-temp-file "benedict-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'xdg-config-home) (lambda () temp-dir)))
          (let ((data '((provider1 . ((api . (:token "tok1"))))
                        (provider2 . ((oauth . (:refresh "ref2")))))))
            (benedict-credentials--write-all data)
            ;; Use high-level get to verify, as it handles alist->plist conversion
            (should (equal (benedict-credentials-get 'provider1 'api)
                           '(:token "tok1")))
            (should (equal (benedict-credentials-get 'provider2 'oauth)
                           '(:refresh "ref2")))
            
            ;; Verify file permissions (600)
            (let ((file (benedict-credentials--file)))
              (should (equal (file-modes file) #o600)))))
      (delete-directory temp-dir t))))

(ert-deftest benedict-credentials-get-set-remove ()
  "Test high-level get, set, and remove operations."
  (let ((temp-dir (make-temp-file "benedict-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'xdg-config-home) (lambda () temp-dir)))
          ;; Initial state: empty
          (should (null (benedict-credentials-get 'test-provider 'api)))

          ;; Set API key
          (benedict-credentials-set 'test-provider 'api '(:token "secret-key"))
          (should (equal (benedict-credentials-get 'test-provider 'api)
                         '(:token "secret-key")))

          ;; Set OAuth for same provider
          (benedict-credentials-set 'test-provider 'oauth '(:refresh "refresh-token"))
          (should (equal (benedict-credentials-get 'test-provider 'api)
                         '(:token "secret-key")))
          (should (equal (benedict-credentials-get 'test-provider 'oauth)
                         '(:refresh "refresh-token")))

          ;; Remove specific auth type
          (benedict-credentials-remove 'test-provider 'api)
          (should (null (benedict-credentials-get 'test-provider 'api)))
          (should (equal (benedict-credentials-get 'test-provider 'oauth)
                         '(:refresh "refresh-token")))

          ;; Remove entire provider
          (benedict-credentials-remove 'test-provider)
          (should (null (benedict-credentials-get 'test-provider 'oauth))))
      (delete-directory temp-dir t))))

(ert-deftest benedict-credentials-resolve-precedence ()
  "Test that credential resolution follows the configured precedence."
  (let ((temp-dir (make-temp-file "benedict-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'xdg-config-home) (lambda () temp-dir))
                  ((symbol-function 'getenv)
                   (lambda (var) (when (string= var "TEST_ENV_VAR") "env-token")))
                  ((symbol-function 'auth-source-search)
                   (lambda (&rest args)
                     (list (list :host "test-host" :secret "auth-source-token")))))
          
          ;; 1. Env wins (default: env file auth-source)
          (benedict-credentials-set 'test-p 'api '(:token "file-token"))
          (let ((res (benedict-credentials-resolve-api-key
                      'test-p
                      :env-var "TEST_ENV_VAR"
                      :auth-source-params '(:host "test-host"))))
            (should (equal (plist-get res :token) "env-token"))
            (should (eq (plist-get res :source) 'env)))

          ;; 2. File wins when env is nil
          (cl-letf (((symbol-function 'getenv) (lambda (_) nil)))
            (let ((res (benedict-credentials-resolve-api-key
                        'test-p
                        :env-var "TEST_ENV_VAR"
                        :auth-source-params '(:host "test-host"))))
              (should (equal (plist-get res :token) "file-token"))
              (should (eq (plist-get res :source) 'file))))

          ;; 3. Auth-source wins when both env and file are nil
          (cl-letf (((symbol-function 'getenv) (lambda (_) nil)))
            (benedict-credentials-remove 'test-p)
            (let ((res (benedict-credentials-resolve-api-key
                        'test-p
                        :env-var "TEST_ENV_VAR"
                        :auth-source-params '(:host "test-host"))))
              (should (equal (plist-get res :token) "auth-source-token"))
              (should (eq (plist-get res :source) 'auth-source))))

          ;; 4. Custom precedence: auth-source first
          (let ((benedict-credentials-sources '(auth-source file env)))
            (benedict-credentials-set 'test-p 'api '(:token "file-token"))
            (let ((res (benedict-credentials-resolve-api-key
                        'test-p
                        :env-var "TEST_ENV_VAR"
                        :auth-source-params '(:host "test-host"))))
              (should (equal (plist-get res :token) "auth-source-token"))
              (should (eq (plist-get res :source) 'auth-source)))))
      (delete-directory temp-dir t))))

(provide 'test/benedict-credentials-test)
;;; benedict-credentials-test.el ends here
