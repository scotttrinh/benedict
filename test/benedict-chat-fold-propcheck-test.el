;;; benedict-chat-fold-propcheck-test.el --- Property tests for magit-section chat folding -*- lexical-binding: t; -*-

;; This file previously tested classic overlay folding via benedict-chat-fold
;; using property-based testing with propcheck. During Phase 3 of the
;; promote-chat-ui-mode effort, classic overlay folding is being removed in
;; favor of magit-section based folding.
;;
;; The old tests have been commented out below for reference. New tests for
;; magit-section based folding should be added as the implementation progresses.

(require 'ert)
(require 'propcheck)
(require 'cl-lib)

;; Load repository modules
(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-chat)
(require 'benedict-chat-render)

;; ============================================================================
;; NEW MAGIT-SECTION BASED PROPERTY TESTS (to be added in Phase 3)
;; ============================================================================

;; TODO: Add property test for magit-section tool toggle invariants
;; (propcheck-deftest benedict-prop-chat-tool-toggle-preserves-invariants ()
;;   "Toggling tool folds preserves magit-section visibility invariants.")

;; TODO: Add property test for magit-section fold state consistency
;; (propcheck-deftest benedict-prop-chat-tool-fold-state-is-consistent ()
;;   "Tool fold state (:tool-folded) stays consistent with magit-section visibility.")

;; ============================================================================
;; CLASSIC OVERLAY FOLDING TESTS (REMOVED - kept for reference)
;; ============================================================================

;; The tests below verified classic overlay folding behavior via the
;; benedict-chat-fold module, which is being removed. They are kept here
;; for reference until Phase 3 is complete.

;; (require 'benedict-chat-fold)
;;
;; (defmacro benedict-chat-fold-prop--with-chat-buffer (&rest body)
;;   "Evaluate BODY inside a benedict chat buffer fixture."
;;   (declare (indent 0) (debug t))
;;   `(let ((buf (generate-new-buffer " *benedict-chat-prop*")))
;;      (unwind-protect
;;          (with-current-buffer buf
;;            (benedict-chat-mode)
;;            (benedict-chat--init-buffer)
;;            ,@body)
;;        (when (buffer-live-p buf)
;;          (kill-buffer buf)))))
;;
;; (defun benedict-test--tool-range (item)
;;   "Return cons of content bounds for ITEM, normalized to ascending order."
;;   (let ((start (plist-get item :content-start))
;;         (end (plist-get item :content-end)))
;;     (when (and start end (marker-position start) (marker-position end))
;;       (let ((s (marker-position start))
;;             (e (marker-position end)))
;;         (cons (min s e) (max s e))))))
;;
;; (defun benedict-test--tool-hidden-p (item)
;;   "Return non-nil when ITEM content is hidden with the tool alias."
;;   (when-let* ((range (benedict-test--tool-range item))
;;               (alias (benedict-fold-core-spec-alias benedict-chat-fold-tool-spec)))
;;     (and (memq alias buffer-invisibility-spec)
;;          (null (text-property-not-all (car range) (cdr range) 'invisible alias)))))
;;
;; (defun benedict-test--tool-visible-p (item)
;;   "Return non-nil when ITEM content is visible (no tool alias)."
;;   (when-let* ((range (benedict-test--tool-range item))
;;               (alias (benedict-fold-core-spec-alias benedict-chat-fold-tool-spec)))
;;     (null (text-property-any (car range) (cdr range) 'invisible alias))))
;;
;; (propcheck-deftest benedict-prop-chat-tool-toggle-syncs-visibility ()
;;   "Toggling tool folds keeps text properties in sync with :tool-folded."
;;   (benedict-chat-fold-prop--with-chat-buffer
;;     (let* ((initial-folded (cl-oddp (propcheck-generate-integer "initial-folded"
;;                                                                 :min 0 :max 1)))
;;            (toggle-count (propcheck-generate-integer "toggle-count" :min 0 :max 6))
;;            (body (propcheck-generate-string "body")))
;;       (let ((item (list :metadata (list :status 'success)
;;                         :tool-call (list :name 'prop-toggle)
;;                         :content body
;;                         :tool-folded initial-folded)))
;;         (benedict-chat--render-tool-item (current-buffer) item)
;;         (dotimes (_ toggle-count)
;;           ;; Toggle from the header to mirror user interactions.
;;           (goto-char (plist-get item :header-start))
;;           (benedict-chat-tool-toggle))
;;         (propcheck-should (benedict-test--tool-range item))
;;         (propcheck-should (if (plist-get item :tool-folded)
;;                               (benedict-test--tool-hidden-p item)
;;                             (benedict-test--tool-visible-p item)))))))
;;
;; (propcheck-deftest benedict-prop-chat-tool-fold-survives-rewrite-and-reorder ()
;;   "Tool folds stay hidden after rewrites and marker reordering."
;;   (benedict-chat-fold-prop--with-chat-buffer
;;     (let* ((body (propcheck-generate-string "body"))
;;            (rewrite (propcheck-generate-string "rewrite"))
;;            (reverse-markers (cl-oddp (propcheck-generate-integer "reverse" :min 0 :max 1))))
;;       (let ((item (list :metadata (list :status 'success)
;;                         :tool-call (list :name 'prop-rewrite)
;;                         :content body
;;                         :tool-folded t)))
;;         (benedict-chat--render-tool-item (current-buffer) item)
;;         (when reverse-markers
;;           (let ((start (plist-get item :content-start))
;;                 (end (plist-get item :content-end)))
;;             (when (and start end)
;;               (let ((s (marker-position start))
;;                     (e (marker-position end)))
;;                 (set-marker start e)
;;                 (set-marker end s)))))
;;         ;; Force folded, rewrite content, then fold again via the adapter.
;;         (benedict-chat-fold-set-tool-folded item t)
;;         (benedict-chat--write-message-item-content item rewrite)
;;         (benedict-chat-fold-set-tool-folded item t)
;;         ;; Open/close through the public toggle to exercise that path too.
;;         (goto-char (plist-get item :header-start))
;;         (benedict-chat-tool-toggle)
;;         (goto-char (plist-get item :header-start))
;;         (benedict-chat-tool-toggle)
;;         (propcheck-should (benedict-test--tool-range item))
;;         (propcheck-should (benedict-test--tool-hidden-p item))))))
;;
;; (propcheck-deftest benedict-prop-chat-tool-fold-recovers-invisibility-entry ()
;;   "Folding should keep tool text hidden even if the invisibility entry is clobbered.
;; Simulates the manual symptom: header shows folded but text remains visible."
;;   (benedict-chat-fold-prop--with-chat-buffer
;;     (let ((item (list :metadata (list :status 'success)
;;                       :tool-call (list :name 'prop-clobber)
;;                       :content "Body"
;;                       :tool-folded t)))
;;       (benedict-chat--render-tool-item (current-buffer) item)
;;       ;; Toggle once through the UI path to mimic real interaction.
;;       (goto-char (plist-get item :header-start))
;;       (benedict-chat-tool-toggle) ;; open
;;       (goto-char (plist-get item :header-start))
;;       (benedict-chat-tool-toggle) ;; close again
;;       ;; Simulate an external clobbering of `buffer-invisibility-spec' while folded.
;;       (setq buffer-invisibility-spec nil)
;;       (benedict-fold-core-repair-invisibility)
;;       ;; The fold state says folded; invisibility should still apply.
;;       (let ((pos (marker-position (plist-get item :content-start))))
;;         (propcheck-should (invisible-p pos))
;;         (propcheck-should (eq (get-text-property pos 'invisible)
;;                               (benedict-fold-core-spec-alias benedict-chat-fold-tool-spec)))))))

(provide 'benedict-chat-fold-propcheck-test)
;;; benedict-chat-fold-propcheck-test.el ends here
