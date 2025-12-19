;;; benedict-tool-actions-test.el --- Tests for tool action buttons -*- lexical-binding: t; -*-

(require 'ert)
(require 'button)

;; Load the features under test
(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-chat)
(require 'benedict-chat-render)

;; Tests for action validation

(ert-deftest benedict-tool-actions--validate-action-valid ()
  "Valid action with :label and :handler should pass."
  (let ((action (list :label "Test" :handler (lambda () nil))))
    (should (equal action (benedict-chat--validate-action action)))))

(ert-deftest benedict-tool-actions--validate-action-missing-label ()
  "Action without :label should signal error."
  (let ((action (list :handler (lambda () nil))))
    (should-error (benedict-chat--validate-action action))))

(ert-deftest benedict-tool-actions--validate-action-missing-handler ()
  "Action without :handler should signal error."
  (let ((action (list :label "Test")))
    (should-error (benedict-chat--validate-action action))))

(ert-deftest benedict-tool-actions--validate-action-invalid-label-type ()
  "Action with non-string :label should signal error."
  (let ((action (list :label 123 :handler (lambda () nil))))
    (should-error (benedict-chat--validate-action action))))

(ert-deftest benedict-tool-actions--validate-action-invalid-handler-type ()
  "Action with non-callable :handler should signal error."
  (let ((action (list :label "Test" :handler "not-a-function")))
    (should-error (benedict-chat--validate-action action))))

(ert-deftest benedict-tool-actions--validate-action-not-plist ()
  "Action that is not a plist should signal error."
  (should-error (benedict-chat--validate-action '("not" "a" "plist"))))

;; Tests for action normalization

(ert-deftest benedict-tool-actions--normalize-actions-nil ()
  "Normalizing nil should return nil."
  (should (null (benedict-chat--normalize-actions nil))))

(ert-deftest benedict-tool-actions--normalize-actions-empty ()
  "Normalizing empty list should return nil or empty."
  (let ((result (benedict-chat--normalize-actions '())))
    (should (or (null result) (and (listp result) (= 0 (length result)))))))

(ert-deftest benedict-tool-actions--normalize-actions-single ()
  "Single valid action should normalize correctly."
  (let* ((action (list :label "Click me" :handler (lambda () (message "clicked"))))
         (result (benedict-chat--normalize-actions (list action))))
    (should (= 1 (length result)))
    (should (string= "Click me" (plist-get (car result) :label)))))

(ert-deftest benedict-tool-actions--normalize-actions-multiple ()
  "Multiple valid actions should normalize correctly."
  (let* ((action1 (list :label "Action 1" :handler (lambda () nil)))
         (action2 (list :label "Action 2" :handler (lambda () nil)))
         (result (benedict-chat--normalize-actions (list action1 action2))))
    (should (= 2 (length result)))
    (should (string= "Action 1" (plist-get (car result) :label)))
    (should (string= "Action 2" (plist-get (cadr result) :label)))))

(ert-deftest benedict-tool-actions--normalize-actions-invalid-list ()
  "Non-list input should signal error."
  (should-error (benedict-chat--normalize-actions "not-a-list")))

;; Tests for UI normalization with actions

(ert-deftest benedict-tool-actions--normalize-tool-ui-with-actions ()
  "UI with valid :actions should be normalized."
  (let* ((action (list :label "Test" :handler (lambda () nil)))
         (ui (list :state 'success :body "Test body" :actions (list action)))
         (call (list :name 'test-tool))
         (normalized (benedict-chat--normalize-tool-ui call 'success ui nil)))
    (should (plist-member normalized :actions))
    (let ((actions (plist-get normalized :actions)))
      (should (= 1 (length actions)))
      (should (string= "Test" (plist-get (car actions) :label))))))

(ert-deftest benedict-tool-actions--normalize-tool-ui-without-actions ()
  "UI without :actions should not error."
  (let ((ui (list :state 'success :body "Test body"))
        (call (list :name 'test-tool)))
    (let ((result (benedict-chat--normalize-tool-ui call 'success ui nil)))
      (should result))))

(ert-deftest benedict-tool-actions--normalize-tool-ui-invalid-action-in-list ()
  "UI with invalid action in list should error during normalization."
  (let* ((invalid-action (list :label "Test"))  ;; missing :handler
         (ui (list :state 'success :body "Test body" :actions (list invalid-action)))
         (call (list :name 'test-tool)))
    (should-error (benedict-chat--normalize-tool-ui call 'success ui nil))))

;; Tests for action button rendering and invocation

(ert-deftest benedict-tool-actions--render-tool-actions-no-ui ()
  "Rendering actions when UI is nil should not error."
  (let ((item (list :ui nil)))
    (with-temp-buffer
      (let ((inhibit-read-only nil))
        (benedict-chat--render-tool-actions item)
        (should t)))))

(ert-deftest benedict-tool-actions--render-tool-actions-no-actions ()
  "Rendering when UI has no :actions should not error."
  (let ((item (list :ui (list :body "Test"))))
    (with-temp-buffer
      (let ((inhibit-read-only nil))
        (benedict-chat--render-tool-actions item)
        (should t)))))

(ert-deftest benedict-tool-actions--render-tool-actions-creates-buttons ()
  "Rendering actions should insert button text with action properties."
  (let* ((called nil)
         (handler (lambda () (setq called t)))
         (action (list :label "Click me" :handler handler))
         (item (list :ui (list :body "Test" :actions (list action)))))
    (with-temp-buffer
      (let ((inhibit-read-only nil))
        (benedict-chat--render-tool-actions item)
        (let ((text (buffer-string)))
          (should (string-match "Click me" text)))))))

(ert-deftest benedict-tool-actions--invoke-handler-via-button ()
  "Handler property should be attached and callable."
  (let* ((invoked nil)
         (handler (lambda () (setq invoked t)))
         (action (list :label "Test" :handler handler))
         (item (list :ui (list :actions (list action)))))
    (with-temp-buffer
      (let ((inhibit-read-only nil))
        (benedict-chat--render-tool-actions item)
        ;; Search for the button text
        (goto-char (point-min))
        (when (re-search-forward "Test" nil t)
          ;; Go back to the start of the button
          (goto-char (match-beginning 0)))
        ;; Check for action handler property at the button
        (let ((handler-fn (get-text-property (point) 'benedict-chat-action)))
          (when handler-fn
            (funcall handler-fn)))
        (should invoked)))))

;; Backward compatibility tests

(ert-deftest benedict-tool-actions--tool-without-actions-renders ()
  "Tools without :actions in UI should render normally."
  (let* ((item (benedict-chat--make-item 'tool
                                        :metadata (list :status 'success)
                                        :tool-call (list :name 'test-tool)
                                        :ui (list :header "Test Tool"
                                                 :body "Output from tool"
                                                 :state 'success)
                                        :content "Output from tool"
                                        :tool-folded nil)))
    (with-temp-buffer
      (let ((inhibit-read-only nil))
        (benedict-chat--render-tool-item item)
        (should (buffer-live-p (current-buffer)))
        (let ((text (buffer-string)))
          (should (string-match "Test Tool" text)))))))

(ert-deftest benedict-tool-actions--empty-actions-list-renders ()
  "UI with empty :actions list should render without error."
  (let* ((item (benedict-chat--make-item 'tool
                                        :metadata (list :status 'success)
                                        :tool-call (list :name 'test-tool)
                                        :ui (list :header "Test Tool"
                                                 :body "Output"
                                                 :state 'success
                                                 :actions '())
                                        :content "Output"
                                        :tool-folded nil)))
    (with-temp-buffer
      (let ((inhibit-read-only nil))
        (benedict-chat--render-tool-item item)
        (should (buffer-live-p (current-buffer)))))))

(ert-deftest benedict-tool-actions--multiple-actions-render ()
  "UI with multiple actions should render all buttons."
  (let* ((action1 (list :label "Action 1" :handler (lambda () nil)))
         (action2 (list :label "Action 2" :handler (lambda () nil)))
         (action3 (list :label "Action 3" :handler (lambda () nil)))
         (item (benedict-chat--make-item 'tool
                                        :metadata (list :status 'success)
                                        :tool-call (list :name 'test-tool)
                                        :ui (list :header "Test"
                                                 :body "Output"
                                                 :state 'success
                                                 :actions (list action1 action2 action3))
                                        :content "Output"
                                        :tool-folded nil)))
    (with-temp-buffer
      (let ((inhibit-read-only nil))
        (benedict-chat--render-tool-item item)
        (let ((text (buffer-string)))
          (should (string-match "Action 1" text))
          (should (string-match "Action 2" text))
          (should (string-match "Action 3" text)))))))

(provide 'test/benedict-tool-actions-test)
;;; benedict-tool-actions-test.el ends here
