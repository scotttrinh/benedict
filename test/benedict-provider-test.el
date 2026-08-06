;;; benedict-provider-test.el --- Provider and API registries  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 7.1 says a provider is not an API and that conflating the two is the
;; most expensive mistake available here.  These tests hold the split in place:
;; a service is a catalog entry over a protocol, models carry the provider/api/
;; model triple that decides how their entries are lowered, and the kernel
;; reaches all of it through exactly one function.

;;; Code:

(require 'ert)
(require 'test-helper)

(defmacro benedict-provider-test--with-registrations (&rest body)
  "Evaluate BODY, removing any test provider or API it registers afterwards."
  (declare (indent 0) (debug body))
  `(unwind-protect (progn ,@body)
     (benedict-provider-unregister 'benedict-test-service)
     (benedict-provider-unregister 'benedict-test-other)
     (benedict-api-unregister 'benedict-test-wire)))

;;;; Registries

(ert-deftest benedict-provider-registration-is-idempotent ()
  "Both registries replace by id, so an extension file stays reloadable."
  (benedict-provider-test--with-registrations
    (benedict-defprovider benedict-test-service :name "First" :api 'benedict-test-wire)
    (benedict-defprovider benedict-test-service :name "Second" :api 'benedict-test-wire)
    (should (equal (benedict-provider-name
                    (benedict-provider-get 'benedict-test-service))
                   "Second"))
    (benedict-defapi benedict-test-wire :name "First")
    (benedict-defapi benedict-test-wire :name "Second")
    (should (equal (benedict-api-name (benedict-api-get 'benedict-test-wire))
                   "Second"))
    (should (equal (length (seq-filter
                            (lambda (p) (eq (benedict-provider-id p)
                                            'benedict-test-service))
                            (benedict-provider-list)))
                   1))))

(ert-deftest benedict-provider-defprovider-keeps-the-short-key-names ()
  "`:models' and `:stream' are the definition surface SPEC-001 7.2 specifies."
  (benedict-provider-test--with-registrations
    (let ((provider (benedict-defprovider benedict-test-service
                      :name "Service"
                      :api 'benedict-test-wire
                      :models (lambda (&optional _force) 'catalog)
                      :stream #'ignore)))
      (should (eq (benedict-provider-models provider) 'catalog))
      (should (eq (benedict-provider-stream-function provider) #'ignore)))))

(ert-deftest benedict-provider-lookups-signal-when-absent ()
  (should-error (benedict-provider-get-or-signal 'benedict-test-absent)
                :type 'benedict-provider-unknown)
  (should-error (benedict-api-get-or-signal 'benedict-test-absent)
                :type 'benedict-api-unknown)
  (should (null (benedict-provider-get 'benedict-test-absent))))

;;;; Model resolution

(ert-deftest benedict-model-resolve-splits-at-the-first-slash-only ()
  "Model ids routinely contain slashes of their own."
  (benedict-provider-test--with-registrations
    (let ((model (benedict-model-create :id "openai/gpt-5"
                                        :provider 'benedict-test-service
                                        :api 'benedict-test-wire)))
      (benedict-defprovider benedict-test-service
        :name "Service"
        :api 'benedict-test-wire
        :models (lambda (&optional _force) (list model)))
      (should (eq (benedict-model-resolve "benedict-test-service/openai/gpt-5") model))
      ;; A model struct passes through untouched.
      (should (eq (benedict-model-resolve model) model)))))

(ert-deftest benedict-model-resolve-reports-what-was-missing ()
  (benedict-provider-test--with-registrations
    (benedict-defprovider benedict-test-service
      :name "Service" :api 'benedict-test-wire :models (lambda (&optional _f) nil))
    (should-error (benedict-model-resolve "benedict-test-absent/x")
                  :type 'benedict-provider-unknown)
    (should-error (benedict-model-resolve "benedict-test-service/absent")
                  :type 'benedict-model-unknown)
    (should-error (benedict-model-resolve "no-slash") :type 'benedict-provider-error)
    (should-error (benedict-model-resolve 42) :type 'benedict-provider-error)))

;;;; The origin triple

(ert-deftest benedict-model-same-origin-p-requires-all-three ()
  "Origin is provider, API, and model together; two out of three is foreign."
  (let ((model (benedict-model-create :id "gpt-5" :provider 'svc :api 'wire)))
    (should (benedict-model-same-origin-p
             model '(:provider svc :api wire :model "gpt-5")))
    (dolist (foreign '((:provider other :api wire :model "gpt-5")
                       (:provider svc :api other :model "gpt-5")
                       (:provider svc :api wire :model "gpt-4")
                       (:provider nil :api nil :model nil)))
      (should-not (benedict-model-same-origin-p model foreign)))))

(ert-deftest benedict-model-origin-matches-what-an-entry-records ()
  "`benedict-entry-origin' produces exactly what the origin test consumes."
  (let ((model (benedict-model-create :id "gpt-5" :provider 'svc :api 'wire))
        (entry (benedict-entry-create
                :role 'assistant :content "hi"
                :meta '(:provider svc :api wire :model "gpt-5"))))
    (should (benedict-model-same-origin-p model (benedict-entry-origin entry)))))

;;;; Capability flags

(ert-deftest benedict-model-compat-falls-back-to-the-provider ()
  "A model overrides a service-wide flag; otherwise it inherits it."
  (benedict-provider-test--with-registrations
    (benedict-defprovider benedict-test-service
      :name "Service"
      :api 'benedict-test-wire
      :compat '(:supports-developer-role t :supports-strict-tools t))
    (let ((model (benedict-model-create :id "m" :provider 'benedict-test-service
                                        :api 'benedict-test-wire
                                        :compat '(:supports-strict-tools nil))))
      (should (eq (benedict-model-compat-get model :supports-developer-role) t))
      ;; Present-and-nil on the model must beat present-and-t on the provider,
      ;; which is why this reads with `plist-member' rather than `plist-get'.
      (should (null (benedict-model-compat-get model :supports-strict-tools)))
      (should (eq (benedict-model-compat-get model :unknown-flag 'default)
                  'default)))))

(ert-deftest benedict-model-input-modalities-default-to-text ()
  (let ((plain (benedict-model-create :id "m" :provider 'svc :api 'wire))
        (visual (benedict-model-create :id "m" :provider 'svc :api 'wire
                                       :input-modalities '(text image))))
    (should (benedict-model-supports-p plain 'text))
    (should-not (benedict-model-supports-p plain 'image))
    (should (benedict-model-supports-p visual 'image))))

;;;; Reaching a provider

(ert-deftest benedict-provider-stream-uses-the-provider-transport ()
  (benedict-provider-test--with-registrations
    (let ((seen nil))
      (benedict-defprovider benedict-test-service
        :name "Service"
        :api 'benedict-test-wire
        :stream (lambda (_model request handler)
                  (setq seen request)
                  (funcall handler '(:type :done :reason stop))
                  (lambda () 'cancelled)))
      (let* ((model (benedict-model-create :id "m" :provider 'benedict-test-service
                                           :api 'benedict-test-wire))
             (events nil)
             (cancel (benedict-provider-stream
                      model '(:entries nil) (lambda (event) (push event events)))))
        (should (equal seen '(:entries nil)))
        (should (equal events '((:type :done :reason stop))))
        (should (eq (funcall cancel) 'cancelled))))))

(ert-deftest benedict-provider-stream-without-a-transport-says-so ()
  "Until a wire adapter exists there is no HTTP path, and that is explicit."
  (benedict-provider-test--with-registrations
    (benedict-defprovider benedict-test-service :name "Service" :api 'benedict-test-wire)
    (let ((model (benedict-model-create :id "m" :provider 'benedict-test-service
                                        :api 'benedict-test-wire)))
      (should-error (benedict-provider-stream model nil #'ignore)
                    :type 'benedict-provider-no-transport))))

(provide 'benedict-provider-test)

;;; benedict-provider-test.el ends here
