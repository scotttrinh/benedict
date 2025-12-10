;;; benedict-tools-test.el --- Tests for agent tools -*- lexical-binding: t; -*-

(require 'ert)
(require 'benedict-tools)

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

;;; Update file tests

(ert-deftest benedict-tools-update-file-replace-test ()
  "Test replacing a range of lines in a file."
  (let* ((test-dir (make-temp-file "benedict-test-update-" t))
         (file (expand-file-name "test.txt" test-dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line 1\nline 2\nline 3\nline 4\n"))
          (let ((default-directory test-dir))
            (let ((result (benedict--tool-update-file :path "test.txt"
                                                      :start-line 2
                                                      :end-line 3
                                                      :content "new A\nnew B\n")))
              (should (plist-get result :path))
              (let ((contents (with-temp-buffer
                                (insert-file-contents file)
                                (buffer-string))))
                (should (string= contents "line 1\nnew A\nnew B\nline 4\n"))))))
      (delete-directory test-dir t))))

(ert-deftest benedict-tools-update-file-single-line-test ()
  "Test replacing a single line in a file."
  (let* ((test-dir (make-temp-file "benedict-test-update-" t))
         (file (expand-file-name "test.txt" test-dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line 1\nline 2\nline 3\n"))
          (let ((default-directory test-dir))
            (let ((result (benedict--tool-update-file :path "test.txt"
                                                      :start-line 2
                                                      :content "replaced")))
              (should (plist-get result :path))
              (let ((contents (with-temp-buffer
                                (insert-file-contents file)
                                (buffer-string))))
                (should (string= contents "line 1\nreplaced\nline 3\n"))))))
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
