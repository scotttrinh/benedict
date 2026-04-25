;;; benedict-propcheck-test.el --- Property-based transcript tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Property tests focused on canonical transcript and persistence invariants.

;;; Code:

(require 'ert)
(require 'propcheck)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-message)
(require 'benedict-session)
(require 'benedict-store)

(defun benedict-propcheck-test--tool-status (seed)
  "Return a tool status chosen from SEED."
  (nth (mod seed 3) '(success failure denied)))

(defun benedict-propcheck-test--tool-effects (seed path)
  "Return synthetic effects for SEED and PATH."
  (when (zerop (mod seed 2))
    (list (list :kind (if (zerop (mod seed 4)) 'write 'read)
                :path path))))

(defun benedict-propcheck-test--assistant-message-fixture ()
  "Return a random assistant message fixture."
  (let* ((seed (propcheck-generate-integer "assistant-seed" :min 0 :max 1000))
         (text (propcheck-generate-string "assistant-text"))
         (thinking (propcheck-generate-string "assistant-thinking"))
         (path (propcheck-generate-string "assistant-path"))
         (tool-name (intern (format "tool-%d" seed)))
         (tool-call-count (1+ (mod seed 2)))
         (tool-calls nil))
    (dotimes (index tool-call-count)
      (push (list :id (format "call-%d-%d" seed index)
                  :name tool-name
                  :arguments (format "{\"path\":\"%s\",\"index\":%d}" path index)
                  :status (nth (mod (+ seed index) 3) '(pending running success)))
            tool-calls))
    (let ((calls (nreverse tool-calls)))
      (benedict-message-assistant-response
       :text text
       :thinking (unless (zerop (mod seed 3)) thinking)
       :tool-calls calls
       :metadata (list :provider 'fake
                       :model (format "fake/model-%d" seed)
                       :tool-call-statuses
                       (mapcar (lambda (call)
                                 (cons (plist-get call :id)
                                       (plist-get call :status)))
                               calls))))))

(defun benedict-propcheck-test--session-entry (index)
  "Return a randomized canonical entry for INDEX."
  (let* ((seed (propcheck-generate-integer (format "entry-seed-%d" index) :min 0 :max 1000))
         (text (propcheck-generate-string (format "entry-text-%d" index)))
         (path (propcheck-generate-string (format "entry-path-%d" index)))
         (status (benedict-propcheck-test--tool-status seed)))
    (pcase (mod index 3)
      (0 (benedict-message-user-text text))
      (1 (benedict-message-assistant-response
          :text text
          :thinking (unless (zerop (mod seed 2))
                      (propcheck-generate-string
                       (format "entry-thinking-%d" index)))
          :tool-calls (list (list :id (format "call-%d" index)
                                  :name (intern (format "tool-%d" seed))
                                  :arguments
                                  (format "{\"path\":\"%s\"}" path)
                                  :status 'success))
          :metadata (list :provider 'fake
                          :model (format "fake/model-%d" seed))))
      (_ (benedict-message-tool-result
          (format "call-%d" index)
          (intern (format "tool-%d" seed))
          status
          text
          (list :path path :line-count (1+ (mod seed 200)))
          (unless (zerop (mod seed 2))
            (list :header (format "Header %d" seed)
                  :body (format "Body %d" seed)))
          (benedict-propcheck-test--tool-effects seed path))))))

(propcheck-deftest benedict-prop-message-store-roundtrip ()
  "Assistant canonical messages survive store round-trips."
  (let* ((canonical (benedict-propcheck-test--assistant-message-fixture))
         (roundtrip
          (benedict-store--message-from-sexp
           (benedict-store--message->sexp canonical))))
    (propcheck-should
     (equal (benedict-store--message->sexp canonical)
            (benedict-store--message->sexp roundtrip)))))

(propcheck-deftest benedict-prop-tool-result-store-roundtrip ()
  "Structured tool results survive store serialization intact."
  (let* ((seed (propcheck-generate-integer "tool-result-seed" :min 0 :max 1000))
         (content (propcheck-generate-string "tool-result-content"))
         (path (propcheck-generate-string "tool-result-path"))
         (status (benedict-propcheck-test--tool-status seed))
         (original
          (benedict-message-tool-result
           (format "call-%d" seed)
           (intern (format "tool-%d" seed))
           status
           content
           (list :path path :line-count (1+ (mod seed 200)))
           (unless (zerop (mod seed 2))
             (list :header (format "Header %d" seed)
                   :body (format "Body %d" seed)))
           (benedict-propcheck-test--tool-effects seed path)))
         (restored
          (benedict-store--message-from-sexp
           (benedict-store--message->sexp original))))
    (propcheck-should
     (equal (benedict-store--message->sexp original)
            (benedict-store--message->sexp restored)))))

(propcheck-deftest benedict-prop-session-persistence-roundtrip ()
  "Saving and loading sessions preserves canonical transcript behavior."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let* ((entry-count (propcheck-generate-integer "entry-count" :min 1 :max 5))
           (seed (propcheck-generate-integer "session-seed" :min 0 :max 1000))
           (root (make-temp-file "benedict-prop-store-" t))
           (session (benedict-session-create
                     :title (format "prop-session-%d" seed)
                     :root default-directory
                     :provider 'fake
                     :model (format "fake/model-%d" seed)
                     :meta (list :instruction-sources '("AGENTS.md")
                                 :branch-parent-id (format "parent-%d" seed))))
           (loaded nil))
      (unwind-protect
          (progn
            (setf (benedict-session-loop-config session)
                  (list :max-turns (1+ (mod seed 5))
                        :max-tool-calls (1+ (mod seed 3))))
            (setf (benedict-harness-audit-log (benedict-session-harness session))
                  (list (list :phase 'authorization
                              :tool-id 'read-file
                              :policy 'allow
                              :decision 'allow)))
            (dotimes (index entry-count)
              (benedict-session-add-entry
               session
               (benedict-propcheck-test--session-entry index)))
            (benedict-session-save session :root root)
            (setq loaded (benedict-session-load
                          (benedict-store-session-path (benedict-session-id session) root)))
            (propcheck-should
             (equal (mapcar #'benedict-store--message->sexp
                            (benedict-session-entries-chronological session))
                    (mapcar #'benedict-store--message->sexp
                            (benedict-session-entries-chronological loaded))))
            (propcheck-should
             (equal (benedict-session-loop-config session)
                    (benedict-session-loop-config loaded)))
            (propcheck-should
             (equal (benedict-harness-audit-log (benedict-session-harness session))
                    (benedict-harness-audit-log (benedict-session-harness loaded)))))
        (delete-directory root t)))))

(provide 'benedict-propcheck-test)
;;; benedict-propcheck-test.el ends here
