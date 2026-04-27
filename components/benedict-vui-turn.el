;;; benedict-vui-turn.el --- Vui turn component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a full chat turn (header + content blocks).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-turn)
(require 'benedict-vui-content-block-list)
(require 'benedict-vui-execution-summary)
(require 'benedict-vui-turn-section)

(defun benedict-vui-turn--coerce-message (message)
  "Return MESSAGE as a canonical entry when possible."
  (cond
   ((null message) nil)
   ((benedict-message-p message) message)
   (t nil)))

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

(defun benedict-vui-turn--message-metadata (message props)
  "Return metadata for MESSAGE or PROPS."
  (or (plist-get props :metadata)
      (and message (benedict-message-metadata message))))

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

(defun benedict-vui-turn--apply-face-to-block-field (block field face)
  "Return BLOCK with FACE applied to FIELD if FIELD is a string."
  (let ((value (plist-get block field)))
    (if (stringp value)
        (let ((copy (copy-sequence block)))
          (plist-put copy field (benedict-vui-turn--apply-face value face))
          copy)
      block)))

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

(defun benedict-vui-turn--blocks-with-region-face (blocks face)
  "Return BLOCKS with FACE layered onto text payloads."
  (mapcar
   (lambda (block)
     (cond
      ((stringp block) (benedict-vui-turn--apply-face block face))
      ((not (listp block)) block)
      ((eq (benedict-vui-turn--block-type block) 'thinking)
       (benedict-vui-turn--apply-face-to-block-field block :thinking face))
      ((eq (benedict-vui-turn--block-type block) 'code)
       (benedict-vui-turn--apply-face-to-block-field block :code face))
      (t
       (let ((updated (benedict-vui-turn--apply-face-to-block-field block :content face)))
         (if (eq updated block)
             (benedict-vui-turn--apply-face-to-block-field block :text face)
           updated)))))
   blocks))

(defun benedict-vui-turn--build-blocks (message)
  "Return block list for canonical MESSAGE."
  (cond
   ((null message) nil)
   ((benedict-message-p message)
    (benedict-message-blocks-for-display message))
   ((plist-member message :blocks) (plist-get message :blocks))
   (t nil)))

(defun benedict-vui-turn--blocks (props)
  "Return content blocks for PROPS."
  (let* ((message (plist-get props :message))
         (role (benedict-vui-turn--normalize-role
                (and message (benedict-message-role message))))
         (metadata (benedict-vui-turn--message-metadata message props))
         (face (benedict-vui-turn--face-for-role role metadata))
         (blocks (or (plist-get props :blocks)
                     (benedict-vui-turn--build-blocks message))))
    (mapcar (lambda (block)
              (benedict-vui-turn--apply-face-to-block block face))
            blocks)))

(defun benedict-vui-turn--content-node (blocks message-key collapsed-blocks on-toggle-block)
  "Return a rendered content node for BLOCKS using MESSAGE-KEY.

COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK are forwarded to the block list."
  (vui-component 'benedict-vui-content-block-list
                 :blocks blocks
                 :collapsed-blocks collapsed-blocks
                 :message-key message-key
                 :on-toggle-block on-toggle-block))

(defun benedict-vui-turn--messages-from-turn (turn session)
  "Return SESSION canonical messages from TURN, including any active draft."
  (let ((message-ids (and turn (benedict-turn-message-ids turn))))
    (if session
        (let* ((msgs (delq nil (mapcar (lambda (id) (benedict-session-get-message session id)) message-ids)))
               (draft (benedict-session-draft session)))
          (if (and draft (not (eq (benedict-turn-state turn) 'turn-complete)))
              (append msgs (list (benedict-message-assistant-response
                                  :text (plist-get draft :content)
                                  :thinking (plist-get draft :thinking)
                                  :tool-calls (plist-get draft :tool-calls)
                                  :metadata '(:streaming t))))
            msgs))
      nil)))

(defun benedict-vui-turn--user-message-p (message)
  "Return non-nil when MESSAGE is a user entry."
  (eq (benedict-vui-turn--normalize-role
       (and message (benedict-message-role message)))
      'user))

(defun benedict-vui-turn--assistant-message-p (message)
  "Return non-nil when MESSAGE is an assistant entry."
  (eq (benedict-vui-turn--normalize-role
       (and message (benedict-message-role message)))
      'assistant))

(defun benedict-vui-turn--turn-prompt-message (turn session messages)
  "Return prompt message for TURN in SESSION using MESSAGES as fallback."
  (let* ((prompt-id (and turn (benedict-turn-prompt-message-id turn)))
         (prompt-message (and session prompt-id (benedict-session-get-message session prompt-id))))
    (or prompt-message
        (cl-find-if #'benedict-vui-turn--user-message-p messages)
        (car messages))))

(defun benedict-vui-turn--turn-outcome-message (turn session messages)
  "Return outcome message for TURN in SESSION using MESSAGES as fallback."
  (let* ((outcome-id (and turn (benedict-turn-outcome-message-id turn)))
         (outcome-message (and session outcome-id (benedict-session-get-message session outcome-id))))
    (or outcome-message
        (car (last (cl-remove-if-not #'benedict-vui-turn--assistant-message-p messages))))))

(defun benedict-vui-turn--message-display-blocks (message)
  "Return display blocks for MESSAGE."
  (when-let ((canonical-message (benedict-vui-turn--coerce-message message)))
    (benedict-vui-turn--blocks (list :message canonical-message))))

(defun benedict-vui-turn--message-text (message)
  "Return text content for MESSAGE, or nil."
  (when-let ((canonical-message (benedict-vui-turn--coerce-message message)))
    (benedict-message-text canonical-message)))

(defun benedict-vui-turn--text-block-predicate (block)
  "Return non-nil when BLOCK is text-like for draft/outcome display."
  (memq (benedict-vui-turn--block-type block) '(text code)))

(defun benedict-vui-turn--execution-block-predicate (block)
  "Return non-nil when BLOCK is execution detail."
  (memq (benedict-vui-turn--block-type block) '(thinking tool-use tool-result)))

(defun benedict-vui-turn--activity-blocks (messages)
  "Return non-text execution blocks drawn from MESSAGES."
  (apply #'append
         (mapcar (lambda (message)
                   (cl-remove-if-not #'benedict-vui-turn--execution-block-predicate
                                 (benedict-vui-turn--message-display-blocks message)))
                 messages)))

(defun benedict-vui-turn--draft-blocks (message)
  "Return text blocks from MESSAGE for in-progress draft rendering."
  (cl-remove-if-not #'benedict-vui-turn--text-block-predicate
                    (benedict-vui-turn--message-display-blocks message)))

(defun benedict-vui-turn--outcome-blocks (message)
  "Return primary answer blocks from MESSAGE."
  (cl-remove-if-not #'benedict-vui-turn--text-block-predicate
                    (benedict-vui-turn--message-display-blocks message)))

(defun benedict-vui-turn--status-error-p (status)
  "Return non-nil when STATUS should count as an error."
  (memq status '(failure denied error)))

(defun benedict-vui-turn--status-warning-p (status)
  "Return non-nil when STATUS should count as a warning."
  (memq status '(warning warn)))

(defun benedict-vui-turn--status-approval-p (status)
  "Return non-nil when STATUS indicates approval involvement."
  (eq status 'awaiting-approval))

(defun benedict-vui-turn--tool-name-from-block (block)
  "Return tool name from display BLOCK, or nil."
  (let ((name (pcase (plist-get block :type)
                ('tool-use (plist-get (plist-get block :tool-call) :name))
                ('tool-result (plist-get (plist-get block :result) :name))
                (_ nil))))
    (cond
     ((null name) nil)
     ((symbolp name) (symbol-name name))
     ((stringp name) name)
     (t (format "%s" name)))))

(defun benedict-vui-turn--tool-status-from-block (block)
  "Return tool status from display BLOCK, or nil."
  (let ((raw (pcase (plist-get block :type)
               ('tool-use (or (plist-get block :status)
                              (plist-get (plist-get block :tool-call) :status)))
               ('tool-result (or (plist-get block :status)
                                 (plist-get (plist-get block :result) :status)))
               (_ nil))))
    (cond
     ((keywordp raw) (intern (substring (symbol-name raw) 1)))
     ((stringp raw) (intern (downcase raw)))
     (t raw))))

(defun benedict-vui-turn--tool-result-summary-snippet (block)
  "Return a compact summary snippet for tool-result BLOCK, or nil."
  (let* ((result (plist-get block :result))
         (status (benedict-vui-turn--tool-status-from-block block))
         (content (string-trim (or (plist-get result :content) "")))
         (tool-name (or (plist-get result :name) "tool")))
    (when (or (benedict-vui-turn--status-error-p status)
              (benedict-vui-turn--status-warning-p status))
      (format "%s: %s"
              tool-name
              (if (string-empty-p content)
                  (symbol-name (or status 'unknown))
                (truncate-string-to-width content 80 nil nil t))))))

(defun benedict-vui-turn--execution-summary (messages execution-blocks)
  "Return summarized execution metadata for turn MESSAGES and EXECUTION-BLOCKS."
  (let ((tool-count 0)
        names
        (error-count (+ (cl-count-if (lambda (message)
                                       (and (not (eq (benedict-message-role message) 'tool))
                                            (plist-get (benedict-message-metadata message) :error)))
                                     messages)))
        (warning-count 0)
        (approval-count 0)
        highlights
        (has-thinking (cl-some (lambda (message) (benedict-message-thinking message)) messages)))
    (dolist (block execution-blocks)
      (when-let ((tool-name (benedict-vui-turn--tool-name-from-block block)))
        (when (eq (plist-get block :type) 'tool-use)
          (setq tool-count (1+ tool-count)))
        (push tool-name names))
      (let ((status (benedict-vui-turn--tool-status-from-block block)))
        (when (benedict-vui-turn--status-error-p status)
          (cl-incf error-count))
        (when (benedict-vui-turn--status-warning-p status)
          (cl-incf warning-count))
        (when (benedict-vui-turn--status-approval-p status)
          (cl-incf approval-count)))
      (when-let ((snippet (benedict-vui-turn--tool-result-summary-snippet block)))
        (push snippet highlights)))
    (list :tool-count tool-count
          :tool-names (delete-dups (delq nil (nreverse names)))
          :error-count error-count
          :warning-count warning-count
          :has-thinking has-thinking
          :has-errors (> error-count 0)
          :has-warnings (> warning-count 0)
          :has-approvals (> approval-count 0)
          :highlights (delete-dups (nreverse highlights)))))

(defun benedict-vui-turn--execution-summary-items (summary)
  "Return compact display strings for execution SUMMARY."
  (let (items)
    (when-let ((tool-count (plist-get summary :tool-count)))
      (when (> tool-count 0)
        (push (format "%d tool%s" tool-count (if (= tool-count 1) "" "s"))
              items)))
    (when-let ((tool-names (plist-get summary :tool-names)))
      (when tool-names
        (push (mapconcat #'identity tool-names ", ") items)))
    (when-let ((error-count (plist-get summary :error-count)))
      (when (> error-count 0)
        (push (format "%d error%s" error-count (if (= error-count 1) "" "s"))
              items)))
    (when-let ((warning-count (plist-get summary :warning-count)))
      (when (> warning-count 0)
        (push (format "%d warning%s" warning-count (if (= warning-count 1) "" "s"))
              items)))
    (when (plist-get summary :has-thinking)
      (push "thinking" items))
    (when (plist-get summary :has-approvals)
      (push "approval" items))
    (nreverse items)))

(defun benedict-vui-turn--section-navigation-properties (turn target &optional message-key)
  "Return navigation properties for TURN TARGET and MESSAGE-KEY."
  (let ((properties (list 'benedict-turn-id
                          (or (and turn (benedict-turn-prompt-message-id turn))
                              (and turn (benedict-turn-id turn)))
                          'benedict-turn-target target
                          'benedict-region-kind 'turn-target)))
    (when message-key
      (setq properties
            (append properties
                    (list 'benedict-message-key message-key))))
    properties))

(defun benedict-vui-turn--prompt-header-node (turn prompt-message prompt-text)
  "Return a dedicated prompt header node for TURN, PROMPT-MESSAGE, and PROMPT-TEXT."
  (let* ((message-key (and prompt-message (benedict-message-id prompt-message)))
         (content (or prompt-text (benedict-vui-turn--message-text prompt-message) ""))
         (content-node
          (when (and (stringp content)
                     (not (string-empty-p content)))
            (vui-component 'benedict-vui-content-block-list
                           :blocks (benedict-vui-turn--blocks-with-region-face
                                    (list (list :type 'text :content content))
                                    'benedict-chat-turn-prompt-header)
                           :collapsed-blocks nil
                           :message-key message-key
                           :on-toggle-block nil))))
    (vui-component 'benedict-vui-turn-section
                   :status 'user
                   :title "Prompt"
                   :detail nil
                   :face 'benedict-chat-turn-prompt-header
                   :navigation-properties
                   (benedict-vui-turn--section-navigation-properties
                    turn 'prompt message-key)
                   :content content-node)))

(defun benedict-vui-turn--active-turn-node (turn session collapsed-blocks on-toggle-block)
  "Return active turn layout for TURN.

SESSION owns TURN's canonical messages.
COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK are forwarded to rendered content blocks."
  (let* ((messages (benedict-vui-turn--messages-from-turn turn session))
         (prompt-message (cl-find-if #'benedict-vui-turn--user-message-p messages))
         (outcome-message (benedict-vui-turn--turn-outcome-message turn session messages))
         (non-prompt-messages (if prompt-message
                                  (delq prompt-message (copy-sequence messages))
                                messages))
         (activity-blocks (benedict-vui-turn--activity-blocks non-prompt-messages))
         (draft-blocks (benedict-vui-turn--draft-blocks outcome-message))
         (draft-message-key (and outcome-message (benedict-message-id outcome-message)))
         (children (list
                    (benedict-vui-turn--prompt-header-node
                     turn
                     prompt-message
                     nil)
                    (vui-component 'benedict-vui-turn-section
                                   :status 'assistant
                                   :title "Activity"
                                   :detail "Working"
                                   :face 'benedict-chat-turn-active
                                   :navigation-properties
                                   (benedict-vui-turn--section-navigation-properties
                                    turn 'activity draft-message-key)
                                   :content (if activity-blocks
                                                (benedict-vui-turn--content-node
                                                 (benedict-vui-turn--blocks-with-region-face
                                                  activity-blocks
                                                  'benedict-chat-turn-detail)
                                                 draft-message-key
                                                 collapsed-blocks
                                                 on-toggle-block)
                                              (vui-text
                                               (propertize
                                                "Waiting for assistant output."
                                                'face '(benedict-chat-turn-active
                                                        benedict-chat-header-time))))))))
    (when draft-blocks
      (setq children
            (append children
                    (list
                     (vui-component 'benedict-vui-turn-section
                                    :status 'active
                                    :title "Draft answer"
                                    :detail nil
                                    :face 'benedict-chat-turn-active
                                    :navigation-properties
                                    (benedict-vui-turn--section-navigation-properties
                                     turn 'draft draft-message-key)
                                    :content (benedict-vui-turn--content-node
                                              (benedict-vui-turn--blocks-with-region-face
                                               draft-blocks
                                               'benedict-chat-turn-active)
                                              draft-message-key
                                              collapsed-blocks
                                              on-toggle-block))))))
    (apply #'vui-vstack (append (list :spacing 1) children))))

(defun benedict-vui-turn--completed-turn-node
    (turn session collapsed-blocks on-toggle-block execution-expanded on-toggle-execution)
  "Return completed turn layout for TURN.

SESSION owns TURN's canonical messages.
COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK are forwarded to block rendering.
EXECUTION-EXPANDED and ON-TOGGLE-EXECUTION control turn-level detail visibility."
  (let* ((messages (benedict-vui-turn--messages-from-turn turn session))
         (prompt-message (benedict-vui-turn--turn-prompt-message turn session messages))
         (outcome-message (benedict-vui-turn--turn-outcome-message turn session messages))
         (outcome-blocks (benedict-vui-turn--outcome-blocks outcome-message))
         (detail-messages (if prompt-message
                              (delq prompt-message (copy-sequence messages))
                            messages))
         (execution-blocks (benedict-vui-turn--activity-blocks detail-messages))
         (execution-summary (benedict-vui-turn--execution-summary messages execution-blocks))
         (outcome-message-key (and outcome-message (benedict-message-id outcome-message)))
         (children (list
                    (benedict-vui-turn--prompt-header-node
                     turn
                     prompt-message
                     (benedict-vui-turn--message-text prompt-message)))))
    (when outcome-blocks
      (setq children
            (append children
                    (list
                     (vui-component 'benedict-vui-turn-section
                                    :status 'assistant
                                    :title "Answer"
                                    :detail nil
                                    :face 'benedict-chat-turn-outcome
                                    :navigation-properties
                                    (benedict-vui-turn--section-navigation-properties
                                     turn 'outcome outcome-message-key)
                                    :content (benedict-vui-turn--content-node
                                              (benedict-vui-turn--blocks-with-region-face
                                               outcome-blocks
                                               'benedict-chat-turn-outcome)
                                              outcome-message-key nil nil))))))
    (when execution-blocks
      (setq children
            (append children
                    (list (vui-component 'benedict-vui-execution-summary
                                         :items (benedict-vui-turn--execution-summary-items
                                                 execution-summary)
                                         :summary execution-summary
                                         :expanded execution-expanded
                                         :on-toggle on-toggle-execution
                                         :navigation-properties
                                         (benedict-vui-turn--section-navigation-properties
                                          turn 'execution-summary outcome-message-key)))))
      (when execution-expanded
        (setq children
              (append children
                      (list
                       (vui-component 'benedict-vui-turn-section
                                      :status 'assistant
                                      :title "Execution details"
                                      :detail nil
                                      :face 'benedict-chat-turn-detail
                                      :navigation-properties
                                      (benedict-vui-turn--section-navigation-properties
                                       turn 'execution-details outcome-message-key)
                                      :content (benedict-vui-turn--content-node
                                                (benedict-vui-turn--blocks-with-region-face
                                                 execution-blocks
                                                 'benedict-chat-turn-detail)
                                                outcome-message-key
                                                collapsed-blocks
                                                on-toggle-block)))))))
    (unless outcome-blocks
      (setq children
            (append children
                    (list (vui-text (propertize "No final assistant answer."
                                                'face '(benedict-chat-turn-summary
                                                        benedict-chat-header-time)))))))
    (apply #'vui-vstack (append (list :spacing 1) children))))

(vui-defcomponent benedict-vui-turn
    (turn session collapsed-blocks on-toggle-block execution-expanded)
  :state ((local-execution-expanded nil))
  :render
  (let ((turn-messages (benedict-vui-turn--messages-from-turn turn session)))
    (when turn-messages
      (let* ((expanded (or execution-expanded local-execution-expanded))
             (toggle-execution (lambda (next)
                                 (vui-set-state :local-execution-expanded next))))
        (if (not (memq (benedict-turn-state turn) '(idle error turn-complete cancelled)))
            (benedict-vui-turn--active-turn-node
             turn session collapsed-blocks on-toggle-block)
          (benedict-vui-turn--completed-turn-node
           turn session collapsed-blocks on-toggle-block expanded toggle-execution))))))

(provide 'benedict-vui-turn)
;;; benedict-vui-turn.el ends here
