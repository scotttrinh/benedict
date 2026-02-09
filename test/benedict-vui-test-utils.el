;;; benedict-vui-test-utils.el --- Helpers for VUI behavior tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers for rendering and interacting with VUI components in tests.

;;; Code:

(require 'cl-lib)
(require 'widget)
(require 'vui)
(require 'benedict-provider-fake)
(require 'benedict-session)
(require 'benedict-vui-compose-field)
(require 'benedict-vui-root)

(defmacro with-mounted-vui-root (&rest body)
  "Mount `benedict-vui-root' with fake provider defaults and run BODY.

Binds `session' in BODY so tests can drive session events directly."
  (declare (indent 0) (debug t))
  `(let* ((benedict-session--registry (make-hash-table :test #'equal))
          (session (benedict-session-create :title "test"
                                           :provider 'fake
                                           :model benedict-provider-fake-default-model)))
     (with-mounted-vui-component
         (vui-component 'benedict-vui-root
                        :session session
                        :initial-slices nil
                        :initial-input nil
                        :retain-context nil
                        :register-actions nil
                        :on-slices-change nil
                        :on-provider-click nil
                        :on-submit #'ignore)
       ,@body)))

(defmacro with-mounted-vui-root-script (script &rest body)
  "Mount `benedict-vui-root' with fake provider SCRIPT, then run BODY."
  (declare (indent 1) (debug t))
  `(benedict-provider-fake-with-script ,script
     (with-mounted-vui-root
       ,@body)))

(defmacro with-mounted-vui-component (component &rest body)
  "Mount COMPONENT in a temp buffer, run BODY, then unmount.

Flushes VUI before BODY and after teardown so tests observe settled state."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (let ((mount (vui-mount ,component (buffer-name))))
       (unwind-protect
           (progn
             (vui-flush-sync)
             ,@body)
         (when (and mount (fboundp 'vui-unmount))
           (ignore-errors (vui-unmount mount)))
         (vui-flush-sync)))))

(defun benedict-vui-test--click-button-at (pos)
  "Invoke the button widget at POS."
  (let ((widget (widget-at pos))
        (button (button-at pos)))
    (cond
     (widget (let ((action (widget-get widget :action)))
               (unless action
                 (error "No action on widget at %s" pos))
               (funcall action widget)))
     (button (button-activate button))
     (t (error "No button widget at %s" pos)))))

(defun benedict-vui-test--click-button-labeled (label)
  "Click the first button labeled LABEL in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (if (search-forward label nil t)
        (let ((start (match-beginning 0))
              (end (match-end 0))
              (clicked nil))
          (cl-loop for pos from (max (1- start) (point-min)) to (min (1+ end) (point-max))
                   when (or (widget-at pos) (button-at pos))
                   do (setq clicked t)
                   and do (benedict-vui-test--click-button-at pos)
                   and do (cl-return))
          (unless clicked
            (error "No button widget found for label %s" label)))
      (error "No button labeled %s" label))))

(defun benedict-vui-test--set-first-field (value)
  "Set the first widget field to VALUE and notify."
  (let ((widget (car widget-field-list)))
    (unless widget
      (error "No widget field found in buffer"))
    (widget-value-set widget value)
    (widget-apply widget :notify widget)))

(defun benedict-vui-test--set-input (value)
  "Set VALUE in the first compose field and flush rendering."
  (benedict-vui-test--set-first-field value)
  (vui-flush-sync)
  value)

(defun benedict-vui-test--submit-input (value)
  "Set VALUE in the first compose field, submit, and flush rendering."
  (benedict-vui-test--set-input value)
  (call-interactively #'benedict-vui-compose-field-submit)
  (vui-flush-sync)
  value)

(cl-defun benedict-vui-test--wait-until (predicate &key (timeout 2.0) (interval 0.01))
  "Wait until PREDICATE return non-nil.

Flushes VUI and accepts process output between checks.  Returns non-nil when
PREDICATE succeeds before TIMEOUT seconds, otherwise return nil.
INTERVAL controls the sleep and process-output cadence between checks."
  (let ((deadline (+ (float-time) timeout))
        done)
    (while (and (not done)
                (< (float-time) deadline))
      (vui-flush-sync)
      (setq done (funcall predicate))
      (unless done
        (accept-process-output nil interval)
        (sleep-for interval)))
    done))

(defun benedict-vui-test--wait-for-request-finished (session &optional timeout)
  "Wait until SESSION no longer has an active request.

Return non-nil on success, or nil when TIMEOUT seconds elapse."
  (benedict-vui-test--wait-until
   (lambda ()
     (not (benedict-session-request-active-p session)))
   :timeout (or timeout 2.0)))

(cl-defun benedict-vui-test--assert-text-properties-at (pos &key message-key block-id region-kind)
  "Assert common Benedict text properties at POS in the current buffer.

MESSAGE-KEY checks `benedict-message-key'.
BLOCK-ID checks `benedict-block-id'.
REGION-KIND checks `benedict-region-kind'."
  (let ((text (buffer-string)))
    (when region-kind
      (should (eq (get-text-property pos 'benedict-region-kind text)
                  region-kind)))
    (when message-key
      (should (equal (get-text-property pos 'benedict-message-key text)
                     message-key)))
    (when block-id
      (should (equal (get-text-property pos 'benedict-block-id text)
                     block-id)))))

(cl-defun benedict-vui-test--assert-text-properties-for (needle &key message-key block-id region-kind)
  "Assert common Benedict text properties at NEEDLE's first match.

Signals a failed `should' when NEEDLE cannot be found.  Returns the match
position when assertions succeed.  MESSAGE-KEY, BLOCK-ID, and REGION-KIND
control which properties are asserted."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward needle nil t))
    (let ((pos (match-beginning 0)))
      (benedict-vui-test--assert-text-properties-at
       pos
       :message-key message-key
       :block-id block-id
       :region-kind region-kind)
      pos)))

(provide 'test/benedict-vui-test-utils)
;;; benedict-vui-test-utils.el ends here
