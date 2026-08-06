(source "gnu")
(source "nongnu")
(source "melpa")

(package "benedict" "0.1.0" "An agent runtime whose medium is Emacs Lisp")
(package-file "core/benedict.el")
(website-url "https://github.com/scotttrinh/benedict")
(keywords "tools" "convenience" "ai")

;; Layer directories per SPEC-001 12.1.  Prefixes stay globally unique, so the
;; layout is organizational rather than semantic.  Tests are not part of the
;; package and are deliberately absent here.
(files "core/*.el" "support/*.el" "api/*.el" "providers/*.el" "ext/*.el" "ui/*.el")

(load-paths "./core" "./support" "./api" "./providers" "./ext" "./ui")

(depends-on "emacs" "29.1")

;; No runtime dependencies.  The kernel and distro are pure Emacs 29.1 plus
;; ERT.  Frontend dependencies arrive with ui/ when there is a frontend.
;; `eask test ert-runner' installs ert-runner itself, so it is not listed.
(development
 (depends-on "package-lint"))
