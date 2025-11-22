;;; benedict-logging.el --- Logging infrastructure using lgr -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provides centralized logging setup for Benedict using lgr.
;; All logging goes through lgr appenders which can be configured by users.
;; Default appender is messages at error level; consumers can configure custom
;; appenders and thresholds as needed.

;;; Code:

(require 'lgr)

(defgroup benedict-logging nil
  "Logging configuration for Benedict."
  :group 'benedict
  :prefix "benedict-logging-")

(defcustom benedict-logging-threshold lgr-level-error
  "Default logging threshold for Benedict.
Set to `lgr-level-debug' or `lgr-level-trace' to see detailed logs.
Set to `lgr-level-error' (default) to only see error messages."
  :type '(choice
          (const :tag "Error" lgr-level-error)
          (const :tag "Warning" lgr-level-warn)
          (const :tag "Info" lgr-level-info)
          (const :tag "Debug" lgr-level-debug)
          (const :tag "Trace" lgr-level-trace))
  :group 'benedict-logging)

(defun benedict-logging--setup ()
  "Configure lgr loggers for Benedict.
This sets up the root logger with a messages appender at the configured level."
  (let ((root-logger (lgr-get-logger "benedict")))
    ;; Configure root logger threshold
    (lgr-set-threshold root-logger benedict-logging-threshold)
    
    ;; Reset any existing appenders to start fresh
    (lgr-reset-appenders root-logger)
    
    ;; Add the default messages appender
    (lgr-add-appender root-logger
                      (-> (lgr-appender)
                          (lgr-set-threshold lgr-level-error)))))

;; Set up logging on load
(benedict-logging--setup)

(provide 'benedict-logging)
;;; benedict-logging.el ends here
