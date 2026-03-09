;;; benedict-vui-audit-log.el --- Vui audit log panel -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders harness audit entries inside the chat buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'vui)
(require 'benedict-vui-collapsible)

(defcustom benedict-vui-audit-log-max-visible 8
  "Maximum number of audit entries rendered in the audit panel."
  :type 'integer
  :group 'benedict)

(defun benedict-vui-audit-log--entry-label (entry)
  "Return a concise label for audit ENTRY."
  (let ((phase (plist-get entry :phase))
        (decision (plist-get entry :decision))
        (tool-id (plist-get entry :tool-id))
        (policy (plist-get entry :policy)))
    (string-trim
     (format "%s %s %s %s"
             (or phase "audit")
             (or policy "")
             (or tool-id "")
             (or decision "")))))

(defun benedict-vui-audit-log--entry-detail (entry)
  "Return descriptive detail for audit ENTRY."
  (or (plist-get entry :message)
      (when-let ((scope (plist-get entry :scope-request)))
        (format "Scope request: %S" scope))
      (when-let ((status (plist-get entry :status)))
        (format "Status: %s" status))
      ""))

(vui-defcomponent benedict-vui-audit-log (entries collapsed on-toggle)
  "Render harness audit ENTRIES in a collapsible panel."
  :render
  (when (consp entries)
    (let* ((visible (last entries (min (length entries)
                                       benedict-vui-audit-log-max-visible)))
           (header (format "Audit Trail (%d)" (length entries)))
           (content
            (apply #'vui-vstack
                   (cl-mapcan
                    (lambda (entry)
                      (list
                       (vui-text (benedict-vui-audit-log--entry-label entry)
                                 :face 'benedict-chat-tool-label)
                       (vui-text (benedict-vui-audit-log--entry-detail entry)
                                 :face 'benedict-chat-system)))
                    visible))))
      (vui-component 'benedict-vui-collapsible
        :collapsed collapsed
        :on-toggle on-toggle
        :header (lambda () (vui-text header :face 'benedict-chat-header))
        :content (lambda () content)))))

(provide 'benedict-vui-audit-log)
;;; benedict-vui-audit-log.el ends here
