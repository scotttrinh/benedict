;;; benedict-vui-content-block-list.el --- Vui content block list component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a list of content blocks (text, thinking, tool calls, code).

;;; Code:

(require 'subr-x)
(require 'vui)
(require 'benedict-vui-code-block)
(require 'benedict-vui-text-block)
(require 'benedict-vui-thinking-block)
(require 'benedict-vui-tool-result-block)
(require 'benedict-vui-tool-use-block)

(defun benedict-vui-content-block-list--normalize-type (value)
  "Return VALUE normalized as a lowercase symbol or nil."
  (cond
   ((keywordp value) (intern (substring (symbol-name value) 1)))
   ((symbolp value) value)
   ((stringp value)
    (let ((trimmed (string-trim value)))
      (unless (string-empty-p trimmed)
        (intern (downcase trimmed)))))
   (t nil)))

(defun benedict-vui-content-block-list--alist-to-plist (alist)
  "Convert ALIST into a plist with keyword keys."
  (let (plist)
    (dolist (pair alist plist)
      (let* ((key (car pair))
             (keyword (cond
                       ((keywordp key) key)
                       ((symbolp key) (intern (format ":%s" (symbol-name key))))
                       ((stringp key) (intern (concat ":" (downcase key))))
                       (t nil))))
        (when keyword
          (setq plist (plist-put plist keyword (cdr pair))))))))

(defun benedict-vui-content-block-list--normalize-block (block)
  "Return BLOCK normalized to a plist or nil."
  (cond
   ((null block) nil)
   ((stringp block) (list :type 'text :content block))
   ((vectorp block)
    (benedict-vui-content-block-list--normalize-block (append block nil)))
   ((listp block)
    (let ((plist (if (and (consp (car block))
                          (not (keywordp (caar block))))
                     (benedict-vui-content-block-list--alist-to-plist block)
                   block)))
      (copy-sequence plist)))
   (t (list :type 'text :content (format "%s" block)))))

(defun benedict-vui-content-block-list--normalize-blocks (blocks)
  "Return BLOCKS normalized to a list of block plists."
  (cond
   ((null blocks) nil)
   ((stringp blocks) (list (list :type 'text :content blocks)))
   ((vectorp blocks)
    (benedict-vui-content-block-list--normalize-blocks (append blocks nil)))
   ((listp blocks)
    (delq nil (mapcar #'benedict-vui-content-block-list--normalize-block blocks)))
   (t (list (list :type 'text :content (format "%s" blocks))))))

(defun benedict-vui-content-block-list--block-type (block)
  "Return the normalized block type for BLOCK."
  (let* ((raw (or (plist-get block :type)
                  (plist-get block :kind)
                  (plist-get block :block-type)
                  (plist-get block :role)))
         (type (benedict-vui-content-block-list--normalize-type raw)))
    (cond
     ((eq type 'tool) 'tool-result)
     ((eq type 'assistant) 'text)
     ((eq type 'user) 'text)
     (type type)
     (t 'text))))

(defun benedict-vui-content-block-list--block-id (block index)
  "Return a stable identifier for BLOCK at INDEX."
  (let* ((tool-call (plist-get block :tool-call))
         (result (plist-get block :result))
         (id (or (plist-get block :id)
                 (plist-get block :block-id)
                 (plist-get block :tool-call-id)
                 (plist-get block :call-id)
                 (and (listp tool-call)
                      (or (plist-get tool-call :id)
                          (plist-get tool-call :call-id)))
                 (and (listp result)
                      (or (plist-get result :id)
                          (plist-get result :tool-call-id))))))
    (or id
        (format "block-%s"
                (if (numberp index)
                    index
                  (sxhash block))))))

(defun benedict-vui-content-block-list--message-key (props)
  "Return the navigation key from PROPS when present."
  (plist-get props :message-key))

(defun benedict-vui-content-block-list--collapsed-p (collapsed-blocks block index)
  "Return non-nil when BLOCK at INDEX is collapsed.

COLLAPSED-BLOCKS may be a list or hash table of block IDs."
  (let ((block-id (benedict-vui-content-block-list--block-id block index)))
    (cond
     ((hash-table-p collapsed-blocks) (gethash block-id collapsed-blocks))
     ((listp collapsed-blocks) (member block-id collapsed-blocks))
     (t nil))))

(defun benedict-vui-content-block-list--text-content (block)
  "Return text content for BLOCK."
  (or (plist-get block :content)
      (plist-get block :text)
      (plist-get block :body)
      ""))

(defun benedict-vui-content-block-list--thinking-content (block)
  "Return thinking payload for BLOCK."
  (or (plist-get block :thinking-data)
      (plist-get block :thinking)
      (plist-get block :content)
      ""))

(defun benedict-vui-content-block-list--code-content (block)
  "Return code payload for BLOCK."
  (or (plist-get block :code)
      (plist-get block :content)
      (plist-get block :text)
      ""))

(defun benedict-vui-content-block-list--render-block
    (block collapsed-blocks index message-key on-toggle-block)
  "Return a Vui node for BLOCK at INDEX using COLLAPSED-BLOCKS.

MESSAGE-KEY and ON-TOGGLE-BLOCK supply navigation and folding behavior."
  (let* ((type (benedict-vui-content-block-list--block-type block))
         (block-id (benedict-vui-content-block-list--block-id block index))
         (collapsed (benedict-vui-content-block-list--collapsed-p
                     collapsed-blocks block index))
         (toggle-handler (when (functionp on-toggle-block)
                           (lambda (next)
                             (funcall on-toggle-block block-id next)))))
    (pcase type
      ('thinking
       (vui-component 'benedict-vui-thinking-block
        :thinking-data (benedict-vui-content-block-list--thinking-content block)
        :collapsed collapsed
        :message-key message-key
        :block-id block-id
        :on-toggle toggle-handler))
      ('tool-use
       (vui-component 'benedict-vui-tool-use-block
        :tool-call (let ((tool-call (or (plist-get block :tool-call)
                                        (plist-get block :call)
                                        block)))
                     (if (plist-get block :status)
                         (plist-put (copy-tree tool-call) :status (plist-get block :status))
                       tool-call))
        :status (plist-get block :status)
        :collapsed collapsed
        :message-key message-key
        :block-id block-id
        :on-toggle toggle-handler))
      ('tool-result
       (vui-component 'benedict-vui-tool-result-block
        :result (or (plist-get block :result) (plist-get block :tool-result) block)
        :status (plist-get block :status)
        :actions (plist-get block :actions)
        :collapsed collapsed
        :message-key message-key
        :block-id block-id
        :on-toggle toggle-handler))
      ('code
       (vui-component 'benedict-vui-code-block
        :code (benedict-vui-content-block-list--code-content block)
        :language (plist-get block :language)
        :message-key message-key
        :block-id block-id))
      (_
       (vui-component 'benedict-vui-text-block
        :content (benedict-vui-content-block-list--text-content block)
        :message-key message-key
        :block-id block-id)))))

(vui-defcomponent benedict-vui-content-block-list (blocks collapsed-blocks message-key on-toggle-block)
  :render
  (let* ((actual-blocks (benedict-vui-content-block-list--normalize-blocks blocks)))
    (vui-list actual-blocks
              (lambda (block &optional index)
                (benedict-vui-content-block-list--render-block
                 block collapsed-blocks index message-key on-toggle-block))
              (lambda (block &optional index)
                (benedict-vui-content-block-list--block-id block index)))))

(defalias 'benedict-vui-content-block-list--render
  (lambda (props)
    (let ((blocks (plist-get props :blocks))
          (collapsed-blocks (plist-get props :collapsed-blocks))
          (message-key (plist-get props :message-key))
          (on-toggle-block (plist-get props :on-toggle-block)))
      (let* ((actual-blocks (benedict-vui-content-block-list--normalize-blocks blocks)))
        (vui-list actual-blocks
                  (lambda (block &optional index)
                    (benedict-vui-content-block-list--render-block
                     block collapsed-blocks index message-key on-toggle-block))
                  (lambda (block &optional index)
                    (benedict-vui-content-block-list--block-id block index)))))))

(provide 'benedict-vui-content-block-list)
;;; benedict-vui-content-block-list.el ends here
