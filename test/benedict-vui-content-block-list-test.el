;;; benedict-vui-content-block-list-test.el --- Tests for VUI content block list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI content block list component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-content-block-list)

(ert-deftest benedict-vui-content-block-list-dispatches-block-types ()
  "Content block list normalizes block types correctly."
  (let* ((blocks (list (list :id "text-1" :type 'text :content "hello")
                       (list :id "code-1" :type 'code :code "(+ 1 2)" :language "elisp")
                       (list :id "thinking-1" :type 'thinking :thinking-data "why")
                       (list :id "tool-use-1" :type 'tool-use :tool-call '(:name "bash"))
                       (list :id "tool-result-1" :type 'tool-result :result '(:content "ok")))))
    (should (eq (benedict-vui-content-block-list--block-type (nth 0 blocks)) 'text))
    (should (eq (benedict-vui-content-block-list--block-type (nth 1 blocks)) 'code))
    (should (eq (benedict-vui-content-block-list--block-type (nth 2 blocks)) 'thinking))
    (should (eq (benedict-vui-content-block-list--block-type (nth 3 blocks)) 'tool-use))
    (should (eq (benedict-vui-content-block-list--block-type (nth 4 blocks)) 'tool-result))))

(ert-deftest benedict-vui-content-block-list-uses-stable-keys ()
  "Content block list uses stable keys for list reconciliation."
  (let* ((blocks (list (list :id "alpha" :type 'text :content "a")
                       (list :type 'text :content "b")))
         key-fn)
    (cl-letf (((symbol-function 'vui-list)
               (lambda (_value _r-fn &optional k-fn &rest _args)
                 (setq key-fn k-fn)
                 'list)))
      (benedict-vui-content-block-list--render (list :blocks blocks))
      (should (equal (funcall key-fn (car blocks) 0) "alpha"))
      (should (stringp (funcall key-fn (cadr blocks) 1))))))

(provide 'test/benedict-vui-content-block-list-test)
;;; benedict-vui-content-block-list-test.el ends here
