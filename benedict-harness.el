;;; benedict-harness.el --- Tool safety harness for Benedict -*- lexical-binding: t; -*-

;;; Commentary:
;; Enforces tool-call scope and budget limits, resolves permission predicates,
;; and records structured audit entries for runtime/UI consumers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function benedict-session--emit "benedict-session" (session event-type &rest payload))
(declare-function benedict-session-p "benedict-session" (object))
(declare-function benedict-session-root "benedict-session" (session))
(declare-function benedict-session-loop-config "benedict-session" (session))
(declare-function benedict-session-loop-start-time "benedict-session" (session))
(declare-function benedict-session-loop-turn-count "benedict-session" (session))
(declare-function benedict-session-accumulated-usage "benedict-session" (session))

(cl-defstruct (benedict-harness (:constructor benedict-harness-create))
  "Safety harness that governs tool execution."
  scope budgets permission-predicate audit-log)

(defun benedict-harness--normalize-keyword (key)
  "Normalize KEY to a keyword symbol."
  (cond
   ((keywordp key) key)
   ((symbolp key) (intern (concat ":" (symbol-name key))))
   ((stringp key) (intern (concat ":" key)))
   (t (error "Tool args key must be symbol or string: %S" key))))

(defun benedict-harness-normalize-args (args)
  "Return ARGS normalized into a plist with keyword keys."
  (cond
   ((null args) nil)
   ((and (listp args) (consp (car args)))
    (let (result)
      (dolist (pair args)
        (setq result (plist-put result
                                (benedict-harness--normalize-keyword (car pair))
                                (cdr pair))))
      result))
   ((listp args)
    (unless (cl-evenp (length args))
      (error "Tool args plist must have even length: %S" args))
    (let (result)
      (cl-loop for (key value) on args by #'cddr
               do (setq result (plist-put result
                                          (benedict-harness--normalize-keyword key)
                                          value)))
      result))
   (t (error "Tool args must be a plist or alist: %S" args))))

