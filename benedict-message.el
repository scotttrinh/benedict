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
        :arguments (plist-get tool-call :arguments)
        :status (plist-get tool-call :status)))

(defun benedict-message--tool-result-block (tool-call-id name status content &optional details)
  "Create a tool-result block for TOOL-CALL-ID, NAME, STATUS, CONTENT, and DETAILS."
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
  "Create a canonical tool result message for TOOL-CALL-ID, NAME, STATUS, CONTENT, and DETAILS."
  (benedict-message-create
   :kind 'message
   :role 'tool
   :blocks (list (benedict-message--tool-result-block tool-call-id name status content details))
   :metadata (list :status status :details details)))

(defun benedict-message-from-data (message)
  "Normalize MESSAGE data into a `benedict-message'."
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
                    :arguments (plist-get block :arguments)
                    :status (plist-get block :status))
              tool-calls)))
    (nreverse tool-calls)))

(defun benedict-message--tool-result-block-data (message)
  "Return the tool-result block from MESSAGE, or nil."
  (benedict-message--block-of-type message 'tool-result))

(defun benedict-message-metadata-value (message key)
  "Return metadata value for KEY from MESSAGE."
  (plist-get (benedict-message-metadata message) key))

(defun benedict-message-status (message)
  "Return canonical status metadata for MESSAGE."
  (benedict-message-metadata-value message :status))

(defun benedict-message-tool-result-name (message)
  "Return tool result name from MESSAGE, or nil."
  (when-let ((block (benedict-message--tool-result-block-data message)))
    (plist-get block :name)))

(defun benedict-message-tool-result-id (message)
  "Return tool call identifier from MESSAGE, or nil."
  (when-let ((block (benedict-message--tool-result-block-data message)))
    (plist-get block :tool-call-id)))

(defun benedict-message-tool-result-details (message)
  "Return tool result details from MESSAGE, or nil."
  (when-let ((block (benedict-message--tool-result-block-data message)))
    (plist-get block :details)))

(defun benedict-message-blocks-for-display (message)
  "Return display blocks for canonical MESSAGE."
  (let ((role (benedict-message-role message))
        (tool-call-statuses (plist-get (benedict-message-metadata message)
                                       :tool-call-statuses))
        (blocks nil))
    (dolist (block (benedict-message-blocks message))
      (pcase (plist-get block :type)
        ('text
         (push (list :type 'text :content (plist-get block :text)) blocks))
        ('thinking
         (push (list :type 'thinking :thinking-data (plist-get block :content)) blocks))
        ('tool-call
         (push (list :type 'tool-use
                     :tool-call (list :id (plist-get block :id)
                                      :name (plist-get block :name)
                                      :arguments (plist-get block :arguments))
                     :status (or (cdr (assoc (plist-get block :id) tool-call-statuses))
                                 (plist-get block :status)))
               blocks))
        ('tool-result
         (push (list :type 'tool-result
                     :result (list :tool-call-id (plist-get block :tool-call-id)
                                   :name (plist-get block :name)
                                   :status (plist-get block :status)
                                   :content (plist-get block :content)
                                   :error (plist-get block :details))
                     :status (plist-get block :status))
               blocks))))
    (if (and (eq role 'tool) blocks)
        (nreverse (cl-remove-if-not
                   (lambda (block) (eq (plist-get block :type) 'tool-result))
                   blocks))
      (nreverse blocks))))

(defun benedict-message->provider-message (message provider-id)
  "Convert canonical MESSAGE to a provider request message for PROVIDER-ID."
  (ignore provider-id)
  (let* ((role (benedict-message-role message))
         (tool-result (and (eq role 'tool)
                           (benedict-message--tool-result-block-data message)))
         (content (or (benedict-message-text message)
                      (and tool-result (plist-get tool-result :content))
                      ""))
         (payload (list :role role
                        :content content))
         (tool-calls (mapcar (lambda (call)
                               (list :id (plist-get call :id)
                                     :name (plist-get call :name)
                                     :arguments (plist-get call :arguments)))
                             (benedict-message-tool-calls message)))
         )
    (when tool-calls
      (setq payload (plist-put payload :tool-calls tool-calls)))
    (when tool-result
      (setq payload (plist-put payload :tool-call-id (plist-get tool-result :tool-call-id)))
      (setq payload (plist-put payload :name (plist-get tool-result :name))))
    payload))

(provide 'benedict-message)
;;; benedict-message.el ends here
