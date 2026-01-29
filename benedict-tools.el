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
(require 'benedict-errors)

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

;;; Tool schema encoding

(defun benedict-tool--plist-entries (plist)
  "Return PLIST as an alist preserving declaration order."
  (let (result)
    (cl-loop for (key value) on plist by #'cddr
             do (push (cons key value) result))
    (nreverse result)))

(defun benedict-tool--schema-key-string (key)
  "Return KEY represented as a JSON property name."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (error "Tool schema keys must be symbols or strings: %S" key))))

(defun benedict-tool-type->json-type (type-tag)
  "Normalize TYPE-TAG symbol to a JSON Schema type string."
  (unless (symbolp type-tag)
    (error "Tool schema :type must be a symbol: %S" type-tag))
  (pcase type-tag
    ('string "string")
    ((or 'integer 'int) "integer")
    ((or 'number 'float 'double 'real) "number")
    ((or 'boolean 'bool) "boolean")
    ('object "object")
    (_ (error "Unknown tool schema type: %S" type-tag))))

(defun benedict-tool--schema-append-metadata (alist schema)
  "Append common metadata keys from SCHEMA onto ALIST."
  (let ((result alist))
    (when-let ((description (plist-get schema :description)))
      (setq result (append result (list (cons "description" description)))))
    (when (plist-member schema :default)
      (setq result (append result (list (cons "default" (plist-get schema :default))))))
    result))

(defun benedict-tool--schema-required-vector (required)
  "Return REQUIRED list as a JSON array vector."
  (let ((names (and (listp required)
                    (cl-remove-if-not #'identity
                                      (mapcar #'benedict-tool--schema-key-string required)))))
    (when names
      (apply #'vector names))))

(defun benedict-tool--encode-property-schema (prop-schema)
  "Return JSON Schema alist for PROP-SCHEMA plist."
  (let* ((type (plist-get prop-schema :type)))
    (unless type
      (error "Property schema missing :type: %S" prop-schema))
    (let ((json-type (benedict-tool-type->json-type type)))
      (if (string= json-type "object")
          (benedict-tool-schema->json-parameters prop-schema)
        (let ((result (list (cons "type" json-type))))
          (benedict-tool--schema-append-metadata result prop-schema))))))

(defun benedict-tool--encode-properties (props)
  "Encode PROPS plist into a JSON Schema properties alist."
  (when props
    (let (encoded)
      (dolist (entry (benedict-tool--plist-entries props))
        (push (cons (benedict-tool--schema-key-string (car entry))
                    (benedict-tool--encode-property-schema (cdr entry)))
              encoded))
      (nreverse encoded))))

(defun benedict-tool-schema->json-parameters (schema)
  "Convert SCHEMA plist to a JSON-Schema-shaped parameters object."
  (let* ((json-type (benedict-tool-type->json-type (plist-get schema :type))))
    (unless (string= json-type "object")
      (error "Tool schemas must use :type object (got %S)" (plist-get schema :type)))
    (let ((result nil))
      (setq result (append result (list (cons "type" "object"))))
      (setq result (benedict-tool--schema-append-metadata result schema))
      (when-let ((properties (benedict-tool--encode-properties (plist-get schema :properties))))
        (setq result (append result (list (cons "properties" properties)))))
      (when-let ((required (benedict-tool--schema-required-vector (plist-get schema :required))))
        (setq result (append result (list (cons "required" required)))))
      result)))

(defun benedict-tool-args->alist (args)
  "Normalize ARGS plist or alist to a string-keyed alist."
  (cond
   ((null args) nil)
   ((and (listp args) (consp (car args)))
    (mapcar (lambda (pair)
              (cons (benedict-tool--schema-key-string (car pair))
                    (cdr pair)))
            args))
   ((listp args)
    (unless (cl-evenp (length args))
      (error "Tool args plist must have even length: %S" args))
    (let (result)
      (cl-loop for (key value) on args by #'cddr
               do (push (cons (benedict-tool--schema-key-string key) value) result))
      (nreverse result)))
   (t (error "Tool args must be a plist or alist: %S" args))))

(defun benedict-tool-encode-args-json (args)
  "Return JSON string for ARGS by delegating to `json-encode'."
  (let ((normalized (benedict-tool-args->alist args)))
    (if normalized
        (json-encode normalized)
      "{}")))

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
              (list (format "Project search requires %s in PATH"
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
      (signal 'benedict-error '("Project search requires a non-empty query")))
    (setq query needle)
    (let* ((root (or (and root (expand-file-name root))
                     (benedict--search-project-root)))
           (default-directory (or root (signal 'benedict-error '("Project root unavailable"))))
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
                    (list (format "Project search failed (rg exited %s) with args %S output %S"
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
         (default-directory (or root (signal 'benedict-error '("Project root unavailable"))))
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
                  (list (format "Find files failed (rg exited %s) with args %S"
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
SCHEMA is a plist following the JSON-Schema-like contract consumed by
`benedict-tool-schema->json-parameters' (top-level :type object with
:properties and optional :required). APPROVAL is one of 'auto,
'confirm, or 'always. DOC is an optional string."
  (puthash id (list :id id :fn fn :schema schema :approval approval :doc doc)
           benedict--tools))

(defun benedict-tools-list ()
  "Return a list of tool specs."
  (let (acc) (maphash (lambda (_k v) (push v acc)) benedict--tools) (nreverse acc)))

(defun benedict--tool-call-direct (id args)
  "Invoke tool ID with ARGS without applying approval policy."
  (let ((spec (gethash id benedict--tools)))
    (unless spec
      (signal 'benedict-error (list (format "Unknown tool: %S" id))))
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
                   (signal 'benedict-error (list (format "Unknown tool: %S" id)))))
         (approval (plist-get spec :approval))
         (approved
          (cond
           ((or (null approval) (eq approval 'auto)) t)
           ((memq approval '(confirm always))
            (benedict--prompt-for-approval spec args))
           (t (benedict--prompt-for-approval spec args)))))
    (unless approved
      (signal 'benedict-error (list (format "Tool %S invocation canceled by user" id))))
    (benedict--tool-call-direct id args)))

(benedict-tools-register
 :id 'write
 :fn #'benedict--tool-write
 :schema '(:type object
           :description "Write content to a file or buffer."
           :properties
           (:target
            (:type object
             :description "Target file or buffer."
             :properties
             (:kind (:type string :description "Either 'file' or 'buffer'.")
              :path (:type string :description "Filesystem path when kind is 'file'.")
              :buffer_name (:type string :description "Buffer name when kind is 'buffer'.")))
            :content (:type string :description "New content to write.")
            :create_if_missing
            (:type boolean :description "Whether to create the target if missing."))
           :required (:target :content))
 :approval 'confirm
 :doc "Create or overwrite a file or buffer with new content.")

(benedict-tools-register
 :id 'edit
 :fn #'benedict--tool-edit
 :schema '(:type object
           :description "Edit text in a file or buffer."
           :properties
           (:target
            (:type object
             :description "Target file or buffer."
             :properties
             (:kind (:type string :description "Either 'file' or 'buffer'.")
              :path (:type string :description "Filesystem path when kind is 'file'.")
              :buffer_name (:type string :description "Buffer name when kind is 'buffer'.")))
            :old_text (:type string :description "Exact text to replace.")
            :new_text (:type string :description "Replacement text."))
           :required (:target :old_text :new_text))
 :approval 'confirm
 :doc "Replace exactly one occurrence of old_text with new_text.")

(benedict-tools-register
 :id 'project-search
 :fn #'benedict--tool-project-search
 :schema '(:type object
           :description "Search files within the current project using grep patterns."
           :properties
           (:query (:type string :description "Search query."))
           :required (:query))
 :approval 'auto
 :doc "Search files within the current project using grep patterns.")

;; Example demo tool used by echo provider later
(defun benedict--tool-uppercase (&key text)
  "Return TEXT uppercased."
  (upcase (or text "")))

(defun benedict--tool-project-search (&key query)
  "Stub tool implementation returning placeholder search results for QUERY."
  (unless (and (stringp query) (not (string-empty-p (string-trim query))))
    (signal 'benedict-error '("project-search requires a non-empty :query")))
  (let* ((result (benedict-search-project-sync query))
         (ui (benedict--project-search--build-ui result))
         (print-level nil)
         (print-length nil)
         (content (prin1-to-string result)))
    (list :content content
          :ui ui
          :data result)))

;; Helpers for the project tools

(defun benedict--resolve-target-path (path root)
  "Return the absolute path for PATH under ROOT."
  (unless (and (stringp path) (not (string-empty-p (string-trim path))))
    (signal 'benedict-error '("Path argument must be non-empty")))
  (let ((expanded (expand-file-name path root)))
    (unless (file-in-directory-p expanded root)
      (signal 'benedict-error '("Path must stay inside the project root")))
    (unless (file-exists-p expanded)
      (signal 'benedict-error (list (format "Path %s does not exist" path))))
    expanded))

(defun benedict--resolve-target-file (path root)
  "Return the absolute filename for PATH under ROOT."
  (let ((expanded (benedict--resolve-target-path path root)))
    (unless (file-regular-p expanded)
(signal 'benedict-error (list (format "Target %s is not a file" path))))
    expanded))


(defun benedict--tool-resolve-target-buffer (target &optional create-if-missing)
  "Resolve TARGET to a buffer.
TARGET is a plist with :kind (string), and either :path (for kind \"file\")
or :buffer_name (for kind \"buffer\").
If CREATE-IF-MISSING is non-nil, create the file/buffer if it doesn't exist.
Returns a plist:
  :buffer        (buffer object)
  :kind          (\"file\" or \"buffer\")
  :path          (original path if file)
  :buffer_name   (original buffer name if buffer)
  :absolute-path (absolute path if file)
  :file-backed-p (boolean)"
  (let* ((kind (plist-get target :kind))
         (path (plist-get target :path))
         (buffer-name (plist-get target :buffer_name)))
    (cond
     ((string= kind "file")
      (unless (and path (not (string-empty-p (string-trim path))))
        (signal 'benedict-error '("Target kind is 'file' but 'path' is missing or empty")))
      (let* ((root (or (benedict--search-project-root)
                       (signal 'benedict-error '("Project root unavailable"))))
             (expanded (expand-file-name path root)))
        (unless (file-in-directory-p expanded root)
          (signal 'benedict-error (list (format "Path %s must stay inside the project root" path))))
        (when (and (not create-if-missing) (not (file-exists-p expanded)))
(signal 'benedict-error (list (format "File %s does not exist and create_if_missing is false" path))))
        (when (and create-if-missing (not (file-exists-p expanded)))
          (let ((parent (file-name-directory expanded)))
            (unless (file-directory-p parent)
              (make-directory parent t))))
        (let ((buf (find-file-noselect expanded)))
          (list :buffer buf
                :kind "file"
                :path path
                :absolute-path expanded
                :file-backed-p t))))
     ((string= kind "buffer")
      (unless (and buffer-name (not (string-empty-p (string-trim buffer-name))))
        (signal 'benedict-error '("Target kind is 'buffer' but 'buffer_name' is missing or empty")))
      (let ((buf (if create-if-missing
                     (get-buffer-create buffer-name)
                   (or (get-buffer buffer-name)
                       (signal 'benedict-error (list (format "Buffer %s does not exist and create_if_missing is false" buffer-name))))))
        (list :buffer buf
              :kind "buffer"
              :buffer_name buffer-name
              :file-backed-p (not (null (buffer-file-name buf))))))
     (t
      (signal 'benedict-error (list (format "Unknown target kind: %S" kind))))))

(cl-defun benedict--tool-write (&key target content (create_if_missing t))
  "Create or overwrite TARGET with CONTENT.
TARGET is a plist with :kind, and either :path or :buffer_name."
  (let* ((create-if-missing (if (eq create_if_missing 'json-false) nil create_if_missing))
         (res (benedict--tool-resolve-target-buffer target create-if-missing))
         (buf (plist-get res :buffer))
         (kind (plist-get res :kind))
         (path (plist-get res :path))
         (buffer-name (plist-get res :buffer_name))
         (file-backed-p (plist-get res :file-backed-p))
         (text (or content "")))
    (with-current-buffer buf
      (atomic-change-group
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text)
          ;; Ensure trailing newline for file-backed buffers
          (when (and file-backed-p
                     (not (string-empty-p text))
                     (not (string-suffix-p "\n" text)))
            (insert "\n"))))
      (when file-backed-p
        (save-buffer)))
    (let* ((line-count (with-current-buffer buf (count-lines (point-min) (point-max))))
           (target-label (if (string= kind "file") path buffer-name))
           (summary (format "Wrote %d lines to %s %s" line-count kind target-label))
           (open-action (list :label (if (string= kind "file") "Open file" "Switch to buffer")
                              :handler (let ((absolute-path (plist-get res :absolute-path))
                                             (target-buffer-name buffer-name)
                                             (target-kind kind))
                                         (lambda ()
                                           (if (string= target-kind "file")
                                               (find-file absolute-path)
                                             (pop-to-buffer target-buffer-name)))))))
      (list :target res
            :operation "write"
            :lines_written line-count
            :content summary
            :ui (list :header (format "Wrote %s — %s" kind target-label)
                      :state 'success
                      :body (format "Overwrote %s with %d lines" kind line-count)
                      :actions (list open-action))))))

(cl-defun benedict--tool-edit (&key target old_text new_text)
  "Replace exactly one occurrence of OLD_TEXT with NEW_TEXT in TARGET.
TARGET is a plist with :kind, and either :path or :buffer_name."
  (let* ((old-text (or old_text ""))
         (new-text (or new_text ""))
         ;; 'edit' never creates missing targets
         (res (benedict--tool-resolve-target-buffer target nil))
         (buf (plist-get res :buffer))
         (kind (plist-get res :kind))
         (path (plist-get res :path))
         (buffer-name (plist-get res :buffer_name))
         (file-backed-p (plist-get res :file-backed-p)))
    (when (string= old-text new-text)
      (signal 'benedict-error '("edit: old_text and new_text are identical; no change to apply")))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (let ((matches nil)
              (case-fold-search nil)) ;; Strict literal matching
          (while (search-forward old-text nil t)
            (push (cons (match-beginning 0) (match-end 0)) matches))
          (let ((n (length matches)))
            (cond
             ((= n 0)
              (signal 'benedict-error '("edit: old_text not found; expected exactly one occurrence. Include more surrounding context in old_text")))
             ((> n 1)
              (signal 'benedict-error (list (format "edit: old_text matched %d times; expected exactly one. Include more surrounding context in old_text" n))))
             (t
              ;; Exactly one match
              (atomic-change-group
                (let ((inhibit-read-only t)
                      (match (car matches)))
                  (delete-region (car match) (cdr match))
                  (goto-char (car match))
                  (insert new-text)))
              (when file-backed-p
                (save-buffer)))))))
      (let* ((target-label (if (string= kind "file") path buffer-name))
             (summary (format "Replaced 1 snippet in %s %s" kind target-label))
             (open-action (list :label (if (string= kind "file") "Open file" "Switch to buffer")
                                :handler (let ((absolute-path (plist-get res :absolute-path))
                                               (target-buffer-name buffer-name)
                                               (target-kind kind))
                                           (lambda ()
                                             (if (string= target-kind "file")
                                                 (find-file absolute-path)
                                               (pop-to-buffer target-buffer-name)))))))
        (list :target res
              :operation "edit"
              :matches_found 1
              :replacements_made 1
              :content summary
              :ui (list :header (format "Edited %s — %s" kind target-label)
                        :state 'success
                        :body summary
                        :actions (list open-action)))))))

(cl-defun benedict--tool-read-file (&key path start-line end-line)

  "Return the content of the file or buffer at PATH.
If PATH matches a live buffer name, reads from that buffer.
Otherwise treats PATH as a file path relative to the project root.
Optional START-LINE and END-LINE (1-based) restrict the output."
  (let* ((start (if (and start-line (> start-line 0)) start-line 1))
         (end (if (and end-line (> end-line 0)) end-line nil))
         ;; Try to resolve as buffer first
         (buffer (get-buffer path))
         (root (unless buffer (benedict--search-project-root)))
         ;; If no buffer, resolve as file
         (target (unless buffer
                   (unless root (signal 'benedict-error '("Project root unavailable")))
                   (benedict--resolve-target-file path root)))
         (relative (if buffer path (file-relative-name target root))))

    (when (and end (< end start))
      (signal 'benedict-error '("end-line cannot be less than start-line")))

    (let ((content
           (if buffer
               ;; Read from buffer
               (with-current-buffer buffer
                 (save-excursion
                   (goto-char (point-min))
                   (forward-line (1- start))
                   (let ((beg (point)))
                     (if end
                         (forward-line (1+ (- end start)))
                       (goto-char (point-max)))
                     (buffer-substring-no-properties beg (point)))))
             ;; Read from file
             (with-temp-buffer
               (insert-file-contents target)
               (goto-char (point-min))
               (forward-line (1- start))
               (let ((beg (point)))
                 (if end
                     (forward-line (1+ (- end start)))
                   (goto-char (point-max)))
                 (buffer-substring-no-properties beg (point)))))))
      (list :path relative
            :content content
            :start-line start
            :end-line end
            :ui (list :header (format "Read %s — %s%s"
                                      (if buffer "buffer" "file")
                                      relative
                                      (if (or (> start 1) end)
                                          (format " (lines %d-%s)" start (or end "EOF"))
                                        ""))
                      :state 'success
                      :body (format "Read %d chars from %s" (length content) relative))))))

(benedict-tools-register
 :id 'read-file
 :fn #'benedict--tool-read-file
 :schema '(:type object
           :description "Read a file or buffer, optionally by line range."
           :properties
           (:path (:type string :description "Filesystem path or buffer name.")
            :start-line (:type integer :description "1-based start line (optional).")
            :end-line (:type integer :description "1-based end line (optional)."))
           :required (:path))
 :approval 'auto
 :doc "Read the contents of a file.")

(cl-defun benedict--tool-find-files (&key pattern path)
  "Return a list of files matching glob PATTERN.
If PATH is provided, search only within that directory."
  (let* ((root (or (benedict--search-project-root)
                   (signal 'benedict-error '("Project root unavailable"))))
         (target-dir (if path
                         (let ((p (benedict--resolve-target-path path root)))
                           (unless (file-directory-p p)
(signal 'benedict-error (list (format "Path %s is not a directory" path))))
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
 :schema '(:type object
           :description "Find files matching a glob pattern."
           :properties
           (:pattern (:type string :description "Glob-like pattern to search for.")
            :path (:type string :description "Base directory relative to the project root."))
           :required (:pattern))
 :approval 'auto
 :doc "Find files matching a glob pattern.")

;;; Elisp execution tool


(cl-defun benedict--tool-exec-elisp (&key code)
  "Execute elisp CODE and return the result.
This is a high-risk tool that evaluates arbitrary elisp code."
  (unless (and (stringp code) (not (string-empty-p (string-trim code))))
    (signal 'benedict-error '("exec-elisp requires a non-empty :code")))
  (condition-case err
      (let* ((form (read code))
             (output nil)
             (result nil))
        (setq output (with-output-to-string
                       (setq result (eval form t))))
        (let* ((result-str (prin1-to-string result))
               (output-str (if (string-empty-p output) nil output)))
          (list :success t
                :result result-str
                :output output-str
                :content (if output-str
                             (format "%s\nOutput:\n%s" result-str output-str)
                           result-str)
                :ui (list :header "Elisp execution"
                          :state 'success
                          :body (format "```elisp\n%s\n```\n=> %s%s"
                                        code
                                        result-str
                                        (if output-str
                                            (format "\nOutput:\n%s" output-str)
                                          ""))))))
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
 :schema '(:type object
           :description "Execute Emacs Lisp code."
           :properties
           (:code (:type string :description "Elisp form to evaluate."))
           :required (:code))
 :approval 'always
 :doc "Execute arbitrary elisp code and return the result.")

(provide 'benedict-tools)
;;; benedict-tools.el ends here
