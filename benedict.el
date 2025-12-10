;;; benedict.el --- Emacs-first AI assistant  -*- lexical-binding: t; -*-
;; Author: Benedict maintainers
;; Version: 0.1.0pre
;; Package-Requires: ((emacs "27.1") (lgr "0.3") (dash "2.26.0") (s "1.12.0") (markdown-mode "2.5"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;;; Commentary:
;; Core package entry.  Defines customization groups, faces, errors, and
;; lightweight scaffolding used by early phases.  User entry points live in
;; benedict-chat.el and minor mode commands in this file.

;;; Code:

(eval-when-compile (require 'cl-lib))

;; Customization
(defgroup benedict nil
  "Emacs-native agents: chat, tools, approvals."
  :group 'applications
  :prefix "benedict-")

(defcustom benedict-keymap-prefix (kbd "C-c C-b")
  "Prefix key for Benedict commands when `benedict-mode' is active."
  :type 'key-sequence
  :group 'benedict)

(defcustom benedict-provider 'openrouter
  "Symbol identifying the provider to use for chat interactions."
  :type 'symbol
  :group 'benedict)

(require 'benedict-logging)
(require 'benedict-provider)

;; Faces (initial, minimal)
(defface benedict-chat-user
  '((t :inherit default :weight bold))
  "Face for user messages in chat buffers.")

(defface benedict-chat-assistant
  '((t :inherit font-lock-doc-face))
  "Face for assistant messages in chat buffers.")

(defface benedict-chat-system
  '((t :inherit shadow))
  "Face for system messages in chat buffers.")

(defface benedict-chat-error
  '((t :inherit error :weight bold))
  "Face for error responses in chat buffers.")

(defface benedict-chat-block-divider
  '((t :inherit shadow))
  "Face for divider lines separating chat blocks.")

(defface benedict-chat-body
  '((t :inherit variable-pitch))
  "Face for prose content in chat messages.")

(defface benedict-chat-heading-1
  '((t :inherit (org-level-1 variable-pitch) :weight bold))
  "Face for top-level markdown headings in chat messages.")

(defface benedict-chat-heading-2
  '((t :inherit (org-level-2 variable-pitch) :weight bold))
  "Face for second-level markdown headings in chat messages.")

(defface benedict-chat-heading-3
  '((t :inherit (org-level-3 variable-pitch) :weight bold))
  "Face for third-level markdown headings in chat messages.")

(defface benedict-chat-list-bullet
  '((t :inherit (org-list-dt variable-pitch)))
  "Face for list bullets and markers in chat messages.")

(defface benedict-chat-inline-code
  '((t :inherit (fixed-pitch org-code)))
  "Face for inline code spans in chat messages.")

(defface benedict-chat-strong
  '((t :inherit (org-bold bold)))
  "Face for bold emphasis in chat messages.")

(defface benedict-chat-emphasis
  '((t :inherit (org-italic italic)))
  "Face for italic emphasis in chat messages.")

(defface benedict-chat-link
  '((t :inherit (org-link link) :weight semibold))
  "Face for links in chat messages.")

(defface benedict-chat-code-block
  '((((class color) (min-colors 88) (background light))
    :inherit fixed-pitch
    :background "#f6f8fa"
    :extend t)
  (((class color) (min-colors 88) (background dark))
    :inherit fixed-pitch
    :background "#161b22"
    :extend t)
  (t :inherit fixed-pitch))
  "Face for content inside fenced code blocks.")

(defface benedict-chat-button
  '((t :inherit link :weight semi-bold))
  "Face for inline chat action buttons.")

(defface benedict-chat-thinking
  '((t :inherit italic))
  "Face for thinking blocks in chat buffers.")

;; Error hierarchy
(define-error 'benedict-error "Benedict error")
(define-error 'benedict-provider-error "Benedict provider error" 'benedict-error)

;; Minor mode
(defvar benedict-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'benedict-chat)
    map)
  "Prefix map for Benedict commands.")

(defvar benedict-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m benedict-keymap-prefix benedict-prefix-map)
    m)
  "Keymap for `benedict-mode'.")

;;;###autoload
(define-minor-mode benedict-mode
  "Minor mode providing Benedict commands under `benedict-keymap-prefix'."
  :lighter " Benedict"
  :keymap benedict-mode-map)

;; Autoload interactive entry points to avoid load-order issues
(autoload 'benedict-chat "benedict-chat" "Open Benedict chat buffer." t)

(require 'benedict-provider-openrouter)
(require 'benedict-provider-vercel)
(require 'benedict-provider-fake)
(require 'benedict-provider-ollama)

(provide 'benedict)
;;; benedict.el ends here
