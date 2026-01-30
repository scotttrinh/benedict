;;; benedict-vui-turn.el --- Vui turn component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a full chat turn (header + content blocks).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict-vui-content-block-list)
(require 'benedict-vui-turn-header)

(defun benedict-vui-turn--normalize-role (role)
  "Normalize ROLE into a symbol."
  (cond
   ((symbolp role) role)
   ((stringp role) (intern (downcase role)))
   (t 'assistant)))

(defun benedict-vui-turn--normalize-type (value)
  "Return VALUE normalized as a lowercase symbol or nil."
  (cond
   ((keywordp value) (intern (substring (symbol-name value) 1)))
   ((symbolp value) value)
   ((stringp value)
    (let ((trimmed (string-trim value)))
      (unless (string-empty-p trimmed)
        (intern (downcase trimmed)))))
   (t nil)))

(defun benedict-vui-turn--message-role (message props)
  "Return the role for MESSAGE or PROPS."
  (benedict-vui-turn--normalize-role
   (or (plist-get props :role)
       (and message (plist-get message :role)))))

(defun benedict-vui-turn--message-timestamp (message props)
  "Return the timestamp for MESSAGE or PROPS."
  (or (plist-get props :timestamp)
      (and message (or (plist-get message :timestamp)
                       (plist-get message :time)))))

(defun benedict-vui-turn--message-metadata (message props)
  "Return metadata for MESSAGE or PROPS."
  (or (plist-get props :metadata)
      (and message (plist-get message :metadata))))

(defun benedict-vui-turn--message-key (message props)
  "Return a navigation key for MESSAGE or PROPS."
  (or (plist-get props :message-key)
      (and message (or (plist-get message :id)
                       (plist-get message :message-id)
                       (plist-get message :turn-id)
                       (plist-get message :uuid)
                       (plist-get message :nav-index)))))

(defun benedict-vui-turn--face-for-role (role metadata)
  "Return a face for ROLE given METADATA."
  (cond
   ((and metadata (plist-get metadata :error)) 'benedict-chat-error)
   ((eq role 'user) 'benedict-chat-user)
   ((eq role 'assistant) 'benedict-chat-assistant)
   (t 'benedict-chat-system)))

(defun benedict-vui-turn--apply-face (value face)
  "Return VALUE with FACE applied when VALUE is a string."
  (if (and (stringp value) face)
      (let ((text (copy-sequence value)))
        (add-face-text-property 0 (length text) face t text)
        text)
    value))

(defun benedict-vui-turn--block-type (block)
  "Return normalized type for BLOCK plist."
  (benedict-vui-turn--normalize-type
   (or (plist-get block :type)
       (plist-get block :kind)
       (plist-get block :block-type)
       (plist-get block :role))))

(defun benedict-vui-turn--text-block-p (block)
  "Return non-nil when BLOCK should receive role text styling."
  (let ((type (benedict-vui-turn--block-type block)))
    (and (not (plist-member block :tool-call))
         (not (plist-member block :result))
         (not (plist-member block :thinking-data))
         (not (plist-member block :thinking))
         (not (plist-member block :code))
         (or (null type)
             (eq type 'text)
             (eq type 'assistant)
             (eq type 'user)
             (eq type 'system)))))

(defun benedict-vui-turn--block-content (block)
  "Return displayable content for BLOCK."
  (or (plist-get block :content)
      (plist-get block :text)
      (plist-get block :body)))

(defun benedict-vui-turn--apply-face-to-block (block face)
  "Return BLOCK with FACE applied to text content when appropriate."
  (cond
   ((stringp block) (benedict-vui-turn--apply-face block face))
   ((and (listp block) (benedict-vui-turn--text-block-p block))
    (let* ((copy (copy-sequence block))
           (content (benedict-vui-turn--block-content copy)))
      (when content
        (plist-put copy :content
                   (benedict-vui-turn--apply-face content face)))
      copy))
   (t block)))

(defun benedict-vui-turn--normalize-content-blocks (content)
  "Return CONTENT coerced into a list of block plists."
  (cond
   ((null content) nil)
   ((stringp content) (list (list :type 'text :content content)))
   ((vectorp content) (append content nil))
   ((listp content) content)
   (t (list (list :type 'text :content (format "%s" content))))))

(defun benedict-vui-turn--tool-result-block (message)
  "Return a tool result block list for MESSAGE."
  (let ((status (plist-get (plist-get message :metadata) :status)))
    (list (list :type 'tool-result :result message :status status))))

(defun benedict-vui-turn--build-blocks (message role)
  "Return block list for MESSAGE given ROLE."
  (cond
   ((null message) nil)
   ((plist-member message :blocks) (plist-get message :blocks))
   ((eq role 'tool) (benedict-vui-turn--tool-result-block message))
   (t
    (let* ((content (or (plist-get message :display-content)
                        (plist-get message :content)))
           (blocks (benedict-vui-turn--normalize-content-blocks content))
           (thinking (plist-get message :thinking))
           (tool-calls (plist-get message :tool-calls)))
      (when thinking
        (setq blocks (append blocks (list (list :type 'thinking
                                                :thinking-data thinking)))))
      (when tool-calls
        (setq blocks (append blocks
                             (mapcar (lambda (call)
                                       (list :type 'tool-use :tool-call call))
                                     tool-calls))))
      blocks))))

(defun benedict-vui-turn--blocks (props)
  "Return content blocks for PROPS."
  (let* ((message (plist-get props :message))
         (role (benedict-vui-turn--message-role message props))
         (metadata (benedict-vui-turn--message-metadata message props))
         (face (benedict-vui-turn--face-for-role role metadata))
         (blocks (or (plist-get props :blocks)
                     (benedict-vui-turn--build-blocks message role))))
    (mapcar (lambda (block)
              (benedict-vui-turn--apply-face-to-block block face))
            blocks)))

(defun benedict-vui-turn--render (props)
  "Render a full turn from PROPS."
  (let* ((message (plist-get props :message))
          (role (benedict-vui-turn--message-role message props))
          (timestamp (benedict-vui-turn--message-timestamp message props))
          (metadata (benedict-vui-turn--message-metadata message props))
          (message-key (benedict-vui-turn--message-key message props))
          (blocks (benedict-vui-turn--blocks props))
          (collapsed-blocks (plist-get props :collapsed-blocks))
          (on-toggle-block (plist-get props :on-toggle-block))
          (header (vui-component 'benedict-vui-turn-header :role role
                                            :timestamp timestamp
                                            :metadata metadata))
          (content (vui-component 'benedict-vui-content-block-list
                    :blocks blocks
                    :collapsed-blocks collapsed-blocks
                    :message-key message-key
                    :on-toggle-block on-toggle-block)))
    (vui-vstack header content)))

(vui-defcomponent benedict-vui-turn (props)
  :render
  (benedict-vui-turn--render props))

(defun benedict-vui-turn (&rest props)
  "Create a turn component node from PROPS."
  (apply #'vui-component 'benedict-vui-turn props))

(provide 'benedict-vui-turn)
;;; benedict-vui-turn.el ends here
