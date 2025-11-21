(require 'ert)
(require 'benedict-tools)


(ert-deftest benedict-search-project-max-matches-per-file-test ()
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

(ert-deftest benedict-find-files-test ()
  "Test finding files."
  (let* ((root (expand-file-name ".." default-directory)) ;; Assumes run from test/ dir
         (files (benedict--tool-find-files :pattern "*.el")))
    (should (> (plist-get files :count) 0))
    (should (member "benedict-tools.el" (plist-get files :files)))))

(ert-deftest benedict-read-file-test ()
  "Test reading files."
  (let ((result (benedict--tool-read-file :path "benedict-tools.el")))
    (should (string-match-p "benedict--tool-read-file" (plist-get result :content)))))

(ert-deftest benedict-read-file-range-test ()
  "Test reading a range of lines from a file."
  (let* ((test-dir (make-temp-file "benedict-test-read-" t))
         (file (expand-file-name "test.txt" test-dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "line 1\nline 2\nline 3\nline 4\n"))
          
          (let ((default-directory test-dir))
            ;; Read middle lines
            (let* ((result (benedict--tool-read-file :path "test.txt" :start-line 2 :end-line 3))
                   (content (plist-get result :content)))
              (should (string= content "line 2\nline 3\n")))
            
            ;; Read to end
            (let* ((result (benedict--tool-read-file :path "test.txt" :start-line 3))
                   (content (plist-get result :content)))
              (should (string= content "line 3\nline 4\n")))))
      (delete-directory test-dir t))))

(ert-run-tests-batch-and-exit)
