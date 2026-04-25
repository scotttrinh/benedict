;;; test/benedict-agent-loop-test.el --- Kernel loop compatibility tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the core-owned loop behavior that replaced session-owned loop
;; orchestration.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-core)

(cl-defun benedict-agent-loop-test--result (&key text tool-calls)
  "Return a strict provider result for loop coverage.
TEXT and TOOL-CALLS are forwarded to `benedict-provider-result-create'."
  (benedict-provider-result-create
   :provider 'fake
   :model "fake-model"
   :text (or text "")
   :tool-calls tool-calls))

(defun benedict-agent-loop-test--dispatch (responses)
  "Return a synchronous fake provider dispatch over RESPONSES."
  (let ((queue responses))
    (lambda (_request &rest callbacks)
      (funcall (plist-get callbacks :on-success) (pop queue)))))

(ert-deftest benedict-loop-core-dispatches-after-tool-calls ()
  "Core dispatches the next provider request after tool results are ready."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (requests 0))
    (let ((session (benedict-core-create-session
                    :provider 'fake
                    :model "fake-model"
                    :approved-capabilities '(project-read)
                    :tools (list (list :id 'tool-a
                                       :capabilities '(project-read)
                                       :fn (lambda (&rest _args) "ok")))
                    :provider-dispatch-fn
                    (lambda (request &rest callbacks)
                      (ignore request)
                      (cl-incf requests)
                      (funcall
                       (plist-get callbacks :on-success)
                       (if (= requests 1)
                           (benedict-agent-loop-test--result
                            :tool-calls '((:id "call-1"
                                           :name tool-a
                                           :arguments nil)))
                         (benedict-agent-loop-test--result :text "done")))))))
      (benedict-core-add-user-input session "Use the tool")
      (benedict-core-run session)
      (should (= 2 requests))
      (should (eq 'idle (benedict-session-run-state session)))
      (should (equal '(user assistant tool assistant)
                     (mapcar #'benedict-message-role
                             (benedict-session-entries-chronological session)))))))

(ert-deftest benedict-loop-core-stops-on-final-assistant-message ()
  "Core returns to idle when the provider response has no tool calls."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-core-create-session
                    :provider 'fake
                    :model "fake-model"
                    :provider-dispatch-fn
                    (benedict-agent-loop-test--dispatch
                     (list (benedict-agent-loop-test--result :text "Done."))))))
      (benedict-core-add-user-input session "Hello")
      (benedict-core-run session)
      (should (eq 'idle (benedict-session-run-state session)))
      (should (eq 'turn-complete (benedict-session-turn-state session)))
      (should-not (benedict-session-outstanding-yields session)))))

(ert-deftest benedict-loop-core-reports-dispatch-needed ()
  "Core emits dispatch-needed when provider/model are missing."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-core-create-session)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type _payload) (push type events)))
      (benedict-core-add-user-input session "Hello")
      (benedict-core-run session)
      (should (eq 'idle (benedict-session-run-state session)))
      (should (memq 'dispatch-needed events)))))

(provide 'test/benedict-agent-loop-test)
;;; benedict-agent-loop-test.el ends here
