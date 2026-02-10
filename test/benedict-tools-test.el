;;; benedict-tools-test.el --- Tests for agent tools -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benedict-tools)

;;; Permission resolver tests

(ert-deftest benedict-tools-resolve-tool-permission-predicate-global-test ()
  "Global permission predicate is used when no local override exists."
  (let ((global (lambda (_tool _args) t))
        (old-default (default-value 'benedict-tool-permission-predicate)))
    (unwind-protect
        (progn
          (set-default 'benedict-tool-permission-predicate global)
          (with-temp-buffer
            (should (eq (benedict--resolve-tool-permission-predicate) global))))
      (set-default 'benedict-tool-permission-predicate old-default))))

(ert-deftest benedict-tools-resolve-tool-permission-predicate-local-overrides-global-test ()
  "Project-local predicate overrides global predicate."
  (let ((global (lambda (_tool _args) t))
        (local (lambda (_tool _args) nil))
        (old-default (default-value 'benedict-tool-permission-predicate)))
    (unwind-protect
        (progn
          (set-default 'benedict-tool-permission-predicate global)
          (with-temp-buffer
            (setq-local benedict-tool-permission-predicate local)
            (should (eq (benedict--resolve-tool-permission-predicate) local))))
      (set-default 'benedict-tool-permission-predicate old-default))))

(ert-deftest benedict-tools-resolve-tool-permission-predicate-none-configured-test ()
  "Resolver returns nil when no permission predicate is configured."
  (let ((old-default (default-value 'benedict-tool-permission-predicate)))
    (unwind-protect
        (progn
          (set-default 'benedict-tool-permission-predicate nil)
          (with-temp-buffer
            (kill-local-variable 'benedict-tool-permission-predicate)
             (should-not (benedict--resolve-tool-permission-predicate))))
      (set-default 'benedict-tool-permission-predicate old-default))))

(ert-deftest benedict-tools-resolve-tool-permission-predicate-dir-locals-overrides-global-test ()
  "Dir-local predicate overrides global predicate resolution."
  (let* ((test-dir (make-temp-file "benedict-test-dir-locals-" t))
         (dir-locals (expand-file-name ".dir-locals.el" test-dir))
         (global (lambda (_tool _args) t))
         (old-default (default-value 'benedict-tool-permission-predicate))
         (old-cache dir-locals-directory-cache)
         (old-class-alist dir-locals-class-alist))
    (unwind-protect
        (progn
          (with-temp-file dir-locals
            (insert "((nil . ((benedict-tool-permission-predicate . benedict-tools-test--project-policy))))\n"))
          (set-default 'benedict-tool-permission-predicate global)
          (setq dir-locals-directory-cache nil)
          (setq dir-locals-class-alist nil)
          (with-temp-buffer
            (setq default-directory (file-name-as-directory test-dir))
            (hack-dir-local-variables-non-file-buffer)
            (should (local-variable-p 'benedict-tool-permission-predicate (current-buffer)))
            (should (eq (benedict--resolve-tool-permission-predicate)
                        'benedict-tools-test--project-policy))))
      (set-default 'benedict-tool-permission-predicate old-default)
      (setq dir-locals-directory-cache old-cache)
      (setq dir-locals-class-alist old-class-alist)
      (delete-directory test-dir t))))

(ert-deftest benedict-tools-permission-predicate-allows-invocation-test ()
  "Predicate returning t should allow invocation without prompting."
  (let* ((tool-id 'benedict-tools-test-permission-allow)
         (called nil)
         (prompted nil)
         (old-default (default-value 'benedict-tool-permission-predicate)))
    (unwind-protect
        (progn
          (benedict-tools-register
           :id tool-id
           :fn (lambda (&rest _args)
                 (setq called t)
                 'ok)
           :approval 'confirm)
          (set-default 'benedict-tool-permission-predicate
                       (lambda (_tool _args) t))
          (cl-letf (((symbol-function 'benedict--prompt-for-approval)
                     (lambda (_spec _args)
                       (setq prompted t)
                       t)))
            (should (eq (benedict-tool-invoke tool-id nil) 'ok))
            (should called)
            (should-not prompted)))
      (set-default 'benedict-tool-permission-predicate old-default)
      (remhash tool-id benedict--tools))))

(ert-deftest benedict-tools-permission-predicate-denies-invocation-test ()
  "Predicate returning nil should deny invocation."
  (let* ((tool-id 'benedict-tools-test-permission-deny)
         (called nil)
         (old-default (default-value 'benedict-tool-permission-predicate)))
    (unwind-protect
        (progn
          (benedict-tools-register
           :id tool-id
           :fn (lambda (&rest _args)
                 (setq called t)
                 'ok)
           :approval 'auto)
          (set-default 'benedict-tool-permission-predicate
                       (lambda (_tool _args) nil))
          (should-error (benedict-tool-invoke tool-id nil) :type 'benedict-error)
          (should-not called))
      (set-default 'benedict-tool-permission-predicate old-default)
      (remhash tool-id benedict--tools))))

(ert-deftest benedict-tools-permission-predicate-error-falls-back-test ()
  "Predicate errors should fall back to legacy approval flow."
  (let* ((tool-id 'benedict-tools-test-permission-error)
         (called nil)
         (prompted nil)
         (old-default (default-value 'benedict-tool-permission-predicate)))
    (unwind-protect
        (progn
          (benedict-tools-register
           :id tool-id
           :fn (lambda (&rest _args)
                 (setq called t)
                 'ok)
           :approval 'confirm)
          (set-default 'benedict-tool-permission-predicate
                       (lambda (_tool _args)
                         (error "Predicate failure")))
          (cl-letf (((symbol-function 'benedict--prompt-for-approval)
                     (lambda (_spec _args)
                       (setq prompted t)
                       t)))
            (should (eq (benedict-tool-invoke tool-id nil) 'ok))
            (should called)
            (should prompted)))
      (set-default 'benedict-tool-permission-predicate old-default)
      (remhash tool-id benedict--tools))))

(ert-deftest benedict-tools-permission-predicate-non-boolean-falls-back-test ()
  "Non-boolean predicate result should fall back to legacy approval flow."
  (let* ((tool-id 'benedict-tools-test-permission-non-bool)
         (called nil)
         (prompted nil)
         (old-default (default-value 'benedict-tool-permission-predicate)))
    (unwind-protect
        (progn
          (benedict-tools-register
           :id tool-id
           :fn (lambda (&rest _args)
                 (setq called t)
                 'ok)
           :approval 'confirm)
          (set-default 'benedict-tool-permission-predicate
                       (lambda (_tool _args) :maybe))
          (cl-letf (((symbol-function 'benedict--prompt-for-approval)
                     (lambda (_spec _args)
                       (setq prompted t)
                       t)))
            (should (eq (benedict-tool-invoke tool-id nil) 'ok))
            (should called)
            (should prompted)))
      (set-default 'benedict-tool-permission-predicate old-default)
      (remhash tool-id benedict--tools))))

(ert-deftest benedict-tools-permission-decision-allow-metadata-test ()
  "Permission decision metadata marks allow decisions explicitly."
  (let ((decision (benedict--tool-permission-decision
                   (lambda (_tool _args) t)
                   'project-search
                   '(:query "foo"))))
    (should (eq 'allow (plist-get decision :policy)))
    (should (eq 'predicate-allow (plist-get decision :decision)))))

(ert-deftest benedict-tools-permission-decision-deny-metadata-test ()
  "Permission decision metadata marks deny decisions explicitly."
  (let ((decision (benedict--tool-permission-decision
                   (lambda (_tool _args) nil)
                   'project-search
                   '(:query "foo"))))
    (should (eq 'deny (plist-get decision :policy)))
    (should (eq 'predicate-deny (plist-get decision :decision)))))

(ert-deftest benedict-tools-permission-decision-fallback-on-error-metadata-test ()
  "Permission decision metadata preserves fallback-on-error reason text."
  (let ((decision (benedict--tool-permission-decision
                   (lambda (_tool _args)
                     (error "boom"))
                   'project-search
                   '(:query "foo"))))
    (should (eq 'fallback (plist-get decision :policy)))
    (should (eq 'fallback-on-error (plist-get decision :decision)))
    (should (string-match-p "boom" (or (plist-get decision :error-message) "")))))

;;; Project search tests

(ert-deftest benedict-tools-search-project-max-matches-per-file-test ()
  "Test that project search respects per-file match limit."
  (let* ((test-dir (make-temp-file "benedict-test-limit-" t))
         (file (expand-file-name "test.txt" test-dir))
         (benedict-search-project-max-matches-per-file 5))
    (unwind-protect
        (progn
          ;; Create a file with 20 matches
          (with-temp-file file
            (dotimes (i 20)
              (insert (format "match %d\n" i))))
          
          (let* ((result (benedict-search-project-sync "match" :root test-dir :limit 100))
                 (matches (plist-get result :matches)))
            ;; Should only have 5 matches despite limit being 100
            (should (= (length matches) 5))))
      (delete-directory test-dir t))))

;;; File finding tests

(ert-deftest benedict-tools-find-files-test ()
  "Test finding files."
  (let* ((root (expand-file-name ".." default-directory))
         (files (benedict--tool-find-files :pattern "*.el")))
    (should (> (plist-get files :count) 0))
    (should (member "benedict-tools.el" (plist-get files :files)))))

;;; Read file tests

(ert-deftest benedict-tools-read-file-test ()
  "Test reading files."
  (let ((result (benedict--tool-read-file :path "benedict-tools.el")))
    (should (string-match-p "benedict--tool-read-file" (plist-get result :content)))))

(ert-deftest benedict-tools-read-file-range-test ()
  "Test reading a range of lines from a file."
  (let* ((test-dir (make-temp-file "benedict-test-read-" t))
         (file (expand-file-name "test.txt" test-dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line 1\nline 2\nline 3\nline 4\n"))
          (let ((default-directory test-dir))
            (let* ((result (benedict--tool-read-file :path "test.txt"
                                                     :start-line 2 :end-line 3))
                   (content (plist-get result :content)))
              (should (string= content "line 2\nline 3\n")))
            (let* ((result (benedict--tool-read-file :path "test.txt" :start-line 3))
                   (content (plist-get result :content)))
              (should (string= content "line 3\nline 4\n")))))
      (delete-directory test-dir t))))

;;; Exec elisp tests

(ert-deftest benedict-tools-exec-elisp-success-test ()
  "Test executing elisp that succeeds."
  (let ((result (benedict--tool-exec-elisp :code "(+ 1 1)")))
    (should (plist-get result :success))
    (should (equal (plist-get result :result) "2"))))

(ert-deftest benedict-tools-exec-elisp-complex-test ()
  "Test executing complex elisp."
  (let ((result (benedict--tool-exec-elisp :code "(mapcar #'1+ '(1 2 3))")))
    (should (plist-get result :success))
    (should (equal (plist-get result :result) "(2 3 4)"))))

(ert-deftest benedict-tools-exec-elisp-error-test ()
  "Test executing elisp that errors."
  (let ((result (benedict--tool-exec-elisp :code "(/ 1 0)")))
    (should-not (plist-get result :success))
    (should (plist-get result :error))
    (should (string-match-p "arith-error" (plist-get result :error)))))

(ert-deftest benedict-tools-exec-elisp-output-test ()
  "Test executing elisp that produces stdout output."
  (let ((result (benedict--tool-exec-elisp :code "(print \"hello world\")")))
    (should (plist-get result :success))
    (should (string-match-p "hello world" (or (plist-get result :output) "")))))

(ert-deftest benedict-tools-read-file-buffer-test ()
  "Test reading from a buffer."
  (let ((buf (get-buffer-create "*Benedict Test Buffer*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert "buffer content"))
    (unwind-protect
        (let ((result (benedict--tool-read-file :path "*Benedict Test Buffer*")))
          (should (string= (plist-get result :content) "buffer content")))
      (kill-buffer buf))))

(provide 'benedict-tools-test)

;;; benedict-tools-test.el ends here
