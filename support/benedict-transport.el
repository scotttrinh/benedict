;;; benedict-transport.el --- Shared Benedict HTTP transport  -*- lexical-binding: t; -*-

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (benedict "0.1.0"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;;; Commentary:
;; Installable entry point for shared logging and HTTP transport support.

;;; Code:
(require 'benedict-log)
(require 'benedict-http)
(provide 'benedict-transport)
;;; benedict-transport.el ends here