(defun benedict-harness-resolve-permission-predicate ()
  "Return the effective tool permission predicate for the current buffer."
  (if (local-variable-p 'benedict-tool-permission-predicate (current-buffer))
      benedict-tool-permission-predicate
    (default-value 'benedict-tool-permission-predicate)))

(defun benedict-harness--record-audit (harness session entry)
  "Append ENTRY to HARNESS audit log and emit an audit event for SESSION."
  (let ((audit-entry (plist-put (copy-tree entry) :timestamp (current-time))))
    (setf (benedict-harness-audit-log harness)
          (append (benedict-harness-audit-log harness) (list audit-entry)))
    (when (and session
               (fboundp 'benedict-session-p)
               (benedict-session-p session)
               (fboundp 'benedict-session--emit))
      (benedict-session--emit session 'tool-audit :audit audit-entry))
    audit-entry))

(defun benedict-harness-record-effect (harness effect-plist session)
  "Record EFFECT-PLIST in HARNESS for SESSION and return the audit entry."
  (benedict-harness--record-audit harness session
                                  (append (list :phase 'effect) effect-plist)))

(defun benedict-harness-request-scope-expansion (harness request session)
  "Record REQUEST as a scope expansion request for HARNESS and SESSION."
  (benedict-harness--record-audit harness session
                                  (append (list :phase 'scope-expansion
                                                :policy 'deny
                                                :decision 'scope-expansion-required)
                                          request)))

(defun benedict-harness--tool-count (harness)
  "Return the number of recorded tool effects in HARNESS."
  (cl-count-if (lambda (entry)
                 (eq (plist-get entry :phase) 'effect))
               (benedict-harness-audit-log harness)))

(defun benedict-harness--usage-total (session)
  "Return the accumulated token total for SESSION."
  (or (plist-get (and session (benedict-session-accumulated-usage session)) :total) 0))

(defun benedict-harness--budget-decision (harness tool-id args session)
  "Return a denial plist when HARNESS budgets reject TOOL-ID with ARGS for SESSION."
  (let* ((budgets (benedict-harness-budgets harness))
         (max-tool-calls (plist-get budgets :max-tool-calls))
         (max-turns (plist-get budgets :max-turns))
         (max-time (plist-get budgets :max-time))
         (max-tokens (plist-get budgets :max-tokens))
         (tool-count (benedict-harness--tool-count harness))
         (turn-count (and session (benedict-session-loop-turn-count session)))
         (loop-start (and session (benedict-session-loop-start-time session)))
         (elapsed (and loop-start (float-time (time-subtract (current-time) loop-start))))
         (total-tokens (and session (benedict-harness--usage-total session))))
    (cond
     ((and max-tool-calls (>= tool-count max-tool-calls))
      (list :tool-id tool-id
            :args args
            :policy 'deny
            :decision 'budget-tool-limit
            :code 'budget-exceeded
            :message (format "Tool call budget exceeded for %S" tool-id)
            :budget :max-tool-calls
            :limit max-tool-calls
            :actual tool-count))
     ((and max-turns turn-count (>= turn-count max-turns))
      (list :tool-id tool-id
            :args args
            :policy 'deny
            :decision 'budget-turn-limit
            :code 'budget-exceeded
            :message (format "Turn budget exceeded for %S" tool-id)
            :budget :max-turns
            :limit max-turns
            :actual turn-count))
     ((and max-time elapsed (> elapsed max-time))
      (list :tool-id tool-id
            :args args
            :policy 'deny
            :decision 'budget-time-limit
            :code 'budget-exceeded
            :message (format "Time budget exceeded for %S" tool-id)
            :budget :max-time
            :limit max-time
            :actual elapsed))
     ((and max-tokens total-tokens (> total-tokens max-tokens))
      (list :tool-id tool-id
            :args args
            :policy 'deny
            :decision 'budget-token-limit
            :code 'budget-exceeded
            :message (format "Token budget exceeded for %S" tool-id)
            :budget :max-tokens
            :limit max-tokens
            :actual total-tokens)))))

(defun benedict-harness--extract-paths (args)
  "Extract filesystem paths from normalized ARGS."
  (let (paths)
    (when-let ((path (plist-get args :path)))
      (push path paths))
    (when-let ((target (plist-get args :target)))
      (when (and (plist-get target :path)
                 (equal (plist-get target :kind) "file"))
        (push (plist-get target :path) paths)))
    (nreverse paths)))

(defun benedict-harness--extract-buffers (args)
  "Extract buffer names from normalized ARGS."
  (let (buffers)
    (when-let ((target (plist-get args :target)))
      (when (and (plist-get target :buffer_name)
                 (equal (plist-get target :kind) "buffer"))
        (push (plist-get target :buffer_name) buffers)))
    (nreverse buffers)))

(defun benedict-harness--path-in-scope-p (path allowed-roots session)
  "Return non-nil when PATH falls under ALLOWED-ROOTS for SESSION."
  (let ((absolute (expand-file-name path (or (and session (benedict-session-root session))
                                             default-directory))))
    (cl-some (lambda (root)
               (file-in-directory-p absolute (expand-file-name root)))
             allowed-roots)))

(defun benedict-harness--scope-decision (harness tool-id args session)
  "Return a denial plist when HARNESS scope rejects TOOL-ID with ARGS for SESSION."
  (let* ((scope (benedict-harness-scope harness))
         (allowed-paths (plist-get scope :paths))
         (allowed-buffers (plist-get scope :buffers))
         (network-policy (plist-get scope :network))
         (paths (benedict-harness--extract-paths args))
         (buffers (benedict-harness--extract-buffers args)))
    (cond
     ((and paths allowed-paths
           (not (cl-every (lambda (path)
                            (benedict-harness--path-in-scope-p path allowed-paths session))
                          paths)))
     (list :tool-id tool-id
           :args args
           :policy 'deny
           :decision 'scope-path-denied
           :code 'scope-expansion-required
           :message (format "Tool %S requires path access outside harness scope" tool-id)
            :scope-request (list :paths paths)))
     ((and buffers allowed-buffers
           (not (cl-every (lambda (buffer-name)
                            (member buffer-name allowed-buffers))
                          buffers)))
      (list :tool-id tool-id
            :args args
            :policy 'deny
            :decision 'scope-buffer-denied
            :code 'scope-expansion-required
            :message (format "Tool %S requires buffer access outside harness scope" tool-id)
            :scope-request (list :buffers buffers)))
     ((and (plist-get args :network) (eq network-policy 'deny))
      (list :tool-id tool-id
            :args args
            :policy 'deny
            :decision 'scope-network-denied
            :code 'scope-expansion-required
            :message (format "Tool %S requires network access outside harness scope" tool-id)
            :scope-request (list :network t))))))

(defun benedict-harness-authorize-tool-call (harness tool-spec args session)
  "Authorize TOOL-SPEC with ARGS under HARNESS for SESSION.
Return an authorization plist with normalized args and an allow/deny policy."
  (let* ((tool-id (plist-get tool-spec :id))
         (normalized-args (benedict-harness-normalize-args args))
         (predicate (or (benedict-harness-permission-predicate harness)
                        (benedict-harness-resolve-permission-predicate)))
         (budget-decision (benedict-harness--budget-decision harness tool-id normalized-args session))
         (scope-decision (benedict-harness--scope-decision harness tool-id normalized-args session)))
    (cond
     (budget-decision
      (benedict-harness--record-audit
       harness session
       (append (list :phase 'authorization) budget-decision)))
     (scope-decision
      (let ((request (plist-get scope-decision :scope-request)))
        (benedict-harness-request-scope-expansion
         harness
         (append (list :tool-id tool-id
                       :args normalized-args)
                 request)
         session)
        (benedict-harness--record-audit
         harness session
         (append (list :phase 'authorization) scope-decision))))
     ((not predicate)
      (benedict-harness--record-audit
       harness session
       (list :phase 'authorization
             :tool-id tool-id
             :args normalized-args
             :policy 'fallback
             :decision 'legacy-approval)))
     (t
      (condition-case err
          (let ((result (funcall predicate tool-id normalized-args)))
            (benedict-harness--record-audit
             harness session
             (cond
              ((eq result t)
               (list :phase 'authorization
                     :tool-id tool-id
                     :args normalized-args
                     :policy 'allow
                     :decision 'predicate-allow))
              ((eq result nil)
               (list :phase 'authorization
                     :tool-id tool-id
                     :args normalized-args
                     :policy 'deny
                     :decision 'predicate-deny
                     :code 'permission-denied
                     :message (format "Tool %S denied by permission predicate" tool-id)))
              (t
               (list :phase 'authorization
                     :tool-id tool-id
                     :args normalized-args
                     :policy 'fallback
                     :decision 'fallback-on-invalid-result)))))
        (error
         (benedict-harness--record-audit
          harness session
          (list :phase 'authorization
                :tool-id tool-id
                :args normalized-args
                :policy 'fallback
                :decision 'fallback-on-error
                :error-message (error-message-string err)))))))))

(provide 'benedict-harness)
;;; benedict-harness.el ends here
