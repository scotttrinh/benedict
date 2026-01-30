;;; benedict-vui-turn-header-test.el --- Tests for VUI turn header -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI turn header component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-turn-header)

(ert-deftest benedict-vui-turn-header-uses-role-badge ()
  "Header uses role badge based on message role."
  (let (badge-status)
    (cl-letf (((symbol-function 'benedict-vui-badge)
               (lambda (&rest args)
                 (setq badge-status (plist-get args :status))
                 'badge))
              ((symbol-function 'vui-hstack)
               (lambda (&rest _children) 'header)))
      (vui-component 'benedict-vui-turn-header--render '(:role "user"))
      (should (eq badge-status 'user)))))

(ert-deftest benedict-vui-turn-header-formats-timestamp ()
  "Timestamp formatting uses the standard header format."
  (let* ((timestamp (encode-time 5 4 15 2 1 2025))
         (expected (format-time-string
                    benedict-vui-turn-header--timestamp-format
                    timestamp)))
    (should (equal (vui-component 'benedict-vui-turn-header--timestamp-string timestamp)
                   expected))))

(ert-deftest benedict-vui-turn-header-handles-missing-timestamp ()
  "Missing timestamp does not render a timestamp node."
  (let (timestamp-called)
    (cl-letf (((symbol-function 'vui-text)
               (lambda (&rest _args)
                 (setq timestamp-called t)
                 'text))
              ((symbol-function 'benedict-vui-badge)
               (lambda (&rest _args) 'badge))
              ((symbol-function 'vui-hstack)
               (lambda (&rest _children) 'header)))
      (vui-component 'benedict-vui-turn-header--render '(:role assistant))
      (should-not timestamp-called))))

(provide 'test/benedict-vui-turn-header-test)
;;; benedict-vui-turn-header-test.el ends here
