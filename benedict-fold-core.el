;;; benedict-fold-core.el --- Folding core primitives  -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Mode-agnostic folding primitives that abstract the underlying
;; representation (overlays vs text properties). Callers register
;; fold specs and then fold/unfold regions through the selected backend.

;;; Code:

(require 'cl-lib)

(cl-defstruct benedict-fold-core-spec
  "Definition for a foldable region.
NAME is the registry key; ALIAS is the invisibility token used by Emacs."
  name alias priority ellipsis isearch-open isearch-ignore
  front-sticky rear-sticky fragile backend)

(cl-defstruct benedict-fold-core-backend
  "Backend functions for a folding representation."
  name make-fold set-folded folded-p delete-fold move-fold
  next-change prev-change capture-state restore-state)

(cl-defstruct benedict-fold-core-fold
  "Instance of a folded region managed by a backend."
  spec backend handle start end)

(defvar benedict-fold-core--specs (make-hash-table :test #'equal)
  "Registry of fold specs keyed by NAME.")

(defvar-local benedict-fold-core-backend nil
  "Buffer-local backend used for folding operations.")

(defconst benedict-fold-core--overlay-backend-name 'overlay)
(defconst benedict-fold-core--text-property-backend-name 'text-property)

(defun benedict-fold-core-define-spec (name &rest plist)
  "Register a fold spec keyed by NAME using properties from PLIST.
When :alias is omitted, NAME is used as the invisibility alias."
  (let* ((alias (or (plist-get plist :alias) name))
         (spec (apply #'make-benedict-fold-core-spec
                      :name name
                      :alias alias
                      plist)))
    (puthash name spec benedict-fold-core--specs)
    spec))

(defun benedict-fold-core-get-spec (name)
  "Return the fold spec registered under NAME."
  (gethash name benedict-fold-core--specs))

(defun benedict-fold-core-clear-specs ()
  "Clear the fold spec registry.
Intended for tests."
  (clrhash benedict-fold-core--specs))

(defun benedict-fold-core--normalize-invisibility-spec ()
  "Ensure `buffer-invisibility-spec' is always a list."
  (unless (listp buffer-invisibility-spec)
    (setq buffer-invisibility-spec
          (cond
           ((null buffer-invisibility-spec) nil)
           (t (list buffer-invisibility-spec))))))

(defun benedict-fold-core--alias-entry (spec)
  "Return the buffer invisibility entry for SPEC."
  (let ((alias (benedict-fold-core-spec-alias spec))
        (ellipsis (benedict-fold-core-spec-ellipsis spec)))
    (if ellipsis
        (cons alias ellipsis)
      alias)))

(defun benedict-fold-core--ensure-alias (spec)
  "Add SPEC's alias to `buffer-invisibility-spec' if missing."
  (benedict-fold-core--normalize-invisibility-spec)
  (let* ((alias (benedict-fold-core-spec-alias spec))
         (entry (benedict-fold-core--alias-entry spec))
         (existing (assoc alias buffer-invisibility-spec)))
    (when existing
      (setq buffer-invisibility-spec
            (remove existing buffer-invisibility-spec)))
    (unless (member entry buffer-invisibility-spec)
      (add-to-invisibility-spec entry))))

(defun benedict-fold-core-ensure-invisibility-entry (spec)
  "Ensure SPEC's alias entry exists in `buffer-invisibility-spec'."
  (benedict-fold-core--ensure-alias spec))

;; -------------------------------------------------------------------
;; Overlay backend

(defun benedict-fold-core--overlay-make (start end spec)
  (let* ((fold-start (copy-marker start))
         (fold-end (copy-marker end))
         (overlay (make-overlay fold-start fold-end nil t t)))
    (set-marker-insertion-type fold-start (not (benedict-fold-core-spec-front-sticky spec)))
    (set-marker-insertion-type fold-end (benedict-fold-core-spec-rear-sticky spec))
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'front-advance (benedict-fold-core-spec-front-sticky spec))
    (overlay-put overlay 'rear-advance (benedict-fold-core-spec-rear-sticky spec))
    (overlay-put overlay 'benedict-fold-core t)
    (overlay-put overlay 'benedict-fold-core-spec spec)
    overlay))

(defun benedict-fold-core--overlay-set-folded (overlay folded spec)
  (benedict-fold-core--ensure-alias spec)
  (overlay-put overlay 'invisible (and folded (benedict-fold-core-spec-alias spec)))
  overlay)

(defun benedict-fold-core--overlay-folded-p (overlay)
  (and (overlayp overlay)
       (overlay-get overlay 'invisible)))

(defun benedict-fold-core--overlay-delete (overlay)
  (when (overlayp overlay)
    (delete-overlay overlay)))

(defun benedict-fold-core--overlay-move (overlay start end)
  (when (overlayp overlay)
    (move-overlay overlay start end)
    overlay))

(defun benedict-fold-core--overlay-next-change (pos _spec)
  (next-overlay-change pos))

(defun benedict-fold-core--overlay-prev-change (pos _spec)
  (previous-overlay-change pos))

(defconst benedict-fold-core-overlay-backend
  (make-benedict-fold-core-backend
   :name benedict-fold-core--overlay-backend-name
   :make-fold #'benedict-fold-core--overlay-make
   :set-folded #'benedict-fold-core--overlay-set-folded
   :folded-p #'benedict-fold-core--overlay-folded-p
   :delete-fold #'benedict-fold-core--overlay-delete
   :move-fold #'benedict-fold-core--overlay-move
   :next-change #'benedict-fold-core--overlay-next-change
   :prev-change #'benedict-fold-core--overlay-prev-change))

;; -------------------------------------------------------------------
;; Text property backend

(cl-defstruct benedict-fold-core--text-fold start end)

(defun benedict-fold-core--text-prop-make (start end spec)
  (let ((start-marker (copy-marker start))
        (end-marker (copy-marker end)))
    (set-marker-insertion-type start-marker (not (benedict-fold-core-spec-front-sticky spec)))
    (set-marker-insertion-type end-marker (benedict-fold-core-spec-rear-sticky spec))
    (make-benedict-fold-core--text-fold
     :start start-marker
     :end end-marker)))

(defun benedict-fold-core--text-prop--range (fold)
  (let ((start (benedict-fold-core--text-fold-start fold))
        (end (benedict-fold-core--text-fold-end fold)))
    (when (and start end (marker-position start) (marker-position end))
      (cons (marker-position start) (marker-position end)))))

(defun benedict-fold-core--text-prop-set-folded (fold folded spec)
  (when-let* ((range (benedict-fold-core--text-prop--range fold))
              (start (car range))
              (end (cdr range)))
    (benedict-fold-core--ensure-alias spec)
    (if folded
        (add-text-properties start end
                             `(invisible ,(benedict-fold-core-spec-alias spec)
                               front-sticky ,(benedict-fold-core-spec-front-sticky spec)
                               rear-nonsticky ,(not (benedict-fold-core-spec-rear-sticky spec))))
      (remove-text-properties start end
                              `(invisible ,(benedict-fold-core-spec-alias spec)
                                front-sticky ,(benedict-fold-core-spec-front-sticky spec)
                                rear-nonsticky ,(not (benedict-fold-core-spec-rear-sticky spec))))))
  fold)

(defun benedict-fold-core--text-prop-folded-p (fold)
  (when-let* ((range (benedict-fold-core--text-prop--range fold))
              (start (car range)))
    (get-text-property start 'invisible)))

(defun benedict-fold-core--text-prop-delete (fold)
  (when-let* ((range (benedict-fold-core--text-prop--range fold))
              (start (car range))
              (end (cdr range)))
    (remove-text-properties start end '(invisible nil front-sticky nil rear-nonsticky nil))))

(defun benedict-fold-core--text-prop-move (fold start end)
  (set-marker (benedict-fold-core--text-fold-start fold) start)
  (set-marker (benedict-fold-core--text-fold-end fold) end)
  fold)

(defun benedict-fold-core--text-prop-next-change (pos _spec)
  (next-single-property-change pos 'invisible nil (point-max)))

(defun benedict-fold-core--text-prop-prev-change (pos _spec)
  (previous-single-property-change pos 'invisible nil (point-min)))

(defconst benedict-fold-core-text-property-backend
  (make-benedict-fold-core-backend
   :name benedict-fold-core--text-property-backend-name
   :make-fold #'benedict-fold-core--text-prop-make
   :set-folded #'benedict-fold-core--text-prop-set-folded
   :folded-p #'benedict-fold-core--text-prop-folded-p
   :delete-fold #'benedict-fold-core--text-prop-delete
   :move-fold #'benedict-fold-core--text-prop-move
   :next-change #'benedict-fold-core--text-prop-next-change
   :prev-change #'benedict-fold-core--text-prop-prev-change))

;; -------------------------------------------------------------------
;; Public API

(defun benedict-fold-core-set-backend (backend)
  "Set BACKEND for the current buffer."
  (setq-local benedict-fold-core-backend backend))

(defun benedict-fold-core--resolve-backend (spec)
  "Return the backend to use for SPEC."
  (or (benedict-fold-core-spec-backend spec)
      benedict-fold-core-backend
      benedict-fold-core-overlay-backend))

(defun benedict-fold-core-fold-region (start end spec &optional folded)
  "Create a fold from START to END using SPEC.
When FOLDED is non-nil, hide the region immediately (defaults to t)."
  (let* ((backend (benedict-fold-core--resolve-backend spec))
         (handle (funcall (benedict-fold-core-backend-make-fold backend)
                          start end spec))
         (fold (make-benedict-fold-core-fold
                :spec spec
                :backend backend
                :handle handle
                :start (copy-marker start)
                :end (copy-marker end))))
    (benedict-fold-core-set-folded fold (if (null folded) t folded))
    fold))

(defun benedict-fold-core-set-folded (fold folded)
  "Set FOLD visibility state to FOLDED."
  (when (and fold (benedict-fold-core-fold-p fold))
    (let* ((backend (benedict-fold-core-fold-backend fold))
           (spec (benedict-fold-core-fold-spec fold)))
      (funcall (benedict-fold-core-backend-set-folded backend)
               (benedict-fold-core-fold-handle fold)
               folded
               spec)))
  fold)

(defun benedict-fold-core-folded-p (fold)
  "Return non-nil when FOLD is currently hidden."
  (when (and fold (benedict-fold-core-fold-p fold))
    (let* ((backend (benedict-fold-core-fold-backend fold))
           (handle (benedict-fold-core-fold-handle fold)))
      (funcall (benedict-fold-core-backend-folded-p backend) handle))))

(defun benedict-fold-core-release (fold)
  "Remove FOLD and its backing representation."
  (when (and fold (benedict-fold-core-fold-p fold))
    (let* ((backend (benedict-fold-core-fold-backend fold))
           (handle (benedict-fold-core-fold-handle fold)))
      (funcall (benedict-fold-core-backend-delete-fold backend) handle))))

(defun benedict-fold-core-resize (fold start end)
  "Move FOLD boundaries to START and END."
  (when (and fold (benedict-fold-core-fold-p fold))
    (set-marker (benedict-fold-core-fold-start fold) start)
    (set-marker (benedict-fold-core-fold-end fold) end)
    (let* ((backend (benedict-fold-core-fold-backend fold))
           (handle (benedict-fold-core-fold-handle fold)))
      (funcall (benedict-fold-core-backend-move-fold backend) handle start end))))

(defun benedict-fold-core-next-visibility-change (pos spec)
  "Return the next change in visibility after POS for SPEC."
  (let ((backend (benedict-fold-core--resolve-backend spec)))
    (funcall (benedict-fold-core-backend-next-change backend) pos spec)))

(defun benedict-fold-core-previous-visibility-change (pos spec)
  "Return the previous change in visibility before POS for SPEC."
  (let ((backend (benedict-fold-core--resolve-backend spec)))
    (funcall (benedict-fold-core-backend-prev-change backend) pos spec)))

(defmacro benedict-fold-core-save-visibility (&rest body)
  "Evaluate BODY and restore buffer invisibility afterwards."
  (declare (indent 0))
  `(let ((saved buffer-invisibility-spec))
     (unwind-protect
         (progn ,@body)
       (setq buffer-invisibility-spec saved))))

(provide 'benedict-fold-core)
;;; benedict-fold-core.el ends here
