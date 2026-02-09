;;; benedict-vui-root-test.el --- Tests for VUI root component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for VUI root component.

;;; Code:

(require 'ert)
(require 'vui)
(require 'benedict-session)
(require 'test/benedict-vui-test-utils)
(require 'benedict-vui-root)

(ert-deftest benedict-vui-root-mount-renders-baseline-layout ()
  "Mounted root renders baseline UI for an empty session."
  (with-mounted-vui-component
      (vui-component 'benedict-vui-root
                     :session nil
                     :initial-slices nil
                     :initial-input nil
                     :retain-context nil
                     :register-actions nil
                     :on-slices-change nil
                     :on-provider-click nil
                     :on-submit #'ignore)
    (let ((text (buffer-string)))
      (should (string-match-p "Chat" text))
      (should (string-match-p "No context" text))
      (should widget-field-list))))

(ert-deftest benedict-vui-root-session-events-update-conversation ()
  "Mounted root reacts to session message events."
  (let ((session (benedict-session-create :title "test")))
    (with-mounted-vui-component
        (vui-component 'benedict-vui-root
                       :session session
                       :initial-slices nil
                       :initial-input nil
                       :retain-context nil
                       :register-actions nil
                       :on-slices-change nil
                       :on-provider-click nil
                       :on-submit #'ignore)
      (should-not (string-match-p "Hello from session" (buffer-string)))
      (benedict-session-add-message session
                                    '(:role user :content "Hello from session"))
      (vui-flush-sync)
      (should (string-match-p "Hello from session" (buffer-string))))))

(provide 'test/benedict-vui-root-test)
;;; benedict-vui-root-test.el ends here
