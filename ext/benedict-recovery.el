;;; benedict-recovery.el --- Conservative transcript recovery reports  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (benedict "0.1.0"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A transcript can prove that a tool result was recorded.  It cannot prove
;; that an unanswered call had no effect: Emacs may have exited after the
;; handler changed the world and before its result was appended.  This module
;; reports that uncertainty without retrying anything.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'benedict-message)
(require 'benedict-session)

(defun benedict-recovery-unknown-tool-calls (session)
  "Return reports for unanswered tools on SESSION's active path.

Each result is a plist with `:entry-id', `:id', `:name', `:arguments',
`:status' equal to `unknown', and a human-readable `:reason'.  Unknown means
the transcript does not establish whether the operation ran or produced side
effects.  This function is read-only and never retries an operation."
  (let ((pending nil))
    (dolist (entry (benedict-session-path session))
      (dolist (block (benedict-entry-content entry))
        (pcase (benedict-block-type block)
          ('tool-call
           (setq pending
                 (append pending
                         (list (list :entry-id (benedict-entry-id entry)
                                     :block block)))))
          ('tool-result
           (let ((match
                  (seq-find
                   (lambda (candidate)
                     (let ((call (plist-get candidate :block)))
                       (and (equal (plist-get call :id) (plist-get block :id))
                            (eq (plist-get call :name) (plist-get block :name)))))
                   (reverse pending))))
             (when match
               (setq pending (delq match pending))))))))
    (mapcar
     (lambda (candidate)
       (let ((call (plist-get candidate :block)))
         (list :entry-id (plist-get candidate :entry-id)
             :id (plist-get call :id)
             :name (plist-get call :name)
             :arguments (copy-tree (plist-get call :arguments))
             :status 'unknown
             :reason "No tool result was recorded; the call may not have started or may have completed with side effects")))
     pending)))

(provide 'benedict-recovery)

;;; benedict-recovery.el ends here
