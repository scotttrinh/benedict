(source "gnu")
(source "melpa")

(package "benedict" "0.1.0pre" "Emacs-first AI assistant")
(package-file "benedict.el")
(website-url "https://github.com/scotttrinh/benedict")
(keywords "tools" "convenience" "ai")
(files "benedict.el" "benedict-*.el" "components/*.el" "test/*.el")

(depends-on "emacs" "27.1")
(depends-on "dash")
(depends-on "s")
(depends-on "lgr")
(depends-on "markdown-mode")
(depends-on "magit-section")
(depends-on "svg-lib")
(depends-on "vui")

(development
 (depends-on "ert-async")
 (depends-on "package-lint")
 (depends-on "propcheck" :fetcher 'github :repo "Wilfred/propcheck" :files '("propcheck.el"))
 (depends-on "flywire" :fetcher 'github :repo "scotttrinh/flywire" :files '("*.el")))
