;;; benedict-vui-compose-field.el --- Vui compose field component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Controlled text input for composing messages in Benedict chat.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict)

(defcustom benedict-vui-compose-field-submit-key "C-c C-c"
  "Key sequence for submitting composed text."
  :type 'string
  :group 'benedict)

(defcustom benedict-vui-compose-field-history-prev-key "M-p"
  "Key sequence for navigating to previous history item."
  :type 'string
  :group 'benedict)

(defcustom benedict-vui-compose-field-history-next-key "M-n"
  "Key sequence for navigating to next history item."
  :type 'string
  :group 'benedict)

(defun benedict-vui-compose-field--handle-change (value on-change)
  "Handle field VALUE change, calling ON-CHANGE."
  (when (functionp on-change)
    (funcall on-change value))
  t)

(defun benedict-vui-compose-field--handle-submit (value on-submit)
  "Handle field VALUE submit, calling ON-SUBMIT."
  (when (functionp on-submit)
    (funcall on-submit value))
  t)

(defun benedict-vui-compose-field--navigate-history (direction history-index history on-change)
  "Navigate in DIRECTION (:prev or :next) through HISTORY.
Calls ON-CHANGE with selected history item."
  (let* ((history-len (length history))
         (new-index (pcase direction
                      (:prev
                       (if (= history-index -1)
                           (if (> history-len 0) (1- history-len) -1)
                         (max -1 (1- history-index))))
                      (:next
                       (if (> history-len 0)
                           (if (< history-index (1- history-len))
                               (1+ history-index)
                             history-index)
                         -1))))
         (history-value (when (and (>= new-index 0) (> history-len 0))
                          (nth new-index history))))
    (when (and history-value (not (= new-index history-index)))
      (funcall on-change history-value))
    new-index))

(vui-defcomponent benedict-vui-compose-field (props state)
  :state ((history-index -1))
  :render
  (let* ((value (plist-get props :value))
         (on-change (plist-get props :on-change))
         (on-submit (plist-get props :on-submit))
         (history (plist-get props :history))
         (placeholder (plist-get props :placeholder))
         (size (plist-get props :size))
         (field-key (plist-get props :key))
         (current-history-index (plist-get state :history-index))
         (history-len (length history))
         (submit-key benedict-vui-compose-field-submit-key)
         (history-prev-key benedict-vui-compose-field-history-prev-key)
         (history-next-key benedict-vui-compose-field-history-next-key))
    (vui-use-effect (history)
      (lambda ()
        (let ((map (make-sparse-keymap)))
          (define-key map (kbd submit-key)
            (lambda ()
              (interactive)
              (let ((current-value (or (and field-key (vui-field-value field-key))
                                       value)))
                (benedict-vui-compose-field--handle-submit current-value on-submit))))
          (when history
            (define-key map (kbd history-prev-key)
              (lambda ()
                (interactive)
                (let ((new-index (benedict-vui-compose-field--navigate-history
                                  :prev current-history-index history on-change)))
                  (vui-set-state :history-index new-index))))
            (define-key map (kbd history-next-key)
              (lambda ()
                (interactive)
                (let ((new-index (benedict-vui-compose-field--navigate-history
                                  :next current-history-index history on-change)))
                  (vui-set-state :history-index new-index)))))
          (use-local-map map)))
      (lambda ()
        (use-local-map nil)))
    (vui-field
     :value (or value "")
     :size (or size 80)
     :placeholder placeholder
     :on-change (lambda (new-value)
                  (benedict-vui-compose-field--handle-change new-value on-change)
                  (when (and history (>= current-history-index 0))
                    (vui-set-state :history-index -1)))
     :on-submit (lambda (new-value)
                  (benedict-vui-compose-field--handle-submit new-value on-submit))
     :key field-key)))

(provide 'benedict-vui-compose-field)
;;; benedict-vui-compose-field.el ends here
