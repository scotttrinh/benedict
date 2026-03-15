;;; benedict-vui-turn.el --- Vui turn component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a full chat turn (header + content blocks).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict-message)
(require 'benedict-vui-badge)
(require 'benedict-vui-content-block-list)
(require 'benedict-vui-turn-header)

(defun benedict-vui-turn--coerce-message (message)
  "Return MESSAGE as a canonical entry when possible."
  (cond
   ((null message) nil)
   ((benedict-message-p message) message)
   ((listp message)
    (benedict-message-from-data message))
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

(defun benedict-vui-turn--message-role (message props)
  "Return the role for MESSAGE or PROPS."
  (benedict-vui-turn--normalize-role
   (or (plist-get props :role)
       (and message (benedict-message-role message)))))

(defun benedict-vui-turn--message-timestamp (message props)
  "Return the timestamp for MESSAGE or PROPS."
  (or (plist-get props :timestamp)
      (and message (benedict-message-timestamp message))))

(defun benedict-vui-turn--message-metadata (message props)
  "Return metadata for MESSAGE or PROPS."
  (or (plist-get props :metadata)
      (and message (benedict-message-metadata message))))

(defun benedict-vui-turn--message-key (message props)
  "Return a navigation key for MESSAGE or PROPS."
  (or (plist-get props :message-key)
      (and message (or (benedict-message-id message)
                       (plist-get props :nav-index)))))

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

(defun benedict-vui-turn--build-blocks (message role)
  "Return block list for MESSAGE given ROLE."
  (cond
   ((null message) nil)
   ((benedict-message-p message)
    (benedict-message-blocks-for-display message))
   ((plist-member message :blocks) (plist-get message :blocks))
   (t nil)))

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

(defun benedict-vui-turn--message-node (message collapsed-blocks on-toggle-block)
  "Return a rendered node for MESSAGE.

COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK are forwarded to the block list."
  (let* ((canonical-message (benedict-vui-turn--coerce-message message))
         (actual-role (benedict-vui-turn--normalize-role
                       (and canonical-message
                            (benedict-message-role canonical-message))))
         (actual-timestamp (and canonical-message
                                (benedict-message-timestamp canonical-message)))
         (actual-metadata (and canonical-message
                               (benedict-message-metadata canonical-message)))
         (actual-message-key (and canonical-message
                                  (benedict-message-id canonical-message)))
         (face (benedict-vui-turn--face-for-role actual-role actual-metadata))
         (actual-blocks (benedict-vui-turn--build-blocks canonical-message actual-role))
         (final-blocks (mapcar (lambda (block)
                                 (benedict-vui-turn--apply-face-to-block block face))
                               actual-blocks))
         (header (vui-component 'benedict-vui-turn-header
                                :role actual-role
                                :timestamp actual-timestamp
                                :metadata actual-metadata))
         (content (benedict-vui-turn--content-node
                   final-blocks actual-message-key collapsed-blocks on-toggle-block)))
    (vui-vstack header content)))

(defun benedict-vui-turn--content-node (blocks message-key collapsed-blocks on-toggle-block)
  "Return a rendered content node for BLOCKS using MESSAGE-KEY.

COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK are forwarded to the block list."
  (vui-component 'benedict-vui-content-block-list
                 :blocks blocks
                 :collapsed-blocks collapsed-blocks
                 :message-key message-key
                 :on-toggle-block on-toggle-block))

(defun benedict-vui-turn--messages-from-turn (turn)
  "Return canonical messages from TURN plist."
  (let ((messages (plist-get turn :messages)))
    (delq nil (mapcar #'benedict-vui-turn--coerce-message messages))))

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

(defun benedict-vui-turn--turn-prompt-message (turn messages)
  "Return prompt message for TURN using canonical MESSAGES as fallback."
  (let ((prompt-message
         (benedict-vui-turn--coerce-message (plist-get turn :prompt-message))))
    (or (and prompt-message
             (benedict-vui-turn--user-message-p prompt-message)
             prompt-message)
        (cl-find-if #'benedict-vui-turn--user-message-p messages))))

(defun benedict-vui-turn--turn-outcome-message (turn messages)
  "Return outcome message for TURN using canonical MESSAGES as fallback."
  (or (benedict-vui-turn--coerce-message (plist-get turn :outcome-message))
      (car (last (cl-remove-if-not #'benedict-vui-turn--assistant-message-p messages)))))

(defun benedict-vui-turn--message-display-blocks (message)
  "Return display blocks for MESSAGE."
  (when-let ((canonical-message (benedict-vui-turn--coerce-message message)))
    (benedict-vui-turn--blocks (list :message canonical-message))))

(defun benedict-vui-turn--text-block-predicate (block)
  "Return non-nil when BLOCK is text-like for draft/outcome display."
  (eq (benedict-vui-turn--block-type block) 'text))

(defun benedict-vui-turn--activity-blocks (messages)
  "Return non-text execution blocks drawn from MESSAGES."
  (apply #'append
         (mapcar (lambda (message)
                   (cl-remove-if #'benedict-vui-turn--text-block-predicate
                                 (benedict-vui-turn--message-display-blocks message)))
                 messages)))

(defun benedict-vui-turn--draft-blocks (message)
  "Return text blocks from MESSAGE for in-progress draft rendering."
  (cl-remove-if-not #'benedict-vui-turn--text-block-predicate
                    (benedict-vui-turn--message-display-blocks message)))

(defun benedict-vui-turn--section-label (status title &optional detail)
  "Return a section label node using STATUS, TITLE, and optional DETAIL."
  (let ((children (list (vui-component 'benedict-vui-badge :status status)
                        (vui-text (propertize title 'face 'benedict-chat-header)))))
    (when detail
      (setq children (append children
                             (list (vui-text "·" :face 'benedict-chat-header-separator)
                                   (vui-text (propertize detail
                                                         'face 'benedict-chat-header-time))))))
    (apply #'vui-hstack children)))

(defun benedict-vui-turn--prompt-header-node (prompt-message prompt-text)
  "Return a dedicated prompt header node for PROMPT-MESSAGE and PROMPT-TEXT."
  (let* ((message-key (and prompt-message (benedict-message-id prompt-message)))
         (content (or prompt-text (benedict-vui-turn--message-text prompt-message) ""))
         (children (list (benedict-vui-turn--section-label 'user "Prompt"))))
    (when (and (stringp content)
               (not (string-empty-p content)))
      (setq children (append children
                             (list (vui-component 'benedict-vui-content-block-list
                                                  :blocks (list (list :type 'text :content content))
                                                  :collapsed-blocks nil
                                                  :message-key message-key
                                                  :on-toggle-block nil)))))
    (apply #'vui-vstack children)))

(defun benedict-vui-turn--active-turn-node (turn collapsed-blocks on-toggle-block)
  "Return active turn layout for TURN.

COLLAPSED-BLOCKS and ON-TOGGLE-BLOCK are forwarded to rendered content blocks."
  (let* ((messages (benedict-vui-turn--messages-from-turn turn))
         (prompt-message (benedict-vui-turn--turn-prompt-message turn messages))
         (outcome-message (benedict-vui-turn--turn-outcome-message turn messages))
         (non-prompt-messages (if prompt-message
                                  (delq prompt-message (copy-sequence messages))
                                messages))
         (activity-blocks (benedict-vui-turn--activity-blocks non-prompt-messages))
         (draft-blocks (benedict-vui-turn--draft-blocks outcome-message))
         (draft-message-key (and outcome-message (benedict-message-id outcome-message)))
         (children (list
                    (benedict-vui-turn--prompt-header-node
                     prompt-message
                     (plist-get turn :prompt-text))
                    (vui-vstack
                     (benedict-vui-turn--section-label 'assistant "Activity" "Working")
                     (if activity-blocks
                         (benedict-vui-turn--content-node
                          activity-blocks draft-message-key collapsed-blocks on-toggle-block)
                       (vui-text (propertize "Waiting for assistant output."
                                             'face 'benedict-chat-header-time)))))))
    (when draft-blocks
      (setq children
            (append children
                    (list
                     (vui-vstack
                      (benedict-vui-turn--section-label 'assistant "Draft answer")
                      (benedict-vui-turn--content-node
                       draft-blocks draft-message-key collapsed-blocks on-toggle-block))))))
    (apply #'vui-vstack children)))

(defun benedict-vui-turn--legacy-node
    (message blocks role timestamp metadata message-key collapsed-blocks on-toggle-block)
  "Render the pre-turn-model node using MESSAGE, BLOCKS, ROLE, TIMESTAMP, METADATA, MESSAGE-KEY, COLLAPSED-BLOCKS, and ON-TOGGLE-BLOCK."
  (let* ((canonical-message (benedict-vui-turn--coerce-message message))
         (actual-role (benedict-vui-turn--normalize-role
                       (or role (and canonical-message (benedict-message-role canonical-message)))))
         (actual-timestamp (or timestamp
                               (and canonical-message (benedict-message-timestamp canonical-message))))
         (actual-metadata (or metadata (and canonical-message (benedict-message-metadata canonical-message))))
         (actual-message-key (or message-key
                                 (and canonical-message (benedict-message-id canonical-message))))
         (face (benedict-vui-turn--face-for-role actual-role actual-metadata))
         (actual-blocks (or blocks (benedict-vui-turn--build-blocks canonical-message actual-role)))
         (final-blocks (mapcar (lambda (block)
                                 (benedict-vui-turn--apply-face-to-block block face))
                               actual-blocks))
         (header (vui-component 'benedict-vui-turn-header :role actual-role
                                            :timestamp actual-timestamp
                                            :metadata actual-metadata))
         (content (benedict-vui-turn--content-node
                   final-blocks actual-message-key collapsed-blocks on-toggle-block)))
    (vui-vstack header content)))

(vui-defcomponent benedict-vui-turn
    (turn message blocks role timestamp metadata message-key collapsed-blocks on-toggle-block)
  :render
  (let ((turn-messages (and (listp turn)
                            (benedict-vui-turn--messages-from-turn turn))))
    (if turn-messages
        (if (plist-get turn :active)
            (benedict-vui-turn--active-turn-node
             turn collapsed-blocks on-toggle-block)
          (apply #'vui-vstack
                 (mapcar (lambda (turn-message)
                           (benedict-vui-turn--message-node
                            turn-message collapsed-blocks on-toggle-block))
                         turn-messages)))
      (benedict-vui-turn--legacy-node
       message blocks role timestamp metadata message-key
       collapsed-blocks on-toggle-block))))

(provide 'benedict-vui-turn)
;;; benedict-vui-turn.el ends here
