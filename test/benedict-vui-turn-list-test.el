;;; benedict-vui-turn-list-test.el --- Tests for VUI turn list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the VUI turn list component helpers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'benedict-vui-turn-list)

(ert-deftest benedict-vui-turn-list-groups-user-assistant-pairs ()
  "Turn list groups user/assistant messages into turns."
  (let* ((conversation (list (list :id "u1" :role 'user :content "Hi")
                             (list :id "a1" :role 'assistant :content "Hello")
                             (list :id "u2" :role 'user :content "How are you?")
                             (list :id "a2" :role 'assistant :content "Good")))
         items)
    (cl-letf (((symbol-function 'vui-list)
               (lambda (value &rest _args)
                 (setq items value)
                 'list))
              ((symbol-function 'vui--register-effect)
               (lambda (&rest _args) nil)))
      (benedict-vui-turn-list--render (list :conversation conversation))
      (should (= (length items) 2))
      (should (= (length (car items)) 2))
      (should (= (length (cadr items)) 2)))))

(ert-deftest benedict-vui-turn-list-uses-stable-keys ()
  "Turn list uses stable keys based on message IDs."
  (let* ((conversation (list (list :id "msg-1" :role 'user :content "Hi")
                             (list :id "msg-2" :role 'assistant :content "Hello")
                             (list :id "msg-3" :role 'user :content "Next")
                             (list :id "msg-4" :role 'assistant :content "Ok")))
         items
         key-fn)
    (cl-letf (((symbol-function 'vui-list)
               (lambda (value _render-fn &optional k-fn &rest _args)
                 (setq items value
                       key-fn k-fn)
                 'list))
              ((symbol-function 'vui--register-effect)
               (lambda (&rest _args) nil)))
      (benedict-vui-turn-list--render (list :conversation conversation))
      (should (equal (funcall key-fn (car items) 0) "msg-1"))
      (should (equal (funcall key-fn (cadr items) 1) "msg-3")))))

(ert-deftest benedict-vui-turn-list-handles-streaming-turn-at-end ()
  "Turn list renders a streaming turn without an ID."
  (let* ((conversation (list (list :role 'assistant :content "Streaming" :streaming t)))
         items
         key-fn)
    (cl-letf (((symbol-function 'vui-list)
               (lambda (value _render-fn &optional k-fn &rest _args)
                 (setq items value
                       key-fn k-fn)
                 'list))
              ((symbol-function 'vui--register-effect)
               (lambda (&rest _args) nil)))
      (benedict-vui-turn-list--render (list :conversation conversation))
      (should (= (length items) 1))
      (should (stringp (funcall key-fn (car items) 0))))))

(ert-deftest benedict-vui-turn-list-scrolls-on-new-content ()
  "Turn list invokes scroll-to-bottom effect when content changes."
  (let* ((conversation (list (list :id "msg-1" :role 'user :content "Hi")
                             (list :id "msg-2" :role 'assistant :content "Hello")))
         captured-effect
         captured-deps
         scrolled)
    (cl-letf (((symbol-function 'vui-list)
               (lambda (_value &rest _props) 'list))
              ((symbol-function 'vui--register-effect)
               (lambda (deps effect-fn)
                 (setq captured-deps deps
                       captured-effect effect-fn)
                 nil))
              ((symbol-function 'benedict-vui-turn-list--scroll-to-bottom)
               (lambda () (setq scrolled t))))
      (benedict-vui-turn-list--render (list :conversation conversation))
      ;; Note: double parens in implementation result in ((deps)) here
      (should (equal captured-deps
                     (list (benedict-vui-turn-list--scroll-deps conversation))))
      (funcall captured-effect)
      (should scrolled))))

(provide 'test/benedict-vui-turn-list-test)
;;; benedict-vui-turn-list-test.el ends here
