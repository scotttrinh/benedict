;;; benedict-api-transform-repair-test.el --- Ids and structural repair  -*- lexical-binding: t; -*-

;;; Commentary:

;; The other half of SPEC-001 7.8: tool call id remapping (7.8.5), structural
;; repair (7.8.6), and the fork-and-switch case (7.8.7).
;;
;; Every failure these tests prevent is a rejected request rather than a wrong
;; answer, which is exactly why they are worth writing before a real provider
;; exists.  A transcript that has gone structurally invalid fails at the far end
;; of an HTTP call with a message that names an id, not a function -- there is
;; nothing to step through and nothing local to breakpoint.

;;; Code:

(require 'ert)
(require 'test-helper)

(defun benedict-api-transform-repair-test--models ()
  "Return two models claiming different provider/api/model triples."
  (list (benedict-test-model :provider 'vercel-ai-gateway
                             :api 'openai-responses
                             :id "openai/gpt-5"
                             :reasoning-p t)
        (benedict-test-model :provider 'anthropic
                             :api 'anthropic-messages
                             :id "claude-sonnet-4"
                             :reasoning-p t)))

(defun benedict-api-transform-repair-test--assistant (model content &rest meta)
  "Return an unappended assistant entry with CONTENT, produced by MODEL."
  (benedict-entry-create
   :role 'assistant
   :content content
   :meta (append (benedict-test-origin-meta model) meta)))

(defun benedict-api-transform-repair-test--result (id name content &rest keys)
  "Return an unappended tool-result entry answering ID with CONTENT.
NAME is the tool symbol and KEYS are passed to `benedict-block-tool-result'."
  (benedict-entry-create
   :role 'tool-result
   :content (list (apply #'benedict-block-tool-result id name content keys))))

(defun benedict-api-transform-repair-test--result-ids (entries)
  "Return the tool-result block id of each tool-result entry in ENTRIES."
  (mapcan (lambda (entry)
            (when (benedict-entry-tool-result-p entry)
              (mapcar (lambda (block) (plist-get block :id))
                      (benedict-entry-tool-results entry))))
          entries))

(defun benedict-api-transform-repair-test--underscore (id _model _entry)
  "Return ID reshaped the way `anthropic-messages' constrains one.
Mirrors the real normalizer: non-word characters become underscores and
the result is capped at 64 characters."
  (truncate-string-to-width
   (replace-regexp-in-string "[^a-zA-Z0-9_-]" "_" id) 64))

;;;; Tool call identifiers

(ert-deftest benedict-api-transform-rewrites-a-foreign-tool-call-id ()
  "An OpenAI Responses id can run past 450 characters and contain a pipe.
Anthropic will not take it, so the adapter's normalizer has to reach it."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-repair-test--models))
                 (entries (list (benedict-api-transform-repair-test--assistant
                                 gpt (list (benedict-block-tool-call
                                            "call_abc|fc_def" 'do-thing '(:x 1))))
                                (benedict-api-transform-repair-test--result
                                 "call_abc|fc_def" 'do-thing "ok")))
                 (lowered (benedict-api-lower
                           entries claude
                           #'benedict-api-transform-repair-test--underscore)))
      (should (equal (plist-get (car (benedict-entry-content (nth 0 lowered))) :id)
                     "call_abc_fc_def")))))

(ert-deftest benedict-api-transform-propagates-a-rewritten-id-to-its-result ()
  "Rewriting a call id without rewriting its result produces an orphaned
result and a rejected request, which is the failure this pass exists for."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-repair-test--models))
                 (entries (list (benedict-api-transform-repair-test--assistant
                                 gpt (list (benedict-block-tool-call
                                            "call_abc|fc_def" 'do-thing '(:x 1))))
                                (benedict-api-transform-repair-test--result
                                 "call_abc|fc_def" 'do-thing "ok")))
                 (lowered (benedict-api-lower
                           entries claude
                           #'benedict-api-transform-repair-test--underscore)))
      (should (equal (benedict-api-transform-repair-test--result-ids lowered)
                     '("call_abc_fc_def"))))))

(ert-deftest benedict-api-transform-rewrites-a-result-that-precedes-its-call ()
  "The map is collected in its own pass, so a transcript whose entries are
not in the tidy order still remaps consistently."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-repair-test--models))
                 (result (benedict-api-transform-repair-test--result
                          "call_a|b" 'do-thing "ok"))
                 (call (benedict-api-transform-repair-test--assistant
                        gpt (list (benedict-block-tool-call
                                   "call_a|b" 'do-thing '(:x 1)))))
                 ;; The repair pass will drop the stray leading result; what is
                 ;; under test is that it was rewritten before that decision.
                 (lowered (benedict-api-transform--entry
                           result claude
                           (benedict-api-transform--tool-call-ids
                            (list call) claude
                            #'benedict-api-transform-repair-test--underscore))))
      (should (equal (plist-get (car (benedict-entry-content lowered)) :id)
                     "call_a_b")))))

(ert-deftest benedict-api-transform-never-renormalizes-a-same-origin-id ()
  "A same-origin id is one this very model minted; rewriting it would break
the continuity the origin test exists to protect."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (entries (list (benedict-api-transform-repair-test--assistant
                                 gpt (list (benedict-block-tool-call
                                            "call_abc|fc_def" 'do-thing '(:x 1))))
                                (benedict-api-transform-repair-test--result
                                 "call_abc|fc_def" 'do-thing "ok")))
                 (lowered (benedict-api-lower
                           entries gpt
                           #'benedict-api-transform-repair-test--underscore)))
      (should (equal (plist-get (car (benedict-entry-content (nth 0 lowered))) :id)
                     "call_abc|fc_def"))
      (should (equal (benedict-api-transform-repair-test--result-ids lowered)
                     '("call_abc|fc_def"))))))

(ert-deftest benedict-api-transform-leaves-ids-alone-without-a-normalizer ()
  "An adapter whose API constrains nothing supplies no normalizer."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-repair-test--models))
                 (entries (list (benedict-api-transform-repair-test--assistant
                                 gpt (list (benedict-block-tool-call
                                            "call_abc|fc_def" 'do-thing '(:x 1))))
                                (benedict-api-transform-repair-test--result
                                 "call_abc|fc_def" 'do-thing "ok")))
                 (lowered (benedict-api-lower entries claude)))
      (should (equal (plist-get (car (benedict-entry-content (nth 0 lowered))) :id)
                     "call_abc|fc_def"))
      (should (equal (benedict-api-transform-repair-test--result-ids lowered)
                     '("call_abc|fc_def"))))))

;;;; Orphaned tool calls

(ert-deftest benedict-api-transform-synthesizes-a-result-at-the-end ()
  "Aborting mid-tool-execution leaves the transcript ending on a call.
Recoverability is the point: the next request has to be well-formed."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-tool-call
                                             "call_1" 'do-thing '(:x 1)))))
                           gpt))
                 (synthetic (nth 1 lowered)))
      (should (equal (mapcar #'benedict-entry-role lowered)
                     '(assistant tool-result)))
      (should (equal (benedict-entry-content synthetic)
                     (list (benedict-block-tool-result
                            "call_1" 'do-thing benedict-api-missing-tool-result
                            :error-p t))))
      ;; Not a transcript member: it exists for the length of one request.
      (should-not (benedict-entry-id synthetic))
      (should-not (benedict-entry-parent synthetic)))))

(ert-deftest benedict-api-transform-synthesizes-a-result-before-the-next-user ()
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-tool-call
                                             "call_1" 'do-thing '(:x 1))))
                                 (benedict-test-entry 'user "never mind"))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered)
                     '(assistant tool-result user)))
      (should (equal (benedict-api-transform-repair-test--result-ids lowered)
                     '("call_1"))))))

(ert-deftest benedict-api-transform-synthesizes-a-result-before-the-next-turn ()
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-tool-call
                                             "call_1" 'do-thing '(:x 1))))
                                 (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-text "moving on"))))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered)
                     '(assistant tool-result assistant))))))

(ert-deftest benedict-api-transform-does-not-synthesize-over-a-real-result ()
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-tool-call
                                             "call_1" 'do-thing '(:x 1))))
                                 (benedict-api-transform-repair-test--result
                                  "call_1" 'do-thing "ok")
                                 (benedict-test-entry 'user "thanks"))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered)
                     '(assistant tool-result user)))
      (should (equal (benedict-entry-text
                      (benedict-test-entry
                       'user (plist-get (car (benedict-entry-content (nth 1 lowered)))
                                        :content)))
                     "ok")))))

(ert-deftest benedict-api-transform-synthesizes-only-the-unanswered-calls ()
  "One result entry per call, per SPEC-001 D12, so a turn can be partly
answered and the repair has to fill exactly the gaps."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-tool-call "call_1" 'a nil)
                                            (benedict-block-tool-call "call_2" 'b nil)
                                            (benedict-block-tool-call "call_3" 'c nil)))
                                 (benedict-api-transform-repair-test--result
                                  "call_2" 'b "ok"))
                           gpt)))
      ;; Synthetics land after the results that did arrive, in call order.
      (should (equal (benedict-api-transform-repair-test--result-ids lowered)
                     '("call_2" "call_1" "call_3")))
      (should (equal (mapcar (lambda (entry)
                               (plist-get (car (benedict-entry-content entry))
                                          :error-p))
                             (cdr lowered))
                     '(nil t t))))))

;;;; Errored and aborted turns

(ert-deftest benedict-api-transform-omits-errored-and-aborted-turns ()
  "Partial content -- reasoning with no following item, half-formed tool call
arguments -- makes a provider reject the whole request on replay."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-test-entry 'user "go")
                                 (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-text "half"))
                                  :stop-reason 'error :error-message "boom")
                                 (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-text "half"))
                                  :stop-reason 'aborted))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered) '(user))))))

(ert-deftest benedict-api-transform-keeps-ordinary-stop-reasons ()
  "Only `error' and `aborted' mean incomplete; `length' and `tool-use' are
turns that really happened."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-text "cut off"))
                                  :stop-reason 'length))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered) '(assistant))))))

(ert-deftest benedict-api-transform-drops-results-orphaned-by-a-skipped-turn ()
  "An errored turn whose tools had already run leaves results answering a
call that is no longer in the request.  Providers reject an orphaned
result exactly as hard as an orphaned call, so both go together."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-test-entry 'user "go")
                                 (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-tool-call
                                             "call_1" 'do-thing '(:x 1)))
                                  :stop-reason 'error)
                                 (benedict-api-transform-repair-test--result
                                  "call_1" 'do-thing "ran anyway"))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered) '(user))))))

