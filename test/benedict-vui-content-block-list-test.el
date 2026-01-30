;;; benedict-vui-content-block-list-test.el --- Tests for VUI content block list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI content block list component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-content-block-list)

(ert-deftest benedict-vui-content-block-list-dispatches-block-types ()
  "Content block list dispatches to the correct block components."
  (let* ((blocks (list (list :id "text-1" :type 'text :content "hello")
                       (list :id "code-1" :type 'code :code "(+ 1 2)" :language "elisp")
                       (list :id "thinking-1" :type 'thinking :thinking-data "why")
                       (list :id "tool-use-1" :type 'tool-use :tool-call '(:name "bash"))
                       (list :id "tool-result-1" :type 'tool-result :result '(:content "ok"))))
         (calls nil)
         render-fn
         items)
    (cl-letf (((symbol-function 'vui-list)
               (lambda (value r-fn &optional _k-fn &rest _args)
                 (setq items value
                       render-fn r-fn)
                 'list))
              ((symbol-function 'benedict-vui-text-block)
               (lambda (&rest _args)
                 (setq calls (append calls (list 'text)))
                 'text-node))
              ((symbol-function 'benedict-vui-code-block)
               (lambda (&rest _args)
                 (setq calls (append calls (list 'code)))
                 'code-node))
              ((symbol-function 'benedict-vui-thinking-block)
               (lambda (&rest _args)
                 (setq calls (append calls (list 'thinking)))
                 'thinking-node))
              ((symbol-function 'benedict-vui-tool-use-block)
               (lambda (&rest _args)
                 (setq calls (append calls (list 'tool-use)))
                 'tool-use-node))
              ((symbol-function 'benedict-vui-tool-result-block)
               (lambda (&rest _args)
                 (setq calls (append calls (list 'tool-result)))
                 'tool-result-node)))
      (vui-component 'benedict-vui-content-block-list--render (list :blocks blocks))
      (dolist (item items)
        (funcall render-fn item))
      (should (equal calls '(text code thinking tool-use tool-result))))))

(ert-deftest benedict-vui-content-block-list-uses-stable-keys ()
  "Content block list uses stable keys for list reconciliation."
  (let* ((blocks (list (list :id "alpha" :type 'text :content "a")
                       (list :type 'text :content "b")))
         key-fn)
    (cl-letf (((symbol-function 'vui-list)
               (lambda (_value _r-fn &optional k-fn &rest _args)
                 (setq key-fn k-fn)
                 'list)))
      (vui-component 'benedict-vui-content-block-list--render (list :blocks blocks))
      (should (equal (funcall key-fn (car blocks) 0) "alpha"))
      (should (stringp (funcall key-fn (cadr blocks) 1))))))

(provide 'test/benedict-vui-content-block-list-test)
;;; benedict-vui-content-block-list-test.el ends here
