;;; benedict-create-file-tool-test.el --- Tests for create-file tool -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-tools)

(declare-function benedict--tool-create-file "benedict-tools" (&rest args))

(defmacro benedict-test-with-temp-project-for-create-file (&rest body)
  "Execute BODY with `default-directory' bound to a fresh temp project root."
  (declare (indent 0) (debug t))
  `(let ((benedict-test--create-file-project-root (make-temp-file "benedict-create-file" t)))
     (unwind-protect
         (let ((default-directory benedict-test--create-file-project-root))
           ,@body)
       (when (file-directory-p benedict-test--create-file-project-root)
         (condition-case nil
             (delete-directory benedict-test--create-file-project-root t)
           (error nil))))))

(defun benedict-test--read-file-if-exists (path)
  "Return contents of PATH if it exists, nil otherwise."
  (let ((full (expand-file-name path default-directory)))
    (when (file-exists-p full)
      (with-temp-buffer
        (insert-file-contents full)
        (buffer-string)))))

(ert-deftest benedict-create-file-creates-new-file ()
  "Creating a file writes content and returns success result."
  (benedict-test-with-temp-project-for-create-file
    (let* ((path "example.txt")
           (content "Hello world\n")
           (result (benedict--tool-create-file
                    :path path
                    :content content
                    :description "Initial content"))
           (ui (plist-get result :ui)))
      (should (equal (plist-get result :path) path))
      (should (string-match-p "Created file" (plist-get result :content)))
      (should (equal (benedict-test--read-file-if-exists path) content))
      (should ui)
      (should (eq (plist-get ui :state) 'success))
      (should (string-match-p "example.txt" (plist-get ui :header)))
      (should (string-match-p "1 lines" (plist-get ui :body))))))

(ert-deftest benedict-create-file-creates-nested-directories ()
  "Creating a file in non-existent nested directories creates parents."
  (benedict-test-with-temp-project-for-create-file
    (let* ((path "src/deep/nested/file.txt")
           (content "Nested content\n")
           (result (benedict--tool-create-file
                    :path path
                    :content content)))
      (should (equal (plist-get result :path) path))
      (should (equal (benedict-test--read-file-if-exists path) content)))))

(ert-deftest benedict-create-file-handles-empty-content ()
  "Creating a file with empty content succeeds."
  (benedict-test-with-temp-project-for-create-file
    (let* ((path "empty.txt")
           (result (benedict--tool-create-file :path path :content "")))
      (should (equal (plist-get result :path) path))
      (should (equal (benedict-test--read-file-if-exists path) "")))))

(ert-deftest benedict-create-file-rejects-existing-file ()
  "Creating a file that already exists signals an error."
  (benedict-test-with-temp-project-for-create-file
    (let* ((path "existing.txt")
           (full (expand-file-name path default-directory)))
      (with-temp-file full
        (insert "Original content"))
      (should-error
       (benedict--tool-create-file :path path :content "New content")
       :type 'benedict-error))))

(ert-deftest benedict-create-file-rejects-empty-path ()
  "Creating a file with empty path signals an error."
  (benedict-test-with-temp-project-for-create-file
    (should-error
     (benedict--tool-create-file :path "" :content "content")
     :type 'benedict-error)))

(ert-deftest benedict-create-file-rejects-path-outside-project ()
  "Creating a file outside the project root signals an error."
  (benedict-test-with-temp-project-for-create-file
    (should-error
     (benedict--tool-create-file :path "../evil.txt" :content "content")
     :type 'benedict-error)))

(ert-deftest benedict-create-file-returns-line-count ()
  "Creating a file returns the correct line count in the result."
  (benedict-test-with-temp-project-for-create-file
    (let* ((content "Line 1\nLine 2\nLine 3\n")
           (result (benedict--tool-create-file
                    :path "multiline.txt"
                    :content content)))
      (should (string-match-p "3 lines" (plist-get result :content)))
      (should (string-match-p "3 lines" (plist-get (plist-get result :ui) :body))))))

(provide 'benedict-create-file-tool-test)
;;; benedict-create-file-tool-test.el ends here
