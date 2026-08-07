;;; benedict-headless-test.el --- Headless frontend boundary check  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 11.1's corollary: a second frontend, written independently against
;; the same public API, is the falsifiable form of "the chat UI needs no private
;; kernel access."  These tests also pin the claim that `ui/' is not shaped
;; around vui -- nothing here loads it.

;;; Code:

(require 'ert)
(require 'test-helper)

(defmacro benedict-headless-test--installed (&rest body)
  "Run BODY with the headless frontend subscribed, unsubscribing afterwards."
  (declare (indent 0) (debug t))
  `(unwind-protect (progn (benedict-headless-install) ,@body)
     (benedict-headless-uninstall)))

(defun benedict-headless-test--echo-tool ()
  "Register a tool echoing its `text' argument."
  (benedict-tool-register
   (benedict-tool-create
    :id 'benedict-headless-test-echo
    :description "Echo the text back."
    :parameters '((text :type string :required t))
    :sync t
    :handler (lambda (invocation)
               (benedict-tool-result
                :content (benedict-tool-arg invocation :text))))))

(ert-deftest benedict-headless-renders-a-multi-turn-run ()
  "A run with a tool call renders every entry, in order, and reports finishing."
  (benedict-test-with-clean-registries
    (benedict-headless-test--echo-tool)
    (benedict-headless-test--installed
      (benedict-test-with-manual-defer
        (let* ((session (benedict-test-session
                         '(((:text "Let me check.")
                            (:tool-call benedict-headless-test-echo (:text "pong")))
                           ((:text "It said pong.")))
                         :tools '(benedict-headless-test-echo)))
               (finished nil)
               (collect (benedict-headless-run
                         session "Hello"
                         (lambda (_session) (setq finished t)))))
          (benedict-test-drain)
          (should finished)
          (let ((text (funcall collect)))
            (should (string-match-p "user:" text))
            (should (string-match-p "Hello" text))
            (should (string-match-p "Let me check." text))
            (should (string-match-p "tool benedict-headless-test-echo" text))
            (should (string-match-p "result benedict-headless-test-echo" text))
            (should (string-match-p "It said pong." text))
            ;; Order is the claim worth pinning: a transcript rendered out of
            ;; order is worse than one rendered late.
            (should (< (string-match "Let me check." text)
                       (string-match "It said pong." text)))))))))

(ert-deftest benedict-headless-reports-an-aborted-run ()
  "An aborted run still renders a terminal entry and still finishes."
  (benedict-test-with-clean-registries
    (benedict-headless-test--installed
      (benedict-test-with-manual-defer
        (let* ((session (benedict-test-session
                         '(((:type :start)
                            (:type :block-start :index 0 :block-type text)
                            (:type :block-delta :index 0 :delta "Partial")
                            (:type :block-delta :index 0 :delta " more")
                            (:type :block-end :index 0)
                            (:type :done :reason stop)))))
               (stop-reason 'unset)
               (collect (benedict-headless-run
                         session "go"
                         (lambda (session)
                           (setq stop-reason
                                 (benedict-session-stop-reason session))))))
          (should (benedict-test-run-until
                   (lambda ()
                     (benedict-session-streaming-entry session))))
          (benedict-session-abort session)
          (benedict-test-drain)
          (should (eq (benedict-session-state session) 'idle))
          (should (eq stop-reason 'aborted))
          (should (string-match-p "aborted" (funcall collect))))))))

(ert-deftest benedict-headless-ignores-sessions-with-no-sink ()
  "A session that never attached renders nothing, so handlers may be global."
  (benedict-test-with-clean-registries
    (benedict-headless-test--installed
      (benedict-test-with-manual-defer
        (let* ((attached (benedict-test-session '(((:text "Rendered.")))))
               (detached (benedict-test-session '(((:text "Unrendered.")))))
               (collect (benedict-headless-run attached "one")))
          (benedict-session-submit detached "two")
          (benedict-test-drain)
          (let ((text (funcall collect)))
            (should (string-match-p "Rendered." text))
            (should-not (string-match-p "Unrendered." text))))))))

(ert-deftest benedict-headless-renders-every-block-type ()
  "Every block type of SPEC-001 4.5 has a representation.

A frontend that silently omits a block type turns a rendering gap into an
apparent gap in the transcript, which is the more expensive confusion."
  (dolist (block (list (benedict-block-text "hi")
                       (benedict-block-thinking "because")
                       (benedict-block-thinking "" :redacted t)
                       (benedict-block-image "AAAA" "image/png")
                       (benedict-block-tool-call "c1" 'some-tool '(:a 1))
                       (benedict-block-tool-result "c1" 'some-tool "out")))
    (let ((rendered (benedict-headless-format-block block)))
      (should (stringp rendered))
      (should-not (string-empty-p rendered))
      (should-not (string-match-p "unrenderable" rendered)))))

(provide 'benedict-headless-test)
;;; benedict-headless-test.el ends here
