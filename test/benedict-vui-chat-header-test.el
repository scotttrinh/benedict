;;; benedict-vui-chat-header-test.el --- Tests for ChatHeader component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the benedict-vui-chat-header component.

;;; Code:

(require 'ert)
(require 'benedict-vui-chat-header)

(ert-deftest benedict-vui-chat-header-component-can-be-loaded ()
  "ChatHeader component can be loaded successfully."
  (should (featurep 'benedict-vui-chat-header)))

(provide 'test/benedict-vui-chat-header-test)
;;; benedict-vui-chat-header-test.el ends here
