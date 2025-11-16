;;; benedict-provider-fake-test.el --- Tests for fake provider -*- lexical-binding: t; -*-

(require 'ert)

(defvar benedict-provider 'fake
  "Fallback provider symbol for tests when benedict.el is not loaded.")

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-provider)
(require 'benedict-provider-fake)

(ert-deftest benedict-provider-fake-default-echo ()
  "Fake provider echoes last user message with metadata."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0))
    (benedict-provider-fake-reset-script)
    (let ((result nil))
      (benedict-provider-dispatch
       (list :messages (list (list :role 'user :content "hello fake")))
       :on-success (lambda (payload) (setq result payload)))
      (cl-loop repeat 50
               until result
               do (sleep-for 0.01))
      (should result)
      (should (equal (plist-get (plist-get result :message) :content)
                     "Fake echo: hello fake"))
      (should (equal (plist-get result :provider) 'fake))
      (should (equal (plist-get result :model) benedict-provider-fake-default-model))
      (let ((usage (plist-get result :usage)))
        (should usage)
        (should (assoc-string "prompt_tokens" usage))
        (should (assoc-string "completion_tokens" usage))))))

(ert-deftest benedict-provider-fake-scripted-error ()
  "Fake provider delivers scripted errors."
  (let ((benedict-provider 'fake)
        (benedict-provider-fake-latency-seconds 0)
        (error-payload nil))
    (let ((benedict-provider-fake-script
           (list (list :type 'error :message "boom" :code "fake_error" :status 500))))
      (benedict-provider-dispatch
       (list :messages (list (list :role 'user :content "trigger error")))
       :on-error (lambda (payload) (setq error-payload payload))))
    (cl-loop repeat 50
             until error-payload
             do (sleep-for 0.01))
    (should error-payload)
    (should (equal (plist-get error-payload :message) "boom"))
    (should (equal (plist-get error-payload :code) "fake_error"))
    (should (equal (plist-get error-payload :status) 500))))

(provide 'benedict-provider-fake-test)
;;; benedict-provider-fake-test.el ends here
