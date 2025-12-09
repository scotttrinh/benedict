;;; benedict-tools.el --- Tool registry skeleton -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Minimal registry to register/list/call tool functions. Approval UX is a
;; placeholder and will be implemented later in Phase 1.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'json)
(require 'project)
(require 'subr-x)

(defvar benedict--tools (make-hash-table :test 'eq)
  "Registry of tool specs keyed by :id symbol.")

(defcustom benedict-propose-edit-review-buffer-history-size 16
  "Maximum number of propose-edit review buffers to remember."
  :type 'integer
  :group 'benedict)

(defvar benedict--propose-edit-review-buffers nil
  "History of review buffer names produced by the propose-edit tool.")

(defcustom benedict-search-project-executable "rg"
  "Name or path of the ripgrep executable used for project searches."
  :type 'string
  :group 'benedict)

(defcustom benedict-search-project-max-results 200
  "Maximum number of matches `project-search' returns per invocation."
  :type 'integer
  :group 'benedict)

(defcustom benedict-search-project-max-matches-per-file 10
  "Maximum number of matches to return per file in project search."
  :type 'integer
  :group 'benedict)

(defcustom benedict-search-project-include-hidden t
  "When non-nil include hidden files and directories in search results."
  :type 'boolean
  :group 'benedict)

(defcustom benedict-search-project-exclude-globs
  '(".git/" ".hg/" ".svn/" ".direnv/" ".venv/" "venv/"
    "node_modules/" "dist/" "build/" "tmp/" "target/"
    "__pycache__/" ".pytest_cache/" ".mypy_cache/" ".DS_Store")
  "Glob patterns excluded from project search results.
Each entry becomes a \"--glob !PATTERN\" argument to ripgrep."
  :type '(repeat string)
  :group 'benedict)

(defun benedict--search-project-root ()
  "Return the project root for the current buffer.
Falls back to `default-directory' when no project is active."
  (or (when (fboundp 'project-current)
        (when-let ((project (project-current nil default-directory)))
          ;; project-root is preferred when available; fall back to roots list.
          (cond
           ((fboundp 'project-root) (expand-file-name (project-root project)))
           ((fboundp 'project-roots)
            (let ((roots (project-roots project)))
              (when roots (expand-file-name (car roots)))))
           (t nil))))
      (when default-directory (expand-file-name default-directory))))

(defun benedict--search-project--ensure-executable ()
  "Return the absolute path for `benedict-search-project-executable'."
  (or (executable-find benedict-search-project-executable)
      (signal 'benedict-error
              (format "Project search requires %s in PATH"
                      benedict-search-project-executable))))

(defun benedict--search-project--relative-path (path root)
  "Return PATH relative to ROOT, resolving symlinks."
  (let* ((absolute (and path root (expand-file-name path root))))
    (if (and absolute root)
        (file-relative-name absolute root)
      path)))

(defun benedict--search-project--glob-args (&optional extra-globs)
  "Return command-line glob args combining defaults and EXTRA-GLOBS."
  (let (args)
    ;; Add extra (user) globs first so they appear earlier in the command line.
    (dolist (pattern extra-globs)
      (when (and pattern (not (string-empty-p pattern)))
        (push "--glob" args)
        (push pattern args)))
    ;; Add default excludes last so they appear later and override user globs
    ;; (e.g. ensuring .git is excluded even if user passes "*").
    (dolist (pattern benedict-search-project-exclude-globs)
      (when (and pattern (not (string-empty-p pattern)))
        (let ((value (if (string-prefix-p "!" pattern) pattern (concat "!" pattern))))
          (push "--glob" args)
          (push value args))))
    (nreverse args)))

(defun benedict--search-project--trim-line (text)
  "Return TEXT with trailing newlines removed."
  (when text
    (string-trim-right text "[\r\n]+")))

(cl-defun benedict-search-project-sync (query &key root limit regexp globs)
  "Search QUERY within ROOT using ripgrep and return structured matches.
ROOT defaults to the current project root or `default-directory'.
LIMIT overrides `benedict-search-project-max-results'. When REGEXP is
non-nil QUERY is interpreted as a regular expression; otherwise it is
treated as a fixed string. Additional glob arguments can be supplied
via GLOBS, a list of strings passed as \"--glob\" arguments."
  (let* ((needle (string-trim (or query ""))))
    (unless (and (stringp needle) (not (string-empty-p needle)))
      (signal 'benedict-error "Project search requires a non-empty query"))
    (setq query needle)
    (let* ((root (or (and root (expand-file-name root))
                     (benedict--search-project-root)))
           (default-directory (or root (signal 'benedict-error "Project root unavailable")))
           (raw-limit (or limit benedict-search-project-max-results))
           (limit (max 1 (or raw-limit 1)))
           (regexp-mode (and regexp t))
           (executable (benedict--search-project--ensure-executable))
           (max-per-file (or benedict-search-project-max-matches-per-file 10))
           (command-args
            (append '("--json" "--line-number" "--column" "--no-heading" "--color" "never" "--with-filename" "--follow")
                    (when benedict-search-project-include-hidden '("--hidden"))
                    (list "--max-count" (number-to-string max-per-file))
                    (benedict--search-project--glob-args globs)
                    (unless regexp-mode '("--fixed-strings"))
                    ;; Protect query so leading dashes are treated as search text.
                    (list "--" query))))
      (with-temp-buffer
        (let ((exit-code (apply #'call-process executable nil (current-buffer) nil command-args)))
          ;; ripgrep exits 1 when no matches are found; treat it as success.
          (unless (member exit-code '(0 1))
            (signal 'benedict-error
                    (format "Project search failed (rg exited %s) with args %S output %S"
                            exit-code command-args (buffer-string)))))
        (goto-char (point-min))
        (let (matches stats-match-count)
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (unless (string-empty-p line)
                (let* ((payload (json-parse-string line :object-type 'plist
                                                        :array-type 'list
                                                        :null-object nil
                                                        :false-object nil))
                       (event-type (plist-get payload :type)))
                  (pcase event-type
                    ("match"
                     (when (< (length matches) limit)
                       (let* ((data (plist-get payload :data))
                              (path (plist-get (plist-get data :path) :text))
                              (line-number (plist-get data :line_number))
                              (line-text (plist-get (plist-get data :lines) :text))
                              (preview (benedict--search-project--trim-line line-text))
                              (submatches (or (plist-get data :submatches) '(nil)))
                              (relative (benedict--search-project--relative-path path root))
                              (absolute (and path (expand-file-name path root))))
                         (dolist (sub submatches)
                           (let* ((match-text (and sub (plist-get (plist-get sub :match) :text)))
                                  (start (and sub (plist-get sub :start)))
                                  (column (and (integerp start) (1+ start))))
                             (push (list :file relative
                                         :absolute absolute
                                         :line line-number
                                         :column column
                                         :match match-text
                                         :preview preview)
                                   matches))))))
                    ("summary"
                     (setq stats-match-count
                           (let* ((data (plist-get payload :data))
                                  (stats (plist-get data :stats)))
                             (plist-get stats :matches))))))))
            (forward-line 1))
          (list :query query
                :root root
                :regexp regexp-mode
                :limit limit
                :match-count (or stats-match-count (length matches))
                :matches (nreverse matches)
                :truncated (and stats-match-count
                                (numberp stats-match-count)
                                (>= stats-match-count limit))))))))

(cl-defun benedict-find-files-sync (pattern &key root)
  "Find files matching PATTERN (glob) in ROOT."
  (let* ((root (or (and root (expand-file-name root))
                   (benedict--search-project-root)))
         (default-directory (or root (signal 'benedict-error "Project root unavailable")))
         (executable (benedict--search-project--ensure-executable))
         ;; If pattern is wildcard "*", omit it to respect .gitignore rules.
         ;; Passing "*" as a glob explicitly overrides gitignores in ripgrep.
         (user-globs (if (or (null pattern) (string= pattern "*") (string-empty-p pattern))
                         nil
                       (list pattern)))
         (command-args
          (append '("--files" "--null" "--sort" "path")
                  (when benedict-search-project-include-hidden '("--hidden"))
                  (benedict--search-project--glob-args user-globs))))
    (with-temp-buffer
      (let ((exit-code (apply #'call-process executable nil (current-buffer) nil command-args)))
        (unless (member exit-code '(0 1))
          (signal 'benedict-error
                  (format "Find files failed (rg exited %s) with args %S"
                          exit-code command-args))))
      (goto-char (point-min))
      (let ((files (split-string (buffer-string) "\0" t)))
        (mapcar (lambda (f) (file-relative-name f root)) files)))))

(defun benedict--project-search--quoted-query (result)
  "Return RESULT's query formatted for display."
  (let ((query (or (plist-get result :query) "")))
    (prin1-to-string query)))

(defun benedict--project-search--format-match-line (match)
  "Return MATCH formatted as a bullet for the UI body."
  (let* ((file (or (plist-get match :file)
                   (plist-get match :absolute)
                   "unknown"))
         (line (or (plist-get match :line) "?"))
         (column (or (plist-get match :column) "?"))
         (preview (or (plist-get match :preview) ""))
         (match-text (plist-get match :match)))
    (when (and match-text (not (string-empty-p match-text)) (not (string-empty-p preview)))
      (setq preview (replace-regexp-in-string
                     (regexp-quote match-text)
                     (format "[[%s]]" match-text)
                     preview t)))
    (if (string-empty-p preview)
        (format "- %s:%s:%s" file line column)
      (format "- %s:%s:%s — %s" file line column preview))))

(defun benedict--project-search--ui-body (result)
  "Return a multi-line string summarizing RESULT."
  (let* ((regexp (plist-get result :regexp))
         (root (plist-get result :root))
         (matches (plist-get result :matches))
         (match-count (or (plist-get result :match-count)
                          (length matches)))
         (limit (plist-get result :limit))
         (truncated (plist-get result :truncated))
         (shown (length matches))
         (summary (format "Showing %d of %d matches%s"
                          shown
                          match-count
                          (if truncated
                              (format " (limit %d)" limit)
                            "")))
         (lines (delq nil
                      (list (format "Query: %s%s"
                                    (if regexp "regexp " "")
                                    (benedict--project-search--quoted-query result))
                            (and root (format "Root: %s" root))
                            summary)))
         (match-lines (if (not matches)
                          '("No matches found.")
                        (mapcar #'benedict--project-search--format-match-line matches))))
    (string-join (append lines (list "") match-lines) "\n")))

(defun benedict--project-search--build-ui (result)
  "Return a :ui plist for RESULT."
  (list :header (format "Project search — %s%s"
                        (if (plist-get result :regexp) "regexp " "")
                        (benedict--project-search--quoted-query result))
        :state 'success
        :body (benedict--project-search--ui-body result)))

(cl-defun benedict-tools-register (&key id fn schema approval doc)
  "Register a tool with ID and FN.
SCHEMA is a plist describing arguments; APPROVAL is one of
'auto, 'confirm, or 'always. DOC is an optional string."
  (puthash id (list :id id :fn fn :schema schema :approval approval :doc doc)
           benedict--tools))

(defun benedict-tools-list ()
  "Return a list of tool specs."
  (let (acc) (maphash (lambda (_k v) (push v acc)) benedict--tools) (nreverse acc)))

(defun benedict--tool-call-direct (id args)
  "Invoke tool ID with ARGS without applying approval policy."
  (let ((spec (gethash id benedict--tools)))
    (unless spec
      (signal 'benedict-error (format "Unknown tool: %S" id)))
    (let ((fn (plist-get spec :fn)))
      (apply fn args))))

(defun benedict--prompt-for-approval (spec args)
  "Return non-nil when SPEC should run with ARGS after confirmation.
Displays a basic `y-or-n-p' dialog showing the tool id, an optional doc
string, and the argument plist."
  (let* ((id (plist-get spec :id))
         (doc (plist-get spec :doc))
         (label (if doc
                    (format "%s — %s" id doc)
                  (format "%s" id)))
         (prompt (format "Benedict tool %s with args %S? " label args)))
    (y-or-n-p prompt)))

(defun benedict-tool-invoke (id &optional args)
  "Invoke tool ID with ARGS after applying the tool's approval policy.
ARGS must be a plist passed directly to the tool implementation."
  (unless (or (null args) (listp args))
    (signal 'wrong-type-argument (list 'plistp args)))
  (let* ((spec (or (gethash id benedict--tools)
                   (signal 'benedict-error (format "Unknown tool: %S" id))))
         (approval (plist-get spec :approval))
         (approved
          (cond
           ((or (null approval) (eq approval 'auto)) t)
           ((memq approval '(confirm always))
            (benedict--prompt-for-approval spec args))
           (t (benedict--prompt-for-approval spec args)))))
    (unless approved
      (signal 'benedict-error (format "Tool %S invocation canceled by user" id)))
    (benedict--tool-call-direct id args)))

;; Example demo tool used by echo provider later
(defun benedict--tool-uppercase (&key text)
  "Return TEXT uppercased."
  (upcase (or text "")))

(defun benedict--tool-project-search (&key query)
  "Stub tool implementation returning placeholder search results for QUERY."
  (unless (and (stringp query) (not (string-empty-p (string-trim query))))
    (signal 'benedict-error "project-search requires a non-empty :query"))
  (let* ((result (benedict-search-project-sync query))
         (ui (benedict--project-search--build-ui result))
         (print-level nil)
         (print-length nil)
         (content (prin1-to-string result)))
    (list :content content
          :ui ui
          :data result)))

;; Helpers for the propose-edit tool

(defun benedict--propose-edit--review-buffer-name (path)
  "Return the review buffer name for PATH."
  (format "*Benedict Edit: %s*" path))

(defun benedict--propose-edit--strip-diff-header (header)
  "Trim HEADER and drop trailing metadata such as timestamps."
  (when header
    (let ((clean (string-trim header)))
      (car (split-string clean "\t" t)))))

(defun benedict--propose-edit--relative-diff-path (value root)
  "Normalize diff path VALUE relative to ROOT."
  (when-let ((header (benedict--propose-edit--strip-diff-header value)))
    (let ((clean (string-trim header)))
      (unless (string-empty-p clean)
        (cond
         ((string= clean "/dev/null") nil)
         ((or (string-prefix-p "a/" clean)
              (string-prefix-p "b/" clean))
          (benedict--propose-edit--relative-diff-path
           (substring clean 2) root))
         (t
          (let ((expanded (if (file-name-absolute-p clean)
                              (expand-file-name clean)
                            (expand-file-name clean root))))
            (if (and root (file-in-directory-p expanded root))
                (file-relative-name expanded root)
              clean))))))))

(defun benedict--propose-edit--unique-diff-paths (diff root)
  "Return the unique normalized paths mentioned in DIFF relative to ROOT."
  (with-temp-buffer
    (insert diff)
    (goto-char (point-min))
    (let (paths)
      (while (re-search-forward "^\\(?:--- \\|\\+\\+\\+ \\)\\(.+\\)$" nil t)
        (let ((path (benedict--propose-edit--relative-diff-path
                     (match-string 1) root)))
          (when path (push path paths))))
      (cl-delete-duplicates (nreverse paths) :test #'string=))))

(defun benedict--propose-edit--count-diff-stats (diff)
  "Return a plist of statistics for DIFF."
  (with-temp-buffer
    (insert diff)
    (goto-char (point-min))
    (let ((added 0)
          (removed 0)
          (hunks 0))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (cond
           ((string-prefix-p "@@" line)
            (cl-incf hunks))
           ((and (> (length line) 0)
                 (eq (aref line 0) ?+)
                 (not (string-prefix-p "+++" line)))
            (cl-incf added))
           ((and (> (length line) 0)
                 (eq (aref line 0) ?-)
                 (not (string-prefix-p "---" line)))
            (cl-incf removed))))
        (forward-line 1))
      (unless (> hunks 0)
        (signal 'benedict-error "Diff must include at least one hunk"))
      (list :added added :removed removed :hunks hunks))))

(defun benedict--propose-edit--prepare-review-buffer (name diff root)
  "Create a review buffer NAME containing DIFF and rooted at ROOT."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert diff)
        (goto-char (point-min))
        (setq-local default-directory root)
        (diff-mode)))
    buffer))

(defun benedict--propose-edit--apply-review-buffer (buffer)
  "Apply the diffs contained in BUFFER."
  (let ((failed nil)
        (orig-message (symbol-function 'message)))
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (_buf &rest _)
                 (or (get-buffer-window _buf 'visible) (selected-window))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (let ((text (apply #'format fmt args)))
                   (when (and (stringp text)
                              (string-match-p "hunks failed" text))
                     (setq failed t))
                   (apply orig-message fmt args)))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (diff-apply-buffer)))
    (when failed
      (signal 'benedict-error "Diff could not be applied"))))

(defun benedict--propose-edit--record-review-buffer (name)
  "Remember the review buffer NAME for later navigation."
  (setq benedict--propose-edit-review-buffers
        (cons name (cl-remove name benedict--propose-edit-review-buffers
                              :test #'string=)))
  (when (> (length benedict--propose-edit-review-buffers)
           benedict-propose-edit-review-buffer-history-size)
    (setcdr (nthcdr (1- benedict-propose-edit-review-buffer-history-size)
                    benedict--propose-edit-review-buffers)
            nil)))

(defun benedict--resolve-target-path (path root)
  "Return the absolute path for PATH under ROOT."
  (unless (and (stringp path) (not (string-empty-p (string-trim path))))
    (signal 'benedict-error "Path argument must be non-empty"))
  (let ((expanded (expand-file-name path root)))
    (unless (file-in-directory-p expanded root)
      (signal 'benedict-error "Path must stay inside the project root"))
    (unless (file-exists-p expanded)
      (signal 'benedict-error (format "Path %s does not exist" path)))
    expanded))

(defun benedict--resolve-target-file (path root)
  "Return the absolute filename for PATH under ROOT."
  (let ((expanded (benedict--resolve-target-path path root)))
    (unless (file-regular-p expanded)
      (signal 'benedict-error (format "Target %s is not a file" path)))
    expanded))

(cl-defun benedict--tool-propose-edit (&key path diff description &allow-other-keys)
   "Apply DIFF to PATH and expose an Emacs diff buffer for review."
   (let* ((path (string-trim (or path "")))
          (diff (or diff ""))
          (root (or (benedict--search-project-root)
                    (signal 'benedict-error "Project root unavailable")))
          (root (expand-file-name root))
          (target (benedict--resolve-target-file path root))
          (relative-path (file-relative-name target root)))
     (when (string-empty-p diff)
       (signal 'benedict-error "propose-edit requires a non-empty :diff"))
     (let* ((diff (if (string-suffix-p "\n" diff) diff (concat diff "\n")))
            (stats (benedict--propose-edit--count-diff-stats diff))
            (diff-paths (benedict--propose-edit--unique-diff-paths diff root)))
       (unless (= (length diff-paths) 1)
         (signal 'benedict-error "Diff must touch exactly one file"))
       (unless (string= (car diff-paths) relative-path)
         (signal 'benedict-error
                 (format "Diff header %s does not match expected path %s"
                         (car diff-paths) relative-path)))
       (let* ((review-name (benedict--propose-edit--review-buffer-name relative-path))
              (review-buffer (benedict--propose-edit--prepare-review-buffer
                              review-name diff root))
              (description-suffix (if (and description (not (string-empty-p description)))
                                      (format " (%s)" description)
                                    ""))
              (summary-line (format "Diff: %d hunks, +%d/-%d lines"
                                    (plist-get stats :hunks)
                                    (plist-get stats :added)
                                    (plist-get stats :removed)))
              ;; Format diff for inline display with syntax highlighting
              (formatted-diff (concat summary-line "\n\n"
                                      (concat "```diff\n" diff "```")))
              ;; Action to open the review buffer
              (open-diff-action (list :label "Open diff"
                                      :handler (lambda ()
                                                 (pop-to-buffer review-name)))))
         (benedict--propose-edit--apply-review-buffer review-buffer)
         (benedict--propose-edit--record-review-buffer review-name)
         (list :path path
               :content (format "Applied edit to %s%s" relative-path description-suffix)
               :stats stats
               :review-buffer review-name
               :ui (list :header (format "Proposed edit — %s" relative-path)
                         :state 'success
                         :body formatted-diff
                         :actions (list open-diff-action)))))))
 (benedict-tools-register
  :id 'propose-edit
  :fn #'benedict--tool-propose-edit
  :schema '(:path string :diff string :description string)
  :approval 'confirm
  :doc "Apply a single-file diff patch and show an Emacs review buffer.")

(cl-defun benedict--tool-create-file (&key path content description &allow-other-keys)
  "Create a new file at PATH with CONTENT."
  (let* ((path (string-trim (or path "")))
         (content (or content ""))
         (root (or (benedict--search-project-root)
                   (signal 'benedict-error "Project root unavailable")))
         (root (expand-file-name root)))
    (unless (and (stringp path) (not (string-empty-p path)))
      (signal 'benedict-error "Path argument must be non-empty"))
    (let ((expanded (expand-file-name path root)))
      (unless (file-in-directory-p expanded root)
        (signal 'benedict-error "Path must stay inside the project root"))
      (when (file-exists-p expanded)
        (signal 'benedict-error (format "File %s already exists" path)))
      ;; Create parent directories if needed
      (let ((parent (file-name-directory expanded)))
        (unless (file-directory-p parent)
          (make-directory parent t)))
      ;; Write the file
      (write-region content nil expanded nil 'silent)
      ;; Verify it was written
      (unless (file-exists-p expanded)
        (signal 'benedict-error (format "Failed to create file %s" path)))
      ;; Return success result
      (let ((relative-path (file-relative-name expanded root))
            (line-count (length (split-string content "\n" t)))
            ;; Action to open the created file
            (open-file-action (list :label "Open file"
                                    :handler (lambda ()
                                               (find-file expanded)))))
        (list :path path
              :content (format "Created file %s with %d lines" relative-path line-count)
              :ui (list :header (format "Created file — %s" relative-path)
                        :state 'success
                        :body (format "File created with %d lines of content" line-count)
                        :actions (list open-file-action)))))))

(benedict-tools-register
  :id 'create-file
  :fn #'benedict--tool-create-file
  :schema '(:path string :content string :description string)
  :approval 'confirm
  :doc "Create a new file with the given content.")

;; Seed demo tool
(benedict-tools-register :id 'uppercase :fn #'benedict--tool-uppercase
                         :schema '(:text string) :approval 'auto
                         :doc "Uppercase a string")

(benedict-tools-register
 :id 'project-search
 :fn #'benedict--tool-project-search
 :schema '(:query string)
 :approval 'auto
 :doc "Search files within the current project using grep patterns.")

(cl-defun benedict--tool-read-file (&key path start-line end-line)
  "Return the content of the file at PATH.
Optional START-LINE and END-LINE (1-based) restrict the output."
  (let* ((root (or (benedict--search-project-root)
                   (signal 'benedict-error "Project root unavailable")))
         (target (benedict--resolve-target-file path root))
         (relative (file-relative-name target root))
         (start (if (and start-line (> start-line 0)) start-line 1))
         (end (if (and end-line (> end-line 0)) end-line nil)))
    (when (and end (< end start))
      (signal 'benedict-error "end-line cannot be less than start-line"))
    (let ((content (with-temp-buffer
                     (insert-file-contents target)
                     (goto-char (point-min))
                     (forward-line (1- start))
                     (let ((beg (point)))
                       (if end
                           (forward-line (1+ (- end start)))
                         (goto-char (point-max)))
                       (buffer-substring-no-properties beg (point))))))
      (list :path relative
            :content content
            :start-line start
            :end-line end
            :ui (list :header (format "Read file — %s%s"
                                      relative
                                      (if (or (> start 1) end)
                                          (format " (lines %d-%s)" start (or end "EOF"))
                                        ""))
                      :state 'success
                      :body (format "Read %d chars from %s" (length content) relative))))))

(benedict-tools-register
 :id 'read-file
 :fn #'benedict--tool-read-file
 :schema '(:path string :start-line integer :end-line integer)
 :approval 'auto
 :doc "Read the contents of a file.")

(cl-defun benedict--tool-find-files (&key pattern path)
  "Return a list of files matching glob PATTERN.
If PATH is provided, search only within that directory."
  (let* ((root (or (benedict--search-project-root)
                   (signal 'benedict-error "Project root unavailable")))
         (target-dir (if path
                         (let ((p (benedict--resolve-target-path path root)))
                           (unless (file-directory-p p)
                             (signal 'benedict-error (format "Path %s is not a directory" path)))
                           p)
                       root)))
    (let* ((files (benedict-find-files-sync pattern :root target-dir))
           ;; files are relative to target-dir. Resolve to relative to project root.
           (rel-files (if path
                          (mapcar (lambda (f) (file-relative-name (expand-file-name f target-dir) root)) files)
                        files))
           (count (length rel-files))
           (ui-body (if (> count 0)
                        (format "Found %d files:\n%s" count (string-join (mapcar (lambda (f) (format "- %s" f)) rel-files) "\n"))
                      "No files found.")))
      (list :files rel-files
            :count count
            :content (prin1-to-string rel-files)
            :ui (list :header (format "Find files — %s" pattern)
                      :state 'success
                      :body ui-body)))))

(benedict-tools-register
 :id 'find-files
 :fn #'benedict--tool-find-files
 :schema '(:pattern string :path string)
 :approval 'auto
 :doc "Find files matching a glob pattern.")

;;; Line-based file update tool

(cl-defun benedict--tool-update-file (&key path start-line end-line content)
  "Replace lines START-LINE to END-LINE in PATH with CONTENT.
START-LINE and END-LINE are 1-based (inclusive).
If END-LINE is nil, replaces only START-LINE."
  (let* ((root (or (benedict--search-project-root)
                   (signal 'benedict-error "Project root unavailable")))
         (target (benedict--resolve-target-file path root))
         (relative (file-relative-name target root))
         (start (if (and start-line (> start-line 0)) start-line 1))
         (end (or end-line start)))
    (when (< end start)
      (signal 'benedict-error "end-line cannot be less than start-line"))
    (with-current-buffer (find-file-noselect target)
      (goto-char (point-min))
      (forward-line (1- start))
      (let ((beg (point)))
        (forward-line (1+ (- end start)))
        (delete-region beg (point))
        (goto-char beg)
        (insert (or content ""))
        (unless (or (null content)
                    (string-empty-p content)
                    (string-suffix-p "\n" content))
          (insert "\n"))
        (save-buffer)
        (let ((line-count (length (split-string (or content "") "\n" t))))
          (list :path relative
                :content (format "Updated lines %d-%d in %s" start end relative)
                :start-line start
                :end-line end
                :lines-written line-count
                :ui (list :header (format "Updated file — %s" relative)
                          :state 'success
                          :body (format "Replaced lines %d-%d with %d lines"
                                        start end line-count))))))))

(benedict-tools-register
 :id 'update-file
 :fn #'benedict--tool-update-file
 :schema '(:path string :start-line integer :end-line integer :content string)
 :approval 'confirm
 :doc "Replace a range of lines in a file with new content.")

;;; Elisp execution tool

(cl-defun benedict--tool-exec-elisp (&key code)
  "Execute elisp CODE and return the result.
This is a high-risk tool that evaluates arbitrary elisp code."
  (unless (and (stringp code) (not (string-empty-p (string-trim code))))
    (signal 'benedict-error "exec-elisp requires a non-empty :code"))
  (condition-case err
      (let* ((form (read code))
             (result (eval form t))
             (result-str (prin1-to-string result)))
        (list :success t
              :result result-str
              :content result-str
              :ui (list :header "Elisp execution"
                        :state 'success
                        :body (format "```elisp\n%s\n```\n=> %s" code result-str))))
    (error
     (let ((err-str (format "%S" err)))
       (list :success nil
             :error err-str
             :content err-str
             :ui (list :header "Elisp execution"
                       :state 'error
                       :body (format "```elisp\n%s\n```\nError: %s" code err-str)))))))

(benedict-tools-register
 :id 'exec-elisp
 :fn #'benedict--tool-exec-elisp
 :schema '(:code string)
 :approval 'always
 :doc "Execute arbitrary elisp code and return the result.")

(provide 'benedict-tools)
;;; benedict-tools.el ends here
