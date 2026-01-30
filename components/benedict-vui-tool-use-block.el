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
  (vui-component 'benedict-vui-tool-use-block--name-string
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
      (_ status)))
   ((stringp status)
    (let* ((normalized (replace-regexp-in-string
                        "[[:space:]]+" "-" (downcase status))))
      (vui-component 'benedict-vui-tool-use-block--normalize-status (intern normalized))))
   (t 'running)))

(defun benedict-vui-tool-use-block--spinner-visible-p (status)
  "Return non-nil when STATUS should display a spinner."
  (eq (vui-component 'benedict-vui-tool-use-block--normalize-status status) 'running))

(defun benedict-vui-tool-use-block--value-string (value)
  "Return VALUE formatted for tool argument display."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (string-trim-right (pp-to-string value)))))

(defun benedict-vui-tool-use-block--arguments-string (arguments)
  "Return formatted ARGUMENTS for display."
  (let ((value (vui-component 'benedict-vui-tool-use-block--value-string arguments)))
    (if (string-empty-p value)
        "None"
      value)))

(defun benedict-vui-tool-use-block--header-title (tool-call)
  "Return header title for TOOL-CALL."
  (format "Tool: %s" (vui-component 'benedict-vui-tool-use-block--tool-name tool-call)))

(defun benedict-vui-tool-use-block--spinner-node (status)
  "Return a spinner node when STATUS is running."
  (when (vui-component 'benedict-vui-tool-use-block--spinner-visible-p status)
    (vui-text (propertize benedict-vui-tool-use-block--spinner
                          'face 'benedict-chat-tool-running))))

(defun benedict-vui-tool-use-block--header (tool-call status)
  "Return the tool header node for TOOL-CALL and STATUS."
  (vui-hstack
   (vui-component 'benedict-vui-badge :status (vui-component 'benedict-vui-tool-use-block--normalize-status status))
   (vui-text (propertize (vui-component 'benedict-vui-tool-use-block--header-title tool-call)
                         'face 'benedict-chat-tool-label))
   (vui-component 'benedict-vui-tool-use-block--spinner-node status)))

(defun benedict-vui-tool-use-block--content-text (tool-call)
  "Return formatted content for TOOL-CALL."
  (let ((arguments (plist-get tool-call :arguments)))
    (format "Arguments:\n%s"
            (vui-component 'benedict-vui-tool-use-block--arguments-string arguments))))

(defun benedict-vui-tool-use-block--content (tool-call)
  "Return the tool call content node for TOOL-CALL."
  (vui-text (vui-component 'benedict-vui-tool-use-block--content-text tool-call)))

(defun benedict-vui-tool-use-block--controlled-p (props)
  "Return non-nil when PROPS includes a :collapsed key."
  (not (null (plist-member props :collapsed))))

(defun benedict-vui-tool-use-block--collapsed-p (props state)
  "Return non-nil when PROPS/STATE indicate collapse."
  (if (vui-component 'benedict-vui-tool-use-block--controlled-p props)
      (plist-get props :collapsed)
    (plist-get state :collapsed)))

(defun benedict-vui-tool-use-block--collapsible-props (props state toggle-handler)
  "Return collapsible props for PROPS/STATE and TOGGLE-HANDLER."
  (let* ((tool-call (plist-get props :tool-call))
         (status (plist-get props :status))
         (collapsed (vui-component 'benedict-vui-tool-use-block--collapsed-p props state)))
    (list :collapsed collapsed
          :on-toggle toggle-handler
          :header (lambda ()
                    (vui-component 'benedict-vui-tool-use-block--header tool-call status))
          :content (lambda ()
                     (vui-component 'benedict-vui-tool-use-block--content tool-call)))))

(defun benedict-vui-tool-use-block--render (props state)
  "Return the rendered tool use block for PROPS/STATE."
  (let* ((controlled (vui-component 'benedict-vui-tool-use-block--controlled-p props))
         (toggle-handler (vui-use-memo (controlled)
                           (lambda (next)
                             (unless controlled
                               (vui-set-state :collapsed next)))))
         (collapsible-props (vui-component 'benedict-vui-tool-use-block--collapsible-props
                             props state toggle-handler)))
    (apply #'benedict-vui-collapsible collapsible-props)))

(vui-defcomponent benedict-vui-tool-use-block (props state)
  :state ((collapsed t))
  :render
  (vui-component 'benedict-vui-tool-use-block--render props state))

(defun benedict-vui-tool-use-block (&rest props)
  "Create a tool use block component node from PROPS."
  (apply #'vui-component 'benedict-vui-tool-use-block props))

(provide 'benedict-vui-tool-use-block)
;;; benedict-vui-tool-use-block.el ends here
