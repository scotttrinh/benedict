;;; benedict-api.el --- Shared Benedict API adapter support  -*- lexical-binding: t; -*-

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (benedict "0.1.0") (benedict-transport "0.1.0") (benedict-auth "0.1.0"))
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;;; Commentary:
;; Protocol-neutral lowering and the shared auth/transport/parse path.

;;; Code:
(require 'benedict-api-transform)
(require 'benedict-api-stream)
(provide 'benedict-api)
;;; benedict-api.el ends here