(ert-deftest benedict-api-transform-keeps-results-of-a-surviving-turn ()
  "The orphan rule must not reach past the turn it is repairing."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-repair-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-tool-call "call_1" 'a nil)))
                                 (benedict-api-transform-repair-test--result
                                  "call_1" 'a "ok")
                                 (benedict-api-transform-repair-test--assistant
                                  gpt (list (benedict-block-text "half"))
                                  :stop-reason 'aborted))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered)
                     '(assistant tool-result))))))

;;;; Fork and switch

(ert-deftest benedict-api-transform-never-lowers-an-abandoned-branch ()
  "Fork-and-switch is the primary use for forking and model switching
together.  Lowering runs over the materialized path, which holds only
ancestors of the head, so signatures from the abandoned branch are
structurally unreachable -- but a regression here fails at the provider
with an opaque error rather than locally, so it is asserted rather than
argued.  See SPEC-001 7.8.7."
  (benedict-test-with-clean-registries
    (benedict-test-with-manual-defer
      (let ((session (benedict-test-session
                      '(((:thinking "abandoned reasoning" :signature "sig-abandoned")
                         (:text "first answer"))
                        ((:text "second answer")))))
            (gpt (benedict-test-model :provider 'vercel-ai-gateway
                                      :api 'openai-responses
                                      :id "openai/gpt-5")))
        (benedict-session-submit session "go")
        (benedict-test-drain)
        ;; The branch about to be abandoned really did carry a signature.
        (should (equal (mapcar #'benedict-entry-role (benedict-session-path session))
                       '(user assistant)))
        (should (seq-some (lambda (block) (plist-get block :signature))
                          (benedict-entry-content
                           (nth 1 (benedict-session-path session)))))
        ;; Fork back to the user entry and answer it a second time.
        (benedict-session-fork
         session (benedict-entry-id (car (benedict-session-path session))))
        (benedict-session-submit session nil)
        (benedict-test-drain)
        (let ((lowered (benedict-api-lower (benedict-session-path session) gpt)))
          (should (equal (benedict-entry-text (car (last lowered))) "second answer"))
          (dolist (entry lowered)
            (dolist (block (benedict-entry-content entry))
              (should-not (equal (plist-get block :signature) "sig-abandoned")))))))))

(provide 'benedict-api-transform-repair-test)

;;; benedict-api-transform-repair-test.el ends here
