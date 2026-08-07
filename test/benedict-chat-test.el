;;; benedict-chat-test.el --- Chat frontend render contract  -*- lexical-binding: t; -*-

;;; Commentary:

;; Phase 5's exit criterion (SPEC-001 14): streaming renders incrementally,
;; branch siblings are visible and navigable, and the whole frontend is built on
;; the published API of 4.1 and the hooks of 4.4.  The criterion tests are
;; `benedict-chat-streams-a-partial-message-before-it-completes' and
;; `benedict-chat-branch-siblings-are-visible-and-navigable'.
;;
;; Assertions are on the mounted buffer, which is where the pre-reset suite
;; learned the only useful coverage lived: per-component render snapshots were
;; deleted across five commits for catching nothing.
;;
;; There is deliberately no `vui-flush-sync' anywhere here.  The chat buffer is
;; written by `vui-stream', whose appends and updates hit the buffer
;; synchronously rather than scheduling a render, so the buffer is already
;; current when a hook returns.  Worse, `vui--root-instance' is BUFFER-LOCAL, so
;; a flush issued inside the chat buffer would force a full root re-render --
;; which re-emits content items and drops component rows.  Flushing here would
;; not synchronize the assertions; it would corrupt what they assert on.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'vui)

(defmacro benedict-chat-test--installed (&rest body)
  "Run BODY with the chat renderer subscribed, unsubscribing afterwards."
  (declare (indent 0) (debug t))
  `(unwind-protect (progn (benedict-chat-install) ,@body)
     (benedict-chat-uninstall)))

(defmacro benedict-chat-test--with-buffer (session-form &rest body)
  "Bind `session' and `buffer' from SESSION-FORM and run BODY, then clean up."
  (declare (indent 1) (debug t))
  `(let* ((session ,session-form)
          (buffer (benedict-chat-for-session session)))
     (unwind-protect (progn ,@body)
       (benedict-chat-detach session)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun benedict-chat-test--text (buffer)
  "Return BUFFER's contents.  No flush: see this file's commentary."
  (with-current-buffer buffer (buffer-substring-no-properties
                               (point-min) (point-max))))

(defun benedict-chat-test--echo-tool ()
  "Register a tool echoing its `text' argument."
  (benedict-tool-register
   (benedict-tool-create
    :id 'benedict-chat-test-echo
    :description "Echo the text back."
    :parameters '((text :type string :required t))
    :sync t
    :handler (lambda (invocation)
               (benedict-tool-result
                :content (benedict-tool-arg invocation :text))))))

;;;; Exit criterion: streaming renders incrementally

(ert-deftest benedict-chat-streams-a-partial-message-before-it-completes ()
  "A partial message is in the buffer before the full one is.

The negative half is the load-bearing half: asserting only that the final
text arrives would pass just as well against a renderer that waited for
the stream to close and drew it once."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             '(((:type :start)
                (:type :block-start :index 0 :block-type text)
                (:type :block-delta :index 0 :delta "Hello")
                (:type :block-delta :index 0 :delta " there")
                (:type :block-end :index 0)
                (:type :done :reason stop))))
          (benedict-session-submit session "Hi")
          ;; Catch the moment the first delta has landed and the second has not.
          (should (benedict-test-run-until
                   (lambda ()
                     (let ((text (benedict-chat-test--text buffer)))
                       (and (string-match-p "Hello" text)
                            (not (string-match-p "Hello there" text)))))))
          (benedict-test-drain)
          (let ((text (benedict-chat-test--text buffer)))
            (should (string-match-p "Hello there" text))
            (should (string-match-p "you" text))
            (should (string-match-p "assistant" text))))))))

(ert-deftest benedict-chat-streaming-does-not-rebuild-the-buffer ()
  "A delta leaves earlier text untouched, proving the re-render is scoped.

A marker in an already-rendered region is the assertion: an erase-and-
rebuild commit would strand it, so this fails loudly on exactly the
regression that made the pre-reset frontend unusable.  It is structural
and deterministic -- no timing, no threshold, nothing machine-dependent."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             (list '((:text "First answer."))
                   (append '((:type :start)
                             (:type :block-start :index 0 :block-type text))
                           (make-list 40 '(:type :block-delta :index 0
                                                 :delta "token "))
                           '((:type :block-end :index 0)
                             (:type :done :reason stop)))))
          (benedict-session-submit session "one")
          (benedict-test-drain)
          (let ((marker (with-current-buffer buffer
                          (save-excursion
                            (goto-char (point-min))
                            (should (search-forward "First answer." nil t))
                            (copy-marker (match-beginning 0))))))
            (benedict-session-submit session "two")
            (benedict-test-drain)
            (should (marker-position marker))
            (with-current-buffer buffer
              (should (string-prefix-p
                       "First answer."
                       (buffer-substring-no-properties
                        (marker-position marker)
                        (min (point-max) (+ (marker-position marker) 13))))))))))))

;;;; Exit criterion: branch siblings are visible and navigable

