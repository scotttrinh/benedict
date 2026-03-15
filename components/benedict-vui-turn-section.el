;;; benedict-vui-turn-section.el --- Vui turn section component -*- lexical-binding: t; -*-
;; Author: Benedict maintainers

;;; Commentary:
;; Renders a labeled section within a chat turn.

;;; Code:

(require 'vui)
(require 'benedict-vui-badge)

(defun benedict-vui-turn-section--decorate-text (text face navigation-properties)
  "Return TEXT propertized with FACE and NAVIGATION-PROPERTIES."
  (let ((value (propertize text 'face face)))
    (when navigation-properties
      (add-text-properties 0 (length value) navigation-properties value))
    value))

(defun benedict-vui-turn-section--label-face (face suffix-face)
  "Return combined FACE with SUFFIX-FACE."
  (if face
      (list face suffix-face)
    suffix-face))

(defun benedict-vui-turn-section--label-node
    (status title detail face navigation-properties)
  "Return a section label node for STATUS, TITLE, DETAIL, FACE, and NAVIGATION-PROPERTIES."
  (let ((children (list (vui-component 'benedict-vui-badge :status status)
                        (vui-text
                         (benedict-vui-turn-section--decorate-text
                          title face navigation-properties)))))
    (when detail
      (setq children
            (append children
                    (list (vui-text "·"
                                    :face (benedict-vui-turn-section--label-face
                                           face
                                           'benedict-chat-header-separator))
                          (vui-text
                           (benedict-vui-turn-section--decorate-text
                            detail
                            (benedict-vui-turn-section--label-face
                             face
                             'benedict-chat-header-time)
                            navigation-properties))))))
    (apply #'vui-hstack children)))

(vui-defcomponent benedict-vui-turn-section
    (status title detail face content navigation-properties)
  "Render a labeled turn section."
  :render
  (let ((children (list (benedict-vui-turn-section--label-node
                         status title detail face navigation-properties))))
    (when content
      (setq children (append children (list content))))
    (apply #'vui-vstack (append (list :spacing 1) children))))

(provide 'benedict-vui-turn-section)
;;; benedict-vui-turn-section.el ends here
