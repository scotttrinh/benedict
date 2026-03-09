;;; benedict-instructions-test.el --- Tests for instruction bootstrap -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-instructions)
(require 'benedict-session)

(defun benedict-instructions-test--write-file (path content)
  "Write CONTENT to PATH, creating parent directories first."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert content)))

(defun benedict-instructions-test--fixture-repo ()
  "Create a temporary repository fixture to test instruction loading."
  (let ((root (make-temp-file "benedict-instructions-" t)))
    (benedict-instructions-test--write-file
     (expand-file-name "AGENTS.md" root)
     "# Project Agent\n\nUse local repo rules.\n")
    (benedict-instructions-test--write-file
     (expand-file-name "agents/skills/impl/SKILL.md" root)
     "---\nname: impl\ndescription: >-\n  Execute implementation work.\n---\n# impl\n\nImplementation skill.\n")
    (benedict-instructions-test--write-file
     (expand-file-name "agents/skills/plan/SKILL.md" root)
     "---\nname: plan\ndescription: >-\n  Plan the work.\n---\n# plan\n\nPlanning skill.\n")
    (benedict-instructions-test--write-file
     (expand-file-name ".wigg/specs/01_overview.md" root)
     "# Overview\n\nOverview body.\n")
    (benedict-instructions-test--write-file
     (expand-file-name ".wigg/specs/02_architecture.md" root)
     "# Architecture\n\nArchitecture body.\n")
    (benedict-instructions-test--write-file
     (expand-file-name ".wigg/specs/06_tools.md" root)
     "# Tools\n\nTooling body.\n")
    (benedict-instructions-test--write-file
     (expand-file-name ".wigg/specs/07_harness_and_skills.md" root)
     "# Harness and Skills\n\nHarness body.\n")
    root))

(ert-deftest benedict-instructions-test-discover-keeps-content-cheap ()
  "Discovery returns metadata without preloading file bodies."
  (let ((root (benedict-instructions-test--fixture-repo)))
    (unwind-protect
        (let* ((discovered (benedict-instructions-discover root))
               (agents (plist-get discovered :agents))
               (skills (plist-get discovered :skills))
               (specs (plist-get discovered :specs)))
          (should (= 1 (length agents)))
          (should (= 2 (length skills)))
          (should (= 4 (length specs)))
          (should-not (plist-member (car skills) :content))
          (should (equal "AGENTS.md"
                         (plist-get (car agents) :relative-path)))
          (should (equal "agents/skills/impl/SKILL.md"
                         (plist-get (car skills) :relative-path))))
      (delete-directory root t))))

(ert-deftest benedict-instructions-test-select-loads-relevant-sources ()
  "Selection loads AGENTS, a relevant skill, and matching specs."
  (let ((root (benedict-instructions-test--fixture-repo)))
    (unwind-protect
        (let* ((discovered (benedict-instructions-discover root))
               (selection (benedict-instructions-select discovered "coding tools harness"))
               (paths (plist-get selection :paths))
               (sources (plist-get selection :sources))
               (prompt (benedict-instructions-build-system-prompt selection)))
          (should (member "AGENTS.md" paths))
          (should (member "agents/skills/impl/SKILL.md" paths))
          (should (member ".wigg/specs/01_overview.md" paths))
          (should (member ".wigg/specs/02_architecture.md" paths))
          (should (member ".wigg/specs/06_tools.md" paths))
          (should (member ".wigg/specs/07_harness_and_skills.md" paths))
          (should (cl-every (lambda (source) (plist-member source :content)) sources))
          (should (string-match-p "Source: AGENTS.md" prompt))
          (should (string-match-p "Implementation skill" prompt)))
      (delete-directory root t))))

(ert-deftest benedict-instructions-test-bootstrap-persists-session-metadata ()
  "Bootstrap stores selection metadata on the session."
  (let ((root (benedict-instructions-test--fixture-repo))
        (benedict-session--registry (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((session (benedict-session-create :root root))
               (selection (benedict-instructions-bootstrap-session session "planning"))
               (meta (benedict-session-meta session)))
          (should (equal selection (plist-get meta :instruction-selection)))
          (should (member "AGENTS.md" (plist-get meta :instruction-sources)))
          (should (member "agents/skills/plan/SKILL.md"
                          (plist-get meta :instruction-sources))))
      (delete-directory root t))))

(provide 'benedict-instructions-test)
;;; benedict-instructions-test.el ends here
