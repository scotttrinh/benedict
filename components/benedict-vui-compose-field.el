;;; benedict-vui-compose-field.el --- Vui compose field component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Controlled text input for composing messages in Benedict chat.

;;; Code:

(require 'cl-lib)
(require 'vui)
(require 'benedict)

(defvar-local benedict-vui-compose-field--field-key nil
  "The field key for accessing compose field value.")

(defvar-local benedict-vui-compose-field--on-submit nil
  "Callback for submit action.")

(defvar-local benedict-vui-compose-field--on-change nil
  "Callback for value changes.")

(defvar-local benedict-vui-compose-field--history nil
  "History list for navigation.")

(defvar-local benedict-vui-compose-field--history-index -1
  "Current history position.")

(defvar benedict-vui-compose-field-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'benedict-vui-compose-field-submit)
    (define-key map (kbd "M-p") #'benedict-vui-compose-field-history-prev)
    (define-key map (kbd "M-n") #'benedict-vui-compose-field-history-next)
    map)
  "Keymap for compose field interactions.")

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
  "Navigate in DIRECTION (:prev or :next) through HISTORY from HISTORY-INDEX.
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
    (when (and history-value (not (= new-index history-index))
               on-change)
      (funcall on-change history-value))
    new-index))

(defun benedict-vui-compose-field-submit ()
  "Submit current compose field value."
  (interactive)
  (when (and benedict-vui-compose-field--on-submit
             benedict-vui-compose-field--field-key)
    (let ((value (vui-field-value benedict-vui-compose-field--field-key)))
      (funcall benedict-vui-compose-field--on-submit value))))

(defun benedict-vui-compose-field-history-prev ()
  "Navigate to previous history item."
  (interactive)
  (when benedict-vui-compose-field--history
    (let* ((current-index benedict-vui-compose-field--history-index)
           (new-index (benedict-vui-compose-field--navigate-history
                      :prev current-index benedict-vui-compose-field--history
                      benedict-vui-compose-field--on-change)))
      (setq benedict-vui-compose-field--history-index new-index))))

(defun benedict-vui-compose-field-history-next ()
  "Navigate to next history item."
  (interactive)
  (when benedict-vui-compose-field--history
    (let* ((current-index benedict-vui-compose-field--history-index)
           (new-index (benedict-vui-compose-field--navigate-history
                      :next current-index benedict-vui-compose-field--history
                      benedict-vui-compose-field--on-change)))
      (setq benedict-vui-compose-field--history-index new-index))))

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
         (current-history-index (plist-get state :history-index)))
    (vui-use-effect ((list on-submit on-change history field-key))
      (setq benedict-vui-compose-field--field-key field-key)
      (setq benedict-vui-compose-field--on-submit on-submit)
      (setq benedict-vui-compose-field--on-change on-change)
      (setq benedict-vui-compose-field--history history)
      (lambda ()
        (setq benedict-vui-compose-field--field-key nil)
        (setq benedict-vui-compose-field--on-submit nil)
        (setq benedict-vui-compose-field--on-change nil)
        (setq benedict-vui-compose-field--history nil)))
    (vui-use-effect (current-history-index)
      (setq benedict-vui-compose-field--history-index current-history-index)
      (lambda ()
        (setq benedict-vui-compose-field--history-index -1)))
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
