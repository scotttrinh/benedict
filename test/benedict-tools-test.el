;;; benedict-tools-test.el --- Tool helper tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-tools)

(ert-deftest benedict-project-search-tool-provides-ui ()
  "project-search returns :content plus formatted :ui data."
  (let* ((sample '(:query "needle"
                   :root "/tmp/project"
                   :regexp nil
                   :limit 5
                   :match-count 12
                   :truncated t
                   :matches ((:file "README.org"
                               :line 12
                               :column 5
                               :match "needle"
                               :preview "needle appears here."))))
         (call-count 0))
    (cl-letf (((symbol-function 'benedict-search-project-sync)
               (lambda (&rest _args)
                 (setq call-count (1+ call-count))
                 sample)))
      (let ((result (benedict--tool-project-search :query "needle")))
        (should (= call-count 1))
        (should (string-match-p "README.org" (plist-get result :content)))
        (should (equal (plist-get result :data) sample))
        (let ((ui (plist-get result :ui)))
          (should ui)
          (should (eq (plist-get ui :state) 'success))
          (should (string-match-p "Project search" (plist-get ui :header)))
          (should (string-match-p "Showing 1 of 12 matches" (plist-get ui :body)))
          (should (string-match-p "- README.org:12:5" (plist-get ui :body)))
          (should (string-match-p "\\[\\[needle\\]\\]" (plist-get ui :body))))))))

(ert-deftest benedict-project-search-tool-ui-empty ()
  "project-search UI notes when no matches were found."
  (let* ((sample '(:query "needle"
                   :root "/tmp/project"
                   :regexp nil
                   :limit 5
                   :match-count 0
                   :truncated nil
                   :matches ()))
         (call-count 0))
    (cl-letf (((symbol-function 'benedict-search-project-sync)
               (lambda (&rest _args)
                 (setq call-count (1+ call-count))
                 sample)))
      (let* ((result (benedict--tool-project-search :query "needle"))
             (ui (plist-get result :ui)))
        (should (= call-count 1))
        (should ui)
        (should (string-match-p "Showing 0 of 0 matches" (plist-get ui :body)))
        (should (string-match-p "No matches found" (plist-get ui :body)))))))

(provide 'benedict-tools-test)
;;; benedict-tools-test.el ends here
