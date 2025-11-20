;;; benedict-propose-edit-tool-test.el --- Tests for propose-edit tool -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-tools)

(declare-function benedict--tool-propose-edit "benedict-tools" (&rest args))

(defconst benedict-test--greeting-original "Hello world\nSame line\n"
  "Baseline file contents used in propose-edit tests.")

(defconst benedict-test--greeting-updated "Hello Benedict\nSame line\n"
  "Updated file contents used in propose-edit tests.")

(defmacro benedict-test-with-temp-project (&rest body)
  "Execute BODY with `default-directory' bound to a fresh temp project root."
  (declare (indent 0) (debug t))
  `(let ((benedict-test--project-root (make-temp-file "benedict-propose-edit" t)))
     (unwind-protect
         (let ((default-directory benedict-test--project-root))
           ,@body)
       (benedict-test--kill-propose-edit-buffers)
       (when (file-directory-p benedict-test--project-root)
         (condition-case nil
             (delete-directory benedict-test--project-root t)
           (error nil))))))

(defun benedict-test--kill-propose-edit-buffers ()
  "Remove any propose-edit review buffers created during tests."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*Benedict Edit:" (buffer-name buffer))
      (kill-buffer buffer))))

(defun benedict-test--write-project-file (path content)
  "Write CONTENT to PATH relative to the temp project root."
  (let* ((full (expand-file-name path default-directory))
         (dir (file-name-directory full)))
    (when dir
      (make-directory dir t))
    (with-temp-file full
      (insert content))
    full))

(defun benedict-test--read-project-file (path)
  "Return the contents of PATH relative to the current project root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name path default-directory))
    (buffer-string)))

(defun benedict-test--greeting-diff (path)
  "Return a unified diff patch for PATH replacing the greeting line."
  (string-join
   (list (format "--- %s" path)
         (format "+++ %s" path)
         "@@ -1,2 +1,2 @@"
         "-Hello world"
         "+Hello Benedict"
         " Same line"
         "")
   "\n"))

(ert-deftest benedict-propose-edit-applies-diff-and-creates-review-buffer ()
  "Applying a valid diff edits the file, returns stats, and opens a diff buffer."
  (benedict-test-with-temp-project
    (let* ((path "src/example.txt")
           (_ (benedict-test--write-project-file path benedict-test--greeting-original))
           (diff (benedict-test--greeting-diff path))
           (result (benedict--tool-propose-edit
                    :path path
                    :diff diff
                    :description "Update greeting headline"))
           (stats (plist-get result :stats))
           (review-name (plist-get result :review-buffer)))
      (should (equal (benedict-test--read-project-file path)
                     benedict-test--greeting-updated))
      (should (equal (plist-get result :path) path))
      (should (string-match-p "Applied edit" (or (plist-get result :content) "")))
      (should stats)
      (should (= (plist-get stats :added) 1))
      (should (= (plist-get stats :removed) 1))
      (should (= (plist-get stats :hunks) 1))
      (should review-name)
      (should (equal review-name (format "*Benedict Edit: %s*" path)))
      (let ((review-buffer (get-buffer review-name)))
        (should review-buffer)
        (with-current-buffer review-buffer
          (should (derived-mode-p 'diff-mode))
          (goto-char (point-min))
          (should (search-forward "Hello world" nil t))
          (should (search-forward "Hello Benedict" nil t))))
      (let ((ui (plist-get result :ui)))
        (should ui)
        (should (eq (plist-get ui :state) 'success))
        (should (string-match-p "example.txt" (or (plist-get ui :header) "")))
        (should (string-match-p "diff" (downcase (or (plist-get ui :body) ""))))))))

(ert-deftest benedict-propose-edit-rejects-multi-file-diffs ()
  "Reject diffs that attempt to touch more than one file."
  (benedict-test-with-temp-project
    (benedict-test--write-project-file "foo.txt" benedict-test--greeting-original)
    (benedict-test--write-project-file "bar.txt" benedict-test--greeting-original)
    (let* ((patch (concat (benedict-test--greeting-diff "foo.txt")
                          "\n"
                          (benedict-test--greeting-diff "bar.txt"))))
      (should-error
       (benedict--tool-propose-edit :path "foo.txt" :diff patch)
       :type 'benedict-error))))

(ert-deftest benedict-propose-edit-errors-on-mismatched-diff-path ()
  "Reject diffs whose headers do not match the provided path."
  (benedict-test-with-temp-project
    (benedict-test--write-project-file "foo.txt" benedict-test--greeting-original)
    (let ((patch (benedict-test--greeting-diff "bar.txt")))
      (should-error
       (benedict--tool-propose-edit :path "foo.txt" :diff patch)
       :type 'benedict-error))))

(ert-deftest benedict-propose-edit-errors-on-malformed-diff ()
  "Reject empty or malformed diff payloads."
  (benedict-test-with-temp-project
    (benedict-test--write-project-file "foo.txt" benedict-test--greeting-original)
    (should-error
     (benedict--tool-propose-edit :path "foo.txt" :diff "totally not a diff")
     :type 'benedict-error)))

(ert-deftest benedict-propose-edit-rejects-paths-outside-project ()
  "Reject edits whose :path escapes the project root."
  (benedict-test-with-temp-project
    (let* ((parent (file-name-directory (directory-file-name benedict-test--project-root)))
           (outside (expand-file-name "evil.txt" parent)))
      (unwind-protect
          (progn
            (with-temp-file outside
              (insert benedict-test--greeting-original))
            (let ((patch (benedict-test--greeting-diff "../evil.txt")))
              (should-error
               (benedict--tool-propose-edit :path "../evil.txt" :diff patch)
               :type 'benedict-error)))
        (when (file-exists-p outside)
          (delete-file outside))))))

(ert-deftest benedict-propose-edit-errors-when-target-missing ()
  "Reject edits when the requested file does not exist."
  (benedict-test-with-temp-project
    (let ((patch (benedict-test--greeting-diff "missing.txt")))
      (should-error
       (benedict--tool-propose-edit :path "missing.txt" :diff patch)
       :type 'benedict-error))))

(provide 'benedict-propose-edit-tool-test)
;;; benedict-propose-edit-tool-test.el ends here
