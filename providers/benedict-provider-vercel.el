;;; benedict-provider-vercel.el --- Vercel AI Gateway provider  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A service, not a protocol.  Vercel AI Gateway speaks the OpenAI Responses
;; API across its whole catalog (SPEC-001 7.4, D1), so this file is a dozen
;; lines of identity plus a catalog function.  The wire adapter lives in
;; `benedict-api-openai-responses'; this file says who the service is, where
;; it is, how to authenticate, and what it offers.
;;
;; The catalog is resolved at runtime with an on-disk cache rather than
;; generated at build time, because Benedict has no build step (P8).  The
;; cache lives at `~/.cache/benedict/models/vercel-ai-gateway.eld' with a
;; 24-hour TTL.  On a cold cache or network failure, a small hardcoded list
;; of known-good model ids keeps the system usable offline.
;;
;; Two things the Vercel catalog made concrete (SPEC-001 7.6):
;;
;;   - Catalog rates are per token, as strings; model records are per million.
;;     Conversion happens at parse time, so nothing downstream knows which
;;     unit it is holding.
;;   - Catalog resolution is the one place a blocking request is acceptable,
;;     because `benedict-model-resolve' is synchronous and the transport is
;;     not.  The cache makes the blocking path cold-cache-only.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'xdg)
(require 'benedict-provider)
(require 'benedict-http)
(require 'benedict-auth)

;;;; Configuration

(defconst benedict-provider-vercel--base-url "https://ai-gateway.vercel.sh/v1"
  "The gateway's API root.")

(defconst benedict-provider-vercel--catalog-ttl 86400
  "Seconds a cached catalog is fresh before it is re-fetched.
24 hours; the catalog changes rarely and the fetch is blocking.")

(defconst benedict-provider-vercel--catalog-timeout 10
  "Seconds to wait for the gateway's model list before falling back.")

;;;; The fallback catalog

;; Known-good model ids with enough metadata to be usable when the network is
;; unavailable.  Pricing is omitted from the fallback; it is a convenience for
;; offline use, not a billing source.

(defconst benedict-provider-vercel--fallback-models
  (list
   (benedict-model-create
    :id "deepseek/deepseek-v4-flash-0731"
    :name "DeepSeek V4 Flash 0731"
    :provider 'vercel-ai-gateway
    :api 'openai-responses
    :context-window 1000000
    :max-tokens 384000
    :reasoning-p t
    :input-modalities '(text)
    :cost '(:input 0.13 :output 0.26 :cache-read 0.028))
   (benedict-model-create
    :id "openai/gpt-5"
    :name "GPT-5"
    :provider 'vercel-ai-gateway
    :api 'openai-responses
    :context-window 400000
    :max-tokens 128000
    :reasoning-p t
    :input-modalities '(text image)
    :cost '(:input 1.25 :output 10.0 :cache-read 0.125))
   (benedict-model-create
    :id "anthropic/claude-sonnet-4.5"
    :name "Claude Sonnet 4.5"
    :provider 'vercel-ai-gateway
    :api 'openai-responses
    :context-window 1000000
    :max-tokens 64000
    :reasoning-p t
    :input-modalities '(text image))
   (benedict-model-create
    :id "alibaba/qwen3-coder"
    :name "Qwen3 Coder 480B A35B Instruct"
    :provider 'vercel-ai-gateway
    :api 'openai-responses
    :context-window 262144
    :max-tokens 65536
    :input-modalities '(text)))
  "Models used when the catalog cannot be fetched or read.")

;;;; Cache

(defun benedict-provider-vercel--cache-file ()
  "Return the on-disk cache path for the gateway catalog.
Resolved through `xdg-cache-home' at call time, so XDG_CACHE_HOME can
change after Emacs starts."
  (expand-file-name "benedict/models/vercel-ai-gateway.eld"
                    (xdg-cache-home)))

