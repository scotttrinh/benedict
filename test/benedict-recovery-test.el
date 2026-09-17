;;; benedict-recovery-test.el --- Conservative recovery reports  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'benedict-recovery)

(ert-deftest benedict-recovery-reports-only-unanswered-calls-as-unknown ()
  (let ((session (benedict-session-create :id "recovery")))
    (benedict-session-append
     session
     (benedict-entry-create
      :role 'assistant
      :content '((:type tool-call :id "answered" :name read-file :arguments (:path "a"))
                 (:type tool-call :id "uncertain" :name write-file :arguments (:path "b")))))
    (benedict-session-append
     session
     (benedict-entry-create
      :role 'tool-result
      :content '((:type tool-result :id "answered" :name read-file
                         :content "ok" :error-p nil))))
    (let ((report (benedict-recovery-unknown-tool-calls session)))
      (should (= (length report) 1))
      (should (equal (plist-get (car report) :id) "uncertain"))
      (should (eq (plist-get (car report) :status) 'unknown)))))

(ert-deftest benedict-recovery-matches-reused-call-ids-chronologically-on-path ()
  (let ((session (benedict-session-create :id "reused")))
    (benedict-session-append
     session (benedict-entry-create
              :role 'assistant
              :content '((:type tool-call :id "call-1" :name mutate :arguments (:n 1)))))
    (benedict-session-append
     session (benedict-entry-create
              :role 'tool-result
              :content '((:type tool-result :id "call-1" :name mutate
                                 :content "done" :error-p nil))))
    (let ((fork (benedict-session-head session)))
      (benedict-session-append
       session (benedict-entry-create
                :role 'assistant
                :content '((:type tool-call :id "off-branch" :name mutate :arguments nil))))
      (benedict-session-fork session fork))
    (let ((entry (benedict-session-append
                  session (benedict-entry-create
                           :role 'assistant
                           :content '((:type tool-call :id "call-1" :name mutate
                                             :arguments (:n 2)))))))
      (let ((report (benedict-recovery-unknown-tool-calls session)))
        (should (= (length report) 1))
        (should (equal (plist-get (car report) :entry-id)
                       (benedict-entry-id entry)))
        (should (equal (plist-get (car report) :arguments) '(:n 2)))))))

(ert-deftest benedict-recovery-result-answers-newest-reused-call-id ()
  (let ((session (benedict-session-create :id "newest")))
    (let ((old (benedict-session-append
                session (benedict-entry-create
                         :role 'assistant
                         :content '((:type tool-call :id "same" :name mutate
                                           :arguments (:turn 1)))))))
      (benedict-session-append
       session (benedict-entry-create
                :role 'assistant
                :content '((:type tool-call :id "same" :name mutate
                                      :arguments (:turn 2)))))
      (benedict-session-append
       session (benedict-entry-create
                :role 'tool-result
                :content '((:type tool-result :id "same" :name mutate
                                      :content "new done" :error-p nil))))
      (let ((report (benedict-recovery-unknown-tool-calls session)))
        (should (= (length report) 1))
        (should (equal (plist-get (car report) :entry-id)
                       (benedict-entry-id old)))
        (should (equal (plist-get (car report) :arguments) '(:turn 1)))))))

(provide 'benedict-recovery-test)

;;; benedict-recovery-test.el ends here
