;;; benedict-store-test.el --- Tests for the append-only transcript log  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 1's exit criterion is `benedict-store-forked-session-round-trips':
;; write a forked session, reload it from disk, and assert the tree and head are
;; identical.  Several of the other tests exist to pin one specific print
;; binding, because the failure each prevents is silent.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benedict-store)

(defun benedict-store-test--lines (file)
  "Return the lines of FILE, excluding the trailing empty one."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" t)))

(defmacro benedict-store-test--silently (&rest body)
  "Evaluate BODY with `display-warning' collecting instead of printing.
Returns a cons of BODY's value and the list of warning messages."
  `(let ((warnings nil))
     (cl-letf (((symbol-function 'display-warning)
                (lambda (_type message &rest _) (push message warnings))))
       (cons (progn ,@body) (nreverse warnings)))))

;;;; Phase 1 exit criterion

(ert-deftest benedict-store-forked-session-round-trips ()
  "A session that branches and ends on a fork reloads exactly as it was."
  (benedict-test-with-store-dir _dir
    (let* ((session-id "test-0001")
           (store (benedict-store-open session-id))
           (transcript (benedict-transcript-create :session-id session-id))
           u1 a1 a2)
      (cl-flet ((add (role text)
                  (let ((entry (benedict-transcript-append
                                transcript
                                (benedict-entry-create :role role :content text))))
                    (benedict-store-append store entry)
                    entry)))
        (setq u1 (add 'user "hi"))
        (setq a1 (add 'assistant "left"))
        ;; Branch off the user entry.
        (benedict-transcript-fork transcript (benedict-entry-id u1))
        (benedict-store-set-head store (benedict-entry-id u1))
        (setq a2 (add 'assistant "right"))
        ;; End the session sitting on the abandoned branch, so head is not the
        ;; last record in the log.  This is the case a head marker exists for.
        (benedict-transcript-fork transcript (benedict-entry-id a1))
        (benedict-store-close store (benedict-entry-id a1)))
      (let ((loaded (benedict-store-load session-id)))
        (should (benedict-transcript-equal-p loaded transcript))
        (should (equal (benedict-transcript-head loaded) (benedict-entry-id a1)))
        (should (equal (benedict-transcript-entries loaded)
                       (benedict-transcript-entries transcript)))
        (should (= (benedict-transcript-counter loaded)
                   (benedict-transcript-counter transcript)))
        ;; Both branches survive, and the reloaded head materializes the one the
        ;; session ended on.
        (should (equal (mapcar #'benedict-entry-text (benedict-transcript-path loaded))
                       '("hi" "left")))
        (should (equal (mapcar #'benedict-entry-text
                               (benedict-transcript-path loaded (benedict-entry-id a2)))
                       '("hi" "right")))))))

;;;; The one-form-per-line invariant

(ert-deftest benedict-store-writes-one-line-per-record ()
  "Content full of newlines must not become content full of records."
  (benedict-test-with-store-dir _dir
    (let* ((store (benedict-store-open "lines"))
           (transcript (benedict-transcript-create :session-id "lines"))
           (text "a\nb\n\tc\r\nd"))
      (dolist (content (list text "plain" text))
        (benedict-store-append
         store (benedict-transcript-append
                transcript (benedict-entry-create :role 'user :content content))))
      ;; One header plus three entries.
      (should (= 4 (length (benedict-store-test--lines
                            (benedict-store-file store)))))
      (let ((loaded (benedict-store-load "lines")))
        (should (equal (mapcar #'benedict-entry-text
                               (benedict-transcript-entries loaded))
                       (list text "plain" text)))))))

(ert-deftest benedict-store-does-not-truncate-large-entries ()
  "Print settings must survive an Emacs configured to abbreviate output."
  (benedict-test-with-store-dir _dir
    (let* ((store (benedict-store-open "big"))
           (transcript (benedict-transcript-create :session-id "big"))
           (long-string (make-string 100000 ?x))
           (many-blocks (cl-loop for i below 2000
                                 collect (benedict-block-text (number-to-string i))))
           ;; Bind the way an interactive session might have them set.
           (print-length 10)
           (print-level 4)
           entry)
      (setq entry (benedict-transcript-append
                   transcript
                   (benedict-entry-create
                    :role 'assistant
                    :content (cons (benedict-block-text long-string) many-blocks)
                    :meta (list :usage (list :input 1204 :output 88)))))
      (benedict-store-append store entry)
      (let* ((loaded (benedict-store-load "big"))
             (reloaded (car (benedict-transcript-entries loaded))))
        (should (equal reloaded entry))
        (should (= 2001 (length (benedict-entry-content reloaded))))
        (should (= 100000 (length (plist-get (car (benedict-entry-content reloaded))
                                             :text))))))))

;;;; Append-only

(ert-deftest benedict-store-only-ever-appends ()
  "Reopening a session extends its log; earlier bytes never move."
  (benedict-test-with-store-dir _dir
    (let ((transcript (benedict-transcript-create :session-id "grow"))
          prefix file)
      (let ((store (benedict-store-open "grow")))
        (setq file (benedict-store-file store))
        (benedict-store-append
         store (benedict-transcript-append
                transcript (benedict-entry-create :role 'user :content "first")))
        (setq prefix (with-temp-buffer (insert-file-contents file) (buffer-string))))
      ;; A fresh handle on an existing session.
      (let ((store (benedict-store-open "grow")))
        (benedict-store-append
         store (benedict-transcript-append
                transcript (benedict-entry-create :role 'assistant :content "second"))))
      (let ((contents (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should (string-prefix-p prefix contents))
        (should (> (length contents) (length prefix))))
      (should (equal (mapcar #'benedict-entry-text
                             (benedict-transcript-entries (benedict-store-load "grow")))
                     '("first" "second"))))))

(ert-deftest benedict-store-elides-redundant-records ()
  "Appending already moves head, so only a fork needs a record of its own."
  (benedict-test-with-store-dir _dir
    (let* ((store (benedict-store-open "elide"))
           (transcript (benedict-transcript-create :session-id "elide"))
           (entry (benedict-transcript-append
                   transcript (benedict-entry-create :role 'user :content "a"))))
      (benedict-store-append store entry)
      (let ((before (length (benedict-store-test--lines (benedict-store-file store)))))
        ;; Head is already here.
        (benedict-store-set-head store (benedict-entry-id entry))
        ;; And a hook that fires twice must not double-write.
        (benedict-store-append store entry)
        (should (= before (length (benedict-store-test--lines
                                   (benedict-store-file store)))))))))

;;;; Paths

(ert-deftest benedict-store-resolves-the-xdg-data-directory ()
  (let* ((temporary (file-name-as-directory (make-temp-file "benedict-xdg-" t)))
         (process-environment (cons (concat "XDG_DATA_HOME=" (directory-file-name temporary))
                                    process-environment))
         (benedict-store-directory nil))
    (unwind-protect
        (should (equal (benedict-store-session-file "s1")
                       (expand-file-name "benedict/sessions/s1.eld" temporary)))
      (delete-directory temporary t))))

(ert-deftest benedict-store-rejects-unusable-session-ids ()
  "Sanitizing would let two sessions collide onto one log."
  (dolist (bad '("../escape" "with/slash" "" ".hidden" "-leading" nil))
    (should-error (benedict-store-session-file bad)
                  :type 'benedict-store-invalid-session-id))
  (should (benedict-store-session-file "20260806T142530-a3f9")))

;;;; Record round trip

(ert-deftest benedict-store-entry-form-round-trip ()
  "Every block type, a float timestamp, and nested metadata survive intact."
  (dolist (entry (list
                  (benedict-entry-create :role 'user :id "s-e0001" :content "hi"
                                         :timestamp 1785000000.5)
                  (benedict-entry-create
                   :role 'assistant :id "s-e0002" :parent "s-e0001"
                   :content (list (benedict-block-text "said" :signature "sig")
                                  (benedict-block-thinking "why" :signature "rs_1")
                                  (benedict-block-thinking "" :redacted t)
                                  (benedict-block-image "AAAA" "image/png")
                                  (benedict-block-tool-call
                                   "call_1" 'eval-elisp '(:form "(+ 1 1)")))
                   :meta '(:provider vercel-ai-gateway :api openai-responses
                           :model "openai/gpt-5"
                           :usage (:input 1204 :output 88) :stop-reason tool-use))
                  (benedict-entry-create
                   :role 'tool-result :id "s-e0003" :parent "s-e0002"
                   :content (list (benedict-block-tool-result
                                   "call_1" 'eval-elisp "2" :error-p t)))
                  (benedict-entry-create :role 'note :id "s-e0004" :content "remember"
                                         :meta '(:context t :source my-extension))))
    (should (equal entry
                   (benedict-store-form->entry (benedict-store-entry->form entry))))))

;;;; Malformed logs

(ert-deftest benedict-store-tolerates-a-truncated-final-record ()
  "A crash mid-append must cost the last entry, not the whole session."
  (benedict-test-with-store-dir _dir
    (let* ((store (benedict-store-open "torn"))
           (transcript (benedict-transcript-create :session-id "torn")))
      (benedict-store-append
       store (benedict-transcript-append
              transcript (benedict-entry-create :role 'user :content "survives")))
      ;; Simulate a write that did not finish.
      (write-region "(:id \"torn-e0002\" :parent nil :role user :content ((:type te"
                    nil (benedict-store-file store) 'append 'no-message)
      (let ((result (benedict-store-test--silently (benedict-store-load "torn"))))
        (should (= 1 (benedict-transcript-count (car result))))
        (should (equal (benedict-entry-text
                        (car (benedict-transcript-entries (car result))))
                       "survives"))
        (should (cdr result)))
      ;; Strictness is available for callers that need to know.
      (let ((benedict-store-strict-load t))
        (should-error (benedict-store-load "torn") :type 'benedict-store-error)))))

(ert-deftest benedict-store-refuses-a-newer-format ()
  "Guessing at a future record shape is worse than refusing to load it."
  (benedict-test-with-store-dir dir
    (let ((file (expand-file-name "future.eld" dir)))
      (write-region "(:type header :format 99 :session-id \"future\")\n" nil file)
      (should-error (benedict-store-load "future") :type 'benedict-store-format-error)
      ;; Even non-strict, which is the point.
      (let ((benedict-store-strict-load nil))
        (should-error (benedict-store-load "future")
                      :type 'benedict-store-format-error)))))

(ert-deftest benedict-store-ignores-unknown-control-records ()
  "A record kind added by a newer writer must not be mistaken for an entry."
  (benedict-test-with-store-dir dir
    (let ((file (expand-file-name "forward.eld" dir)))
      (write-region (concat "(:type header :format 1 :session-id \"forward\")\n"
                            "(:type checkpoint :sha \"abc123\")\n"
                            "(:id \"forward-e0001\" :parent nil :role user"
                            " :timestamp 1.0 :content ((:type text :text \"hi\")) :meta nil)\n")
                    nil file)
      (let ((loaded (benedict-store-load "forward")))
        (should (= 1 (benedict-transcript-count loaded)))
        (should (equal (benedict-transcript-head loaded) "forward-e0001"))))))

(ert-deftest benedict-store-reports-an-unresolvable-head ()
  (benedict-test-with-store-dir dir
    (let ((file (expand-file-name "lost.eld" dir)))
      (write-region (concat "(:type header :format 1 :session-id \"lost\")\n"
                            "(:id \"lost-e0001\" :parent nil :role user"
                            " :timestamp 1.0 :content nil :meta nil)\n"
                            "(:type head :id \"lost-e0099\")\n")
                    nil file)
      (let ((result (benedict-store-test--silently (benedict-store-load "lost"))))
        (should (cdr result))
        ;; Falls back to the last entry rather than leaving head dangling.
        (should (equal (benedict-transcript-head (car result)) "lost-e0001")))
      (let ((benedict-store-strict-load t))
        (should-error (benedict-store-load "lost") :type 'benedict-store-error)))))

(ert-deftest benedict-store-reports-an-unreadable-entry ()
  "An entry the current reader cannot build is a warning, not a lost session."
  (benedict-test-with-store-dir dir
    (let ((file (expand-file-name "weird.eld" dir)))
      (write-region (concat "(:type header :format 1 :session-id \"weird\")\n"
                            "(:id \"weird-e0001\" :parent nil :role telepathy"
                            " :timestamp 1.0 :content nil :meta nil)\n"
                            "(:id \"weird-e0002\" :parent nil :role user"
                            " :timestamp 1.0 :content ((:type text :text \"ok\")) :meta nil)\n")
                    nil file)
      (let ((result (benedict-store-test--silently (benedict-store-load "weird"))))
        (should (cdr result))
        (should (= 1 (benedict-transcript-count (car result))))
        (should (equal (benedict-entry-text
                        (car (benedict-transcript-entries (car result))))
                       "ok"))))))

;;;; Subscription

(ert-deftest benedict-store-persists-through-the-hook-handlers ()
  "The hook handlers work with any object standing in for a session."
  (benedict-test-with-store-dir _dir
    (let* ((session (make-symbol "session"))
           (store (benedict-store-open "hooked"))
           (transcript (benedict-transcript-create :session-id "hooked")))
      ;; With nothing attached, they are no-ops rather than errors.
      (should (benedict-store-on-entry-end
               session (benedict-entry-create :role 'user :content "dropped" :id "x")))
      (benedict-store-attach session store)
      (let ((first (benedict-transcript-append
                    transcript (benedict-entry-create :role 'user :content "a")))
            (second (benedict-transcript-append
                     transcript (benedict-entry-create :role 'assistant :content "b"))))
        (benedict-store-on-entry-end session first)
        (benedict-store-on-entry-end session second)
        (benedict-store-on-head-change session (benedict-entry-id second)
                                       (benedict-entry-id first))
        (benedict-transcript-fork transcript (benedict-entry-id first)))
      (should (benedict-store-detach session))
      (should-not (benedict-store-detach session))
      (let ((loaded (benedict-store-load "hooked")))
        (should (benedict-transcript-equal-p loaded transcript))
        (should (= 2 (benedict-transcript-count loaded)))))))

(provide 'benedict-store-test)

;;; benedict-store-test.el ends here
