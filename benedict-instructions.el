;;; benedict-instructions.el --- Instruction bootstrap for Benedict -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Discovers project-local instruction sources and selects a minimal subset to
;; seed new sessions with repository guidance.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'benedict-session)

(defgroup benedict-instructions nil
  "Instruction bootstrap for Benedict."
  :group 'benedict
  :prefix "benedict-instructions-")

(defcustom benedict-instructions-agents-file "AGENTS.md"
  "Project-local instructions file loaded when present."
  :type 'string
  :group 'benedict-instructions)

(defcustom benedict-instructions-specs-directory ".wigg/specs"
  "Directory containing project specification markdown files."
  :type 'string
  :group 'benedict-instructions)

(defcustom benedict-instructions-skills-directories '("agents/skills")
  "Directories searched for `SKILL.md' files."
  :type '(repeat string)
  :group 'benedict-instructions)

(defcustom benedict-instructions-max-selected-specs 4
  "Maximum number of spec files loaded into the system prompt."
  :type 'integer
  :group 'benedict-instructions)

(defcustom benedict-instructions-bootstrap-hook nil
  "Hook run after bootstrapping a session's instruction selection.
Each function receives `(SESSION DISCOVERED SELECTION)'."
  :type 'hook
  :group 'benedict-instructions)

(defconst benedict-instructions--spec-base-order
  '("01_overview.md" "02_architecture.md")
  "Spec files always selected when they exist.")

(defconst benedict-instructions--profile-skill-fallbacks
  '(("coding" . "impl")
    ("planning" . "plan")
    ("review" . "research")
    ("writing" . "research"))
  "Fallback skill names keyed by profile-like task text.")

(defconst benedict-instructions--spec-keywords
  '(("03_ui_ux.md" "ui" "ux" "vui" "render" "component" "chat")
    ("04_agent_loop.md" "agent" "loop" "autonomous" "checkpoint" "plan")
    ("05_providers.md" "provider" "model" "openrouter" "gemini" "ollama" "fake")
    ("06_tools.md" "tool" "tools" "read" "write" "edit" "exec" "search")
    ("07_harness_and_skills.md" "harness" "skill" "skills" "instruction" "agents" "scope" "budget"))
  "Keyword map used to rank optional spec files.")

(defun benedict-instructions--relative-path (path root)
  "Return PATH relative to ROOT when possible."
  (if (and root path)
      (file-relative-name path root)
    path))

(defun benedict-instructions--read-file (path)
  "Return PATH contents as a string."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun benedict-instructions--first-heading (text)
  "Return the first markdown heading in TEXT, or nil."
  (when (string-match "^# +\\(.+\\)$" text)
    (string-trim (match-string 1 text))))

(defun benedict-instructions--frontmatter-value (text key)
  "Return YAML frontmatter KEY from TEXT, or nil."
  (when (string-match "\\`---\n\\([\\s\\S]*?\\)\n---" text)
    (let* ((frontmatter (match-string 1 text))
           (scalar-pattern (format "^%s:[[:space:]]*\\(.+\\)$" (regexp-quote key)))
           (folded-pattern (format "^%s:[[:space:]]*>-?[[:space:]]*$" (regexp-quote key))))
      (cond
       ((string-match folded-pattern frontmatter)
        (let* ((start (match-end 0))
               (rest (substring frontmatter start))
               (lines (split-string rest "\n"))
               (collected nil))
          (while (and lines (string-match-p "^[[:space:]]+" (car lines)))
            (push (string-trim (car lines)) collected)
            (setq lines (cdr lines)))
          (when collected
            (string-join (nreverse collected) " "))))
       ((string-match scalar-pattern frontmatter)
        (string-trim (match-string 1 frontmatter) "\"" "\""))))))

(defun benedict-instructions--tokens (text)
  "Return lowercase word tokens extracted from TEXT."
  (delete-dups
   (split-string (downcase (or text "")) "[^[:alnum:]]+" t)))

(defun benedict-instructions--make-source (kind path root &optional content)
  "Build source metadata plist for KIND at PATH under ROOT.
When CONTENT is non-nil, include it in the returned plist."
  (let* ((raw (or content (benedict-instructions--read-file path)))
         (relative-path (benedict-instructions--relative-path path root))
         (title (pcase kind
                  ('skill (or (benedict-instructions--frontmatter-value raw "name")
                              (benedict-instructions--first-heading raw)
                              relative-path))
                  (_ (or (benedict-instructions--first-heading raw)
                         relative-path))))
         (summary (pcase kind
                    ('skill (benedict-instructions--frontmatter-value raw "description"))
                    (_ nil)))
         (entry (list :kind kind
                      :path path
                      :relative-path relative-path
                      :title title
                      :summary summary
                      :tokens (benedict-instructions--tokens
                               (string-join (delq nil (list relative-path title summary)) " ")))))
    (if content
        (plist-put entry :content raw)
      entry)))

(defun benedict-instructions-discover (root)
  "Discover instruction sources under ROOT.
Returns a plist with cheap metadata only; source bodies are not retained."
  (let* ((project-root (and root (expand-file-name root)))
         (agents-path (and project-root
                           (expand-file-name benedict-instructions-agents-file project-root)))
         (skill-paths
          (and project-root
               (cl-mapcan
                (lambda (dir)
                  (file-expand-wildcards
                   (expand-file-name "*/SKILL.md" (expand-file-name dir project-root))
                   t))
                benedict-instructions-skills-directories)))
         (spec-paths
          (and project-root
               (file-expand-wildcards
                (expand-file-name "*.md"
                                  (expand-file-name benedict-instructions-specs-directory
                                                    project-root))
                t))))
    (list :root project-root
          :agents (when (and agents-path (file-exists-p agents-path))
                    (list (benedict-instructions--make-source 'agents agents-path project-root)))
          :skills (mapcar (lambda (path)
                            (benedict-instructions--make-source 'skill path project-root))
                          (sort skill-paths #'string<))
          :specs (mapcar (lambda (path)
                           (benedict-instructions--make-source 'spec path project-root))
                         (sort spec-paths #'string<)))))

(defun benedict-instructions--match-score (source query)
  "Return a simple relevance score for SOURCE against QUERY tokens."
  (let* ((query-tokens (benedict-instructions--tokens query))
         (source-tokens (plist-get source :tokens))
         (score 0))
    (dolist (token query-tokens score)
      (when (member token source-tokens)
        (setq score (1+ score))))))

(defun benedict-instructions--load-source-content (source root)
  "Return SOURCE with file content loaded from ROOT."
  (benedict-instructions--make-source
   (plist-get source :kind)
   (expand-file-name (plist-get source :relative-path) root)
   root
   (benedict-instructions--read-file
    (expand-file-name (plist-get source :relative-path) root))))

(defun benedict-instructions--find-by-relative-path (sources relative-path)
  "Return the source in SOURCES with RELATIVE-PATH, or nil."
  (cl-find relative-path sources
           :key (lambda (source) (plist-get source :relative-path))
           :test #'equal))

(defun benedict-instructions--find-skill-by-name (skills name)
  "Return skill plist from SKILLS matching NAME."
  (cl-find-if (lambda (skill)
                (or (equal name (plist-get skill :title))
                    (equal name
                           (file-name-base
                            (directory-file-name
                             (file-name-directory
                              (plist-get skill :relative-path)))))))
              skills))

(defun benedict-instructions--select-skills (skills query)
  "Return selected skill metadata from SKILLS for QUERY."
  (let* ((scored
          (sort (mapcar (lambda (skill)
                          (cons (benedict-instructions--match-score skill query) skill))
                        skills)
                (lambda (left right)
                  (> (car left) (car right)))))
         (positive (mapcar #'cdr (seq-filter (lambda (pair) (> (car pair) 0)) scored))))
    (cond
     (positive
      (list (car positive)))
     (t
      (let* ((query-tokens (benedict-instructions--tokens query))
             (fallback-name
              (cl-loop for (needle . skill-name) in benedict-instructions--profile-skill-fallbacks
                       when (member needle query-tokens)
                       return skill-name)))
        (when fallback-name
          (when-let ((skill (benedict-instructions--find-skill-by-name skills fallback-name)))
            (list skill))))))))

(defun benedict-instructions--spec-extra-score (spec query)
  "Return score for optional SPEC selection from QUERY."
  (let ((relative-path (file-name-nondirectory (plist-get spec :relative-path)))
        (score (benedict-instructions--match-score spec query)))
    (+ score
       (cl-loop for (file . keywords) in benedict-instructions--spec-keywords
                when (and (equal file relative-path)
                          (cl-some (lambda (keyword)
                                     (member keyword (benedict-instructions--tokens query)))
                                   keywords))
                sum 2))))

(defun benedict-instructions-select (discovered task-text)
  "Select instruction sources from DISCOVERED for TASK-TEXT.
The returned plist includes selected sources with file bodies loaded."
  (let* ((root (plist-get discovered :root))
         (agents (plist-get discovered :agents))
         (skills (plist-get discovered :skills))
         (specs (plist-get discovered :specs))
         (query (or task-text ""))
         (selected-meta nil))
    (setq selected-meta
          (append selected-meta agents))
    (setq selected-meta
          (append selected-meta
                  (benedict-instructions--select-skills skills query)))
    (dolist (relative-path benedict-instructions--spec-base-order)
      (when-let ((spec (benedict-instructions--find-by-relative-path specs
                                                                     (concat benedict-instructions-specs-directory
                                                                             "/"
                                                                             relative-path))))
        (cl-pushnew spec selected-meta :test #'equal)))
    (let* ((optional-specs
            (cl-set-difference specs selected-meta :test #'equal))
           (ranked-optional
            (sort (mapcar (lambda (spec)
                            (cons (benedict-instructions--spec-extra-score spec query) spec))
                          optional-specs)
                  (lambda (left right)
                    (> (car left) (car right)))))
           (remaining (max 0 (- benedict-instructions-max-selected-specs
                                (cl-count-if (lambda (source)
                                               (eq (plist-get source :kind) 'spec))
                                             selected-meta)))))
      (dolist (pair ranked-optional)
        (when (and (> remaining 0)
                   (> (car pair) 0))
          (push (cdr pair) selected-meta)
          (setq remaining (1- remaining)))))
    (let ((selected
           (mapcar (lambda (source)
                     (benedict-instructions--load-source-content source root))
                   (cl-remove-duplicates (nreverse selected-meta) :test #'equal))))
      (list :root root
            :task-text task-text
            :sources selected
            :paths (mapcar (lambda (source) (plist-get source :relative-path)) selected)))))

(defun benedict-instructions-build-system-prompt (selection)
  "Build a system prompt string from instruction SELECTION."
  (when-let ((sources (plist-get selection :sources)))
    (string-join
     (append
      (list "Repository-local instructions are part of the system context. Apply them in the listed order."
            (format "Loaded sources: %s"
                    (string-join
                     (mapcar (lambda (source) (plist-get source :relative-path)) sources)
                     ", ")))
      (mapcar
       (lambda (source)
         (format "## Source: %s\n\n%s"
                 (plist-get source :relative-path)
                 (string-trim-right (or (plist-get source :content) ""))))
       sources))
     "\n\n")))

(defun benedict-instructions-bootstrap-session (session &optional task-text)
  "Bootstrap SESSION from repository-local instructions using TASK-TEXT."
  (let* ((root (or (benedict-session-root session)
                   default-directory))
         (discovered (benedict-instructions-discover root))
         (selection (benedict-instructions-select discovered task-text))
         (meta (copy-tree (benedict-session-meta session))))
    (setq meta
          (plist-put meta :instruction-discovery discovered))
    (setq meta
          (plist-put meta :instruction-selection selection))
    (setq meta
          (plist-put meta :instruction-sources (plist-get selection :paths)))
    (setf (benedict-session-meta session) meta)
    (run-hook-with-args 'benedict-instructions-bootstrap-hook
                        session discovered selection)
    selection))

(provide 'benedict-instructions)
;;; benedict-instructions.el ends here
