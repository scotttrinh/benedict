;;; benedict-mutation-tools-test.el --- Tests for write and edit tools -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-tools)

(defmacro benedict-test-with-temp-project (&rest body)
  "Execute BODY with `default-directory' bound to a fresh temp project root."
  (declare (indent 0) (debug t))
  `(let ((benedict-test--project-root (make-temp-file "benedict-mutation-test" t)))
     (unwind-protect
         (let ((default-directory benedict-test--project-root))
           ,@body)
       (when (file-directory-p benedict-test--project-root)
         (condition-case nil
             (delete-directory benedict-test--project-root t)
           (error nil))))))

;;; Write tool tests

(ert-deftest benedict-write-tool-creates-new-file ()
  "Test that write tool creates a new file with content."
  (benedict-test-with-temp-project
    (let* ((path "new-file.txt")
           (content "hello world")
           (result (benedict--tool-write :target `(:kind "file" :path ,path)
                                         :content content))
           (full-path (expand-file-name path)))
      (should (file-exists-p full-path))
      (with-temp-buffer
        (insert-file-contents full-path)
        ;; Should have trailing newline
        (should (string= (buffer-string) "hello world\n")))
      (should (equal (plist-get (plist-get result :target) :path) path)))))

(ert-deftest benedict-write-tool-overwrites-existing-file ()
  "Test that write tool overwrites an existing file."
  (benedict-test-with-temp-project
    (let* ((path "existing.txt")
           (full-path (expand-file-name path)))
      (with-temp-file full-path (insert "old content"))
      (benedict--tool-write :target `(:kind "file" :path ,path)
                            :content "new content")
      (with-temp-buffer
        (insert-file-contents full-path)
        (should (string= (buffer-string) "new content\n"))))))

(ert-deftest benedict-write-tool-errors-on-missing-file-if-not-creating ()
  "Test that write tool errors if create_if_missing is nil and file is missing."
  (benedict-test-with-temp-project
    (should-error
     (benedict--tool-write :target '(:kind "file" :path "missing.txt")
                           :content "content"
                           :create_if_missing 'json-false)
     :type 'benedict-error)))

(ert-deftest benedict-write-tool-writes-to-buffer ()
  "Test that write tool writes to a non-file buffer."
  (let* ((buf-name "*benedict-test-write*")
         (result (benedict--tool-write :target `(:kind "buffer" :buffer_name ,buf-name)
                                       :content "buffer content")))
    (should (get-buffer buf-name))
    (with-current-buffer buf-name
      (should (string= (buffer-string) "buffer content")))
    (kill-buffer buf-name)))

;;; Edit tool tests

(ert-deftest benedict-edit-tool-replaces-snippet ()
  "Test that edit tool replaces exactly one occurrence."
  (benedict-test-with-temp-project
    (let* ((path "test.txt")
           (full-path (expand-file-name path))
           (content "line 1\nTARGET\nline 3\n"))
      (with-temp-file full-path (insert content))
      (benedict--tool-edit :target `(:kind "file" :path ,path)
                           :old_text "TARGET"
                           :new_text "REPLACED")
      (with-temp-buffer
        (insert-file-contents full-path)
        (should (string= (buffer-string) "line 1\nREPLACED\nline 3\n"))))))

(ert-deftest benedict-edit-tool-errors-on-zero-matches ()
  "Test that edit tool errors if old_text is not found."
  (benedict-test-with-temp-project
    (let* ((path "test.txt")
           (full-path (expand-file-name path)))
      (with-temp-file full-path (insert "content"))
      (should-error
       (benedict--tool-edit :target `(:kind "file" :path ,path)
                            :old_text "MISSING"
                            :new_text "NEW")
       :type 'benedict-error))))

(ert-deftest benedict-edit-tool-errors-on-multiple-matches ()
  "Test that edit tool errors if old_text matches multiple times."
  (benedict-test-with-temp-project
    (let* ((path "test.txt")
           (full-path (expand-file-name path)))
      (with-temp-file full-path (insert "repeat\nrepeat"))
      (should-error
       (benedict--tool-edit :target `(:kind "file" :path ,path)
                            :old_text "repeat"
                            :new_text "new")
       :type 'benedict-error))))

(ert-deftest benedict-edit-tool-rejects-identical-text ()
  "Test that edit tool rejects no-op edits."
  (benedict-test-with-temp-project
    (let* ((path "test.txt")
           (full-path (expand-file-name path)))
      (with-temp-file full-path (insert "content"))
      (should-error
       (benedict--tool-edit :target `(:kind "file" :path ,path)
                            :old_text "content"
                            :new_text "content")
       :type 'benedict-error))))

(ert-deftest benedict-edit-tool-works-on-buffer ()
  "Test that edit tool works on a non-file buffer."
  (let* ((buf-name "*benedict-test-edit*")
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (erase-buffer)
      (insert "some snippet here"))
    (benedict--tool-edit :target `(:kind "buffer" :buffer_name ,buf-name)
                         :old_text "snippet"
                         :new_text "TEXT")
    (with-current-buffer buf
      (should (string= (buffer-string) "some TEXT here")))
    (kill-buffer buf)))

;;; Safety tests

(ert-deftest benedict-mutation-tools-reject-absolute-paths ()
  "Test that tools reject absolute paths."
  (benedict-test-with-temp-project
    (should-error
     (benedict--tool-write :target `(:kind "file" :path "/etc/passwd")
                           :content "evil")
     :type 'benedict-error)))

(ert-deftest benedict-mutation-tools-reject-escaping-paths ()
  "Test that tools reject paths that escape the project root."
  (benedict-test-with-temp-project
    (should-error
     (benedict--tool-write :target `(:kind "file" :path "../../evil.txt")
                           :content "evil")
     :type 'benedict-error)))

(provide 'test/benedict-mutation-tools-test)
