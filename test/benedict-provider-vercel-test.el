;;; benedict-provider-vercel-test.el --- Tests for the Vercel AI Gateway provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; The provider is a catalog over the Responses adapter — a dozen lines of
;; identity plus a catalog function.  The catalog function is where the
;; interesting behavior lives: parsing the gateway's `/v1/models' response,
;; converting per-token pricing to per-million, filtering non-language models,
;; caching to disk, and falling back to a hardcoded list when the network is
;; unavailable.
;;
;; No network call is made.  `benedict-http-request-sync' is stubbed to return
;; the recorded fixture, and the cache file is redirected to a temp directory.
;;
;; See SPEC-001 7.6 and D21.

;;; Code:

(require 'ert)
(require 'json)
(require 'test-helper)

;;;; Helpers

(defun benedict-provider-vercel-test--fixture-body ()
  "Return the contents of the recorded models fixture as an HTTP result plist."
  (list :status 200
        :headers '(("content-type" . "application/json"))
        :body (benedict-test-fixture-contents "vercel-ai-gateway-models.json")))

(defmacro benedict-provider-vercel-test--with-fixture-catalog (&rest body)
  "Evaluate BODY with the catalog fetch returning the recorded fixture."
  (declare (indent 0) (debug body))
  `(benedict-test-with-quiet-log
     (cl-letf (((symbol-function 'benedict-http-request-sync)
                (lambda (&rest _) (benedict-provider-vercel-test--fixture-body))))
       ,@body)))

