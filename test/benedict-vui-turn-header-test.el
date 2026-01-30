;;; benedict-vui-turn-header-test.el --- Tests for VUI turn header -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI turn header component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-turn-header)

(ert-deftest benedict-vui-turn-header-uses-role-badge ()
  "Header uses role badge based on message role."
  (should (eq (benedict-vui-turn-header--normalize-role "user") 'user)))

(ert-deftest benedict-vui-turn-header-formats-timestamp ()
  "Timestamp formatting uses the standard header format."
  (let* ((timestamp (encode-time 5 4 15 2 1 2025))
         (expected (format-time-string
                    benedict-vui-turn-header--timestamp-format
                    timestamp)))
    (should (equal (benedict-vui-turn-header--timestamp-string timestamp)
                   expected))))

(ert-deftest benedict-vui-turn-header-handles-missing-timestamp ()
  "Missing timestamp does not render a timestamp node."
  (should-not (benedict-vui-turn-header--timestamp-node nil)))

(provide 'test/benedict-vui-turn-header-test)
;;; benedict-vui-turn-header-test.el ends here
