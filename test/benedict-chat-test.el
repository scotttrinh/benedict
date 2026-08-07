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

(defun benedict-chat-test--fontify (buffer)
  "Fontify BUFFER the way redisplay would.  Return BUFFER.

`font-lock-mode' turns itself straight back off when `noninteractive',
which is every run of this suite, so it is forced on here.  Nothing else
is batch-specific: `jit-lock-fontify-now' is exactly what redisplay calls
on meeting text whose `fontified' property is nil, and calling it over
the whole buffer is the same one-chunk request a first display makes."
  (with-current-buffer buffer
    (let ((noninteractive nil)) (font-lock-mode 1))
    (jit-lock-fontify-now (point-min) (point-max)))
  buffer)

(defun benedict-chat-test--faces-on (buffer string)
  "Return the `face' property where STRING first occurs in BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward string nil t)
        (get-text-property (match-beginning 0) 'face)))))

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

;;;; Markdown fontification

(ert-deftest benedict-chat-fontifies-markdown-and-leaves-the-chrome-alone ()
  "Markdown reaches the prose and stops at the role header.

Both halves are the regression.  A transcript BEGINS with chrome, so a
gate that can only keep the one run containing the start of font-lock's
region throws the whole chunk away and the buffer comes out entirely
unstyled -- which is what a `font-lock-extend-region-functions' member
can express and why the gate is a region function instead."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session '(((:text "a **bold** word"))))
          (benedict-session-submit session "Hi")
          (benedict-test-drain)
          (benedict-chat-test--fontify buffer)
          (should (equal '(markdown-bold-face)
                         (benedict-chat-test--faces-on buffer "bold")))
          (should (eq 'benedict-chat-assistant
                      (benedict-chat-test--faces-on buffer "assistant"))))))))

(ert-deftest benedict-chat-defers-markdown-until-the-block-closes ()
  "Half a construct is left unstyled; the whole one is styled when it lands.

The negative half is what pins the design down: fontifying as text
arrives would style a lone \"**\" as markup, and an unclosed fence would
style the rest of the message as code until its partner turned up."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             '(((:type :start)
                (:type :block-start :index 0 :block-type text)
                (:type :block-delta :index 0 :delta "a **bo")
                (:type :block-delta :index 0 :delta "ld** word")
                (:type :block-end :index 0)
                (:type :done :reason stop))))
          (benedict-session-submit session "Hi")
          ;; Catch the moment the opening delimiter has landed unpaired.
          (should (benedict-test-run-until
                   (lambda ()
                     (let ((text (benedict-chat-test--text buffer)))
                       (and (string-match-p "\\*\\*bo" text)
                            (not (string-match-p "bold" text)))))))
          (benedict-chat-test--fontify buffer)
          (should-not (benedict-chat-test--faces-on buffer "**bo"))
          (benedict-test-drain)
          (benedict-chat-test--fontify buffer)
          (should (equal '(markdown-bold-face)
                         (benedict-chat-test--faces-on buffer "bold"))))))))

(ert-deftest benedict-chat-fontifies-a-fence-reassembled-from-deltas ()
  "A fenced block whose delimiters arrived in pieces is still code.

`vui' writes with `inhibit-modification-hooks' bound, so nothing tells
`syntax-propertize' that the text is new and its high-water mark can
already sit past it.  Without the flush in
`benedict-chat--fontify-region' the closed block keeps the syntax
properties of the half-written text it replaced, and the fence is never
recognized."
  (benedict-test-with-clean-registries
    (benedict-chat-test--installed
      (benedict-test-with-manual-defer
        (benedict-chat-test--with-buffer
            (benedict-test-session
             '(((:type :start)
                (:type :block-start :index 0 :block-type text)
                (:type :block-delta :index 0 :delta "```eli")
                (:type :block-delta :index 0 :delta "sp\n(+ 1 2)\n``")
                (:type :block-delta :index 0 :delta "`\n")
                (:type :block-end :index 0)
                (:type :done :reason stop))))
          (benedict-session-submit session "Hi")
          ;; Fontify as the deltas land, so the pass at the end is working
          ;; against stale syntax properties rather than a clean buffer.
          (should (benedict-test-run-until
                   (lambda ()
                     (benedict-chat-test--fontify buffer)
                     (string-match-p "(\\+ 1 2)"
                                     (benedict-chat-test--text buffer)))))
          (benedict-test-drain)
          (benedict-chat-test--fontify buffer)
          (should (memq 'markdown-code-face
                        (benedict-chat-test--faces-on buffer "(+ 1 2)")))
          (should (memq 'markdown-language-keyword-face
                        (benedict-chat-test--faces-on buffer "elisp"))))))))

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
