;;; benedict-vui-streaming-indicator-test.el --- Tests for VUI streaming indicator -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI streaming indicator component.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vui)
(require 'benedict-vui-streaming-indicator)

(ert-deftest benedict-vui-streaming-indicator-frames-exist ()
  "Spinner frames are defined."
  (should (> (length benedict-vui-streaming-indicator--frames) 0))
  (should (cl-every #'stringp benedict-vui-streaming-indicator--frames)))

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

(ert-deftest benedict-vui-streaming-indicator-mount-visible-renders-frame-with-stubbed-timer ()
  "Mounted visible indicator renders a spinner frame without real timers."
  (let ((run-args nil)
        (fake-timer (list :timer "streaming")))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest args)
                 (setq run-args args)
                 fake-timer))
              ((symbol-function 'cancel-timer)
               (lambda (&rest _))))
      (with-temp-buffer
        (let ((buffer-name (buffer-name)))
          (vui-mount
           (vui-component 'benedict-vui-streaming-indicator :visible t)
           buffer-name)
          (vui-flush-sync)
          (let ((text (buffer-string)))
            (should (string-match-p (regexp-quote (car benedict-vui-streaming-indicator--frames))
                                    text)))
          (should run-args)
          (vui-mount
           (vui-component 'benedict-vui-streaming-indicator :visible nil)
           buffer-name)
          (vui-flush-sync))))))

(ert-deftest benedict-vui-streaming-indicator-mount-hidden-renders-no-spinner ()
  "Mounted hidden indicator does not render spinner text."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'benedict-vui-streaming-indicator :visible nil)
       buffer-name)
      (vui-flush-sync)
      (let ((text (buffer-string)))
        (should-not (string-match-p
                     (regexp-quote (car benedict-vui-streaming-indicator--frames))
                     text))))))

(provide 'test/benedict-vui-streaming-indicator-test)
;;; benedict-vui-streaming-indicator-test.el ends here
