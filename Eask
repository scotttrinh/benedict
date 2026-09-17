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
(files "core/*.el" "support/*.el" "api/*.el" "providers/*.el" "ext/*.el"
       "ui/*.el" "distro/*.el" "docs/*.org")

(load-paths "./core" "./support" "./api" "./providers" "./ext" "./ui" "./distro" "./packages")

(depends-on "emacs" "29.1")

;; vui is pinned to a tag rather than tracked on MELPA.  The pre-reset frontend
;; carried `fboundp' cascades against a moving vui API, and 1.3.0 itself renamed
;; button activation out from under the old test helpers; a render layer that
;; shifts underneath the bridge is how that code rotted.  `:vc' hands its tail
;; to `package-vc-install', whose second argument is the revision.  Bump
;; deliberately.
;; Runtime dependencies of separately built artifacts are declared in
;; `packages/benedict-packages.el'.  This root Eask is the aggregate development
;; environment, so frontend libraries are development dependencies here.
;; `eask test ert-runner' installs ert-runner itself, so it is not listed.
(development
 (depends-on "package-lint")
 (depends-on "markdown-mode")
 (depends-on "vui" :vc '(vui :url "https://github.com/d12frosted/vui.el") "v1.3.0"))
