;;; benedict-logging.el --- Logging infrastructure using lgr -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Provides centralized logging setup for Benedict using lgr.
;; All logging goes through lgr appenders which can be configured by users.
;; By default we defer to lgr's own configuration; set
;; `benedict-logging-configure-function' to install appenders or adjust
;; `benedict-logging-threshold' for verbosity.

;;; Code:

(require 'lgr)

(defgroup benedict-logging nil
  "Logging configuration for Benedict."
  :group 'benedict
  :prefix "benedict-logging-")

(defcustom benedict-logging-threshold nil
  "Optional logging threshold for Benedict.
When nil, `lgr' keeps its default threshold.  Set to
`lgr-level-debug' or `lgr-level-trace' to see detailed logs, or
`lgr-level-error' to only see error messages."
  :type '(choice
          (const :tag "Use lgr default" nil)
          (const :tag "Error" lgr-level-error)
          (const :tag "Warning" lgr-level-warn)
          (const :tag "Info" lgr-level-info)
          (const :tag "Debug" lgr-level-debug)
          (const :tag "Trace" lgr-level-trace))
  :group 'benedict-logging)

(defcustom benedict-logging-configure-function nil
  "Function used to configure Benedict's lgr loggers.

When non-nil, the function is called with the root Benedict
logger (\"benedict\") and should install appenders, layouts, and
any additional thresholds.  Leave nil to defer entirely to lgr's
own defaults.  Set this to `benedict-logging-configure-default'
to get a simple *Messages* appender."
  :type '(choice
          (const :tag "Use lgr defaults" nil)
          (function :tag "Custom configure function"))
  :group 'benedict-logging)

(defun benedict-logging-configure-default (logger)
  "Install a basic messages appender on LOGGER.
Resets existing appenders and applies `benedict-logging-threshold'
when provided, otherwise falling back to `lgr-level-info'."
  (lgr-reset-appenders logger)
  (let ((appender (lgr-appender)))
    (lgr-set-threshold appender (or benedict-logging-threshold lgr-level-info))
    (lgr-add-appender logger appender)))

(defun benedict-logging-setup ()
  "Configure lgr loggers for Benedict.
Applies `benedict-logging-threshold' when set and delegates
appender installation to `benedict-logging-configure-function'
when provided.  Safe to call multiple times."
  (let ((root-logger (lgr-get-logger "benedict")))
    (when benedict-logging-threshold
      (lgr-set-threshold root-logger benedict-logging-threshold))
    (when benedict-logging-configure-function
      (funcall benedict-logging-configure-function root-logger))))

;; Set up logging on load
(benedict-logging-setup)

(provide 'benedict-logging)
;;; benedict-logging.el ends here
