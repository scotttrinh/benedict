(source "gnu")
(source "melpa")

(package "benedict" "0.0.0" "AI chat in Emacs")
(package-file "benedict.el")
(files "benedict.el" "benedict-*.el" "test/*.el")

(depends-on "dash")
(depends-on "s")
(depends-on "lgr")
(depends-on "markdown-mode")

(development
 (depends-on "ert-async")
 (depends-on "package-lint")
 (depends-on "propcheck" :fetcher 'github :repo "Wilfred/propcheck" :files '("propcheck.el"))
 (depends-on "flywire" :fetcher 'github :repo "scotttrinh/flywire" :files '("*.el")))
