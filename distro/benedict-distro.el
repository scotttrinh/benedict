;;; benedict-distro.el --- First-party Benedict distribution  -*- lexical-binding: t; -*-

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (benedict "0.1.0") (benedict-eval "0.1.0") (benedict-recovery "0.1.0") (benedict-retry "0.1.0") (benedict-store "0.1.0") (benedict-ui "0.1.0") (benedict-headless "0.1.0"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;;; Commentary:
;; Convenience dependency bundle.  Requiring it does not install policies.

;;; Code:
(require 'benedict-eval)
(require 'benedict-recovery)
(require 'benedict-retry)
(require 'benedict-store)
(require 'benedict-ui)
(require 'benedict-headless)
(provide 'benedict-distro)
;;; benedict-distro.el ends here
