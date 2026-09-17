;;; benedict-eval-test.el --- The eval-elisp tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tool on its own: no session, no reducer, no provider.  What is being
;; checked here is the contract SPEC-001 6.2 puts on every handler and 6.1 puts
;; on this one -- that a call always produces a RESULT.  A tool whose whole
;; purpose is running arbitrary code the model wrote will be handed broken code
;; constantly, and every one of those has to come back as something the model
;; can read and correct rather than as a signal, an empty string, or a silently
;; truncated value.
;;
;; The session-level half of Phase 3 is in `benedict-eval-session-test.el'.

;;; Code:

(require 'ert)
(require 'test-helper)

(defvar benedict-eval-test--ran nil
  "Set by a form that a test expects never to be evaluated.")

(defun benedict-eval-test--content (source)
  "Return the content `benedict-eval--run' produces for SOURCE."
  (benedict-tool-result-value-content (benedict-eval--run source)))

(defun benedict-eval-test--error-p (source)
  "Return non-nil when evaluating SOURCE produces a failed result."
  (benedict-tool-result-value-error-p (benedict-eval--run source)))

;;;; Values

(ert-deftest benedict-eval-returns-the-printed-value ()
  (should (equal (benedict-eval-test--content "(+ 1 2)") "3"))
  (should (equal (benedict-eval-test--content "(list 1 \"two\" 'three)")
                 "(1 \"two\" three)")))

(ert-deftest benedict-eval-evaluates-with-lexical-binding ()
  "A closure must close over its binding, as it does everywhere else here."
  (should (equal (benedict-eval-test--content
                  "(let ((x 41)) (funcall (lambda () (1+ x))))")
                 "42")))

(ert-deftest benedict-eval-tolerates-a-trailing-comment ()
  "A form sent with an explanation after it is still one form."
  (should (equal (benedict-eval-test--content "(+ 1 2) ; adds them up") "3")))

(ert-deftest benedict-eval-prints-a-cyclic-value-instead-of-hanging ()
  "`print-circle' is what keeps a self-referential value from taking the image."
  (let ((content (benedict-eval-test--content
                  "(let ((x (list 1 2))) (setcdr (cdr x) x) x)")))
    (should (string-match-p "#1=" content))))

;;;; Refusals, before anything runs

(ert-deftest benedict-eval-refuses-more-than-one-form ()
  "SPEC-001 6.1 says one form; several are wrapped in `progn' by the caller."
  (should (benedict-eval-test--error-p "(+ 1 2) (+ 3 4)"))
  (should (string-match-p "single form" (benedict-eval-test--content "(+ 1 2) (+ 3 4)")))
  (should (string-match-p "progn" (benedict-eval-test--content "(+ 1 2) (+ 3 4)"))))

(ert-deftest benedict-eval-refuses-before-evaluating-anything ()
  "A refused call must not have already had half its effect."
  (let ((benedict-eval-test--ran nil))
    (should (benedict-eval-test--error-p
             "(setq benedict-eval-test--ran t) (ignore)"))
    (should-not benedict-eval-test--ran)))

(ert-deftest benedict-eval-refuses-a-blank-form ()
  (should (benedict-eval-test--error-p "   \n  "))
  (should (string-match-p "No form" (benedict-eval-test--content "   \n  "))))

(ert-deftest benedict-eval-reports-a-read-failure-as-a-read-failure ()
  "\"Your syntax is wrong\" and \"your form failed\" are different problems."
  (let ((content (benedict-eval-test--content "(+ 1")))
    (should (benedict-eval-test--error-p "(+ 1"))
    (should (string-match-p "Cannot read form" content))))

;;;; Failures reach the model rather than the stack

(ert-deftest benedict-eval-a-signal-becomes-a-failed-result ()
  (should (benedict-eval-test--error-p "(error \"boom\")"))
  (should (string-match-p "boom" (benedict-eval-test--content "(error \"boom\")"))))

(ert-deftest benedict-eval-a-failure-keeps-the-output-it-produced ()
  "The output a half-finished form produced is often the only diagnostic."
  (let ((content (benedict-eval-test--content
                  "(progn (princ \"got this far\") (error \"then stopped\"))")))
    (should (string-match-p "then stopped" content))
    (should (string-match-p "got this far" content))))

;;;; Output is part of the result

(ert-deftest benedict-eval-captures-standard-output ()
  (let ((content (benedict-eval-test--content "(progn (princ \"hi\") 'done)")))
    (should (string-match-p "\\_<done\\_>" content))
    (should (string-match-p "Output:\nhi" content))))

(ert-deftest benedict-eval-captures-messages ()
  (let ((content (benedict-eval-test--content
                  "(progn (message \"logged %d\" 7) nil)")))
    (should (string-match-p "Messages:\nlogged 7" content))))

(ert-deftest benedict-eval-omits-empty-sections ()
  "A form that printed nothing must not come back with empty headings."
  (let ((content (benedict-eval-test--content "(+ 1 2)")))
    (should (equal content "3"))
    (should-not (string-match-p "Output:" content))
    (should-not (string-match-p "Messages:" content))))

