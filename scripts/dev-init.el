;;; dev-init.el --- Run Benedict out of its working tree  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The by-hand counterpart to `nix run .#test' and `nix run .#live': an Emacs
;; that loads the checkout directly, so the frontend can be driven with a
;; keyboard instead of an assertion.  `benedict-chat''s commentary records why
;; that matters -- a root re-render drops every component row while faithfully
;; re-emitting the content items, so the transcript still reads correctly and
;; no assertion about buffer TEXT notices.  That is exactly how the pre-reset
;; frontend held a green suite while being unusable by hand.  Looking at it is
;; the only test for it, and this is how you look at it.
;;
;; Usage:
;;
;;   emacs -Q -l scripts/dev-init.el -f benedict-demo    ; offline, spends nothing
;;   emacs -Q -l scripts/dev-init.el -f benedict         ; live, spends money
;;
;; `-Q' is deliberate.  The eval-elisp tool evaluates arbitrary forms in the
;; running image, so the agent can redefine anything the image has loaded.  A
;; throwaway image bounds that to this file; a personal configuration does not.
;;
;; Nothing is copied and nothing is compiled.  The two frontend dependencies
;; come from wherever they already are: vui from the Eask sandbox, which is
;; pinned to the v1.3.0 the Eask file requires, and markdown-mode from any
;; package directory the machine already has one in.

;;; Code:

(defvar benedict-dev-root
  (or (getenv "BENEDICT_ROOT")
      (when load-file-name
        (directory-file-name
         (file-name-directory (directory-file-name
                               (file-name-directory load-file-name)))))
      "~/github.com/scotttrinh/benedict")
  "The Benedict checkout to run.  Defaults to the one holding this file.")

(defun benedict-dev--add-load-path (directory)
  "Add DIRECTORY to `load-path' when it exists.  Return non-nil when added."
  (when (file-directory-p directory)
    (add-to-list 'load-path (expand-file-name directory))))

(defun benedict-dev--find-package (name)
  "Add the newest directory providing NAME.el to `load-path', or return nil.

Searches the Eask sandbox first, then Doom's straight builds, then anywhere
`package.el' has installed things.  The version components of those paths move
with the Emacs version, so they are globbed rather than spelled out."
  (let* ((roots (list (expand-file-name ".eask/*/elpa" benedict-dev-root)
                      "~/.config/emacs/.local/straight/build-*"
                      "~/.emacs.d/.local/straight/build-*"
                      (expand-file-name "elpa" user-emacs-directory)))
         (candidates
          (seq-filter (lambda (dir)
                        (file-exists-p (expand-file-name (format "%s.el" name)
                                                         dir)))
                      (mapcan (lambda (root)
                                (file-expand-wildcards
                                 (expand-file-name (format "%s*" name) root)))
                              roots))))
    ;; Newest mtime wins, which for a versioned ELPA directory is the newest
    ;; version.  Ties do not matter: any copy that satisfies the require does.
    (when-let* ((best (car (sort candidates
                                 (lambda (a b)
                                   (time-less-p
                                    (file-attribute-modification-time
                                     (file-attributes b))
                                    (file-attribute-modification-time
                                     (file-attributes a))))))))
      (benedict-dev--add-load-path best))))

(dolist (dir '("core" "support" "api" "providers" "ext" "ui"))
  (benedict-dev--add-load-path (expand-file-name dir benedict-dev-root)))

(dolist (package '("vui" "markdown-mode"))
  (unless (or (benedict-dev--find-package package)
              (locate-library package))
    (error "Cannot find %s.  Run `eask install-deps' in %s"
           package benedict-dev-root)))

(require 'benedict)
(require 'benedict-session)
(require 'benedict-core)                ; the reducer; required for its effect
(require 'benedict-api-stream)
(require 'benedict-api-openai-responses)
(require 'benedict-provider-vercel)     ; registers the gateway provider
(require 'benedict-provider-fake)       ; the offline provider `benedict-demo' uses
(require 'benedict-eval)                ; registers the eval-elisp tool
(require 'benedict-retry-http)
(require 'benedict-chat)

;; Subscribing is a command rather than a load-time side effect, so that
;; requiring a ui/ file to reach a face does not enrol the image in every
;; session it holds.  Here we do want the image enrolled.
(benedict-chat-install)
(benedict-retry-http-install)

(defvar benedict-dev-model "vercel-ai-gateway/deepseek/deepseek-v4-flash-0731"
  "Model for `benedict'.  The cheap reasoning-and-tool-use one live-smoke uses.

A \"PROVIDER-ID/MODEL-ID\" string resolved through `benedict-model-resolve'.
Others in the offline fallback catalog: \"openai/gpt-5\",
\"anthropic/claude-sonnet-4.5\", \"alibaba/qwen3-coder\", all under the
\"vercel-ai-gateway/\" prefix.")

(defvar benedict-dev-system-prompt
  "You are Benedict, an agent running inside a live Emacs image.  Your medium \
is Emacs Lisp: the eval-elisp tool evaluates a form in the running image, and \
anything you define takes effect immediately and is callable on your next turn."
  "System prompt for sessions started by `benedict'.")

(defun benedict ()
  "Open a chat buffer on a new session against `benedict-dev-model'.

Spends real money.  The credential is resolved by `benedict-auth-resolve'
from AI_GATEWAY_API_KEY or ~/.config/benedict/auth.json.

In the buffer, \\<benedict-chat-mode-map>
\\[benedict-chat-send] sends and \\[benedict-chat-abort] aborts,
\\[benedict-chat-next-sibling] and \\[benedict-chat-previous-sibling] walk
branch siblings, and \\[benedict-chat-revert] redraws from the transcript.
Sending during a run is not an error -- the kernel queues it as steering."
  (interactive)
  (let ((session (benedict-session-create
                  :model benedict-dev-model
                  :tools '(eval-elisp)
                  :system-prompt benedict-dev-system-prompt)))
    (benedict-eval-attach session :project-root (expand-file-name default-directory)
                         :target-buffer (current-buffer))
    (pop-to-buffer (benedict-chat-for-session session))))

(defun benedict-demo ()
  "Open a chat buffer on a scripted offline session.  Return the session.

Spends nothing and needs no credential.  Replays a two-turn conversation
through `benedict-provider-fake' -- reasoning, text, a tool call, its result,
then a closing turn -- which is every component row the frontend draws."
  (interactive)
  (let* ((script (benedict-provider-fake-script
                  '(((:thinking "The user wants arithmetic.  Use the tool."
                      :signature "sig")
                     (:text "Let me compute that.")
                     (:tool-call eval-elisp (:form "(+ 1 2)") :id "call_1"))
                    ((:text "The answer is **3**.")))))
         (model (benedict-provider-fake-model script :reasoning-p t))
         (session (benedict-session-create :model model
                                           :tools '(eval-elisp)
                                           :system-prompt "You are helpful.")))
    (benedict-eval-attach session :project-root (expand-file-name default-directory)
                         :target-buffer (current-buffer))
    (pop-to-buffer (benedict-chat-for-session session))
    (benedict-session-submit session "What is (+ 1 2)?")
    session))

(provide 'dev-init)

;;; dev-init.el ends here
