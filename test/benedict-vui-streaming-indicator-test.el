;;; benedict-vui-streaming-indicator-test.el --- Tests for VUI streaming indicator -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI streaming indicator component.

;;; Code:

(require 'ert)
(require 'benedict-vui-streaming-indicator)

(ert-deftest benedict-vui-streaming-indicator-frames-exist ()
  "Spinner frames are defined."
  (should (> (length benedict-vui-streaming-indicator--frames) 0))
  (should (cl-every #'stringp benedict-vui-streaming-indicator--frames)))

(ert-deftest benedict-vui-streaming-indicator-frame-wrapping ()
  "Frame index wraps around the frame list."
  (should (equal (vui-component 'benedict-vui-streaming-indicator--frame 0)
                 (elt benedict-vui-streaming-indicator--frames 0)))
  (should (equal (vui-component 'benedict-vui-streaming-indicator--frame 1)
                 (elt benedict-vui-streaming-indicator--frames 1)))
  (should (equal (vui-component 'benedict-vui-streaming-indicator--frame
                  (length benedict-vui-streaming-indicator--frames))
                 (elt benedict-vui-streaming-indicator--frames 0)))
  (should (equal (vui-component 'benedict-vui-streaming-indicator--frame
                  (* 2 (length benedict-vui-streaming-indicator--frames)))
                 (elt benedict-vui-streaming-indicator--frames 0))))

(provide 'test/benedict-vui-streaming-indicator-test)
;;; benedict-vui-streaming-indicator-test.el ends here
