;;; benedict-chat-perf-test.el --- The chat renderer stays scoped  -*- lexical-binding: t; -*-

;;; Commentary:

;; The regression gate for the failure that made the pre-reset frontend
;; unusable.  That version committed every render by erasing the buffer and
;; rebuilding it, so one streaming delta cost O(transcript): measured against vui
;; 1.0.0, 0.6ms at ten entries and 32ms at two hundred.  A long session became
;; unusable and no functional test noticed, because every assertion about
;; CONTENT still passed.
;;
;; Two assertions, deliberately different in kind:
;;
;; - `benedict-chat-perf-a-delta-does-not-disturb-earlier-regions' is
;;   STRUCTURAL and fully deterministic.  Markers placed in already-rendered
;;   regions cannot survive an erase-and-rebuild, so this fails on the exact
;;   mechanism at issue with no timing, no threshold, and nothing
;;   machine-dependent.  It is the assertion worth trusting.
;;
;; - `benedict-chat-perf-delta-cost-is-flat-in-transcript-size' is a RATIO
;;   between two measurements in the same process, not a millisecond threshold.
;;   An absolute bound would be a flaky test on a loaded machine; a ratio has no
;;   machine-dependent constant in it.  Measured flat today (0.010ms at both ten
;;   and five hundred entries), so the tolerance below is enormous headroom
;;   rather than a tuned value.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'vui)

(defconst benedict-chat-perf-test--deltas 120
  "Streaming deltas driven per measurement.")

(defconst benedict-chat-perf-test--tolerance 3.0
  "How much slower a delta may get when the transcript grows 10x.

Flat is 1.0.  Linear in transcript size -- the regression this guards --
would be roughly 10.  Three leaves room for allocation noise and a loaded
machine while still failing long before a linear renderer would be
usable.")

(defun benedict-chat-perf-test--script (deltas)
  "Return a one-turn fake-provider script streaming DELTAS text events."
  (list (append '((:type :start)
                  (:type :block-start :index 0 :block-type text))
                (make-list deltas '(:type :block-delta :index 0 :delta "token "))
                '((:type :block-end :index 0)
                  (:type :done :reason stop)))))

(defun benedict-chat-perf-test--fill (session count)
  "Append COUNT complete entries to SESSION's transcript.

Uses `benedict-session-append', which is a tree operation that fires no
hooks -- exactly right here, since the point is to have a large
transcript to RENDER, not to exercise the reducer building one."
  (dotimes (i count)
    (benedict-session-append
     session
     (benedict-entry-create
      :role (if (cl-evenp i) 'user 'assistant)
      :content (list (benedict-block-text
                      (format "Entry %d. %s" i
                              (mapconcat #'identity
                                         (make-list 12 "some prose") " "))))))))

(defun benedict-chat-perf-test--seconds-per-delta (entries)
  "Return seconds per streaming delta with ENTRIES already in the transcript."
  (let (elapsed)
    (benedict-test-with-clean-registries
      (unwind-protect
          (progn
            (benedict-chat-install)
            (benedict-test-with-manual-defer
              (let* ((session (benedict-test-session
                               (benedict-chat-perf-test--script
                                benedict-chat-perf-test--deltas)))
                     (buffer nil))
                (benedict-chat-perf-test--fill session entries)
                (setq buffer (benedict-chat-for-session session))
                (unwind-protect
                    (progn
                      ;; Cumulative suite heap churn made this ratio suite-order-dependent.
                      ;; Collect before each phase so the measurement is deterministic.
                      (garbage-collect)
                      (let ((start (float-time)))
                        (benedict-session-submit session "go")
                        (benedict-test-drain 2000)
                        (setq elapsed (/ (- (float-time) start)
                                         (float benedict-chat-perf-test--deltas)))))
                  (benedict-chat-detach session)
                  (when (buffer-live-p buffer) (kill-buffer buffer))))))
        (benedict-chat-uninstall)))
    elapsed))

(ert-deftest benedict-chat-perf-a-delta-does-not-disturb-earlier-regions ()
  "Streaming leaves every earlier entry's region exactly where it was.

Markers are the assertion because an erase-and-rebuild commit strands
them.  Checking both the first and the last pre-existing entry catches a
renderer that keeps the head of the buffer but rewrites its tail."
  (benedict-test-with-clean-registries
    (unwind-protect
        (progn
          (benedict-chat-install)
          (benedict-test-with-manual-defer
            (let* ((session (benedict-test-session
                             (benedict-chat-perf-test--script 60)))
                   (buffer nil))
              (benedict-chat-perf-test--fill session 40)
              (setq buffer (benedict-chat-for-session session))
              (unwind-protect
                  (with-current-buffer buffer
                    (let ((first-marker (save-excursion
                                          (goto-char (point-min))
                                          (should (search-forward "Entry 0." nil t))
                                          (copy-marker (match-beginning 0))))
                          (last-marker (save-excursion
                                         (goto-char (point-min))
                                         (should (search-forward "Entry 39." nil t))
                                         (copy-marker (match-beginning 0)))))
                      (benedict-session-submit session "go")
                      (benedict-test-drain 2000)
                      ;; Both markers survive, and each still sits on the text
                      ;; it was placed on -- so nothing above the stream tail
                      ;; was rewritten, not merely that the buffer still parses.
                      (should (marker-position first-marker))
                      (should (marker-position last-marker))
                      (should (string-prefix-p
                               "Entry 0."
                               (buffer-substring-no-properties
                                first-marker (+ first-marker 8))))
                      (should (string-prefix-p
                               "Entry 39."
                               (buffer-substring-no-properties
                                last-marker (+ last-marker 9))))
                      ;; And the run really did render into this buffer.
                      (should (string-match-p "token token"
                                              (buffer-substring-no-properties
                                               (point-min) (point-max))))))
                (benedict-chat-detach session)
                (when (buffer-live-p buffer) (kill-buffer buffer))))))
      (benedict-chat-uninstall))))

(ert-deftest benedict-chat-perf-delta-cost-is-flat-in-transcript-size ()
  "A delta costs about the same into a 200-entry transcript as into a 20-entry one.

The ratio, not the absolute time, is the assertion: see this file's
commentary for why."
  ;; Warm up so the first measurement is not paying for autoloads and the
  ;; first-render path that the second one will not.
  (benedict-chat-perf-test--seconds-per-delta 20)
  (let* ((small (benedict-chat-perf-test--seconds-per-delta 20))
         (large (benedict-chat-perf-test--seconds-per-delta 200))
         (ratio (/ large (max small 1e-9))))
    (should (< ratio benedict-chat-perf-test--tolerance))))

(provide 'benedict-chat-perf-test)
;;; benedict-chat-perf-test.el ends here
