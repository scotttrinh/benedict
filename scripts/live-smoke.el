;;; live-smoke.el --- Live provider smoke test for `nix run .#live'  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The SPEC-001 14 exit criterion: a real multi-turn conversation with tool
;; use against a cheap gateway model, run end to end through the kernel, the
;; auth layer, the transport, and the Responses adapter.
;;
;; This is deliberately NOT a test.  It spends real money, needs a real
;; credential, and runs against a live service.  `nix run .#test' is offline
;; and credential-free and stays that way (SPEC-001 12.5, D21).  This script
;; is what proves the whole stack works after the fixture-backed suites have
;; run — the fixtures keep it working without spending tokens, and this run
;; keeps the fixtures honest.
;;
;; Usage:
;;
;;   nix run .#live
;;   nix run .#live -- vercel-ai-gateway/openai/gpt-5
;;
;; The credential is read from the environment or from
;; `~/.config/benedict/auth.json' by `benedict-auth-resolve'.

;;; Code:

(require 'cl-lib)
(require 'benedict)
(require 'benedict-session)
(require 'benedict-core)
(require 'benedict-provider)
(require 'benedict-provider-vercel)
(require 'benedict-eval)
(require 'benedict-retry-http)

;;;; The smoke test
(require 'benedict-api-stream)
(require 'benedict-api-openai-responses)

(benedict-retry-http-install)

(defconst benedict-live-smoke--model "vercel-ai-gateway/deepseek/deepseek-v4-flash-0731"
  "The default model for the smoke test.  Cheap, reasoning-capable, tool-using.")

(defconst benedict-live-smoke--prompt
  "Use the eval-elisp tool to compute (+ 1 2). Then tell me the answer."
  "The prompt that forces a tool call followed by a text response.")

(defconst benedict-live-smoke--max-wait 120
  "Maximum seconds to wait for the conversation to reach idle.")

(defun benedict-live-smoke ()
  "Run a live two-turn tool-use conversation against Vercel AI Gateway.

Registers `eval-elisp', submits a prompt that forces a tool call, drives
the session to completion, and prints the transcript.  Exits non-zero when
the conversation did not produce the expected shape: at least one tool
call, a matching result, and a second turn that references it."
  (let ((model-spec (or (car command-line-args-left)
                        benedict-live-smoke--model))
        (started (float-time)))
    (message "Live smoke: model %s" model-spec)
    (let ((session (benedict-session-create
                    :model model-spec
                    :tools '(eval-elisp)
                    :system-prompt "You are a helpful assistant.")))
      (benedict-session-submit session benedict-live-smoke--prompt)
      (benedict-live-smoke--drain session started)
      (benedict-live-smoke--report session))))

(defun benedict-live-smoke--drain (session started)
  "Process events until SESSION is finally idle or STARTED reaches timeout."
  (while (and (or (not (eq (benedict-session-state session) 'idle))
                  (benedict-retry-pending-p session))
              (< (- (float-time) started) benedict-live-smoke--max-wait))
    (sit-for 0.1))
  (unless (and (eq (benedict-session-state session) 'idle)
               (not (benedict-retry-pending-p session)))
    (message "Live smoke: timed out in state %s%s after %.0fs"
             (benedict-session-state session)
             (if (benedict-retry-pending-p session) " with retry pending" "")
             (- (float-time) started))
    (kill-emacs 1)))

(defun benedict-live-smoke--report (session)
  "Print SESSION's transcript and verify the expected conversation shape."
  (let ((entries (benedict-session-path session)))
    (message "")
    (message "=== Transcript (%d entries) ===" (length entries))
    (dolist (entry entries)
      (let ((role (benedict-entry-role entry))
            (text (benedict-entry-text entry))
            (stop (benedict-entry-meta-get entry :stop-reason))
            (errmsg (benedict-entry-meta-get entry :error-message))
            (blocks (benedict-entry-content entry)))
        (cond
         ((benedict-entry-tool-result-p entry)
          (message "  [tool-result] %s" (or text "(structured)")))
         ((benedict-entry-assistant-p entry)
          (let ((calls (benedict-entry-tool-calls entry)))
            (message "  [assistant] %s%s  [blocks: %d, stop: %s%s]"
                     (or text "(no text)")
                     (if calls
                         (format "  [tools: %d]" (length calls))
                       "")
                     (length blocks)
                     stop
                     (if errmsg (format ", error: %s" errmsg) ""))))
         (t
          (message "  [%s] %s" role (or text "(empty)"))))))
    (message "")
    (benedict-live-smoke--verify entries)
    (message "Live smoke: PASS")))

(defun benedict-live-smoke--verify (entries)
  "Assert ENTRIES have the expected shape for a two-turn tool-use conversation."
  (let ((assistant-entries (seq-filter #'benedict-entry-assistant-p entries))
        (result-entries (seq-filter #'benedict-entry-tool-result-p entries))
        (errors nil))
    (unless (>= (length assistant-entries) 2)
      (push (format "expected >=2 assistant entries, got %d"
                    (length assistant-entries))
            errors))
    (unless (seq-some #'benedict-entry-tool-calls assistant-entries)
      (push "no tool call found in any assistant entry" errors))
    (unless (>= (length result-entries) 1)
      (push (format "expected >=1 tool-result entry, got %d"
                    (length result-entries))
            errors))
    (when errors
      (message "Live smoke: FAIL")
      (dolist (e (nreverse errors))
        (message "  - %s" e))
      (kill-emacs 1))))

(provide 'live-smoke)

;;; live-smoke.el ends here
