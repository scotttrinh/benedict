;;; benedict-chat.el --- Chat buffers and commands -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Minimal chat buffer that supports a simple echo-based send command for Phase 1.

;;; Code:

(require 'benedict)

(defvar-local benedict-chat--messages nil
  "List of messages in the current chat buffer.
Each entry is a plist like (:role SYMBOL :text STRING :time TIME).")

(defvar benedict-chat-buffer-name "*Benedict Chat*"
  "Default chat buffer name.")

(defun benedict-chat--insert (role text)
  "Insert TEXT for ROLE at point with appropriate face."
  (let* ((face (pcase role
                 ('user 'benedict-chat-user)
                 ('assistant 'benedict-chat-assistant)
                 (_ 'benedict-chat-system)))
         (prefix (capitalize (symbol-name role))))
    (goto-char (point-max))
    (insert (propertize (format "%s: " prefix) 'face face))
    (insert text)
    (insert "\n")))

(defun benedict-chat-send-prompt (text)
  "Send TEXT to the chat and insert an echo response.
This is a placeholder for Phase 1 while providers are stubbed."
  (interactive (list (read-string "Prompt: ")))
  (push (list :role 'user :text text :time (current-time)) benedict-chat--messages)
  (benedict-chat--insert 'user text)
  ;; Echo provider behavior (local, no network)
  (let ((resp (format "Echo: %s" text)))
    (push (list :role 'assistant :text resp :time (current-time)) benedict-chat--messages)
    (benedict-chat--insert 'assistant resp)))

(defvar benedict-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-s") #'benedict-chat-send-prompt)
    m)
  "Keymap for `benedict-chat-mode'.")

(define-derived-mode benedict-chat-mode special-mode "Benedict-Chat"
  "Major mode for Benedict chat buffers."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines t)
  (setq-local benedict-chat--messages nil)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Benedict Chat (Phase 1 echo placeholder)\n\n" 'face 'benedict-chat-system))))

;;;###autoload
(defun benedict-chat ()
  "Open or switch to the Benedict chat buffer."
  (interactive)
  (let ((buf (get-buffer-create benedict-chat-buffer-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'benedict-chat-mode)
      (benedict-chat-mode)))
  (message "Type C-c C-s to send a prompt."))

(provide 'benedict-chat)
;;; benedict-chat.el ends here
