;;; benedict-vui-thinking-block.el --- Vui thinking block component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders assistant thinking content in a collapsible block.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict-vui-badge)
(require 'benedict-vui-collapsible)

(defconst benedict-vui-thinking-block--encrypted-placeholder
  "[Encrypted reasoning block]"
  "Placeholder text for encrypted reasoning blocks.")

(defun benedict-vui-thinking-block--normalize-string (value)
  "Return VALUE as a string, treating nil as empty."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (format "%s" value))))

(defun benedict-vui-thinking-block--normalize-seq (value)
  "Return VALUE coerced into a list."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((vectorp value) (append value nil))
   (t (list value))))

(defun benedict-vui-thinking-block--alist-to-plist (alist)
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

(defun benedict-vui-thinking-block--normalize-entry (entry)
  "Normalize a single thinking ENTRY into a plist."
  (cond
   ((null entry) nil)
   ((stringp entry) (list :text entry))
   ((listp entry)
    (let* ((plist (if (and (consp (car entry))
                           (not (keywordp (caar entry))))
                      (vui-component 'benedict-vui-thinking-block--alist-to-plist entry)
                    entry))
           (result (copy-sequence plist)))
      (when-let ((chunks (plist-get result :chunks)))
        (plist-put result :chunks (vui-component 'benedict-vui-thinking-block--normalize-seq chunks)))
      result))
   (t nil)))

(defun benedict-vui-thinking-block--normalize-payload (thinking)
  "Normalize THINKING payloads into a list of detail plists."
  (cond
   ((null thinking) nil)
   ((stringp thinking)
    (list (vui-component 'benedict-vui-thinking-block--normalize-entry thinking)))
   ((vectorp thinking)
    (vui-component 'benedict-vui-thinking-block--normalize-payload (append thinking nil)))
   ((and (listp thinking)
         (cl-every #'stringp thinking))
    (list (vui-component 'benedict-vui-thinking-block--normalize-entry
           (string-join thinking "\n\n"))))
   ((listp thinking)
    (delq nil (mapcar #'benedict-vui-thinking-block--normalize-entry thinking)))
   (t nil)))

(defun benedict-vui-thinking-block--detail-text (detail)
  "Return display text for thinking DETAIL plist."
  (let ((text (or (plist-get detail :text)
                  (plist-get detail :summary))))
    (cond
     (text (vui-component 'benedict-vui-thinking-block--normalize-string text))
     ((plist-get detail :data)
      (let ((data (vui-component 'benedict-vui-thinking-block--normalize-string
                   (plist-get detail :data))))
        (if (string-empty-p data)
            benedict-vui-thinking-block--encrypted-placeholder
          (format "%s\n%s"
                  benedict-vui-thinking-block--encrypted-placeholder
                  data))))
     ((plist-get detail :chunks)
      (mapconcat #'benedict-vui-thinking-block--normalize-string
                 (vui-component 'benedict-vui-thinking-block--normalize-seq
                  (plist-get detail :chunks))
                 ""))
     (t ""))))

(defun benedict-vui-thinking-block--content-text (thinking)
  "Return combined text for THINKING payload."
  (let ((details (vui-component 'benedict-vui-thinking-block--normalize-payload thinking)))
    (mapconcat #'benedict-vui-thinking-block--detail-text details "\n\n")))

(defun benedict-vui-thinking-block--propertize (content)
  "Return CONTENT with thinking text properties applied."
  (propertize (vui-component 'benedict-vui-thinking-block--normalize-string content)
              'benedict-region-kind 'thinking
              'face 'benedict-chat-thinking))

(defun benedict-vui-thinking-block--controlled-p (props)
  "Return non-nil when PROPS includes a :collapsed key."
  (not (null (plist-member props :collapsed))))

(defun benedict-vui-thinking-block--collapsed-p (props state)
  "Return non-nil when PROPS/STATE indicate collapse."
  (if (vui-component 'benedict-vui-thinking-block--controlled-p props)
      (plist-get props :collapsed)
    (plist-get state :collapsed)))

(defun benedict-vui-thinking-block--header ()
  "Return the thinking block header content."
  (vui-hstack
   (vui-component 'benedict-vui-badge :status 'thinking
                       :theme 'benedict-chat-thinking)))

(defun benedict-vui-thinking-block--content (thinking)
  "Return the thinking block content node for THINKING payload."
  (vui-text (vui-component 'benedict-vui-thinking-block--propertize
             (vui-component 'benedict-vui-thinking-block--content-text thinking))))

(defun benedict-vui-thinking-block--collapsible-props (props state toggle-handler)
  "Return collapsible props for PROPS/STATE and TOGGLE-HANDLER."
  (let* ((thinking (plist-get props :thinking-data))
         (collapsed (vui-component 'benedict-vui-thinking-block--collapsed-p props state)))
    (list :collapsed collapsed
          :on-toggle toggle-handler
          :header #'benedict-vui-thinking-block--header
          :content (lambda ()
                     (vui-component 'benedict-vui-thinking-block--content thinking)))))

(defun benedict-vui-thinking-block--render (props state)
  "Return the rendered thinking block for PROPS/STATE."
  (let* ((controlled (vui-component 'benedict-vui-thinking-block--controlled-p props))
         (toggle-handler (vui-use-memo (controlled)
                           (lambda (next)
                             (unless controlled
                               (vui-set-state :collapsed next)))))
         (collapsible-props (vui-component 'benedict-vui-thinking-block--collapsible-props
                             props state toggle-handler)))
    (apply #'benedict-vui-collapsible collapsible-props)))

(vui-defcomponent benedict-vui-thinking-block (props state)
  :state ((collapsed t))
  :render
  (vui-component 'benedict-vui-thinking-block--render props state))

(defun benedict-vui-thinking-block (&rest props)
  "Create a thinking block component node from PROPS."
  (apply #'vui-component 'benedict-vui-thinking-block props))

(provide 'benedict-vui-thinking-block)
;;; benedict-vui-thinking-block.el ends here