(defmacro benedict-provider-vercel-test--with-failed-fetch (&rest body)
  "Evaluate BODY with the catalog fetch always failing."
  (declare (indent 0) (debug body))
  `(benedict-test-with-quiet-log
     (cl-letf (((symbol-function 'benedict-http-request-sync)
                (lambda (&rest _) (list :error "network down" :reason 'process))))
       ,@body)))

(defmacro benedict-provider-vercel-test--with-temp-cache (&rest body)
  "Evaluate BODY with the catalog cache redirected to a temp directory."
  (declare (indent 0))
  `(let ((dir (make-temp-file "benedict-vercel-cache-" t)))
     (unwind-protect
         (cl-letf (((symbol-function 'xdg-cache-home)
                    (lambda () dir)))
           ,@body)
       (delete-directory dir t))))

;;;; Parsing the catalog

(ert-deftest benedict-provider-vercel-parses-language-models-from-the-catalog ()
  "The catalog parser returns language models with their metadata."
  (benedict-provider-vercel-test--with-fixture-catalog
    (benedict-provider-vercel-test--with-temp-cache
      (let ((models (benedict-provider-vercel--catalog t)))
        (should (>= (length models) 4))
        (dolist (model models)
          (should (equal (benedict-model-provider model) 'vercel-ai-gateway))
          (should (equal (benedict-model-api model) 'openai-responses)))))))

(ert-deftest benedict-provider-vercel-filters-out-non-language-models ()
  "An embedding model in the catalog is not returned (SPEC-001 7.6)."
  (benedict-provider-vercel-test--with-fixture-catalog
    (benedict-provider-vercel-test--with-temp-cache
      (let ((models (benedict-provider-vercel--catalog t)))
        (should-not (seq-find
                     (lambda (m)
                       (string-match-p "embedding" (benedict-model-id m)))
                     models))))))

(ert-deftest benedict-provider-vercel-sets-reasoning-p-from-tags ()
  "The `reasoning' tag sets `reasoning-p'."
  (benedict-provider-vercel-test--with-fixture-catalog
    (benedict-provider-vercel-test--with-temp-cache
      (let ((deepseek (seq-find
                       (lambda (m)
                         (equal (benedict-model-id m)
                                "deepseek/deepseek-v4-flash-0731"))
                       (benedict-provider-vercel--catalog t))))
        (should deepseek)
        (should (benedict-model-reasoning-p deepseek))))))

(ert-deftest benedict-provider-vercel-sets-input-modalities-from-catalog ()
  "The catalog's `modalities.input' becomes the model's `input-modalities'."
  (benedict-provider-vercel-test--with-fixture-catalog
    (benedict-provider-vercel-test--with-temp-cache
      (let ((gpt5 (seq-find
                    (lambda (m) (equal (benedict-model-id m) "openai/gpt-5"))
                    (benedict-provider-vercel--catalog t))))
        (should gpt5)
        (should (equal (benedict-model-input-modalities gpt5) '(text image pdf)))))))

;;;; Pricing conversion

(ert-deftest benedict-provider-vercel-converts-per-token-to-per-million ()
  "Pricing strings are multiplied by 1e6 at parse time (SPEC-001 7.6).
DeepSeek reports input \"0.00000013\" per token → 0.13 per million."
  (benedict-provider-vercel-test--with-fixture-catalog
    (benedict-provider-vercel-test--with-temp-cache
      (let ((deepseek (seq-find
                       (lambda (m)
                         (equal (benedict-model-id m)
                                "deepseek/deepseek-v4-flash-0731"))
                       (benedict-provider-vercel--catalog t))))
        (should deepseek)
        (should (equal (plist-get (benedict-model-cost deepseek) :input)
                       0.13))
        (should (equal (plist-get (benedict-model-cost deepseek) :output)
                       0.26))
        (should (equal (plist-get (benedict-model-cost deepseek) :cache-read)
                       0.028))))))

;;;; Fallback

(ert-deftest benedict-provider-vercel-falls-back-when-fetch-fails ()
  "When the fetch fails, the hardcoded fallback list is returned."
  (benedict-provider-vercel-test--with-failed-fetch
    (benedict-provider-vercel-test--with-temp-cache
      (let ((models (benedict-provider-vercel--catalog t)))
        (should (equal models benedict-provider-vercel--fallback-models))))))

(ert-deftest benedict-provider-vercel-fallback-models-have-correct-provider-and-api ()
  "Fallback models are over vercel-ai-gateway / openai-responses."
  (dolist (model benedict-provider-vercel--fallback-models)
    (should (equal (benedict-model-provider model) 'vercel-ai-gateway))
    (should (equal (benedict-model-api model) 'openai-responses))))

;;;; Caching

(ert-deftest benedict-provider-vercel-caches-a-fetched-catalog ()
  "A fetched catalog is written to disk and read on the next call without fetching."
  (benedict-provider-vercel-test--with-temp-cache
    (let ((fetches 0))
      (cl-letf (((symbol-function 'benedict-http-request-sync)
                 (lambda (&rest _)
                   (cl-incf fetches)
                   (benedict-provider-vercel-test--fixture-body))))
        (benedict-test-with-quiet-log
          ;; First call fetches.
          (let ((first (benedict-provider-vercel--catalog t)))
            (should (= fetches 1))
            ;; Second call reads from cache, no fetch.
            (let ((second (benedict-provider-vercel--catalog)))
              (should (= fetches 1))
              (should (= (length first) (length second))))))))))

(ert-deftest benedict-provider-vercel-does-not-fetch-when-cache-is-fresh ()
  "A fresh cache means no fetch on a normal (non-force) call."
  (benedict-provider-vercel-test--with-temp-cache
    (let ((fetches 0))
      (cl-letf (((symbol-function 'benedict-http-request-sync)
                 (lambda (&rest _)
                   (cl-incf fetches)
                   (benedict-provider-vercel-test--fixture-body))))
        (benedict-test-with-quiet-log
          (benedict-provider-vercel--catalog t)
          (should (= fetches 1))
          (benedict-provider-vercel--catalog)
          (should (= fetches 1)))))))

;;;; Registration

(ert-deftest benedict-provider-vercel-is-registered ()
  "The provider is registered under `vercel-ai-gateway'."
  (should (benedict-provider-get 'vercel-ai-gateway)))

(ert-deftest benedict-provider-vercel-resolves-a-model-from-the-fallback ()
  "A fallback model resolves through `benedict-model-resolve'."
  (let ((model (benedict-model-resolve
                "vercel-ai-gateway/deepseek/deepseek-v4-flash-0731")))
    (should (equal (benedict-model-id model)
                   "deepseek/deepseek-v4-flash-0731"))))

(provide 'benedict-provider-vercel-test)

;;; benedict-provider-vercel-test.el ends here
