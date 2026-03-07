;;; benedict-message.el --- Canonical transcript entries for Benedict -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider-agnostic message structures and translation helpers used by the
;; runtime, persistence, and UI layers.

;;; Code:

(require 'cl-lib)

(cl-defstruct (benedict-message (:constructor benedict-message-create))
  "Canonical transcript entry for Benedict."
  id kind role blocks metadata timestamp)

(defun benedict-message--copy-blocks (blocks)
  "Return a shallow copy of BLOCKS."
  (mapcar (lambda (block)
            (if (listp block) (copy-tree block) block))
          blocks))

(defun benedict-message--text-block (text)
  "Create a text block for TEXT."
  (list :type 'text :text (or text "")))

(defun benedict-message--thinking-block (thinking)
  "Create a thinking block for THINKING."
  (list :type 'thinking :content thinking))

(defun benedict-message--tool-call-block (tool-call)
  "Create a tool-call block from TOOL-CALL."
  (list :type 'tool-call
        :id (plist-get tool-call :id)
        :name (or (plist-get tool-call :name)
                  (plist-get tool-call :tool))
        :arguments (plist-get tool-call :arguments)))

(defun benedict-message--tool-result-block (tool-call-id name status content &optional details)
  "Create a tool-result block."
  (list :type 'tool-result
        :tool-call-id tool-call-id
        :name name
        :status status
        :content content
        :details details))

(defun benedict-message-user-text (text &optional metadata)
  "Create a canonical user text message for TEXT and METADATA."
  (benedict-message-create
   :kind 'message
   :role 'user
   :blocks (list (benedict-message--text-block text))
   :metadata metadata))

(defun benedict-message-assistant-text (text &optional metadata)
  "Create a canonical assistant text message for TEXT and METADATA."
  (benedict-message-create
   :kind 'message
   :role 'assistant
   :blocks (list (benedict-message--text-block text))
   :metadata metadata))

(defun benedict-message-tool-result (tool-call-id name status content &optional details)
  "Create a canonical tool result message."
  (benedict-message-create
   :kind 'message
   :role 'tool
   :blocks (list (benedict-message--tool-result-block tool-call-id name status content details))
   :metadata (list :status status :details details)))

(defun benedict-message-from-legacy (message)
  "Normalize legacy plist MESSAGE into a `benedict-message'."
  (if (benedict-message-p message)
      (benedict-message-create
       :id (benedict-message-id message)
       :kind (benedict-message-kind message)
       :role (benedict-message-role message)
       :blocks (benedict-message--copy-blocks (benedict-message-blocks message))
       :metadata (copy-tree (benedict-message-metadata message))
       :timestamp (benedict-message-timestamp message))
    (let* ((role (plist-get message :role))
           (kind (or (plist-get message :kind) 'message))
           (content (plist-get message :content))
           (thinking (plist-get message :thinking))
           (tool-calls (let ((value (plist-get message :tool-calls)))
                         (cond
                          ((vectorp value) (append value nil))
                          ((listp value) value)
                          (t nil))))
           (tool-call-id (plist-get message :tool-call-id))
           (name (plist-get message :name))
           (metadata (copy-tree (plist-get message :metadata)))
           (blocks nil))
      (when (or content (memq role '(assistant user system tool)))
        (push (benedict-message--text-block content) blocks))
      (when thinking
        (push (benedict-message--thinking-block thinking) blocks))
      (dolist (tool-call tool-calls)
        (push (benedict-message--tool-call-block tool-call) blocks))
      (when (eq role 'tool)
        (push (benedict-message--tool-result-block
               tool-call-id
               name
               (or (plist-get metadata :status) 'success)
               content
               (plist-get metadata :error))
              blocks))
      (benedict-message-create
       :id (plist-get message :id)
       :kind kind
       :role role
       :blocks (nreverse blocks)
       :metadata metadata
       :timestamp (plist-get message :timestamp)))))

(defun benedict-message--block-of-type (message type)
  "Return the first block of TYPE in MESSAGE."
  (cl-find type (benedict-message-blocks message)
           :key (lambda (block) (plist-get block :type))))

(defun benedict-message-text (message)
  "Return MESSAGE text content, or nil."
  (when-let ((block (benedict-message--block-of-type message 'text)))
    (plist-get block :text)))

(defun benedict-message-thinking (message)
  "Return MESSAGE thinking content, or nil."
  (when-let ((block (benedict-message--block-of-type message 'thinking)))
    (plist-get block :content)))

(defun benedict-message-tool-calls (message)
  "Return MESSAGE tool-call blocks as provider-style plists."
  (let (tool-calls)
    (dolist (block (benedict-message-blocks message))
      (when (eq (plist-get block :type) 'tool-call)
        (push (list :id (plist-get block :id)
                    :name (plist-get block :name)
                    :arguments (plist-get block :arguments))
              tool-calls)))
    (nreverse tool-calls)))

(defun benedict-message--tool-result-block-data (message)
  "Return the tool-result block from MESSAGE, or nil."
  (benedict-message--block-of-type message 'tool-result))

(defun benedict-message-to-legacy (message)
  "Convert canonical MESSAGE to the legacy plist shape."
  (let* ((role (benedict-message-role message))
         (tool-result (and (eq role 'tool)
                           (benedict-message--tool-result-block-data message)))
         (metadata (copy-tree (benedict-message-metadata message)))
         (legacy (list :id (benedict-message-id message)
                       :kind (benedict-message-kind message)
                       :role role
                       :content (benedict-message-text message)
                       :thinking (benedict-message-thinking message)
                       :tool-calls (benedict-message-tool-calls message)
                       :timestamp (benedict-message-timestamp message)
                       :metadata metadata)))
    (when tool-result
      (setq legacy (plist-put legacy :tool-call-id (plist-get tool-result :tool-call-id)))
      (setq legacy (plist-put legacy :name (plist-get tool-result :name)))
      (setq legacy (plist-put legacy :content (plist-get tool-result :content)))
      (setq legacy (plist-put legacy :metadata
                              (append metadata
                                      (list :status (plist-get tool-result :status)
                                            :error (plist-get tool-result :details))))))
    legacy))

(defun benedict-message-legacy-get (message key)
  "Read KEY from MESSAGE via the legacy plist contract."
  (plist-get (benedict-message-to-legacy message) key))

(defun benedict-message-merge-legacy (message updates)
  "Apply legacy plist UPDATES to canonical MESSAGE."
  (let* ((legacy (benedict-message-to-legacy message))
         (merged (copy-sequence legacy)))
    (cl-loop for (key value) on updates by #'cddr
             do (setq merged (plist-put merged key value)))
    (benedict-message-from-legacy merged)))

(defun benedict-message->provider-message (message provider-id)
  "Convert canonical MESSAGE to a provider request message for PROVIDER-ID."
  (ignore provider-id)
  (let* ((role (benedict-message-role message))
         (payload (list :role role
                        :content (or (benedict-message-text message) "")))
         (tool-calls (benedict-message-tool-calls message))
         (tool-result (and (eq role 'tool)
                           (benedict-message--tool-result-block-data message))))
    (when tool-calls
      (setq payload (plist-put payload :tool-calls tool-calls)))
    (when tool-result
      (setq payload (plist-put payload :tool-call-id (plist-get tool-result :tool-call-id)))
      (setq payload (plist-put payload :name (plist-get tool-result :name))))
    payload))

(provide 'benedict-message)
;;; benedict-message.el ends here
