;;; benedict-api-transform-test.el --- Origin and degradation  -*- lexical-binding: t; -*-

;;; Commentary:

;; SPEC-001 7.8.4 is a table, and a table is worth asserting row by row in both
;; directions: what a same-origin entry keeps is as load-bearing as what a
;; foreign one loses.  Dropping a signature that should have been replayed
;; degrades quality silently rather than erroring, and replaying one that should
;; have been dropped fails at the provider with a message that names nothing in
;; this repository.  Neither failure is visible without these tests.
;;
;; Structural repair and tool call id remapping live in
;; `benedict-api-transform-repair-test.el'.

;;; Code:

(require 'ert)
(require 'test-helper)

(defun benedict-api-transform-test--models ()
  "Return two models claiming different provider/api/model triples."
  (list (benedict-test-model :provider 'vercel-ai-gateway
                             :api 'openai-responses
                             :id "openai/gpt-5"
                             :reasoning-p t)
        (benedict-test-model :provider 'anthropic
                             :api 'anthropic-messages
                             :id "claude-sonnet-4"
                             :reasoning-p t)))

(defun benedict-api-transform-test--assistant (model content &rest meta)
  "Return an unappended assistant entry with CONTENT, produced by MODEL."
  (benedict-entry-create
   :role 'assistant
   :content content
   :meta (append (benedict-test-origin-meta model) meta)))

(defun benedict-api-transform-test--content (entries)
  "Return the content of the single entry in ENTRIES."
  (should (= (length entries) 1))
  (benedict-entry-content (car entries)))

;;;; The origin test

(ert-deftest benedict-api-transform-compares-origin-per-entry ()
  "A transcript holding entries from two models lowers each by its own origin.
Origin is not a property of the conversation, so a single pass has to
treat neighbouring entries differently."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-test--models))
                 (entries (list (benedict-api-transform-test--assistant
                                 gpt (list (benedict-block-text "a" :signature "sig-a")))
                                (benedict-api-transform-test--assistant
                                 claude (list (benedict-block-text "b" :signature "sig-b")))))
                 (lowered (benedict-api-lower entries gpt)))
      ;; The gpt entry keeps its signature; the claude entry loses one that gpt
      ;; never issued and could not interpret.
      (should (equal (benedict-entry-content (nth 0 lowered))
                     (list (benedict-block-text "a" :signature "sig-a"))))
      (should (equal (benedict-entry-content (nth 1 lowered))
                     (list (benedict-block-text "b")))))))

(ert-deftest benedict-api-transform-returns-unchanged-entries-by-identity ()
  "Lowering runs on every request, so an unchanged entry must not be copied."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (user (benedict-test-entry 'user "hello"))
                 (assistant (benedict-api-transform-test--assistant
                             gpt (list (benedict-block-text "hi" :signature "s"))))
                 (lowered (benedict-api-lower (list user assistant) gpt)))
      (should (eq (nth 0 lowered) user))
      (should (eq (nth 1 lowered) assistant)))))

(ert-deftest benedict-api-transform-does-not-modify-its-input ()
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-test--models))
                 (entries (list (benedict-api-transform-test--assistant
                                 claude
                                 (list (benedict-block-thinking "why" :signature "t")
                                       (benedict-block-text "answer" :signature "s")
                                       (benedict-block-tool-call "call_1" 'do-thing
                                                                 '(:x 1) :signature "u")))))
                 (before (copy-tree (benedict-entry-content (car entries)))))
      (benedict-api-lower entries gpt (lambda (id _model _entry) (concat "n-" id)))
      (should (equal (benedict-entry-content (car entries)) before)))))

;;;; The degradation table, same origin

(ert-deftest benedict-api-transform-keeps-same-origin-signatures ()
  "Same origin preserves everything verbatim, which is the whole point of
recording origin on every assistant entry."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (content (list (benedict-block-thinking "reasoning" :signature "t")
                                (benedict-block-text "answer" :signature "s")
                                (benedict-block-tool-call "call_1" 'do-thing
                                                          '(:x 1) :signature "u")))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant gpt content))
                           gpt)))
      ;; The unanswered call picks up a synthetic result; the turn itself is
      ;; what is under test here.
      (should (equal (benedict-entry-content (nth 0 lowered)) content)))))

(ert-deftest benedict-api-transform-keeps-same-origin-redacted-thinking ()
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (block (benedict-block-thinking "" :signature "t" :redacted t))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant gpt (list block)))
                           gpt)))
      (should (equal (benedict-api-transform-test--content lowered) (list block))))))

(ert-deftest benedict-api-transform-keeps-signed-empty-thinking-same-origin ()
  "A provider returning encrypted reasoning sends a signature and no text.
Dropping the block breaks replay continuity, so the signature outranks
the emptiness rule."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (block (benedict-block-thinking "" :signature "rs_123"))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant gpt (list block)))
                           gpt)))
      (should (equal (benedict-api-transform-test--content lowered) (list block))))))

(ert-deftest benedict-api-transform-drops-unsigned-empty-thinking-same-origin ()
  "Emptiness only survives when a signature justifies it."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant
                                  gpt (list (benedict-block-thinking "   ")
                                            (benedict-block-text "answer"))))
                           gpt)))
      (should (equal (benedict-api-transform-test--content lowered)
                     (list (benedict-block-text "answer")))))))

;;;; The degradation table, foreign origin

(ert-deftest benedict-api-transform-drops-foreign-redacted-thinking ()
  "Redacted thinking is ciphertext only its issuer can decrypt, so it is
dropped rather than converted -- sending it on is at best rejected."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant
                                  claude
                                  (list (benedict-block-thinking "secret"
                                                                :signature "t"
                                                                :redacted t)
                                        (benedict-block-text "answer"))))
                           gpt)))
      (should (equal (benedict-api-transform-test--content lowered)
                     (list (benedict-block-text "answer")))))))

(ert-deftest benedict-api-transform-converts-foreign-thinking-to-text ()
  "The reasoning still has value to the new model; only the protocol
artifact of a signature it did not issue has to go."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant
                                  claude
                                  (list (benedict-block-thinking "step one"
                                                                :signature "t"))))
                           gpt)))
      (should (equal (benedict-api-transform-test--content lowered)
                     (list (benedict-block-text "step one")))))))

(ert-deftest benedict-api-transform-drops-foreign-signed-empty-thinking ()
  "The keep-if-signed rule is same-origin only: an empty foreign thinking
block would convert to an empty text block, which is worse than nothing."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant
                                  claude
                                  (list (benedict-block-thinking "" :signature "rs_1")
                                        (benedict-block-text "answer"))))
                           gpt)))
      (should (equal (benedict-api-transform-test--content lowered)
                     (list (benedict-block-text "answer")))))))

(ert-deftest benedict-api-transform-strips-foreign-text-signatures ()
  "The signature key must be absent, not present and nil: adapters serialize
by walking the plist, and a nil value is still a key."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant
                                  claude
                                  (list (benedict-block-text "answer" :signature "s"))))
                           gpt))
                 (block (car (benedict-api-transform-test--content lowered))))
      (should (equal block (benedict-block-text "answer")))
      (should-not (plist-member block :signature)))))

(ert-deftest benedict-api-transform-strips-foreign-tool-call-signatures ()
  "Arguments and name survive; only the signature is a protocol artifact."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,claude) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant
                                  claude
                                  (list (benedict-block-tool-call
                                         "call_1" 'do-thing '(:x 1) :signature "u"))))
                           gpt))
                 (block (car (benedict-entry-content (nth 0 lowered)))))
      (should (equal block (benedict-block-tool-call "call_1" 'do-thing '(:x 1))))
      (should-not (plist-member block :signature)))))

(ert-deftest benedict-api-transform-leaves-user-entries-alone ()
  "User entries have no origin, so there is nothing to degrade."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (user (benedict-test-entry 'user "hello"))
                 (lowered (benedict-api-lower (list user) gpt)))
      (should (equal lowered (list user))))))

;;;; Images

(ert-deftest benedict-api-transform-keeps-images-for-a-vision-model ()
  (benedict-test-with-clean-registries
    (let* ((model (benedict-test-model :input-modalities '(text image)))
           (content (list (benedict-block-text "look")
                          (benedict-block-image "AAAA" "image/png")))
           (entry (benedict-entry-create :role 'user :content content))
           (lowered (benedict-api-lower (list entry) model)))
      (should (eq (car lowered) entry)))))

(ert-deftest benedict-api-transform-replaces-images-for-a-text-only-model ()
  (benedict-test-with-clean-registries
    (let* ((model (benedict-test-model :input-modalities '(text)))
           (entry (benedict-entry-create
                   :role 'user
                   :content (list (benedict-block-text "look")
                                  (benedict-block-image "AAAA" "image/png"))))
           (lowered (benedict-api-lower (list entry) model)))
      (should (equal (benedict-api-transform-test--content lowered)
                     (list (benedict-block-text "look")
                           (benedict-block-text benedict-api-image-placeholder)))))))

(ert-deftest benedict-api-transform-collapses-consecutive-image-placeholders ()
  "A ten-image turn should not become ten lines of noise."
  (benedict-test-with-clean-registries
    (let* ((model (benedict-test-model :input-modalities '(text)))
           (entry (benedict-entry-create
                   :role 'user
                   :content (list (benedict-block-image "A" "image/png")
                                  (benedict-block-image "B" "image/png")
                                  (benedict-block-image "C" "image/png")
                                  (benedict-block-text "and this")
                                  (benedict-block-image "D" "image/png"))))
           (lowered (benedict-api-lower (list entry) model)))
      (should (equal (benedict-api-transform-test--content lowered)
                     (list (benedict-block-text benedict-api-image-placeholder)
                           (benedict-block-text "and this")
                           (benedict-block-text benedict-api-image-placeholder)))))))

(ert-deftest benedict-api-transform-does-not-double-an-existing-placeholder ()
  "Lowering the same transcript twice must reach a fixed point."
  (benedict-test-with-clean-registries
    (let* ((model (benedict-test-model :input-modalities '(text)))
           (entry (benedict-entry-create
                   :role 'user
                   :content (list (benedict-block-text benedict-api-image-placeholder)
                                  (benedict-block-image "A" "image/png"))))
           (lowered (benedict-api-lower (list entry) model)))
      (should (equal (benedict-api-transform-test--content lowered)
                     (list (benedict-block-text benedict-api-image-placeholder)))))))

(ert-deftest benedict-api-transform-replaces-images-inside-tool-results ()
  "A tool result carrying a screenshot uses the tool-specific placeholder, so
the model can tell an image it was shown from one a tool produced."
  (benedict-test-with-clean-registries
    (let* ((model (benedict-test-model :input-modalities '(text)))
           (call (benedict-entry-create
                  :role 'assistant
                  :content (list (benedict-block-tool-call
                                  "call_1" 'screenshot nil))
                  :meta (benedict-test-origin-meta model)))
           (result (benedict-entry-create
                    :role 'tool-result
                    :content (list (benedict-block-tool-result
                                    "call_1" 'screenshot
                                    (list (benedict-block-text "captured")
                                          (benedict-block-image "A" "image/png"))))))
           (lowered (benedict-api-lower (list call result) model)))
      (should (equal (mapcar #'benedict-entry-role lowered)
                     '(assistant tool-result)))
      (should (equal (plist-get (car (benedict-entry-content (nth 1 lowered)))
                                :content)
                     (list (benedict-block-text "captured")
                           (benedict-block-text
                            benedict-api-tool-image-placeholder)))))))

(ert-deftest benedict-api-transform-leaves-string-tool-result-payloads-alone ()
  "A string payload has no images in it and must survive byte for byte."
  (benedict-test-with-clean-registries
    (let* ((model (benedict-test-model :input-modalities '(text)))
           (call (benedict-entry-create
                  :role 'assistant
                  :content (list (benedict-block-tool-call "call_1" 'do-thing nil))
                  :meta (benedict-test-origin-meta model)))
           (result (benedict-entry-create
                    :role 'tool-result
                    :content (list (benedict-block-tool-result
                                    "call_1" 'do-thing "plain text"))))
           (lowered (benedict-api-lower (list call result) model)))
      (should (eq (nth 1 lowered) result)))))

;;;; Notes

(ert-deftest benedict-api-transform-drops-plain-notes ()
  "Model-change markers and UI markers are part of the record but never part
of a request."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-test-entry 'user "hello")
                                 (benedict-test-entry 'note "switched to gpt-5"
                                                      :source 'model-change))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered) '(user))))))

(ert-deftest benedict-api-transform-promotes-context-flagged-notes-to-user ()
  "No wire protocol has a note role, so the mapping happens once here rather
than in every adapter.  See SPEC-001 4.5."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (note (benedict-test-entry 'note "User prefers ISO dates."
                                            :context t))
                 (lowered (benedict-api-lower (list note) gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered) '(user)))
      (should (equal (benedict-entry-text (car lowered))
                     "User prefers ISO dates.")))))

(ert-deftest benedict-api-transform-promoted-notes-close-a-tool-flow ()
  "A promoted note is a user entry in every respect, including interrupting
an unanswered tool call the way a typed message would."
  (benedict-test-with-clean-registries
    (pcase-let* ((`(,gpt ,_) (benedict-api-transform-test--models))
                 (lowered (benedict-api-lower
                           (list (benedict-api-transform-test--assistant
                                  gpt (list (benedict-block-tool-call
                                             "call_1" 'do-thing '(:x 1))))
                                 (benedict-test-entry 'note "remember this"
                                                      :context t))
                           gpt)))
      (should (equal (mapcar #'benedict-entry-role lowered)
                     '(assistant tool-result user))))))

(provide 'benedict-api-transform-test)

;;; benedict-api-transform-test.el ends here
