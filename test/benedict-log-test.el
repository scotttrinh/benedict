;;; benedict-log-test.el --- Tests for level-gated logging  -*- lexical-binding: t; -*-

;;; Commentary:

;; A logger is easy to write and easy to write wrongly, and both of its wrong
;; versions are quiet.  These tests pin the three claims the rest of the system
;; makes about this one.
;;
;; The two thresholds are independent.  `benedict-http' traces every SSE frame,
;; and the whole reason that is affordable is that recording and echoing are
;; separate decisions.  A logger where one threshold governs both is a logger
;; whose useful level cannot be left on.
;;
;; The level macros do not evaluate their arguments when the level is off.  If
;; they did, a disabled trace would still cost a `format' of a payload, once
;; per frame, and the level would be a filter on output rather than on work.
;; `benedict-log-costs-nothing-when-the-level-is-disabled' asserts it directly
;; by putting a side effect in an argument.
;;
;; The ring is bounded and says so.  A history that silently loses its old end
;; is worse than one that admits to it, because the thing being debugged is
;; usually whatever happened first.
;;
;; See SPEC-001 3.2.

;;; Code:

(require 'ert)
(require 'test-helper)

(defmacro benedict-log-test--with-log (&rest body)
  "Evaluate BODY with an empty ring, recording everything and echoing nothing.
The ring, both thresholds, and the limit are global, so a test that left
one changed would change what the next test means."
  (declare (indent 0) (debug body))
  `(let ((benedict-log--records nil)
         (benedict-log--length 0)
         (benedict-log--dropped 0)
         (benedict-log-level 'trace)
         (benedict-log-echo-level nil)
         (benedict-log-limit 500))
     ,@body))

(defun benedict-log-test--messages ()
  "Return the messages of every retained record, oldest first."
  (mapcar (lambda (record) (plist-get record :message))
          (benedict-log-history)))

;;;; Exit criterion: the thresholds are independent

(ert-deftest benedict-log-records-and-echoes-on-separate-thresholds ()
  "Recording at `debug' while echoing at `error' must keep both records."
  (benedict-log-test--with-log
    (let ((echoed nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) echoed))))
        (let ((benedict-log-level 'debug)
              (benedict-log-echo-level 'error))
          (benedict-log-debug "quiet %d" 1)
          (benedict-log-error "loud %d" 2)))
      (should (equal (benedict-log-test--messages) '("quiet 1" "loud 2")))
      (should (equal (mapcar (lambda (line) (string-suffix-p "loud 2" line)) echoed)
                     '(t))))))

;;;; Level gating

(ert-deftest benedict-log-drops-records-below-its-level ()
  (benedict-log-test--with-log
    (let ((benedict-log-level 'warn))
      (benedict-log-error "kept")
      (benedict-log-warn "kept too")
      (benedict-log-info "dropped")
      (benedict-log-trace "dropped too"))
    (should (equal (benedict-log-test--messages) '("kept" "kept too")))))

(ert-deftest benedict-log-records-nothing-when-its-level-is-nil ()
  "Nil is off, not `error' -- there is no floor that always records."
  (benedict-log-test--with-log
    (let ((benedict-log-level nil))
      (benedict-log-error "gone"))
    (should-not (benedict-log-history))))

(ert-deftest benedict-log-costs-nothing-when-the-level-is-disabled ()
  "A disabled level must not evaluate its arguments.
This is why the level entry points are macros: a trace that formats its
payload before discovering it is disabled is a trace nobody can afford to
leave enabled."
  (benedict-log-test--with-log
    (let ((evaluated 0))
      (let ((benedict-log-level 'warn)
            (benedict-log-echo-level nil))
        (benedict-log-trace "%d" (cl-incf evaluated)))
      (should (= evaluated 0))
      (let ((benedict-log-level 'trace))
        (benedict-log-trace "%d" (cl-incf evaluated)))
      (should (= evaluated 1)))))

(ert-deftest benedict-log-signals-on-an-unknown-level ()
  "An unknown level is a programming error and says so."
  (should-error (benedict-log-record 'verbose "nope") :type 'benedict-error))

;;;; The ring

(ert-deftest benedict-log-drops-its-oldest-records-past-the-limit ()
  (benedict-log-test--with-log
    (let ((benedict-log-limit 3))
      (dotimes (index 5)
        (benedict-log-info "record %d" index))
      (should (equal (benedict-log-test--messages)
                     '("record 2" "record 3" "record 4")))
      (should (= (benedict-log-dropped) 2)))))

(ert-deftest benedict-log-history-reads-oldest-first ()
  "The ring is newest-first internally; readers get chronological order."
  (benedict-log-test--with-log
    (benedict-log-info "first")
    (benedict-log-info "second")
    (should (equal (benedict-log-test--messages) '("first" "second")))))

(ert-deftest benedict-log-history-filters-by-level ()
  (benedict-log-test--with-log
    (benedict-log-error "bad")
    (benedict-log-debug "chatty")
    (should (equal (mapcar (lambda (record) (plist-get record :message))
                           (benedict-log-history 'warn))
                   '("bad")))))

(ert-deftest benedict-log-clear-empties-the-ring-and-the-drop-count ()
  (benedict-log-test--with-log
    (let ((benedict-log-limit 1))
      (benedict-log-info "a")
      (benedict-log-info "b")
      (should (= (benedict-log-dropped) 1))
      (benedict-log-clear)
      (should-not (benedict-log-history))
      (should (= (benedict-log-dropped) 0)))))

(ert-deftest benedict-log-lines-are-readable ()
  "`benedict-log-lines' is for a human or an agent, not for a parser."
  (benedict-log-test--with-log
    (benedict-log-warn "something happened")
    (let ((line (car (benedict-log-lines))))
      (should (string-match-p "\\`[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\." line))
      (should (string-match-p "warn" line))
      (should (string-suffix-p "something happened" line)))))

(provide 'benedict-log-test)

;;; benedict-log-test.el ends here
