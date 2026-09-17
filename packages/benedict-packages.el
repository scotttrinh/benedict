;;; benedict-packages.el --- First-party package artifact manifest  -*- lexical-binding: t; -*-

;;; Commentary:
;; Source files and package dependencies for independently installable tarballs.

;;; Code:

(defconst benedict-packages
  '((benedict
     :feature benedict
     :files ("core/benedict.el" "core/benedict-message.el"
             "core/benedict-schema.el" "core/benedict-tool.el"
             "core/benedict-provider.el" "core/benedict-session.el"
             "core/benedict-core.el" "docs/extending-benedict.org")
     :requires ((emacs "29.1")))
    (benedict-transport
     :feature benedict-transport
     :files ("support/benedict-log.el" "support/benedict-http.el"
             "support/benedict-transport.el")
     :requires ((emacs "29.1") (benedict "0.1.0")))
    (benedict-auth
     :feature benedict-auth
     :files ("support/benedict-auth.el")
     :requires ((emacs "29.1") (benedict "0.1.0")
                (benedict-transport "0.1.0")))
    (benedict-api
     :feature benedict-api
     :files ("api/benedict-api-transform.el" "api/benedict-api-stream.el"
             "api/benedict-api.el")
     :requires ((emacs "29.1") (benedict "0.1.0")
                (benedict-transport "0.1.0") (benedict-auth "0.1.0")))
    (benedict-openai-responses
     :feature benedict-openai-responses
     :files ("api/benedict-api-openai-responses.el"
             "api/benedict-openai-responses.el")
     :requires ((emacs "29.1") (benedict "0.1.0")
                (benedict-api "0.1.0")))
    (benedict-vercel
     :feature benedict-vercel
     :files ("providers/benedict-provider-vercel.el"
             "providers/benedict-vercel.el")
     :requires ((emacs "29.1") (benedict "0.1.0")
                (benedict-transport "0.1.0") (benedict-auth "0.1.0")
                (benedict-openai-responses "0.1.0")))
    (benedict-fake
     :feature benedict-fake
     :files ("providers/benedict-provider-fake.el" "providers/benedict-fake.el")
     :requires ((emacs "29.1") (benedict "0.1.0")))
    (benedict-eval
     :feature benedict-eval :files ("ext/benedict-eval.el")
     :requires ((emacs "29.1") (benedict "0.1.0")))
    (benedict-retry
     :feature benedict-retry
     :files ("ext/benedict-retry.el" "ext/benedict-retry-http.el")
     :requires ((emacs "29.1") (benedict "0.1.0")
                (benedict-transport "0.1.0")))
    (benedict-store
     :feature benedict-store :files ("ext/benedict-store.el")
     :requires ((emacs "29.1") (benedict "0.1.0")))
    (benedict-recovery
     :feature benedict-recovery :files ("ext/benedict-recovery.el")
     :requires ((emacs "29.1") (benedict "0.1.0")))
    (benedict-headless
     :feature benedict-headless :files ("ui/benedict-headless.el")
     :requires ((emacs "29.1") (benedict "0.1.0")))
    (benedict-ui
     :feature benedict-ui
     :files ("ui/benedict-chat-widgets.el" "ui/benedict-chat-blocks.el"
             "ui/benedict-chat-render.el" "ui/benedict-chat.el"
             "ui/benedict-ui.el")
     :requires ((emacs "29.1") (benedict "0.1.0")
                (benedict-retry "0.1.0") (markdown-mode "2.5") (vui "1.3.0")))
    (benedict-distro
     :feature benedict-distro :files ("distro/benedict-distro.el")
     :requires ((emacs "29.1") (benedict "0.1.0")
                (benedict-eval "0.1.0") (benedict-recovery "0.1.0")
                (benedict-retry "0.1.0") (benedict-store "0.1.0")
                (benedict-ui "0.1.0") (benedict-headless "0.1.0"))))
  "Ordered manifest for the independently installable Benedict packages.")

(provide 'benedict-packages)
;;; benedict-packages.el ends here
