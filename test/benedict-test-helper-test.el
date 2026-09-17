;;; benedict-test-helper-test.el --- Shared test isolation contracts  -*- lexical-binding: t; -*-

;;; Commentary:

;; Extension-shaped tests replace process-global registrations and hooks.
;; These tests hold `benedict-test-with-clean-registries' to its contract:
;; whatever registrations and default hook values it finds come back by
;; identity -- across a signalling body and nested uses too -- so one
;; contract test cannot change the meaning of the next.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'benedict-retry-http)


(defun benedict-test-helper-test--deftool (id label)
  "Register and return a do-nothing tool named ID advertising LABEL."
  (benedict-tool-register
   (benedict-tool-create :id id :label label :parameters nil :sync t
                         :handler (lambda (_invocation)
                                    (benedict-tool-result :content "")))))

(ert-deftest benedict-test-clean-registries-baseline-precedes-test-bodies ()
  "A pre-entry mutation cannot become the suite's permanent baseline."
  (let ((original-baseline benedict-test--baseline)
        (original-hook-value (default-value 'benedict-run-start-functions))
        (temporary-hook-value (list #'ignore)))
    (unwind-protect
        (progn
          (set-default 'benedict-run-start-functions temporary-hook-value)
          (benedict-test-with-clean-registries
            (should-not (default-value 'benedict-run-start-functions)))
          (should (eq temporary-hook-value
                      (default-value 'benedict-run-start-functions))))
      (setq benedict-test--baseline original-baseline)
      (set-default 'benedict-run-start-functions original-hook-value))))

(ert-deftest benedict-test-clean-registries-restore-registrations-by-identity ()
  "Registrations the body replaces or adds are undone exactly.

Bootstrap registrations -- `eval-elisp' among them -- come back as the
very objects the helper found, and ids the body added disappear."
  (let ((original-tool (benedict-tool-get 'eval-elisp))
        (original-provider (benedict-provider-get 'fake))
        (original-api (benedict-api-get 'openai-responses)))
    (should original-tool)
    (should original-provider)
    (should original-api)
    (unwind-protect
        (progn
          (benedict-test-with-clean-registries
            (benedict-test-helper-test--deftool 'eval-elisp "replacement")
            (benedict-test-helper-test--deftool
             'benedict-test-helper-test-added-tool "added")
            (benedict-defprovider fake :name "replacement")
            (benedict-defprovider benedict-test-helper-test-added-provider
              :name "added")
            (benedict-defapi openai-responses :name "replacement")
            (benedict-defapi benedict-test-helper-test-added-api :name "added"))
          (should (eq original-tool (benedict-tool-get 'eval-elisp)))
          (should (eq original-provider (benedict-provider-get 'fake)))
          (should (eq original-api (benedict-api-get 'openai-responses)))
          (should-not (benedict-tool-get 'benedict-test-helper-test-added-tool))
          (should-not (benedict-provider-get
                       'benedict-test-helper-test-added-provider))
          (should-not (benedict-api-get 'benedict-test-helper-test-added-api)))
      (benedict-tool-register original-tool)
      (benedict-provider-register original-provider)
      (benedict-api-register original-api)
      (benedict-tool-unregister 'benedict-test-helper-test-added-tool)
      (benedict-provider-unregister 'benedict-test-helper-test-added-provider)
      (benedict-api-unregister 'benedict-test-helper-test-added-api))))

(ert-deftest benedict-test-clean-registries-restore-after-a-signal ()
  "A signalling body still restores registrations and default hook values."
  (let ((original-provider (benedict-provider-get 'fake))
        (original-hook-value (default-value 'benedict-run-start-functions))
        (original-http-hook-value
         (default-value 'benedict-http-result-filter-functions)))
    (unwind-protect
        (progn
          (set-default 'benedict-run-start-functions
                       (list (lambda (&rest _) nil)))
          (set-default 'benedict-http-result-filter-functions
                       (list (lambda (result) result)))
          (let ((saved-hook-value (default-value
                                   'benedict-run-start-functions))
                (saved-http-hook-value
                 (default-value 'benedict-http-result-filter-functions)))
            (should-error
             (benedict-test-with-clean-registries
               (benedict-defprovider fake :name "signalling replacement")
               (benedict-defprovider benedict-test-helper-test-signal-provider
                 :name "added before the signal")
               (set-default 'benedict-run-start-functions
                            (list (lambda (&rest _) t)))
               (set-default 'benedict-http-result-filter-functions nil)
               (error "Intentional isolation failure")))
            (should (eq original-provider (benedict-provider-get 'fake)))
            (should-not (benedict-provider-get
                         'benedict-test-helper-test-signal-provider))
            (should (eq saved-hook-value
                        (default-value 'benedict-run-start-functions)))
            (should (eq saved-http-hook-value
                        (default-value
                         'benedict-http-result-filter-functions)))))
      (benedict-provider-register original-provider)
      (benedict-provider-unregister 'benedict-test-helper-test-signal-provider)
      (set-default 'benedict-run-start-functions original-hook-value)
      (set-default 'benedict-http-result-filter-functions
                   original-http-hook-value))))

(ert-deftest benedict-test-clean-registries-tear-down-retry-on-exit ()
  "A helper body cannot leave retry installed or retain retry bookkeeping."
  (let ((entry-http-installed benedict-retry-http--installed)
        (entry-retry-installed benedict-retry--installed))
    (unwind-protect
        (progn
          (benedict-test-with-clean-registries
            (benedict-retry-http-install)
            (puthash 'body '(:attempt 1) benedict-retry--states))
          (should-not benedict-retry-http--installed)
          (should-not benedict-retry--installed)
          (should (= 0 (hash-table-count benedict-retry--states)))
          (benedict-test-with-clean-registries
            (benedict-retry-http-install)
            (benedict-test-with-clean-registries
              (should-not benedict-retry-http--installed)
              (should-not benedict-retry--installed))
            (should benedict-retry-http--installed)
            (should benedict-retry--installed)))
      (benedict-retry-http-uninstall)
      (setq benedict-retry-http--installed entry-http-installed)
      (setq benedict-retry--installed entry-retry-installed))))


(ert-deftest benedict-test-clean-registries-nest-fake-model-catalogs ()
  "An inner use restores the exact fake model the enclosing use registered."
  (unwind-protect
      (benedict-test-with-clean-registries
        (let ((outer-model
               (benedict-provider-fake-model
                (benedict-provider-fake-script nil)
                :id "outer-model")))
          (benedict-test-with-clean-registries
            (benedict-provider-fake-model
             (benedict-provider-fake-script nil)
             :id "inner-model"))
          (should (eq outer-model
                      (benedict-model-resolve "fake/outer-model")))
          (should-error (benedict-model-resolve "fake/inner-model")
                        :type 'benedict-model-unknown)))
    (benedict-provider-fake-reset)))

(ert-deftest benedict-test-clean-registries-nest ()
  "An inner use restores the enclosing use's exact registrations."
  (let ((original-tool (benedict-tool-get 'eval-elisp))
        (original-provider (benedict-provider-get 'fake))
        (original-api (benedict-api-get 'openai-responses)))
    (unwind-protect
        (progn
          (benedict-test-with-clean-registries
            (let ((outer-tool (benedict-test-helper-test--deftool
                               'eval-elisp "outer"))
                  (outer-provider (benedict-defprovider fake
                                    :name "outer"))
                  (outer-api (benedict-defapi openai-responses
                               :name "outer")))
              (benedict-test-with-clean-registries
                (benedict-test-helper-test--deftool 'eval-elisp "inner")
                (benedict-defprovider fake :name "inner")
                (benedict-defapi openai-responses :name "inner")
                (benedict-test-helper-test--deftool
                 'benedict-test-helper-test-inner-tool "inner"))
              (should (eq outer-tool (benedict-tool-get 'eval-elisp)))
              (should (eq outer-provider (benedict-provider-get 'fake)))
              (should (eq outer-api (benedict-api-get 'openai-responses)))
              (should-not (benedict-tool-get
                           'benedict-test-helper-test-inner-tool))))
          (should (eq original-tool (benedict-tool-get 'eval-elisp)))
          (should (eq original-provider (benedict-provider-get 'fake)))
          (should (eq original-api (benedict-api-get 'openai-responses))))
      (benedict-tool-register original-tool)
      (benedict-provider-register original-provider)
      (benedict-api-register original-api)
      (benedict-tool-unregister 'benedict-test-helper-test-inner-tool))))

(provide 'benedict-test-helper-test)

;;; benedict-test-helper-test.el ends here