(ert-deftest benedict-chat-branch-siblings-are-visible-and-navigable ()
  "Two branches from one fork point render an affordance and can be cycled."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             '(((:text "Branch one."))
               ((:text "Branch two."))))
          (benedict-session-submit session "go")
          (benedict-test-drain)
          (let* ((path (benedict-session-path session))
                 (user-entry (seq-find #'benedict-entry-user-p path)))
            ;; Fork back to the user entry and answer it a second time.
            (benedict-session-fork session (benedict-entry-id user-entry))
            (benedict-session-submit session nil)
            (benedict-test-drain)
            (let ((text (benedict-chat-test--text buffer)))
              (should (string-match-p "Branch two." text))
              (should (string-match-p "\\[2/2\\]" text)))
            ;; Cycle back to the first branch.
            (with-current-buffer buffer (benedict-chat-previous-sibling))
            (let ((text (benedict-chat-test--text buffer)))
              (should (string-match-p "Branch one." text))
              (should-not (string-match-p "Branch two." text))
              (should (string-match-p "\\[1/2\\]" text)))))))))

;;;; Tool calls, aborts, and isolation

(ert-deftest benedict-chat-renders-a-tool-call-and-its-result ()
  "A tool call and the result answering it both reach the buffer."
  (benedict-test-with-clean-registries
    (benedict-chat-test--echo-tool)
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             '(((:tool-call benedict-chat-test-echo (:text "pong")))
               ((:text "It said pong.")))
             :tools '(benedict-chat-test-echo))
          (benedict-session-submit session "call it")
          (benedict-test-drain)
          (let ((text (benedict-chat-test--text buffer)))
            (should (string-match-p "benedict-chat-test-echo" text))
            (should (string-match-p "pong" text))
            (should (string-match-p "It said pong." text))))))))

(ert-deftest benedict-chat-renders-an-aborted-turn ()
  "Aborting mid-stream leaves a terminal entry visible in the buffer."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             '(((:type :start)
                (:type :block-start :index 0 :block-type text)
                (:type :block-delta :index 0 :delta "Partial")
                (:type :block-delta :index 0 :delta " more")
                (:type :block-end :index 0)
                (:type :done :reason stop))))
          (benedict-session-submit session "go")
          (should (benedict-test-run-until
                   (lambda ()
                     (string-match-p "Partial" (benedict-chat-test--text buffer)))))
          (benedict-session-abort session)
          (benedict-test-drain)
          (should (eq (benedict-session-state session) 'idle))
          (let ((text (benedict-chat-test--text buffer)))
            (should (string-match-p "Partial" text))
            (should (string-match-p "aborted" text))))))))

(ert-deftest benedict-chat-keeps-two-sessions-in-their-own-buffers ()
  "A delta in one session's buffer does not reach another's.

The handlers are global, so this is what the weak session-to-buffer map
buys: a session with no attached buffer is a no-op, and a session with one
never writes into someone else's."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session '(((:text "From session one."))))
          (let* ((other (benedict-test-session '(((:text "From session two.")))))
                 (other-buffer (benedict-chat-for-session other)))
            (unwind-protect
                (progn
                  (benedict-session-submit session "one")
                  (benedict-test-drain)
                  (benedict-session-submit other "two")
                  (benedict-test-drain)
                  (let ((first (benedict-chat-test--text buffer))
                        (second (benedict-chat-test--text other-buffer)))
                    (should (string-match-p "From session one." first))
                    (should-not (string-match-p "From session two." first))
                    (should (string-match-p "From session two." second))
                    (should-not (string-match-p "From session one." second))))
              (benedict-chat-detach other)
              (when (buffer-live-p other-buffer) (kill-buffer other-buffer)))))))))

;;;; Component rows survive a redraw

(ert-deftest benedict-chat-revert-keeps-component-rows ()
  "\\`g' rebuilds from the transcript rather than re-rendering the root.

`vui-mode' binds \\`g' to `vui-refresh', which schedules a root re-render;
`vui--stream-render' re-emits content items but SKIPS component rows, so
that path would faithfully redraw the prose and silently drop every tool
card.  Asserting on text alone cannot see the difference, which is why
this asserts on a row's content specifically."
  (benedict-test-with-clean-registries
    (benedict-chat-test--echo-tool)
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             '(((:tool-call benedict-chat-test-echo (:text "pong")))
               ((:text "Done.")))
             :tools '(benedict-chat-test-echo))
          (benedict-session-submit session "call it")
          (benedict-test-drain)
          (should (string-match-p "benedict-chat-test-echo"
                                  (benedict-chat-test--text buffer)))
          (should (eq (lookup-key benedict-chat-mode-map (kbd "g"))
                      #'benedict-chat-revert))
          (with-current-buffer buffer (benedict-chat-revert))
          (let ((text (benedict-chat-test--text buffer)))
            (should (string-match-p "benedict-chat-test-echo" text))
            (should (string-match-p "Done." text))))))))

;;;; Installation is idempotent

(ert-deftest benedict-chat-install-is-idempotent ()
  "Installing twice subscribes each handler once, per SPEC-001 9.2."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-chat-install)
      (should (= 1 (seq-count (lambda (fn) (eq fn #'benedict-chat-on-entry-update))
                              benedict-entry-update-functions))))))

(provide 'benedict-chat-test)
;;; benedict-chat-test.el ends here
