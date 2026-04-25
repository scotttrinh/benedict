;;; benedict-vui-root-test.el --- Tests for VUI root component -*- lexical-binding: t; -*-

;;; Commentary:
;; Focused tests for root-only state wiring and controls.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vui)
(require 'benedict-message)
(require 'benedict-provider)
(require 'benedict-session)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-root)

(defun benedict-vui-root-test--emit-session-event (session event-type &rest payload)
  "Emit EVENT-TYPE for SESSION with PAYLOAD and then flush VUI state."
  (run-hook-with-args
   'benedict-session-event-hook
   session
   event-type
   payload)
  (vui-flush-sync))

(defun benedict-vui-root-test--set-run-state (session state)
  "Set SESSION run STATE and emit the matching event."
  (let ((old (benedict-session-run-state session)))
    (setf (benedict-session-run-state session) state)
    (benedict-vui-root-test--emit-session-event
     session 'state-changed :axis 'run :old old :new state)))

(ert-deftest benedict-vui-root-mount-renders-baseline-layout ()
  "Mounted root renders the empty-session baseline without stray widgets."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-root
                     :session nil
                     :register-actions nil
                     :on-provider-click nil
                     :on-continue-checkpoint nil
                     :on-stop-checkpoint nil
                     :on-approve-approval nil
                     :on-deny-approval nil)
    (let ((text (buffer-string)))
      (should (string-match-p "Chat" text))
      (should-not (string-match-p "No context" text))
      (should-not widget-field-list))))

(ert-deftest benedict-vui-root-mount-renders-session-metadata-panel ()
  "Mounted root surfaces session metadata from the attached session."
  (let ((benedict-session--registry (make-hash-table :test #'equal)))
    (let ((session (benedict-session-create :title "metadata"
                                            :provider 'fake
                                            :model "fake/model"
                                            :root default-directory
                                            :meta (list :instruction-sources
                                                        '("AGENTS.md" ".wigg/specs/03_ui_ux.md")
                                                        :store-path "/tmp/benedict/session-1"
                                                        :last-saved-at (current-time)))))
      (with-mounted-vui-component
          (vui-component 'benedict-vui-root
                         :session session
                         :register-actions nil
                         :on-provider-click nil
                         :on-continue-checkpoint nil
                         :on-stop-checkpoint nil
                         :on-approve-approval nil
                         :on-deny-approval nil)
        (let ((text (buffer-string)))
          (should (string-match-p "Session Context" text))
          (should (string-match-p "Session:" text))
          (should (string-match-p "Instructions: AGENTS.md, \\.wigg/specs/03_ui_ux.md" text))
          (should (string-match-p "/tmp/benedict/session-1" text)))))))

(ert-deftest benedict-vui-root-session-events-drive-mounted-lifecycle ()
  "Mounted root follows the canonical session event flow."
  (with-mounted-vui-root
    (should-not (string-match-p "Hello from session" (buffer-string)))
    (benedict-session-add-message session
                                  (benedict-message-user-text "Hello from session"))
    (vui-flush-sync)
    (should (string-match-p "Hello from session" (buffer-string)))
    (should-not (string-match-p "ACTIVE" (buffer-string)))
    (benedict-session-start-draft session)
    (benedict-session-append-draft session "Hello")
    (vui-flush-sync)
    (should (string-match-p "ACTIVE" (buffer-string)))
    (should (string-match-p "Hello" (buffer-string)))
    (benedict-session-append-draft session " world")
    (benedict-session-add-draft-tool-call
     session
     '(:id "call-1" :name "bash" :arguments "pwd"))
    (vui-flush-sync)
    (let ((text (buffer-string)))
      (should (string-match-p "Hello world" text))
      (should (string-match-p "Tool: bash" text)))
    (benedict-session-finalize-draft session)
    (vui-flush-sync)
    (should-not (string-match-p "ACTIVE" (buffer-string)))))

(ert-deftest benedict-vui-root-state-and-request-events-update-status ()
  "Mounted root clears errors and updates header/status details from session events."
  (with-mounted-vui-root
    (benedict-vui-root-test--set-run-state session 'error)
    (vui-flush-sync)
    (should (string-match-p "Session error: idle -> error" (buffer-string)))
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
     :result (benedict-provider-result-create
              :provider 'anthropic
              :model "vendor/claude-test"
              :usage '(:total 321 :cost 0.25)))
    (let ((text (buffer-string)))
      (should (string-match-p "ANT" text))
      (should (string-match-p "claude-test" text))
      (should (string-match-p "321 tokens" text))
      (should-not (string-match-p "Transient boom" text)))
    (benedict-vui-root-test--set-run-state session 'running)
    (benedict-vui-root-test--set-run-state session 'idle)
    (vui-flush-sync)
    (should-not (string-match-p "Session error:" (buffer-string)))))

(ert-deftest benedict-vui-root-tool-audit-events-render-audit-panel ()
  "Tool audit events surface a visible audit trail."
  (with-mounted-vui-root
    (benedict-vui-root-test--emit-session-event
     session
     'tool-audit
     :audit '(:phase authorization
              :policy allow
              :tool-id read-file
              :decision approved))
    (let ((text (buffer-string)))
      (should (string-match-p "Audit Trail (1)" text))
      (should (string-match-p "authorization allow read-file approved" text)))))

(ert-deftest benedict-vui-root-checkpoint-block-renders-buttons-and-calls-actions ()
  "Checkpoint events render persistent controls that call their handlers."
  (let ((continued nil)
        (stopped nil)
        (benedict-session--registry (make-hash-table :test #'equal))
        (session (benedict-session-create :title "checkpoint"
                                          :provider 'fake
                                          :model "fake/model")))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-root
                       :session session
                       :register-actions nil
                       :on-provider-click nil
                       :on-continue-checkpoint (lambda (&rest _) (setq continued t))
                       :on-stop-checkpoint (lambda (&rest _) (setq stopped t))
                       :on-approve-approval nil
                       :on-deny-approval nil)
      (benedict-vui-root-test--emit-session-event
       session
       'checkpoint-requested
       :reason 'turn-limit
       :turn-count 3
       :limit 3)
      (should (string-match-p "Checkpoint" (buffer-string)))
      (should (string-match-p "Continue" (buffer-string)))
      (should (string-match-p "Stop" (buffer-string)))
      (benedict-vui-test--click-button-labeled "Continue")
      (should continued)
      (benedict-vui-test--click-button-labeled "Stop")
      (should stopped))))

(ert-deftest benedict-vui-root-approval-block-renders-buttons-and-calls-actions ()
  "Approval events render persistent controls that call their handlers."
  (let ((approved nil)
        (denied nil)
        (benedict-session--registry (make-hash-table :test #'equal))
        (session (benedict-session-create :title "approval"
                                          :provider 'fake
                                          :model "fake/model")))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-root
                       :session session
                       :register-actions nil
                       :on-provider-click nil
                       :on-continue-checkpoint nil
                       :on-stop-checkpoint nil
                       :on-approve-approval (lambda (&rest _) (setq approved t))
                       :on-deny-approval (lambda (&rest _) (setq denied t)))
      (benedict-vui-root-test--emit-session-event
       session
       'approval-requested
       :yield '(:type approval-request
                :tool-id write
                :approval confirm
                :args (:path "README.org")))
      (should (string-match-p "Approval request: write" (buffer-string)))
      (should (string-match-p "Approve" (buffer-string)))
      (should (string-match-p "Deny" (buffer-string)))
      (benedict-vui-test--click-button-labeled "Approve")
      (should approved)
      (benedict-vui-test--click-button-labeled "Deny")
      (should denied))))

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
