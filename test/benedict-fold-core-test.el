;;; benedict-fold-core-test.el --- Tests for folding core -*- lexical-binding: t; -*-

(require 'ert)
(require 'benedict-fold-core)

(ert-deftest benedict-fold-core-overlay-folds-region ()
  (benedict-fold-core-clear-specs)
  (let ((spec (benedict-fold-core-define-spec :overlay-test
               :alias 'benedict-overlay-fold-test)))
    (with-temp-buffer
      (insert "hello\nworld")
      (let* ((benedict-fold-core-backend benedict-fold-core-overlay-backend)
             (fold (benedict-fold-core-fold-region (point-min) (point-max) spec)))
        (should (benedict-fold-core-folded-p fold))
        (should (memq 'benedict-overlay-fold-test buffer-invisibility-spec))
        (benedict-fold-core-set-folded fold nil)
        (should-not (benedict-fold-core-folded-p fold))
        (benedict-fold-core-set-folded fold t)
        (should (eq (get-char-property (point-min) 'invisible)
                    'benedict-overlay-fold-test))
        (benedict-fold-core-release fold)
        (should-not (overlay-buffer (benedict-fold-core-fold-handle fold)))))))

(ert-deftest benedict-fold-core-text-property-folds-region ()
  (benedict-fold-core-clear-specs)
  (let ((spec (benedict-fold-core-define-spec :text-prop-test
               :alias 'benedict-text-fold-test
               :backend benedict-fold-core-text-property-backend)))
    (with-temp-buffer
      (insert "alpha\nbeta")
      (let* ((benedict-fold-core-backend benedict-fold-core-text-property-backend)
             (fold (benedict-fold-core-fold-region (point-min) (1+ (point-min)) spec)))
        (should (benedict-fold-core-folded-p fold))
        (should (memq 'benedict-text-fold-test buffer-invisibility-spec))
        (should (eq (get-text-property (point-min) 'invisible) 'benedict-text-fold-test))
        (benedict-fold-core-set-folded fold nil)
        (should-not (get-text-property (point-min) 'invisible))
        (benedict-fold-core-resize fold (point-min) (point-max))
        (benedict-fold-core-set-folded fold t)
        (should (eq (get-text-property (1- (point-max)) 'invisible)
                    'benedict-text-fold-test))
        (benedict-fold-core-release fold)
        (should-not (get-text-property (point-min) 'invisible))))))

(ert-deftest benedict-fold-core-overlay-fold-survives-boundary-insert ()
  (benedict-fold-core-clear-specs)
  (let ((spec (benedict-fold-core-define-spec :overlay-boundary
               :alias 'benedict-overlay-boundary
               :front-sticky t
               :rear-sticky t)))
    (with-temp-buffer
      (insert "fold-me")
      (let* ((benedict-fold-core-backend benedict-fold-core-overlay-backend)
             (fold (benedict-fold-core-fold-region (point-min) (point-max) spec)))
        (goto-char (point-min))
        (insert "A")
        (goto-char (point-max))
        (insert "Z")
        (benedict-fold-core-resize fold (point-min) (point-max))
        (benedict-fold-core-set-folded fold t)
        (should (eq (get-char-property (point-min) 'invisible)
                    'benedict-overlay-boundary))
        (should (eq (get-char-property (1- (point-max)) 'invisible)
                    'benedict-overlay-boundary))
        (benedict-fold-core-set-folded fold nil)
        (should-not (get-char-property (point-min) 'invisible))
        (benedict-fold-core-set-folded fold t)
        (should (eq (get-char-property (point-min) 'invisible)
                    'benedict-overlay-boundary))))))

(ert-deftest benedict-fold-core-text-property-sticky-boundaries ()
  (benedict-fold-core-clear-specs)
  (let ((spec (benedict-fold-core-define-spec :text-boundary
               :alias 'benedict-text-boundary
               :front-sticky t
               :rear-sticky t
               :backend benedict-fold-core-text-property-backend)))
    (with-temp-buffer
      (insert "hidden")
      (let* ((benedict-fold-core-backend benedict-fold-core-text-property-backend)
             (fold (benedict-fold-core-fold-region (point-min) (point-max) spec)))
        (goto-char (point-min))
        (insert "L")
        (goto-char (point-max))
        (insert "R")
        (benedict-fold-core-set-folded fold t)
        (should (eq (get-text-property (point-min) 'invisible)
                    'benedict-text-boundary))
        (should (eq (get-text-property (1- (point-max)) 'invisible)
                    'benedict-text-boundary))
        (benedict-fold-core-set-folded fold nil)
        (should-not (get-text-property (point-min) 'invisible))
        (benedict-fold-core-set-folded fold t)
        (should (eq (get-text-property (point-min) 'invisible)
                    'benedict-text-boundary))))))

(ert-deftest benedict-fold-core-save-visibility-restores ()
  (with-temp-buffer
    (setq buffer-invisibility-spec nil)
    (benedict-fold-core-save-visibility
      (setq buffer-invisibility-spec '(foo)))
    (should (equal buffer-invisibility-spec nil))))

;;; benedict-fold-core-test.el ends here
