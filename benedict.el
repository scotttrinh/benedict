;;; benedict.el --- Emacs-first AI assistant  -*- lexical-binding: t; -*-
;; Author: Benedict maintainers
;; Version: 0.1.0pre
;; Package-Requires: ((emacs "27.1") (lgr "0.3") (dash "2.26.0") (s "1.12.0") (markdown-mode "2.5") (svg-lib "0.2.8") (vui "0.1.0"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;;; Commentary:
;; Core package entry.  Defines customization groups, faces, errors, and
;; lightweight scaffolding used by early phases.  User entry points live in
;; benedict-chat.el and minor mode commands in this file.

;;; Code:

(eval-when-compile (require 'cl-lib))

(defconst benedict--components-directory
  (expand-file-name "components"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory that stores Benedict Vui components.")

(when (file-directory-p benedict--components-directory)
  (add-to-list 'load-path benedict--components-directory))

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
(require 'benedict-errors)

;; Faces
(defgroup benedict-chat nil
  "Chat buffers and rendering for Benedict."
  :group 'benedict
  :prefix "benedict-chat-")

(defface benedict-chat-role
  '((t :inherit (font-lock-keyword-face bold)))
  "Face for role labels like \"[USER]\" in chat headers."
  :group 'benedict-chat)

(defface benedict-chat-header
  '((t :inherit default :weight semi-bold))
  "Face for message headers."
  :group 'benedict-chat)

(defface benedict-chat-header-separator
  '((t :inherit shadow))
  "Face for separators (e.g. \"·\") in message headers."
  :group 'benedict-chat)

(defface benedict-chat-header-error
  '((t :inherit error))
  "Face for error markers shown in message headers."
  :group 'benedict-chat)

(defface benedict-chat-header-provider
  '((t :inherit (benedict-chat-header font-lock-keyword-face)))
  "Face for provider labels in message headers."
  :group 'benedict-chat)

(defface benedict-chat-header-model
  '((t :inherit (benedict-chat-header font-lock-type-face)))
  "Face for model labels in message headers."
  :group 'benedict-chat)

(defface benedict-chat-header-time
  '((t :inherit (benedict-chat-header font-lock-constant-face)))
  "Face for timing/latency labels in message headers."
  :group 'benedict-chat)

(defface benedict-chat-header-usage
  '((t :inherit (benedict-chat-header font-lock-function-name-face)))
  "Face for usage/cost labels in message headers."
  :group 'benedict-chat)

(defface benedict-chat-user
  '((t :inherit (font-lock-keyword-face bold)))
  "Face for user role labels in chat buffers.")

(defface benedict-chat-assistant
  '((t :inherit font-lock-doc-face))
  "Face for assistant role labels in chat buffers.")

(defface benedict-chat-system
  '((t :inherit shadow))
  "Face for system role labels in chat buffers.")

(defface benedict-chat-error
  '((t :inherit (error bold)))
  "Face for error responses in chat buffers.")

(defface benedict-chat-block-divider
  '((t :inherit shadow))
  "Face for divider lines separating chat blocks.")

(defface benedict-chat-button
  '((t :inherit button :weight semi-bold))
  "Face for inline chat action buttons.")

(defface benedict-chat-thinking
  '((t :inherit (shadow italic)))
  "Face for thinking blocks in chat buffers.")

(defface benedict-chat-tool-label
  '((t :inherit (benedict-chat-header font-lock-function-name-face)))
  "Face for tool call names/labels in tool headers."
  :group 'benedict-chat)

(defface benedict-chat-tool-indicator
  '((t :inherit shadow))
  "Face for fold indicators and icons in tool headers."
  :group 'benedict-chat)

(defface benedict-chat-tool-success
  '((t :inherit success))
  "Face for successful tool call status indicators."
  :group 'benedict-chat)

(defface benedict-chat-tool-error
  '((t :inherit error))
  "Face for failed tool call status indicators."
  :group 'benedict-chat)

(defface benedict-chat-tool-running
  '((t :inherit warning))
  "Face for running tool call status indicators."
  :group 'benedict-chat)

;; Minor mode
(defvar benedict-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'benedict-chat)
    (define-key map (kbd "l") #'benedict-chat-jump-to-latest)
    (define-key map (kbd "a") #'benedict-chat-jump-to-last-assistant)
    (define-key map (kbd "A") #'benedict-chat-jump-to-last-assistant-with-tools)
    (define-key map (kbd "t") #'benedict-chat-next-tool)
    (define-key map (kbd "T") #'benedict-chat-previous-tool)
    (define-key map (kbd "f") #'benedict-chat-next-tool-failure)
    (define-key map (kbd "F") #'benedict-chat-previous-tool-failure)
    (define-key map (kbd "e") #'benedict-chat-next-error)
    (define-key map (kbd "E") #'benedict-chat-previous-error)
    (define-key map (kbd "h") #'benedict-chat-next-thinking)
    (define-key map (kbd "H") #'benedict-chat-previous-thinking)
    (define-key map (kbd "s") #'benedict-chat-toggle-thinking)
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
(autoload 'benedict-chat-jump-to-latest "benedict-chat" "Jump to the newest Benedict chat item." t)
(autoload 'benedict-chat-jump-to-last-assistant "benedict-chat" "Jump to the most recent Benedict assistant message." t)
(autoload 'benedict-chat-jump-to-last-assistant-with-tools "benedict-chat" "Jump to the most recent assistant message that has tool blocks." t)
(autoload 'benedict-chat-next-tool "benedict-chat" "Move to the next Benedict tool block." t)
(autoload 'benedict-chat-previous-tool "benedict-chat" "Move to the previous Benedict tool block." t)
(autoload 'benedict-chat-next-tool-failure "benedict-chat" "Move to the next failed Benedict tool block." t)
(autoload 'benedict-chat-previous-tool-failure "benedict-chat" "Move to the previous failed Benedict tool block." t)
(autoload 'benedict-chat-next-error "benedict-chat" "Move to the next Benedict error block." t)
(autoload 'benedict-chat-previous-error "benedict-chat" "Move to the previous Benedict error block." t)
(autoload 'benedict-chat-next-thinking "benedict-chat" "Move to the next Benedict thinking block." t)
(autoload 'benedict-chat-previous-thinking "benedict-chat" "Move to the previous Benedict thinking block." t)
(autoload 'benedict-chat-toggle-thinking "benedict-chat" "Toggle Benedict thinking blocks at point." t)

(require 'benedict-provider-openrouter)
(require 'benedict-provider-vercel)
(require 'benedict-provider-gemini)
(require 'benedict-provider-fake)
(require 'benedict-provider-ollama)

(with-eval-after-load 'benedict-session
  (require 'benedict-store)
  (with-eval-after-load 'benedict-tools
    (setq benedict-session-tool-invoke-fn #'benedict-tool-invoke)))

(provide 'benedict)
;;; benedict.el ends here
