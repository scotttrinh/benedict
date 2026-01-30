;;; benedict-credentials.el --- Generic credentials store for Benedict -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Shared, filesystem-backed credentials store that centralizes provider
;; credential resolution and supports XDG-based auth layouts.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'xdg)
(require 'subr-x)

(defgroup benedict-credentials nil
  "Generic credentials store for Benedict."
  :group 'benedict
  :prefix "benedict-credentials-")

(defcustom benedict-credentials-file-name "auth.json"
  "Filename for the Benedict credentials store."
  :type 'string
  :group 'benedict-credentials)

(defcustom benedict-credentials-config-app-name "benedict"
  "Application name used for XDG config directory resolution."
  :type 'string
  :group 'benedict-credentials)

(defun benedict-credentials--config-dir ()
  "Return the directory for Benedict credentials."
  (let* ((base (xdg-config-home))
         (dir (expand-file-name benedict-credentials-config-app-name base)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun benedict-credentials--file ()
  "Return the full path to the credentials file."
  (expand-file-name benedict-credentials-file-name
                    (benedict-credentials--config-dir)))

(defun benedict-credentials--read-all ()
  "Return the full credentials map as an alist."
  (let ((file (benedict-credentials--file)))
    (if (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (condition-case nil
              (let ((json-object-type 'alist)
                    (json-key-type 'symbol)
                    (json-array-type 'list))
                (let ((data (json-read)))
                  (if (and (listp data)
                           (or (null data)
                               (consp (car data))))
                      data
                    nil)))
            (json-error nil)
            (error nil)))
      nil)))

(defun benedict-credentials--write-all (data)
  "Write DATA (an alist) to the credentials file with 600 perms."
  (let* ((file (benedict-credentials--file))
         (json-encoding-pretty-print t))
    (with-temp-file file
      (insert (json-encode data)))
    (set-file-modes file #o600)))

(defun benedict-credentials--alist-to-plist (alist)
  "Convert ALIST to a plist recursively."
  (let (plist)
    (dolist (pair alist)
      (let ((k (car pair))
            (v (cdr pair)))
        (push (intern (format ":%s" k)) plist)
        (push (if (and (listp v) (not (keywordp (car v))) (consp (car v)))
                  (benedict-credentials--alist-to-plist v)
                v)
              plist)))
    (nreverse plist)))

(defun benedict-credentials-get (provider-id auth-type)
  "Read the entry for PROVIDER-ID and specific AUTH-TYPE.
Return the underlying plist for that auth-type, or nil if not found."
  (let* ((all (benedict-credentials--read-all))
         (provider-entry (alist-get provider-id all))
         (auth-entry (when (listp provider-entry)
                       (alist-get auth-type provider-entry))))
    (if (and auth-entry (listp auth-entry) (not (keywordp (car auth-entry))))
        (benedict-credentials--alist-to-plist auth-entry)
      auth-entry)))

(defun benedict-credentials-set (provider-id auth-type entry)
  "Set or update the given AUTH-TYPE ENTRY for PROVIDER-ID.
ENTRY should be a plist.  Persist changes to disk."
  (let* ((all (benedict-credentials--read-all))
         (provider-entry (alist-get provider-id all))
         (updated-provider-entry (if (and (listp provider-entry)
                                          (or (null provider-entry)
                                              (consp (car provider-entry))))
                                     (cl-copy-list provider-entry)
                                   nil)))
    (setf (alist-get auth-type updated-provider-entry) entry)
    (setf (alist-get provider-id all) updated-provider-entry)
    (benedict-credentials--write-all all)))

(defun benedict-credentials-remove (provider-id &optional auth-type)
  "Delete AUTH-TYPE entry for PROVIDER-ID, or entire provider if AUTH-TYPE is nil.
Persist changes to disk."
  (let* ((all (benedict-credentials--read-all)))
    (when (listp all)
      (if (null auth-type)
          (setq all (assoc-delete-all provider-id all))
        (let* ((provider-entry (alist-get provider-id all)))
          (when (and (listp provider-entry)
                     (or (null provider-entry)
                         (consp (car provider-entry))))
            (setq provider-entry (assoc-delete-all auth-type provider-entry))
            (if (null provider-entry)
                (setq all (assoc-delete-all provider-id all))
              (setf (alist-get provider-id all) provider-entry)))))
      (benedict-credentials--write-all all))))

(defcustom benedict-credentials-sources '(env file auth-source)
  "Ordered list of credential sources to consult.

By default this is a breaking change from the previous
auth-source-first behavior: environment variables now take
precedence over filesystem and auth-source entries, so setting an
env var like OPENROUTER_API_KEY temporarily overrides other stored
credentials."
  :type '(repeat (choice (const env) (const file) (const auth-source)))
  :group 'benedict-credentials)

(cl-defun benedict-credentials-resolve-api-key (provider-id &key env-var auth-source-params)
  "Resolve an API key for PROVIDER-ID.
Consults `benedict-credentials-sources` in order.
ENV-VAR is the environment variable name to check.
AUTH-SOURCE-PARAMS is a plist of parameters for `auth-source-search'."
  (let ((result nil))
    (dolist (source benedict-credentials-sources)
      (unless result
        (pcase source
          ('env
           (when env-var
             (let ((token (getenv env-var)))
               (when (and (stringp token) (not (string-empty-p token)))
                 (setq result (list :token token :source 'env))))))
          ('file
           (let ((entry (benedict-credentials-get provider-id 'api)))
             (when (and entry (plist-get entry :token))
               (setq result (list :token (plist-get entry :token)
                                  :source 'file
                                  :meta (plist-get entry :meta))))))
          ('auth-source
           (when (and auth-source-params (require 'auth-source nil t))
             (let* ((search-args (append auth-source-params '(:max 1 :require (:secret))))
                    (entry (car (apply #'auth-source-search search-args))))
               (when entry
                 (let* ((secret (plist-get entry :secret))
                        (token (cond
                                ((functionp secret) (funcall secret))
                                ((stringp secret) secret)
                                (t nil))))
                   (when (and (stringp token) (not (string-empty-p token)))
                     (setq result (list :token token :source 'auth-source :entry entry)))))))))))
    result))

(cl-defun benedict-credentials-resolve-oauth (provider-id &key env-var auth-source-params)
  "Resolve OAuth credentials for PROVIDER-ID.
Consults `benedict-credentials-sources` in order.
ENV-VAR is the environment variable name to check for a refresh token.
AUTH-SOURCE-PARAMS is a plist of parameters for `auth-source-search'."
  (let ((result nil))
    (dolist (source benedict-credentials-sources)
      (unless result
        (pcase source
          ('env
           (when env-var
             (let ((token (getenv env-var)))
               (when (and (stringp token) (not (string-empty-p token)))
                 (setq result (list :refresh token :source 'env))))))
          ('file
           (let ((entry (benedict-credentials-get provider-id 'oauth)))
             (when entry
               (setq result (append entry (list :source 'file))))))
          ('auth-source
           (when (and auth-source-params (require 'auth-source nil t))
             (let* ((search-args (append auth-source-params '(:max 1 :require (:secret))))
                    (entry (car (apply #'auth-source-search search-args))))
               (when entry
                 (let* ((secret (plist-get entry :secret))
                        (token (cond
                                ((functionp secret) (funcall secret))
                                ((stringp secret) secret)
                                (t nil))))
                   (when (and (stringp token) (not (string-empty-p token)))
                     (setq result (list :refresh token :source 'auth-source :entry entry)))))))))))
    result))

(defun benedict-credentials-error-message (provider-id &optional env-var auth-source-host)
  "Return a standard error message for missing credentials for PROVIDER-ID.
ENV-VAR and AUTH-SOURCE-HOST are used to provide specific guidance."
  (let ((file (benedict-credentials--file)))
    (concat (format "Credentials for %s missing. " provider-id)
            (when env-var (format "Set the %s environment variable, " env-var))
            (when auth-source-host (format "configure auth-source for host %s, " auth-source-host))
            (format "or add an entry to %s." file))))
(provide 'benedict-credentials)
;;; benedict-credentials.el ends here
