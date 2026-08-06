;;; benedict-eval-session-test.el --- eval-elisp through the reducer  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Phase 3 exit criterion of SPEC-001 14: "the fake provider requests
;; `eval-elisp', the result is appended, the next turn sees it."
;;
;; The last clause is the one worth being careful about.  "The next turn sees
;; it" is a claim about what goes out on the wire, not about what is sitting in
;; the transcript, so it is asserted on the request the provider received --
;; which is exactly the assertion that would have caught a context filter or a
;; materialization bug quietly dropping tool results.
;;
;; `benedict-eval-session-extends-the-image-mid-run' is here because Phase 3 is
;; the first moment the thesis of SPEC-001 1 is testable at all: the agent
;; defines a tool by evaluating a form, and calls it on its next turn, with no
;; file written and no reload.

;;; Code:

(require 'ert)
(require 'test-helper)

(defconst benedict-eval-session-test--deftool-form
  (concat "(benedict-deftool benedict-eval-session-test--minted"
          " :description \"Defined by the agent, mid-run.\""
          " :parameters nil"
          " :sync t"
          " :handler (lambda (_invocation)"
          "            (benedict-tool-result :content \"from the tool I wrote\")))")
  "A form that registers a new tool, for the agent to evaluate at runtime.")

(defun benedict-eval-session-test--result-contents (session)
  "Return the content of each tool-result entry on SESSION's path."
  (mapcar (lambda (entry) (plist-get (car (benedict-entry-content entry)) :content))
          (seq-filter #'benedict-entry-tool-result-p
                      (benedict-session-path session))))

(defun benedict-eval-session-test--requests (session)
  "Return the requests SESSION's model has received, oldest first."
  (benedict-provider-fake-requests
   (benedict-provider-fake-script-of (benedict-session-model session))))

(defun benedict-eval-session-test--sent-results (request)
  "Return the tool-result contents carried by REQUEST's entries."
  (mapcan (lambda (entry)
            (mapcar (lambda (block) (plist-get block :content))
                    (benedict-entry-tool-results entry)))
          (plist-get request :entries)))

;;;; The exit criterion

(ert-deftest benedict-eval-session-result-reaches-the-next-turn ()
  "The provider asks for `eval-elisp', and the answer is in the next request."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:text "Let me add those.")
                         (:tool-call eval-elisp (:form "(+ 1 2)")))
                        ((:text "It is 3.")))
                      :tools '(eval-elisp))))
        (benedict-session-submit session "What is 1 + 2?")
        (benedict-test-drain)

        (should (eq (benedict-session-state session) 'idle))
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant tool-result assistant)))

        ;; Appended: as a tool-result entry of its own, per D12, carrying the
        ;; id of the call it answers -- the pairing every wire format needs.
        (let ((call (car (benedict-entry-tool-calls
                          (nth 1 (benedict-session-path session)))))
              (block (car (benedict-entry-content
                           (nth 2 (benedict-session-path session))))))
          (should (equal (plist-get block :content) "3"))
          (should (equal (plist-get block :name) 'eval-elisp))
          (should (equal (plist-get block :id) (plist-get call :id)))
          (should-not (plist-get block :error-p)))

        ;; Seen by the next turn: the second request carries it.  The
        ;; transcript holding it is not the same claim.
        (let ((requests (benedict-eval-session-test--requests session)))
          (should (equal (length requests) 2))
          (should (null (benedict-eval-session-test--sent-results (nth 0 requests))))
          (should (equal (benedict-eval-session-test--sent-results (nth 1 requests))
                         '("3"))))))))

(ert-deftest benedict-eval-session-advertises-the-tool ()
  "The model is told the tool exists, with the schema the DSL compiled."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session '(((:text "nothing to do")))
                                            :tools '(eval-elisp))))
        (benedict-session-submit session "hello")
        (benedict-test-drain)
        (let* ((request (car (benedict-eval-session-test--requests session)))
               (tools (plist-get request :tools)))
          (should (equal (mapcar #'benedict-tool-id tools) '(eval-elisp)))
          (should (json-serialize (benedict-tool-schema (car tools)))))))))

;;;; Failure is history, not the end of the run

(ert-deftest benedict-eval-session-a-failed-form-does-not-end-the-run ()
  "A form that signals comes back as a result the model gets to react to."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call eval-elisp (:form "(car 5)")))
                        ((:text "Right, that is not a list.")))
                      :tools '(eval-elisp))))
        (benedict-session-submit session "call car on 5")
        (benedict-test-drain)

        (should (eq (benedict-session-state session) 'idle))
        (should (equal (benedict-test-entry-roles session)
                       '(user assistant tool-result assistant)))
        (let ((block (car (benedict-entry-content
                           (nth 1 (benedict-session-path session))))))
          (should (equal (plist-get block :type) 'tool-call)))
        (should (string-match-p
                 "Error:" (car (benedict-eval-session-test--result-contents session))))
        (should (plist-get (car (benedict-entry-content
                                 (nth 2 (benedict-session-path session))))
                           :error-p))))))

(ert-deftest benedict-eval-session-a-refused-form-does-not-end-the-run ()
  "Two forms in one call are refused the same way -- an answer, not a break."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:tool-call eval-elisp (:form "(setq x 1) (setq y 2)")))
                        ((:text "I will wrap them in progn.")))
                      :tools '(eval-elisp))))
        (benedict-session-submit session "set two variables")
        (benedict-test-drain)
        (should (eq (benedict-session-state session) 'idle))
        (should (string-match-p
                 "progn"
                 (car (benedict-eval-session-test--result-contents session))))))))

;;;; The thesis

(ert-deftest benedict-eval-session-extends-the-image-mid-run ()
  "The agent defines a tool by evaluating a form and calls it on the next turn.

SPEC-001 10.1 steps 4 and 5, minus the file: there is no reload subsystem
to go through, so the new tool is callable as soon as the form returns."
  (benedict-test-with-clean-registries
    (unwind-protect
        (benedict-test-with-manual-defer
          (let ((session (benedict-test-session
                          `(((:tool-call eval-elisp
                                         (:form ,benedict-eval-session-test--deftool-form)))
                            ((:tool-call benedict-eval-session-test--minted nil
                                         :id "call_minted"))
                            ((:text "It works.")))
                          :tools '(eval-elisp))))
            (should-not (benedict-tool-get 'benedict-eval-session-test--minted))
            (benedict-session-submit session "write yourself a tool")
            (benedict-test-drain)

            (should (eq (benedict-session-state session) 'idle))
            (should (benedict-tool-get 'benedict-eval-session-test--minted))
            (should (equal (nth 1 (benedict-eval-session-test--result-contents session))
                           "from the tool I wrote"))
            (should (equal (benedict-test-entry-roles session)
                           '(user assistant tool-result assistant tool-result
                                  assistant)))

            ;; The finding.  Resolution goes through the global registry, so
            ;; the call works -- but the session's tool list was resolved once
            ;; at creation, so no request ever tells the model the tool it just
            ;; wrote exists.  A tool the agent cannot be told about is a tool
            ;; it can only call by remembering it.
            (should (equal (mapcar #'benedict-tool-id (benedict-session-tools session))
                           '(eval-elisp)))
            (dolist (request (benedict-eval-session-test--requests session))
              (should (equal (mapcar #'benedict-tool-id (plist-get request :tools))
                             '(eval-elisp))))))
      (benedict-tool-unregister 'benedict-eval-session-test--minted))))

(provide 'benedict-eval-session-test)

;;; benedict-eval-session-test.el ends here
