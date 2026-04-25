;;; benedict-message.el --- Canonical transcript entries for Benedict -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider-agnostic message structures and helpers used by the runtime,
;; persistence, and UI layers.  Provider wire serialization belongs in
;; `benedict-provider.el' and concrete provider modules.

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

(defun benedict-message--tool-result-block
    (tool-call-id name status content &optional details ui effects)
  "Create a tool-result block for TOOL-CALL-ID, NAME, STATUS, and CONTENT.

DETAILS preserves structured runtime metadata.  UI carries render hints and
EFFECTS carries observed side-effect summaries."
  (list :type 'tool-result
        :tool-call-id tool-call-id
        :name name
        :status status
        :content content
        :details details
        :ui ui
        :effects effects))

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

(defun benedict-message-system-text (text &optional metadata)
  "Create a canonical system text message for TEXT and METADATA."
  (benedict-message-create
   :kind 'message
   :role 'system
   :blocks (list (benedict-message--text-block text))
   :metadata metadata))

(cl-defun benedict-message-assistant-response
    (&key text thinking tool-calls metadata)
  "Create a canonical assistant response.
TEXT is assistant text content.  THINKING preserves reasoning details.
TOOL-CALLS is a list of canonical tool-call plists containing :id, :name, and
:arguments.  METADATA is copied into the message metadata slot."
  (let ((blocks nil))
    (push (benedict-message--text-block text) blocks)
    (when thinking
      (push (benedict-message--thinking-block thinking) blocks))
    (dolist (tool-call tool-calls)
      (push (benedict-message--tool-call-block tool-call) blocks))
    (benedict-message-create
     :kind 'message
     :role 'assistant
     :blocks (nreverse blocks)
     :metadata metadata)))

(cl-defun benedict-message-assistant-tool-call
    (id name arguments &key text thinking metadata status)
  "Create a canonical assistant message containing one tool call.
ID, NAME, and ARGUMENTS identify the tool request.  TEXT, THINKING, METADATA,
and STATUS preserve optional assistant content and execution state."
  (benedict-message-assistant-response
   :text text
   :thinking thinking
   :tool-calls (list (list :id id
                           :name name
                           :arguments arguments
                           :status status))
   :metadata metadata))

(defun benedict-message-tool-result
    (tool-call-id name status content &optional details ui effects)
  "Create a canonical tool result message.

TOOL-CALL-ID, NAME, STATUS, and CONTENT identify the result.  DETAILS, UI,
and EFFECTS mirror the structured tool result contract."
  (let ((metadata (list :status status)))
    (when details
      (setq metadata (plist-put metadata :details details)))
    (when ui
      (setq metadata (plist-put metadata :ui ui)))
    (when effects
      (setq metadata (plist-put metadata :effects effects)))
    (when (and details (memq status '(failure denied)))
      (setq metadata (plist-put metadata :error details)))
    (benedict-message-create
     :kind 'message
     :role 'tool
     :blocks (list (benedict-message--tool-result-block
                    tool-call-id name status content details ui effects))
     :metadata metadata)))

(defun benedict-message-copy (message)
  "Return a durable copy of canonical MESSAGE."
  (unless (benedict-message-p message)
    (error "Expected canonical benedict-message, got: %S" message))
  (benedict-message-create
   :id (benedict-message-id message)
   :kind (benedict-message-kind message)
   :role (benedict-message-role message)
   :blocks (benedict-message--copy-blocks (benedict-message-blocks message))
   :metadata (copy-tree (benedict-message-metadata message))
   :timestamp (benedict-message-timestamp message)))

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

(defun benedict-message-tool-result-ui (message)
  "Return tool result UI metadata from MESSAGE, or nil."
  (when-let ((block (benedict-message--tool-result-block-data message)))
    (plist-get block :ui)))

(defun benedict-message-tool-result-effects (message)
  "Return tool result effects metadata from MESSAGE, or nil."
  (when-let ((block (benedict-message--tool-result-block-data message)))
    (plist-get block :effects)))

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
                                   :details (plist-get block :details)
                                   :error (plist-get block :details)
                                   :ui (plist-get block :ui)
                                   :effects (plist-get block :effects))
                     :status (plist-get block :status))
               blocks))))
    (if (and (eq role 'tool) blocks)
        (nreverse (cl-remove-if-not
                   (lambda (block) (eq (plist-get block :type) 'tool-result))
                   blocks))
      (nreverse blocks))))

(provide 'benedict-message)
;;; benedict-message.el ends here
