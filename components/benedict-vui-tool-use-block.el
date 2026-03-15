;;; benedict-vui-tool-use-block.el --- Vui tool use block component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders tool invocation details in a collapsible block.

;;; Code:

(require 'pp)
(require 'subr-x)
(require 'vui)
(require 'benedict-vui-badge)
(require 'benedict-vui-collapsible)

(defconst benedict-vui-tool-use-block--spinner "..."
  "Spinner placeholder for running tools.")

(defun benedict-vui-tool-use-block--name-string (name)
  "Return a human-readable string for tool NAME."
  (cond
   ((symbolp name) (symbol-name name))
   ((stringp name) name)
   ((null name) "Tool")
   (t (format "%s" name))))

(defun benedict-vui-tool-use-block--tool-name (tool-call)
  "Return the tool name string from TOOL-CALL plist."
  (benedict-vui-tool-use-block--name-string
   (or (plist-get tool-call :name)
       (plist-get tool-call :tool)
       (plist-get tool-call :id)
       "Tool")))

(defun benedict-vui-tool-use-block--normalize-status (status)
  "Return STATUS coerced into a canonical symbol."
  (cond
   ((null status) 'running)
   ((keywordp status) (intern (substring (symbol-name status) 1)))
   ((symbolp status)
   (pcase status
      ('ok 'success)
      ('error 'failure)
      ('pending 'running)
      ('in-progress 'running)
      ('awaiting-approval 'awaiting-approval)
      (_ status)))
   ((stringp status)
    (let* ((normalized (replace-regexp-in-string
                        "[[:space:]]+" "-" (downcase status))))
      (benedict-vui-tool-use-block--normalize-status (intern normalized))))
   (t 'running)))

(defun benedict-vui-tool-use-block--spinner-visible-p (status)
  "Return non-nil when STATUS should display a spinner."
  (eq (benedict-vui-tool-use-block--normalize-status status) 'running))

(defun benedict-vui-tool-use-block--value-string (value)
  "Return VALUE formatted for tool argument display."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (string-trim-right (pp-to-string value)))))

(defun benedict-vui-tool-use-block--arguments-string (arguments)
  "Return formatted ARGUMENTS for display."
  (let ((value (benedict-vui-tool-use-block--value-string arguments)))
    (if (string-empty-p value)
        "None"
      value)))

(defun benedict-vui-tool-use-block--header-title (tool-call)
  "Return header title for TOOL-CALL."
  (format "Tool: %s" (benedict-vui-tool-use-block--tool-name tool-call)))

(defun benedict-vui-tool-use-block--spinner-node (status)
  "Return a spinner node when STATUS is running."
  (when (benedict-vui-tool-use-block--spinner-visible-p status)
    (vui-text (propertize benedict-vui-tool-use-block--spinner
                          'face 'benedict-chat-tool-running))))

(defun benedict-vui-tool-use-block--propertize (content &optional message-key block-id)
  "Return CONTENT with tool-use text properties applied.

MESSAGE-KEY and BLOCK-ID are stored as text properties when provided."
  (propertize (benedict-vui-tool-use-block--value-string content)
              'benedict-region-kind 'tool-ui
              'benedict-message-key message-key
              'benedict-block-id block-id))

(defun benedict-vui-tool-use-block--header (tool-call status message-key block-id)
  "Return the tool header node for TOOL-CALL and STATUS.

MESSAGE-KEY and BLOCK-ID annotate the rendered header."
  (vui-hstack
   (vui-component 'benedict-vui-badge :status (benedict-vui-tool-use-block--normalize-status status))
   (vui-text (propertize (benedict-vui-tool-use-block--header-title tool-call)
                         'face 'benedict-chat-tool-label
                         'benedict-message-key message-key
                         'benedict-block-id block-id))
   (benedict-vui-tool-use-block--spinner-node status)))

(defun benedict-vui-tool-use-block--content-text (tool-call)
  "Return formatted content for TOOL-CALL."
  (let ((arguments (plist-get tool-call :arguments)))
    (format "%s\nArguments:\n%s"
            (pcase (benedict-vui-tool-use-block--normalize-status
                    (plist-get tool-call :status))
              ('awaiting-approval "Awaiting approval")
              (_ ""))
            (benedict-vui-tool-use-block--arguments-string arguments))))

(defun benedict-vui-tool-use-block--content (tool-call message-key block-id)
  "Return the tool call content node for TOOL-CALL.

MESSAGE-KEY and BLOCK-ID annotate the rendered content."
  (vui-text (benedict-vui-tool-use-block--propertize
             (benedict-vui-tool-use-block--content-text tool-call)
             message-key
             block-id)))

(defun benedict-vui-tool-use-block--controlled-p (props)
  "Return non-nil when PROPS includes a :collapsed key."
  (not (null (plist-member props :collapsed))))

(defun benedict-vui-tool-use-block--collapsed-p (props state)
  "Return non-nil when PROPS/STATE indicate collapse."
  (if (benedict-vui-tool-use-block--controlled-p props)
      (plist-get props :collapsed)
    (plist-get state :collapsed)))

(vui-defcomponent benedict-vui-tool-use-block (tool-call status on-toggle message-key block-id collapsed)
  :render
  (let* ((toggle-handler (lambda (next)
                           (when (functionp on-toggle)
                             (funcall on-toggle next)))))
    (vui-component 'benedict-vui-collapsible
      :collapsed collapsed
      :on-toggle toggle-handler
      :header (lambda ()
                 (benedict-vui-tool-use-block--header tool-call status message-key block-id))
      :content (lambda ()
                  (benedict-vui-tool-use-block--content tool-call message-key block-id)))))

(provide 'benedict-vui-tool-use-block)
;;; benedict-vui-tool-use-block.el ends here
