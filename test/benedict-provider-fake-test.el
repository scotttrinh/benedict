;;; benedict-provider-fake-test.el --- Tests for fake provider -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'ert-async)

(defvar benedict-provider 'fake
  "Fallback provider symbol for tests when benedict.el is not loaded.")

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-provider)
(require 'benedict-provider-fake)
(require 'benedict-test-helpers)

(defmacro benedict-provider-test--with-provider (provider &rest body)
  "Register PROVIDER for BODY, then restore the previous registry entry."
  (declare (indent 1))
  `(let* ((provider-id (benedict-provider-id ,provider))
          (previous (benedict-provider-lookup provider-id)))
     (unwind-protect
         (progn
           (benedict-provider-register ,provider)
           ,@body)
       (if previous
           (puthash provider-id previous benedict-provider--registry)
         (remhash provider-id benedict-provider--registry)))))

(ert-deftest-async benedict-provider-fake-default-echo (done)
  "Fake provider echoes last user message with metadata."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success :delay 0.01))))
    (benedict-provider-dispatch
     (list :messages (list (benedict-message-user-text "hello fake")))
     :on-success (lambda (payload)
                   (should (benedict-provider-result-p payload))
                   (should (equal (benedict-provider-result-text payload)
                                  "Fake echo: hello fake"))
                   (should (equal (benedict-provider-result-provider payload) 'fake))
                   (should (equal (benedict-provider-result-model payload)
                                  benedict-provider-fake-default-model))
                   (let ((usage (benedict-provider-result-usage payload)))
                     (should usage)
                     (should (assoc-string "prompt_tokens" usage))
                     (should (assoc-string "completion_tokens" usage)))
                   (funcall done)))))

(ert-deftest-async benedict-provider-fake-scripted-error (done)
  "Fake provider delivers scripted errors."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'error :message "boom" :code "fake_error" :status 500))))
    (benedict-provider-dispatch
     (list :messages (list (benedict-message-user-text "trigger error")))
     :on-error (lambda (payload)
                 (should (equal (plist-get payload :message) "boom"))
                 (should (equal (plist-get payload :code) "fake_error"))
                 (should (equal (plist-get payload :status) 500))
                 (funcall done)))))

(ert-deftest-async benedict-provider-fake-streaming-delivers-chunks (done)
  "Streaming scripts emit chunks before the final payload."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.01)
       (benedict-provider-fake-streaming-chunk-delay 0.0)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("chunk-1" "chunk-2")
                    :chunk-delay 0.005
                    :delay 0.01))))
    (let ((chunks nil))
      (benedict-provider-dispatch
       (list :messages (list (benedict-message-user-text "streaming test")))
       :on-delta (lambda (&rest payload)
                   (should (eq (plist-get payload :kind) 'content-delta))
                   (push (plist-get payload :text) chunks))
       :on-success (lambda (payload)
                     (should (equal (nreverse chunks) '("chunk-1" "chunk-2")))
                     (should (equal (benedict-provider-result-text payload)
                                    "Fake echo: streaming test"))
                     (funcall done))))))

(ert-deftest-async benedict-provider-fake-cancel-aborts-timers (done)
  "Cancelling a fake request prevents callbacks."
  (benedict-test-with-bindings done
      ((benedict-provider 'fake)
       (benedict-provider-fake-latency-seconds 0.2))
    (let ((callback-fired nil))
      (let ((handle
             (benedict-provider-dispatch
              (list :messages (list (benedict-message-user-text "cancel me")))
              :on-success (lambda (_payload)
                            (setq callback-fired t)
                            (funcall done "Callback should not have fired after cancel")))))
        (should handle)
        (benedict-provider-abort handle)
        ;; Wait longer than the latency to ensure callback would have fired
        (run-at-time 0.25 nil
                     (lambda ()
                       (should-not callback-fired)
                       (funcall done)))))))

(ert-deftest benedict-provider-dispatch-uses-request-provider ()
  "Dispatch honors REQUEST provider instead of global provider state."
  (let ((benedict-provider 'fake)
        (captured nil))
    (benedict-provider-test--with-provider
        (benedict-provider--create
         :id 'dispatch-test
         :name "Dispatch Test"
         :send (lambda (provider request &rest callbacks)
                 (setq captured (list :provider (benedict-provider-id provider)
                                      :request request))
                 (funcall (plist-get callbacks :on-success)
                          (benedict-provider-result-create
                           :text "override"
                           :provider 'dispatch-test
                           :model "dispatch/model"))
                 '(:provider dispatch-test :request-id "dispatch-test"))
         :capabilities nil
         :cancel #'ignore)
      (let ((result nil))
        (benedict-provider-dispatch
         (list :provider 'dispatch-test
               :model "dispatch/model"
               :messages (list (benedict-message-user-text "hi")))
         :on-success (lambda (payload)
                       (setq result payload)))
        (should (eq (plist-get captured :provider) 'dispatch-test))
        (should (eq (plist-get (plist-get captured :request) :provider) 'dispatch-test))
        (should (equal (benedict-provider-result-provider result) 'dispatch-test))
        (should (equal (benedict-provider-result-model result) "dispatch/model"))))))

(ert-deftest benedict-provider-abort-uses-handle-provider ()
  "Abort honors HANDLE provider instead of global provider state."
  (let ((benedict-provider 'fake)
        (aborted nil))
    (benedict-provider-test--with-provider
        (benedict-provider--create
         :id 'abort-test
         :name "Abort Test"
         :send #'ignore
         :capabilities nil
         :cancel (lambda (provider handle)
                   (setq aborted (list :provider (benedict-provider-id provider)
                                       :handle handle))))
      (let ((handle '(:provider abort-test :request-id "abort-me")))
        (benedict-provider-abort handle)
        (should (eq (plist-get aborted :provider) 'abort-test))
        (should (equal (plist-get (plist-get aborted :handle) :request-id)
                       "abort-me"))))))

(provide 'benedict-provider-fake-test)
;;; benedict-provider-fake-test.el ends here
