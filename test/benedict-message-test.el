;;; benedict-message-test.el --- Tests for the canonical data model  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 0's exit criterion is `benedict-message-branching-transcript-materializes-two-paths':
;; build a branching transcript, materialize two different paths, assert both.
;; Everything else here guards a specific property the rest of the system will
;; lean on.

;;; Code:

(require 'ert)
(require 'benedict-message)

;;;; Phase 0 exit criterion

(ert-deftest benedict-message-branching-transcript-materializes-two-paths ()
  "A fork produces a sibling, and both branches materialize independently."
  (let* ((tr (benedict-transcript-create :session-id "s1"))
         (u1 (benedict-transcript-append
              tr (benedict-entry-create :role 'user :content "hi")))
         (a1 (benedict-transcript-append
              tr (benedict-entry-create :role 'assistant :content "left"))))
    (benedict-transcript-fork tr (benedict-entry-id u1))
    (let ((a2 (benedict-transcript-append
               tr (benedict-entry-create :role 'assistant :content "right"))))
      ;; Ids follow the documented scheme and come from one counter.
      (should (equal (benedict-entry-id u1) "s1-e0001"))
      (should (equal (benedict-entry-id a1) "s1-e0002"))
      (should (equal (benedict-entry-id a2) "s1-e0003"))
      ;; The fork made a sibling of a1, not a child of it.
      (should (equal (benedict-entry-parent a2) (benedict-entry-id u1)))
      (should (equal (benedict-transcript-head tr) (benedict-entry-id a2)))
      ;; Both paths are intact; the abandoned branch is still materializable.
      (should (equal (mapcar #'benedict-entry-text
                             (benedict-transcript-path tr (benedict-entry-id a1)))
                     '("hi" "left")))
      (should (equal (mapcar #'benedict-entry-text
                             (benedict-transcript-path tr (benedict-entry-id a2)))
                     '("hi" "right")))
      ;; With no id, the path is head's.
      (should (equal (benedict-transcript-path tr)
                     (benedict-transcript-path tr (benedict-entry-id a2))))
      ;; The data a "2 of 3" branch affordance needs.
      (should (= 2 (length (benedict-transcript-children tr (benedict-entry-id u1)))))
      (should (= 2 (length (benedict-transcript-siblings tr (benedict-entry-id a1)))))
      (should (= 1 (length (benedict-transcript-children tr nil))))
      ;; Nothing was removed.
      (should (= 3 (benedict-transcript-count tr))))))

;;;; Entry ids

(ert-deftest benedict-message-entry-id-round-trips ()
  (should (equal (benedict-entry-mint-id "s1" 7) "s1-e0007"))
  (should (equal (benedict-entry-mint-id "s1" 12345) "s1-e12345"))
  (should (= 7 (benedict-entry-id-counter (benedict-entry-mint-id "s1" 7))))
  (should (equal "s1" (benedict-entry-id-session (benedict-entry-mint-id "s1" 7)))))

(ert-deftest benedict-message-entry-id-splits-at-the-final-separator ()
  "A session id that itself contains \"-e\" still parses."
  (should (= 12 (benedict-entry-id-counter "weird-e5-e0012")))
  (should (equal "weird-e5" (benedict-entry-id-session "weird-e5-e0012"))))

(ert-deftest benedict-message-foreign-entry-id-has-no-counter ()
  "Hand-written and imported ids are usable but do not advance a counter."
  (should-not (benedict-entry-id-counter "abc"))
  (should-not (benedict-entry-id-counter nil)))

(ert-deftest benedict-message-generated-session-ids-differ ()
  (should-not (equal (benedict-generate-session-id)
                     ;; Same second, different sub-second clock.
                     (progn (sleep-for 0.01) (benedict-generate-session-id)))))

;;;; Entries

(ert-deftest benedict-message-entry-create-rejects-unknown-roles ()
  (should-error (benedict-entry-create :role 'system) :type 'benedict-entry-error)
  (should-error (benedict-entry-create :role nil) :type 'benedict-entry-error))

(ert-deftest benedict-message-entry-create-normalizes-content ()
  (should (equal (benedict-entry-content (benedict-entry-create :role 'user :content "hi"))
                 '((:type text :text "hi"))))
  (should (equal (benedict-entry-content
                  (benedict-entry-create :role 'user :content '(:type text :text "hi")))
                 '((:type text :text "hi"))))
  (should (equal (benedict-entry-content
                  (benedict-entry-create :role 'user :content '((:type text :text "hi"))))
                 '((:type text :text "hi"))))
  (should-not (benedict-entry-content (benedict-entry-create :role 'user)))
  (should-error (benedict-entry-create :role 'user :content 42)
                :type 'benedict-entry-error))

(ert-deftest benedict-message-entry-role-predicates ()
  (should (benedict-entry-user-p (benedict-entry-create :role 'user)))
  (should (benedict-entry-assistant-p (benedict-entry-create :role 'assistant)))
  (should (benedict-entry-tool-result-p (benedict-entry-create :role 'tool-result)))
  (should (benedict-entry-note-p (benedict-entry-create :role 'note)))
  (should-not (benedict-entry-note-p (benedict-entry-create :role 'user))))

(ert-deftest benedict-message-entry-with-does-not-alias-the-original ()
  "Carried-over content is copied, so mutating the copy cannot reach back."
  (let* ((original (benedict-entry-create :role 'user :content "x"
                                          :meta '(:model "m")))
         (copy (benedict-entry-with original :role 'note)))
    (setf (car (benedict-entry-content copy)) '(:type text :text "MUTATED"))
    (setf (benedict-entry-meta copy) (plist-put (benedict-entry-meta copy) :model "n"))
    (should (equal (benedict-entry-text original) "x"))
    (should (equal (benedict-entry-meta-get original :model) "m"))
    (should (equal (benedict-entry-text copy) "MUTATED"))))

(ert-deftest benedict-message-entry-with-carries-unsupplied-slots ()
  (let* ((original (benedict-entry-create :role 'user :content "x" :id "i" :parent "p"
                                          :timestamp 1.5 :meta '(:model "m")))
         (copy (benedict-entry-with original :content "y")))
    (should (equal (benedict-entry-id copy) "i"))
    (should (equal (benedict-entry-parent copy) "p"))
    (should (eq (benedict-entry-role copy) 'user))
    (should (equal (benedict-entry-timestamp copy) 1.5))
    (should (equal (benedict-entry-meta copy) '(:model "m")))
    (should (equal (benedict-entry-text copy) "y"))))

(ert-deftest benedict-message-entry-with-distinguishes-nil-from-absent ()
  "Passing nil explicitly clears a slot; omitting the key carries it over."
  (let ((original (benedict-entry-create :role 'user :content "x" :parent "p")))
    (should (equal (benedict-entry-parent (benedict-entry-with original)) "p"))
    (should-not (benedict-entry-parent (benedict-entry-with original :parent nil)))))

;;;; Entry metadata

(ert-deftest benedict-message-meta-accessors ()
  (let ((entry (benedict-entry-create :role 'user :meta '(:model "m" :usage nil))))
    (should (equal (benedict-entry-meta-get entry :model) "m"))
    (should-not (benedict-entry-meta-get entry :usage))
    (should (equal (benedict-entry-meta-get entry :missing 'fallback) 'fallback))
    ;; A key present with a nil value is not the same as an absent key.
    (should (benedict-entry-meta-member entry :usage))
    (should-not (benedict-entry-meta-member entry :missing))))

(ert-deftest benedict-message-meta-put-mutates-and-with-meta-does-not ()
  (let ((entry (benedict-entry-create :role 'user)))
    ;; plist-put on a nil plist returns a fresh list, so the slot must be set.
    (benedict-entry-meta-put entry :model "m")
    (should (equal (benedict-entry-meta-get entry :model) "m"))
    (let ((derived (benedict-entry-with-meta entry :model "n" :api 'openai-responses)))
      (should (equal (benedict-entry-meta-get entry :model) "m"))
      (should (equal (benedict-entry-meta-get derived :model) "n"))
      (should (eq (benedict-entry-meta-get derived :api) 'openai-responses)))))

(ert-deftest benedict-message-with-meta-rejects-odd-arguments ()
  (should-error (benedict-entry-with-meta (benedict-entry-create :role 'user) :model)
                :type 'benedict-entry-error))

(ert-deftest benedict-message-entry-origin ()
  (let ((entry (benedict-entry-create
                :role 'assistant
                :meta '(:provider vercel-ai-gateway :api openai-responses
                        :model "openai/gpt-5"))))
    (should (equal (benedict-entry-origin entry)
                   '(:provider vercel-ai-gateway :api openai-responses
                     :model "openai/gpt-5"))))
  ;; A hand-built entry has no origin, and that is a plist of nils, not an error.
  (should (equal (benedict-entry-origin (benedict-entry-create :role 'user))
                 '(:provider nil :api nil :model nil))))

(ert-deftest benedict-message-notes-opt-into-context ()
  "Ordinary entries are always context; notes only when flagged."
  (should (benedict-entry-context-p (benedict-entry-create :role 'user)))
  (should (benedict-entry-context-p (benedict-entry-create :role 'assistant)))
  (should-not (benedict-entry-context-p (benedict-entry-create :role 'note)))
  (should (benedict-entry-context-p
           (benedict-entry-create :role 'note :content "User prefers ISO dates."
                                  :meta '(:context t :source my-extension))))
  (should-not (benedict-entry-context-p
               (benedict-entry-create :role 'note :meta '(:context nil)))))

;;;; Content blocks

(ert-deftest benedict-message-block-constructors-omit-nil-options ()
  "Absent optional keys are absent, not present and nil, so `equal' behaves."
  (should (equal (benedict-block-text "hi") '(:type text :text "hi")))
  (should (equal (benedict-block-text "hi" :signature "sig")
                 '(:type text :text "hi" :signature "sig")))
  (should (equal (benedict-block-thinking "why") '(:type thinking :thinking "why")))
  (should (equal (benedict-block-thinking "" :signature "sig" :redacted t)
                 '(:type thinking :thinking "" :signature "sig" :redacted t)))
  (should (equal (benedict-block-image "AAAA" "image/png")
                 '(:type image :data "AAAA" :mime-type "image/png")))
  (should (equal (benedict-block-tool-call "c1" 'eval-elisp '(:form "(+ 1 1)"))
                 '(:type tool-call :id "c1" :name eval-elisp :arguments (:form "(+ 1 1)"))))
  (should (equal (benedict-block-tool-result "c1" 'eval-elisp "2")
                 '(:type tool-result :id "c1" :name eval-elisp :content "2")))
  (should (equal (benedict-block-tool-result "c1" 'eval-elisp "boom" :error-p t)
                 '(:type tool-result :id "c1" :name eval-elisp :content "boom" :error-p t))))

(ert-deftest benedict-message-block-accessors-and-predicates ()
  (let ((block (benedict-block-tool-result "c1" 'eval-elisp "2")))
    (should (eq (benedict-block-type block) 'tool-result))
    (should (benedict-block-tool-result-p block))
    (should-not (benedict-block-text-p block))
    (should (equal (benedict-block-get block :content) "2"))
    (should (equal (benedict-block-get block :error-p 'absent) 'absent))
    ;; Present-but-nil is distinguished from absent.
    (should-not (benedict-block-get '(:type text :text nil) :text 'absent))))

(ert-deftest benedict-message-blocks-of-type-preserves-order ()
  (let ((blocks (list (benedict-block-text "a")
                      (benedict-block-thinking "t")
                      (benedict-block-text "b"))))
    (should (equal (benedict-blocks-of-type blocks 'text)
                   (list (benedict-block-text "a") (benedict-block-text "b"))))
    (should (= 1 (length (benedict-blocks-of-type blocks 'thinking))))
    (should-not (benedict-blocks-of-type blocks 'image))))

(ert-deftest benedict-message-block-pcase-pattern ()
  (should (equal "yo" (pcase (benedict-block-text "yo")
                        ((benedict-block text :text s) s))))
  (should (equal '(eval-elisp "c1")
                 (pcase (benedict-block-tool-call "c1" 'eval-elisp '(:form "1"))
                   ((benedict-block tool-call :name n :id i) (list n i)))))
  ;; The type must match.
  (should (eq 'fell-through
              (pcase (benedict-block-text "no")
                ((benedict-block thinking) 'matched)
                (_ 'fell-through))))
  ;; Keys may carry patterns, not just bindings.
  (should (eq 'redacted
              (pcase (benedict-block-thinking "" :redacted t)
                ((benedict-block thinking :redacted 't) 'redacted)
                (_ 'plain)))))

(ert-deftest benedict-message-entry-content-helpers ()
  (let ((entry (benedict-entry-create
                :role 'assistant
                :content (list (benedict-block-text "one ")
                               (benedict-block-thinking "hidden")
                               (benedict-block-text "two")
                               (benedict-block-tool-call "c1" 'eval-elisp nil)))))
    ;; Thinking is not text and must not leak into the rendered string.
    (should (equal (benedict-entry-text entry) "one two"))
    (should (= 1 (length (benedict-entry-tool-calls entry))))
    (should-not (benedict-entry-tool-results entry)))
  (should (equal "" (benedict-entry-text (benedict-entry-create :role 'user)))))

;;;; The transcript tree

(ert-deftest benedict-message-append-honors-an-explicit-parent ()
  (let* ((tr (benedict-transcript-create :session-id "s1"))
         (u1 (benedict-transcript-append tr (benedict-entry-create :role 'user :content "a")))
         (_a1 (benedict-transcript-append tr (benedict-entry-create :role 'assistant :content "b")))
         (u2 (benedict-transcript-append
              tr (benedict-entry-create :role 'user :content "c"
                                        :parent (benedict-entry-id u1)))))
    (should (equal (benedict-entry-parent u2) (benedict-entry-id u1)))
    (should (equal (benedict-transcript-head tr) (benedict-entry-id u2)))))

(ert-deftest benedict-message-forking-to-nil-starts-a-new-root ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (benedict-transcript-append tr (benedict-entry-create :role 'user :content "a"))
    (benedict-transcript-fork tr nil)
    (let ((root (benedict-transcript-append
                 tr (benedict-entry-create :role 'user :content "b"))))
      (should-not (benedict-entry-parent root))
      (should (= 2 (length (benedict-transcript-children tr nil))))
      (should (equal (mapcar #'benedict-entry-text (benedict-transcript-path tr))
                     '("b"))))))

(ert-deftest benedict-message-append-honors-a-preset-id-and-absorbs-its-counter ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (benedict-transcript-append
     tr (benedict-entry-create :role 'user :content "a" :id "s1-e0042"))
    (should (= 42 (benedict-transcript-counter tr)))
    (let ((next (benedict-transcript-append
                 tr (benedict-entry-create :role 'assistant :content "b"))))
      (should (equal (benedict-entry-id next) "s1-e0043")))))

(ert-deftest benedict-message-duplicate-ids-are-rejected ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (benedict-transcript-append
     tr (benedict-entry-create :role 'user :content "a" :id "dup"))
    (should-error (benedict-transcript-append
                   tr (benedict-entry-create :role 'user :content "b" :id "dup"))
                  :type 'benedict-entry-error)))

(ert-deftest benedict-message-unknown-parent-is-rejected ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (should-error (benedict-transcript-append
                   tr (benedict-entry-create :role 'user :content "a" :parent "nope"))
                  :type 'benedict-transcript-broken-chain)))

(ert-deftest benedict-message-insert-does-not-move-head ()
  "The load path replays head separately, so inserting must leave it alone."
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (benedict-transcript-insert
     tr (benedict-entry-create :role 'user :content "a" :id "s1-e0001"))
    (should-not (benedict-transcript-head tr))
    (should (= 1 (benedict-transcript-counter tr)))
    (should-error (benedict-transcript-insert
                   tr (benedict-entry-create :role 'user :content "b"))
                  :type 'benedict-entry-error)))

(ert-deftest benedict-message-fork-rejects-unknown-ids ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (should-error (benedict-transcript-fork tr "nope")
                  :type 'benedict-transcript-unknown-entry)
    ;; nil is always legal: it means "the next append starts a root".
    (should-not (benedict-transcript-fork tr nil))))

(ert-deftest benedict-message-siblings-rejects-unknown-ids ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (should-error (benedict-transcript-siblings tr "nope")
                  :type 'benedict-transcript-unknown-entry)))

(ert-deftest benedict-message-path-on-an-empty-transcript-is-nil ()
  (should-not (benedict-transcript-path (benedict-transcript-create :session-id "s1"))))

(ert-deftest benedict-message-path-rejects-unknown-ids ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (benedict-transcript-append tr (benedict-entry-create :role 'user :content "a"))
    (should-error (benedict-transcript-path tr "nope")
                  :type 'benedict-transcript-unknown-entry)))

(ert-deftest benedict-message-path-detects-a-cycle ()
  "A corrupted or hand-edited log must error rather than hang a renderer."
  (let* ((tr (benedict-transcript-create :session-id "s1"))
         (a (benedict-transcript-append tr (benedict-entry-create :role 'user :content "a")))
         (b (benedict-transcript-append tr (benedict-entry-create :role 'assistant :content "b"))))
    ;; Reach past the API to build something the API cannot build.
    (setf (benedict-entry-parent a) (benedict-entry-id b))
    (should-error (benedict-transcript-path tr) :type 'benedict-transcript-cycle)))

(ert-deftest benedict-message-path-detects-a-broken-chain ()
  (let* ((tr (benedict-transcript-create :session-id "s1"))
         (a (benedict-transcript-append tr (benedict-entry-create :role 'user :content "a"))))
    (benedict-transcript-append tr (benedict-entry-create :role 'assistant :content "b"))
    (remhash (benedict-entry-id a) (benedict-transcript-table tr))
    (should-error (benedict-transcript-path tr) :type 'benedict-transcript-broken-chain)))

(ert-deftest benedict-message-entries-are-in-append-order ()
  (let ((tr (benedict-transcript-create :session-id "s1")))
    (dolist (text '("a" "b" "c"))
      (benedict-transcript-append tr (benedict-entry-create :role 'user :content text)))
    (benedict-transcript-fork tr "s1-e0001")
    (benedict-transcript-append tr (benedict-entry-create :role 'user :content "d"))
    (should (equal (mapcar #'benedict-entry-text (benedict-transcript-entries tr))
                   '("a" "b" "c" "d")))))

(ert-deftest benedict-message-transcript-equal-p-compares-entries-and-head ()
  (cl-flet ((build (head-text)
              (let ((tr (benedict-transcript-create :session-id "s1")))
                (benedict-transcript-append
                 tr (benedict-entry-create :role 'user :content "a" :timestamp 1.0))
                (benedict-transcript-append
                 tr (benedict-entry-create :role 'assistant :content head-text
                                           :timestamp 2.0))
                tr)))
    (should (benedict-transcript-equal-p (build "b") (build "b")))
    (should-not (benedict-transcript-equal-p (build "b") (build "c")))
    ;; Same entries, different head.
    (let ((a (build "b"))
          (b (build "b")))
      (benedict-transcript-fork b "s1-e0001")
      (should-not (benedict-transcript-equal-p a b)))))

(provide 'benedict-message-test)

;;; benedict-message-test.el ends here
