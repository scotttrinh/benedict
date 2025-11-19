;;; benedict-tools.el --- Tool registry skeleton -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Minimal registry to register/list/call tool functions. Approval UX is a
;; placeholder and will be implemented later in Phase 1.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)

(defvar benedict--tools (make-hash-table :test 'eq)
  "Registry of tool specs keyed by :id symbol.")

(defcustom benedict-search-project-executable "rg"
  "Name or path of the ripgrep executable used for project searches."
  :type 'string
  :group 'benedict)

(defcustom benedict-search-project-max-results 200
  "Maximum number of matches `project-search' returns per invocation."
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
    (dolist (pattern benedict-search-project-exclude-globs)
      (when (and pattern (not (string-empty-p pattern)))
        (let ((value (if (string-prefix-p "!" pattern) pattern (concat "!" pattern))))
          (push "--glob" args)
          (push value args))))
    (dolist (pattern extra-globs)
      (when (and pattern (not (string-empty-p pattern)))
        (push "--glob" args)
        (push pattern args)))
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
           (command-args
            (append '("--json" "--line-number" "--column" "--no-heading" "--color" "never" "--with-filename" "--follow")
                    (when benedict-search-project-include-hidden '("--hidden"))
                    (list "--max-count" (number-to-string limit))
                    (benedict--search-project--glob-args globs)
                    (unless regexp-mode '("--fixed-strings"))
                    ;; Protect query so leading dashes are treated as search text.
                    (list "--" query))))
      (with-temp-buffer
        (let ((exit-code (apply #'call-process executable nil (current-buffer) nil command-args)))
          ;; ripgrep exits 1 when no matches are found; treat it as success.
          (unless (member exit-code '(0 1))
            (signal 'benedict-error
                    (format "Project search failed (rg exited %s) with args %S"
                            exit-code command-args))))
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
                                 matches)))))
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

;; Seed demo tool
(benedict-tools-register :id 'uppercase :fn #'benedict--tool-uppercase
                         :schema '(:text string) :approval 'auto
                         :doc "Uppercase a string")

(benedict-tools-register
 :id 'project-search
 :fn #'benedict--tool-project-search
 :schema '(:query string)
 :approval 'confirm
 :doc "Search files within the current project.")

(provide 'benedict-tools)
;;; benedict-tools.el ends here