(ert-deftest benedict-eval-captures-only-its-own-messages ()
  "The capture window is the evaluation, not everything since Emacs started."
  (message "before the evaluation")
  (let ((content (benedict-eval-test--content "(progn (message \"during\") nil)")))
    (should (string-match-p "during" content))
    (should-not (string-match-p "before the evaluation" content))))

;;;; Truncation announces itself

(ert-deftest benedict-eval-truncates-a-long-value ()
  "A silently shortened result is one the model reasons from as if complete."
  (let* ((benedict-eval-max-output-length 20)
         (content (benedict-eval-test--content "(make-string 500 ?x)")))
    (should (string-match-p "truncated: 20 of 502 characters shown" content))
    (should (< (length content) 200))))

(ert-deftest benedict-eval-truncates-captured-output ()
  (let* ((benedict-eval-max-output-length 20)
         (content (benedict-eval-test--content
                   "(progn (princ (make-string 500 ?y)) nil)")))
    (should (string-match-p "Output:" content))
    (should (string-match-p "truncated: 20 of 500 characters shown" content))))

(ert-deftest benedict-eval-can-be-told-not-to-truncate ()
  (let* ((benedict-eval-max-output-length nil)
         (content (benedict-eval-test--content "(make-string 500 ?x)")))
    (should (equal (length content) 502))
    (should-not (string-match-p "truncated" content))))

;;;; The live image

(ert-deftest benedict-eval-defines-into-the-running-image ()
  "The point of the medium: a definition takes effect with no reload."
  (unwind-protect
      (progn
        (should-not (fboundp 'benedict-eval-test--defined))
        (benedict-eval--run "(defun benedict-eval-test--defined () 'here)")
        (should (fboundp 'benedict-eval-test--defined))
        (should (equal (benedict-eval-test--content "(benedict-eval-test--defined)")
                       "here")))
    (fmakunbound 'benedict-eval-test--defined)))

;;;; Registration

(ert-deftest benedict-eval-registers-itself-on-load ()
  "Loading the file is all it takes; there is no install step for a tool."
  (let ((tool (benedict-tool-get 'eval-elisp)))
    (should tool)
    (should (equal (benedict-tool-label tool) "Evaluate Elisp"))
    (should (functionp (benedict-tool-handler tool)))))

(ert-deftest benedict-eval-schema-survives-json-serialize ()
  "SPEC-001 6.1: a schema that satisfies `equal' can still fail at request time."
  (let* ((schema (benedict-tool-schema (benedict-tool-get 'eval-elisp)))
         (json (json-parse-string (json-serialize schema))))
    (should (equal (gethash "type" json) "object"))
    (should (equal (gethash "required" json) ["form"]))
    (should (equal (gethash "type" (gethash "form" (gethash "properties" json)))
                   "string"))))

(ert-deftest benedict-eval-handler-reads-its-argument ()
  "The handler is reached the way the reducer reaches it, through an invocation."
  (let* ((tool (benedict-tool-get 'eval-elisp))
         (invocation (benedict-invocation-create
                      :id "call_1" :name 'eval-elisp :arguments '(:form "(* 6 7)")))
         (result nil))
    (funcall (benedict-tool-handler tool) invocation
             (lambda (value) (setq result value)))
    (should (equal (benedict-tool-result-value-content result) "42"))))

(ert-deftest benedict-eval-a-missing-argument-is-a-failed-result ()
  "A model that omits `form' gets told so, rather than breaking the run."
  (let* ((tool (benedict-tool-get 'eval-elisp))
         (invocation (benedict-invocation-create
                      :id "call_1" :name 'eval-elisp :arguments nil))
         (result nil))
    (funcall (benedict-tool-handler tool) invocation
             (lambda (value) (setq result value)))
    (should (benedict-tool-result-value-error-p result))))

(ert-deftest benedict-eval-context-binds-project-without-changing-target ()
  "Evaluation sees the captured root without mutating the target buffer."
  (let ((buffer (generate-new-buffer " *benedict-eval-target*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq default-directory "/tmp/")
          (let* ((context (benedict-eval-context-create
                           :project-root benedict-test-root
                           :target-buffer buffer))
                 (result (benedict-eval-run "default-directory" context)))
            (should (equal (read (benedict-tool-result-value-content result))
                           benedict-test-root))
            (should (equal default-directory "/tmp/"))))
      (kill-buffer buffer))))

(ert-deftest benedict-eval-killed-target-fails-without-retargeting ()
  "A dead captured target does not fall back to the ambient current buffer."
  (let* ((buffer (generate-new-buffer " *benedict-eval-dead*"))
         (context (benedict-eval-context-create
                   :project-root benedict-test-root :target-buffer buffer))
         (benedict-eval-test--dead-target-side-effect nil))
    (kill-buffer buffer)
    (let ((result (benedict-eval-run
                   "(setq benedict-eval-test--dead-target-side-effect t)"
                   context)))
      (should (benedict-tool-result-value-error-p result))
      (should (string-match-p "target buffer was killed"
                              (benedict-tool-result-value-content result)))
      (should-not benedict-eval-test--dead-target-side-effect))))

(provide 'benedict-eval-test)

;;; benedict-eval-test.el ends here
