;;; benedict-vui-root-test.el --- Tests for VUI root component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI root component.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vui)
(require 'benedict-session)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-root)

(defun benedict-vui-root-test--emit-session-event (session event-type &rest payload)
  "Emit EVENT-TYPE for SESSION with PAYLOAD and flush VUI updates."
  (run-hook-with-args
   'benedict-session-event-hook
   session
   event-type
   payload)
  (vui-flush-sync))

(ert-deftest benedict-vui-root-mount-renders-baseline-layout ()
  "Mounted root renders baseline UI for an empty session."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-root
                     :session nil
                     :initial-slices nil
                     :initial-input nil
                     :retain-context nil
                     :register-actions nil
                     :on-slices-change nil
                     :on-provider-click nil
                     :on-submit #'ignore)
    (let ((text (buffer-string)))
      (should (string-match-p "Chat" text))
      (should (string-match-p "No context" text))
      (should widget-field-list))))

(ert-deftest benedict-vui-root-session-events-update-conversation ()
  "Mounted root reacts to session message events."
  (with-mounted-vui-root
    (should-not (string-match-p "Hello from session" (buffer-string)))
    (benedict-session-add-message session
                                  '(:role user :content "Hello from session"))
    (vui-flush-sync)
    (should (string-match-p "Hello from session" (buffer-string)))))

(ert-deftest benedict-vui-root-draft-started-sets-active-streaming-state ()
  "Draft-started events mark the root as actively streaming."
  (with-mounted-vui-root
    (should-not (string-match-p "ACTIVE" (buffer-string)))
    (benedict-session-start-draft session)
    (vui-flush-sync)
    (should (string-match-p "ACTIVE" (buffer-string)))))

(ert-deftest benedict-vui-root-draft-updated-appends-delta-content ()
  "Draft-updated delta events append streaming content in order."
  (with-mounted-vui-root
    (benedict-session-start-draft session)
    (benedict-session-append-draft session "Hello")
    (vui-flush-sync)
    (benedict-session-append-draft session " world")
    (vui-flush-sync)
    (should (string-match-p "Hello world" (buffer-string)))))

(ert-deftest benedict-vui-root-draft-updated-appends-tool-call-blocks ()
  "Draft-updated tool-call events append tool-use blocks to streaming output."
  (with-mounted-vui-root
    (benedict-session-start-draft session)
    (benedict-session-add-draft-tool-call
     session
     '(:id "call-1" :name "bash" :arguments "pwd"))
    (vui-flush-sync)
    (should (string-match-p "Tool: bash" (buffer-string)))))

(ert-deftest benedict-vui-root-draft-finalized-clears-streaming-indicator ()
  "Draft-finalized events clear active streaming state in the root UI."
  (with-mounted-vui-root
    (benedict-session-start-draft session)
    (benedict-session-append-draft session "Streaming")
    (vui-flush-sync)
    (should (string-match-p "ACTIVE" (buffer-string)))
    (benedict-session-finalize-draft session)
    (vui-flush-sync)
    (should-not (string-match-p "ACTIVE" (buffer-string)))))

(ert-deftest benedict-vui-root-state-changed-manages-error-transitions ()
  "State-changed events set and clear root error text as states transition."
  (with-mounted-vui-root
    (benedict-session-set-state session 'error)
    (vui-flush-sync)
    (should (string-match-p "Session error: idle -> error" (buffer-string)))
    (benedict-session-start-draft session)
    (vui-flush-sync)
    (benedict-session-set-state session 'idle)
    (vui-flush-sync)
    (should-not (string-match-p "Session error:" (buffer-string)))))

(ert-deftest benedict-vui-root-request-completed-success-updates-header-and-usage ()
  "Successful request-completed events update provider/model/usage and clear errors."
  (with-mounted-vui-root
    (benedict-vui-root-test--emit-session-event
     session
     'request-completed
     :success nil
     :error '(:message "Transient boom"))
    (should (string-match-p "Transient boom" (buffer-string)))
    (benedict-vui-root-test--emit-session-event
     session
     'request-completed
     :success t
     :result '(:provider anthropic
               :model "vendor/claude-test"
               :usage (:total 321 :cost 0.25)))
    (let ((text (buffer-string)))
      (should (string-match-p "ANT" text))
      (should (string-match-p "claude-test" text))
      (should (string-match-p "321 tokens" text))
      (should-not (string-match-p "Transient boom" text)))))

(ert-deftest benedict-vui-root-request-completed-failure-renders-error ()
  "Failed request-completed events surface provider error text in the status bar."
  (with-mounted-vui-root
    (benedict-vui-root-test--emit-session-event
     session
     'request-completed
     :success nil
     :error '(:message "Network timeout"))
    (should (string-match-p "Network timeout" (buffer-string)))))

(ert-deftest benedict-vui-root-submit-clears-input-and-appends-history ()
  "Successful submit clears compose input and appends prompt history."
  (let (updates)
    (cl-letf (((symbol-function 'vui-set-state)
               (lambda (key value)
                 (push (cons key value) updates))))
      (should (benedict-vui-root--submit "prompt"
                                         (lambda (_) t)
                                         nil)))
    (let ((history-update (alist-get :history updates))
          (input-update (alist-get :input-text updates))
          (slices-update (alist-get :slices updates)))
      (should (functionp history-update))
      (should (equal (funcall history-update '("older"))
                     '("older" "prompt")))
      (should (equal input-update ""))
      (should (null slices-update)))))

(ert-deftest benedict-vui-root-submit-retain-context-nil-clears-slices ()
  "Successful submit clears slices when `retain-context' is nil."
  (let (updates)
    (cl-letf (((symbol-function 'vui-set-state)
               (lambda (key value)
                 (push (cons key value) updates))))
      (should (benedict-vui-root--submit "prompt"
                                         (lambda (_) t)
                                         nil)))
    (should (assq :slices updates))))

(ert-deftest benedict-vui-root-submit-retain-context-t-keeps-slices ()
  "Successful submit keeps slices when `retain-context' is non-nil."
  (let (updates)
    (cl-letf (((symbol-function 'vui-set-state)
               (lambda (key value)
                 (push (cons key value) updates))))
      (should (benedict-vui-root--submit "prompt"
                                         (lambda (_) t)
                                         t)))
    (should-not (assq :slices updates))))

(ert-deftest benedict-vui-root-toggle-collapsed-block-list-representation ()
  "Toggling collapsed blocks behaves correctly for list state."
  (let ((collapsed nil))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-a"))
    (should (equal collapsed '("block-a")))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-b"))
    (should (equal collapsed '("block-b" "block-a")))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-a"))
    (should (equal collapsed '("block-b")))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-b" t))
    (should (equal collapsed '("block-b")))
    (should (equal (benedict-vui-root--toggle-collapsed-block collapsed nil)
                   collapsed))))

(ert-deftest benedict-vui-root-toggle-collapsed-block-hash-table-representation ()
  "Toggling collapsed blocks behaves correctly for hash-table state."
  (let ((collapsed (make-hash-table :test #'equal)))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-a"))
    (should (gethash "block-a" collapsed))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-b"))
    (should (gethash "block-b" collapsed))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-a"))
    (should-not (gethash "block-a" collapsed))
    (setq collapsed (benedict-vui-root--toggle-collapsed-block collapsed "block-b" t))
    (should (gethash "block-b" collapsed))
    (let ((same collapsed))
      (should (eq (benedict-vui-root--toggle-collapsed-block same nil) same)))))

(provide 'test/benedict-vui-root-test)
;;; benedict-vui-root-test.el ends here
