;;; benedict-vui-tool-result-block.el --- Vui tool result block component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders tool execution results in a collapsible block with optional actions.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'subr-x)
(require 'vui)
(require 'benedict-vui-badge)
(require 'benedict-vui-collapsible)

(defconst benedict-vui-tool-result-block--truncate-limit 500
  "Maximum length of tool result content before truncation.")

(defun benedict-vui-tool-result-block--name-string (name)
  "Return a human-readable string for tool NAME."
  (cond
   ((symbolp name) (symbol-name name))
   ((stringp name) name)
   ((null name) "Tool")
   (t (format "%s" name))))

(defun benedict-vui-tool-result-block--tool-name (result)
  "Return the tool name string from RESULT plist."
  (benedict-vui-tool-result-block--name-string
   (or (plist-get result :name)
       (plist-get result :tool)
       (plist-get result :id)
       "Tool")))

(defun benedict-vui-tool-result-block--normalize-status (status)
  "Return STATUS coerced into a canonical symbol."
  (cond
   ((null status) 'success)
   ((keywordp status) (intern (substring (symbol-name status) 1)))
   ((symbolp status)
    (pcase status
      ('ok 'success)
      ('error 'failure)
      ('pending 'running)
      ('in-progress 'running)
      (_ status)))
   ((stringp status)
    (let ((normalized (replace-regexp-in-string
                       "[[:space:]]+" "-" (downcase status))))
      (benedict-vui-tool-result-block--normalize-status (intern normalized))))
   (t 'success)))

(defun benedict-vui-tool-result-block--value-string (value)
  "Return VALUE formatted for tool result display."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (string-trim-right (pp-to-string value)))))

(defun benedict-vui-tool-result-block--ui (result)
  "Return the :ui plist from RESULT when present."
  (and (listp result)
       (plist-member result :ui)
       (plist-get result :ui)))

(defun benedict-vui-tool-result-block--result-status (props result)
  "Return normalized status for PROPS and RESULT."
  (let* ((ui (benedict-vui-tool-result-block--ui result))
         (status (or (plist-get props :status)
                     (and (listp result) (plist-get result :status))
                     (and (listp result)
                          (plist-get (plist-get result :metadata) :status))
                     (and (listp ui) (plist-get ui :state))))
         (error-info (or (and (listp result) (plist-get result :error))
                         (and (listp result)
                              (plist-get (plist-get result :metadata) :error)))))
    (benedict-vui-tool-result-block--normalize-status
     (if error-info 'failure status))))

(defun benedict-vui-tool-result-block--normalize-actions (actions)
  "Return ACTIONS filtered to valid action plists."
  (when (listp actions)
    (cl-remove-if-not
     (lambda (action)
       (and (listp action)
            (stringp (plist-get action :label))
            (functionp (plist-get action :handler))))
     actions)))

(defun benedict-vui-tool-result-block--resolve-actions (props result)
  "Return validated action plists from PROPS or RESULT UI."
  (let* ((direct (plist-get props :actions))
         (ui (benedict-vui-tool-result-block--ui result))
         (ui-actions (and (listp ui) (plist-get ui :actions))))
    (benedict-vui-tool-result-block--normalize-actions (or direct ui-actions))))

(defun benedict-vui-tool-result-block--header-title (result)
  "Return header title for RESULT."
  (let* ((ui (benedict-vui-tool-result-block--ui result))
         (ui-header (and (listp ui) (plist-get ui :header))))
    (if (and (stringp ui-header) (not (string-empty-p ui-header)))
        ui-header
      (format "Result: %s" (benedict-vui-tool-result-block--tool-name result)))))

(defun benedict-vui-tool-result-block--header (result status)
  "Return the tool result header node for RESULT and STATUS."
  (vui-hstack
   (vui-component 'benedict-vui-badge :status status)
   (vui-text (propertize (benedict-vui-tool-result-block--header-title result)
                         'face 'benedict-chat-tool-label))))

(defun benedict-vui-tool-result-block--body-text (result)
  "Return formatted body text for RESULT."
  (let* ((ui (benedict-vui-tool-result-block--ui result))
         (ui-body (and (listp ui) (plist-get ui :body)))
         (text (cond
                ((and (stringp ui-body) (not (string-empty-p ui-body))) ui-body)
                ((and (listp result) (plist-member result :content))
                 (plist-get result :content))
                ((and (listp result) (plist-member result :message))
                 (plist-get result :message))
                ((and (listp result) (plist-member result :text))
                 (plist-get result :text))
                ((stringp result) result)
                ((null result) "Tool returned no output.")
                (t (benedict-vui-tool-result-block--value-string result)))))
    (if (and text (not (string-empty-p text)))
        text
      "Tool returned no output.")))

(defun benedict-vui-tool-result-block--truncate (text limit)
  "Return TEXT truncated to LIMIT and whether truncation occurred."
  (if (and text limit (> (length text) limit))
      (cons (concat (substring text 0 limit) "... [truncated]") t)
    (cons text nil)))

(defun benedict-vui-tool-result-block--propertize (text status &optional message-key block-id)
  "Return TEXT with tool result text properties applied.

STATUS controls error styling for failures.
MESSAGE-KEY and BLOCK-ID are stored as text properties when provided."
  (let ((value (if (stringp text) text (format "%s" text))))
    (if (eq status 'failure)
        (propertize value
                    'benedict-region-kind 'tool-ui
                    'benedict-message-key message-key
                    'benedict-block-id block-id
                    'face 'benedict-chat-tool-error)
      (propertize value
                  'benedict-region-kind 'tool-ui
                  'benedict-message-key message-key
                  'benedict-block-id block-id))))

(defun benedict-vui-tool-result-block--actions-node (actions)
  "Return a node containing action buttons for ACTIONS."
  (let ((nodes
         (delq nil
               (mapcar (lambda (action)
                         (let ((label (plist-get action :label))
                               (handler (plist-get action :handler)))
                           (when (and (stringp label) (functionp handler))
                             (vui-button label :on-click handler))))
                       actions))))
    (when nodes
      (apply #'vui-hstack nodes))))

(defun benedict-vui-tool-result-block--content-node
    (text truncated expanded toggle-expand actions status message-key block-id)
  "Return the tool result content node for TEXT and ACTIONS.

TRUNCATED and EXPANDED control expansion UI, using TOGGLE-EXPAND.
STATUS determines error styling."
  (let* ((body-node (vui-text (benedict-vui-tool-result-block--propertize
                               text status message-key block-id)))
         (toggle-node (when truncated
                        (vui-button (if expanded "Show less" "Show more")
                                    :on-click toggle-expand)))
         (actions-node (benedict-vui-tool-result-block--actions-node actions))
         (nodes (delq nil (list body-node toggle-node actions-node))))
    (apply #'vui-vstack nodes)))

(defun benedict-vui-tool-result-block--controlled-p (props)
  "Return non-nil when PROPS includes a :collapsed key."
  (not (null (plist-member props :collapsed))))

(defun benedict-vui-tool-result-block--collapsed-p (props state)
  "Return non-nil when PROPS/STATE indicate collapse."
  (if (benedict-vui-tool-result-block--controlled-p props)
      (plist-get props :collapsed)
    (plist-get state :collapsed)))

(defun benedict-vui-tool-result-block--collapsible-props
    (props state toggle-handler content-node header-node)
  "Return collapsible props for PROPS/STATE and TOGGLE-HANDLER.

CONTENT-NODE and HEADER-NODE are precomputed VUI nodes."
  (let ((collapsed (benedict-vui-tool-result-block--collapsed-p props state)))
    (list :collapsed collapsed
          :on-toggle toggle-handler
          :header (lambda () header-node)
          :content (lambda () content-node))))

(vui-defcomponent benedict-vui-tool-result-block (result status actions on-toggle message-key block-id collapsed)
  :state ((collapsed-state t)
          (expanded nil))
  :render
  (let* ((controlled (not (null (plist-member --props-- :collapsed))))
         (is-collapsed (if controlled collapsed collapsed-state))
         (actual-status (benedict-vui-tool-result-block--result-status --props-- result))
         (body-text (benedict-vui-tool-result-block--body-text result))
         (actual-actions (benedict-vui-tool-result-block--resolve-actions --props-- result))
         (truncation (benedict-vui-tool-result-block--truncate
                      body-text
                      benedict-vui-tool-result-block--truncate-limit))
         (truncated (cdr truncation))
         (display-text (if (and truncated (not expanded))
                           (car truncation)
                         body-text))
         (body-ref (vui-use-ref body-text))
         (toggle-collapse (lambda (next)
                            (unless controlled
                              (vui-set-state :collapsed-state next))
                            (when (functionp on-toggle)
                              (funcall on-toggle next))))
         (toggle-expand (lambda (&rest _)
                          (vui-set-state :expanded (not expanded))))
         (header-node (benedict-vui-tool-result-block--header result actual-status))
         (content-node (benedict-vui-tool-result-block--content-node
                        display-text truncated expanded toggle-expand actual-actions actual-status message-key block-id)))
    (vui-use-effect (body-text)
      (let ((prev (car body-ref)))
        (unless (equal prev body-text)
          (setcar body-ref body-text)
          (vui-set-state :expanded nil)))
      nil)
    (vui-component 'benedict-vui-collapsible
      :collapsed is-collapsed
      :on-toggle toggle-collapse
      :header (lambda () header-node)
      :content (lambda () content-node))))

(provide 'benedict-vui-tool-result-block)
;;; benedict-vui-tool-result-block.el ends here
