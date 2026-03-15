;;; benedict-vui-streaming-indicator-test.el --- Tests for VUI streaming indicator -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI streaming indicator component.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-streaming-indicator)

(vui-defcomponent benedict-vui-streaming-indicator-test--harness ()
  :state ((visible nil))
  :render
  (vui-vstack
   (vui-button "Show" :on-click (lambda (&rest _) (vui-set-state :visible t)))
   (vui-button "Hide" :on-click (lambda (&rest _) (vui-set-state :visible nil)))
   (vui-component 'benedict-vui-streaming-indicator :visible visible)))

(ert-deftest benedict-vui-streaming-indicator-frame-wrapping ()
  "Frame index wraps around the frame list."
  (should (equal (benedict-vui-streaming-indicator--frame 0)
                 (elt benedict-vui-streaming-indicator--frames 0)))
  (should (equal (benedict-vui-streaming-indicator--frame 1)
                 (elt benedict-vui-streaming-indicator--frames 1)))
  (should (equal (benedict-vui-streaming-indicator--frame
                 (length benedict-vui-streaming-indicator--frames))
                 (elt benedict-vui-streaming-indicator--frames 0)))
  (should (equal (benedict-vui-streaming-indicator--frame
                  (* 2 (length benedict-vui-streaming-indicator--frames)))
                 (elt benedict-vui-streaming-indicator--frames 0))))

(ert-deftest benedict-vui-streaming-indicator-visible-transitions-start-and-stop-timer ()
  "Toggling visible state starts and then stops the animation timer."
  (let ((run-count 0)
        (run-args nil)
        (cancelled nil)
        (fake-timer (list :timer "streaming")))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest args)
                 (setq run-count (1+ run-count))
                 (setq run-args args)
                 fake-timer))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (push timer cancelled))))
      (with-mounted-vui-component
          (vui-component 'benedict-vui-streaming-indicator-test--harness)
        (should (= run-count 0))
        (benedict-vui-test--click-button-labeled "Show")
        (vui-flush-sync)
        (should (> run-count 0))
        (should (equal (seq-take run-args 2)
                       (list benedict-vui-streaming-indicator--interval
                             benedict-vui-streaming-indicator--interval)))
        (should (cl-some (lambda (frame)
                           (string-match-p (regexp-quote frame) (buffer-string)))
                         benedict-vui-streaming-indicator--frames))
        (benedict-vui-test--click-button-labeled "Hide")
        (vui-flush-sync)
        (should (> (length cancelled) 0))
        (should-not (cl-some (lambda (frame)
                               (string-match-p (regexp-quote frame) (buffer-string)))
                             benedict-vui-streaming-indicator--frames))))))

(ert-deftest benedict-vui-streaming-indicator-cancels-timer-on-unmount ()
  "Unmounting a visible indicator cancels its animation timer."
  (skip-unless (fboundp 'vui-unmount))
  (let ((cancelled nil)
        (fake-timer (list :timer "streaming")))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _)
                 fake-timer))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (push timer cancelled))))
      (with-temp-buffer
        (let ((mount (vui-mount (vui-component 'benedict-vui-streaming-indicator :visible t)
                                (buffer-name))))
          (vui-flush-sync)
          (should mount)
          (vui-unmount mount)
          (vui-flush-sync))))
    (should (> (length cancelled) 0))
    (should (equal (car cancelled) fake-timer))))

(provide 'test/benedict-vui-streaming-indicator-test)
;;; benedict-vui-streaming-indicator-test.el ends here