(defun benedict-provider-vercel--read-cache ()
  "Return the cached catalog as a plist `(:fetched TIME :models ...)', or nil.

Returns nil when the file is absent, unreadable, older than the TTL, or
malformed — every one of those falls through to a fetch or the fallback."
  (let ((file (benedict-provider-vercel--cache-file)))
    (when (file-readable-p file)
      (condition-case nil
          (let* ((data (with-temp-buffer
                         (let ((coding-system-for-read 'utf-8-emacs-unix))
                           (insert-file-contents file))
                         (read (current-buffer))))
                 (fetched (plist-get data :fetched))
                 (models (plist-get data :models)))
            (and (numberp fetched)
                 (consp models)
                 (< (- (float-time) fetched)
                    benedict-provider-vercel--catalog-ttl)
                 data))
        (error nil)))))

(defun benedict-provider-vercel--write-cache (models)
  "Write MODELS to the cache file as a `read'-able s-expression."
  (let ((file (benedict-provider-vercel--cache-file)))
    (ignore-errors
      (make-directory (file-name-directory file) t))
    (condition-case nil
        (with-temp-buffer
          (let ((coding-system-for-write 'utf-8-emacs-unix)
                (print-length nil)
                (print-level nil)
                (print-circle t))
            (prin1 (list :fetched (float-time) :models models)
                   (current-buffer))
          (write-region (buffer-string) nil file nil 'silent)))
      (error nil))))

;;;; Fetching

(defun benedict-provider-vercel--fetch-catalog ()
  "Fetch and parse the gateway catalog, returning a list of models or nil."
  (let ((result (benedict-http-request-sync
                 (concat benedict-provider-vercel--base-url "/models")
                 :method "GET"
                 :timeout benedict-provider-vercel--catalog-timeout)))
    (if (plist-member result :error)
        nil
      (benedict-provider-vercel--parse-catalog
       (plist-get result :body)))))

;;;; The catalog function

(defun benedict-provider-vercel--catalog (&optional force)
  "Return the gateway model catalog, refreshing the cache when stale or FORCE.

The cache is consulted first; on a miss, a blocking fetch is attempted;
on failure, a stale cache is preferred over the hardcoded fallback, which
is the last resort.  This ordering is why a warm cache makes the system
work offline — `benedict-model-resolve' calls this, and it is the one
synchronous path in an otherwise async system."
  (or (and (not force)
           (plist-get (benedict-provider-vercel--read-cache) :models))
      (let ((models (benedict-provider-vercel--fetch-catalog)))
        (cond
         (models
          (benedict-provider-vercel--write-cache models)
          models)
         ((and (not force)
               (plist-get (benedict-provider-vercel--read-cache) :models)))
         (t benedict-provider-vercel--fallback-models)))))

;;;; Parsing the catalog

(defun benedict-provider-vercel--parse-catalog (body)
  "Parse the /v1/models response BODY into a list of `benedict-model' records.
Returns nil when BODY is missing or unparseable."
  (when (and body (stringp body))
    (let ((json (condition-case nil
                    (json-parse-string body
                                       :object-type 'plist
                                       :null-object nil
                                       :false-object nil)
                  (error nil))))
      (when json
        (delq nil
              (mapcar #'benedict-provider-vercel--parse-model
                      (append (plist-get json :data) nil)))))))

(defun benedict-provider-vercel--parse-model (entry)
  "Parse one catalog ENTRY into a `benedict-model', or nil to skip.

Non-`language' models (embeddings, rerankers) are filtered out: the
Responses API addresses language models, and resolving a model the API
cannot serve produces a confusing 404 rather than a useful conversation."
  (when (equal (plist-get entry :type) "language")
    (let ((tags (append (plist-get entry :tags) nil))
          (modalities (plist-get entry :modalities)))
      (benedict-model-create
       :id (plist-get entry :id)
       :name (plist-get entry :name)
       :provider 'vercel-ai-gateway
       :api 'openai-responses
       :context-window (plist-get entry :context_window)
       :max-tokens (plist-get entry :max_tokens)
       :reasoning-p (and (member "reasoning" tags) t)
       :input-modalities
       (mapcar #'intern (append (plist-get modalities :input) nil))
       :cost (benedict-provider-vercel--parse-cost
              (plist-get entry :pricing))))))

(defun benedict-provider-vercel--parse-cost (pricing)
  "Parse PRICING (per-token strings) into per-million rates.

The gateway reports rates as per-token strings like \"0.00000013\"; model
records carry per-million rates.  Multiplying by 1e6 at parse time means
nothing downstream has to know which unit it is holding.  Missing rates are
omitted rather than defaulted to zero — a missing `output' rate is not the
same claim as a free model.  See SPEC-001 7.6."
  (when pricing
    (let ((input (benedict-provider-vercel--per-million
                  (plist-get pricing :input)))
          (output (benedict-provider-vercel--per-million
                   (plist-get pricing :output)))
          (cache-read (benedict-provider-vercel--per-million
                       (plist-get pricing :input_cache_read)))
          (cache-write (benedict-provider-vercel--per-million
                        (plist-get pricing :input_cache_write))))
      (append (when input (list :input input))
              (when output (list :output output))
              (when cache-read (list :cache-read cache-read))
              (when cache-write (list :cache-write cache-write))))))

(defun benedict-provider-vercel--per-million (string)
  "Return STRING (a per-token rate) as a per-million number, or nil."
  (when (stringp string)
    (* (string-to-number string) 1000000)))

;;;; Registration

(benedict-defprovider vercel-ai-gateway
  :name "Vercel AI Gateway"
  :base-url benedict-provider-vercel--base-url
  :api 'openai-responses
  :auth (benedict-auth-env-api-key
         :name "Vercel AI Gateway API key"
         :env '("AI_GATEWAY_API_KEY"))
  :models #'benedict-provider-vercel--catalog)

(provide 'benedict-provider-vercel)

;;; benedict-provider-vercel.el ends here
