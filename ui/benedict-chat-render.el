;;; benedict-chat-render.el --- Root component and entry chrome for the chat UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;;; Commentary:

;; The root component and the per-entry chrome around the blocks of
;; `benedict-chat-blocks'.
;;
;; THE ROOT RENDERS THE STREAM AND NOTHING ELSE, and that is a hard constraint
;; rather than a minimalist preference.  Re-rendering a root re-emits every
;; content item the stream holds -- O(transcript) -- and `vui--stream-render'
;; deliberately SKIPS component rows, because a full re-emit cannot reproduce an
;; inline instance.  So a root re-render mid-conversation would both cost the
;; whole transcript and silently drop every tool card and reasoning section from
;; the buffer.
;;
;; The consequence: after mount, nothing may re-render the root until the
;; transcript is rebuilt wholesale (a fork).  Anything that changes on every turn
;; -- run state, model, token usage -- therefore lives in the HEADER LINE, which
;; Emacs redraws on its own and which no part of vui is involved in.  That is not
;; a workaround; a status readout is what a header line is for.
;;
;; The stream handle is created by the buffer and passed IN as a prop rather than
;; taken with `vui-use-stream'.  The bridge in `benedict-chat' owns the buffer's
;; lifetime anyway, and owning the handle too means it can append without waiting
;; for a render to hand it back.

;;; Code:

(require 'benedict)
(require 'benedict-message)
(require 'benedict-session)
(require 'vui)
(require 'benedict-chat-widgets)
(require 'benedict-chat-blocks)

;;;; The root

(vui-defcomponent benedict-chat-root (handle)
  "Render the transcript stream anchored by HANDLE.

Deliberately has no state and no other children: see this file's
commentary for why a root re-render is destructive to a live stream."
  :render
  (vui-stream handle))

;;;; Entry chrome

(defun benedict-chat--role-face (entry)
  "Return the face for ENTRY's role header."
  (pcase (benedict-entry-role entry)
    ('user 'benedict-chat-user)
    ('assistant 'benedict-chat-assistant)
    ('note 'benedict-chat-note)
    (_ 'benedict-chat-badge)))

(defun benedict-chat--role-label (entry)
  "Return the display label for ENTRY's role."
  (pcase (benedict-entry-role entry)
    ('user "you")
    ('assistant "assistant")
    ('tool-result "tool")
    ('note "note")
    (role (format "%s" role))))

(defun benedict-chat--origin-label (entry)
  "Return ENTRY's model as a badge string, or nil when it has no origin.
Assistant entries carry provider, api, and model in meta, and a
transcript may mix several models, so the badge is what makes a change of
model legible when reading back."
  (let ((origin (benedict-entry-origin entry)))
    (when-let* ((model (plist-get origin :model)))
      (format "  %s" model))))

(defun benedict-chat--branch-label (session entry)
  "Return a branch affordance for ENTRY in SESSION, or nil when it is unique.

The label reads \"[2/3]\": ENTRY is the second of three siblings sharing a
parent.  Computed when the entry is rendered, so it is accurate as of the
last rebuild of the transcript -- which is exactly when a fork happens,
since a fork rebuilds the stream."
  (when-let* ((id (benedict-entry-id entry)))
    (let* ((siblings (benedict-session-siblings session id))
           (total (length siblings)))
      (when (> total 1)
        (let ((position (1+ (or (seq-position
                                 (mapcar #'benedict-entry-id siblings) id)
                                0))))
          (format "  [%d/%d]" position total))))))

(defun benedict-chat-entry-header-vnode (session entry)
  "Return the header vnode for ENTRY in SESSION.

Static content: role, origin badge, and branch affordance.  Appended to
the stream once and never updated, which is what lets it be a content
vnode rather than a row."
  (let ((stop-reason (benedict-entry-meta-get entry :stop-reason)))
    (apply
     #'vui-fragment
     (delq nil
           (list
            (vui-text (benedict-chat--role-label entry)
                      :face (benedict-chat--role-face entry))
            (when-let* ((origin (benedict-chat--origin-label entry)))
              (benedict-chat-badge origin))
            (when-let* ((branch (benedict-chat--branch-label session entry)))
              (vui-text branch :face 'benedict-chat-branch))
            ;; An errored or aborted turn is real history and the UI shows it;
            ;; only the lowering pass skips it.  Saying so on the header is
            ;; what keeps a short reply from reading as a complete one.
            (when (memq stop-reason '(error aborted))
              (vui-text (format "  (%s: %s)" stop-reason
                                (or (benedict-entry-meta-get entry :error-message)
                                    "no message"))
                        :face 'benedict-chat-error)))))))

;;;; Header line

(defun benedict-chat--usage-label (session)
  "Return a token-usage summary for SESSION's most recent assistant entry."
  (let* ((path (benedict-session-path session))
         (entry (seq-find #'benedict-entry-assistant-p (reverse path)))
         (usage (and entry (benedict-entry-meta-get entry :usage))))
    (when usage
      (format "  %s in / %s out"
              (or (plist-get usage :input) "?")
              (or (plist-get usage :output) "?")))))

(defun benedict-chat-header-line (session)
  "Return the header-line string for SESSION.

Run state, model, and usage change every turn, and the header line is
where they live precisely because redrawing it does not touch the vui
tree.  See this file's commentary."
  (let ((model (benedict-session-model session)))
    (concat
     (propertize (format " %s " (benedict-session-state session))
                 'face 'benedict-chat-status)
     (when model (format " %s" (benedict-model-id model)))
     (or (benedict-chat--usage-label session) "")
     (when (benedict-session-queued-p session) "  (queued)")
     (when-let* ((reason (benedict-session-stop-reason session)))
       (format "  stopped: %s" reason)))))

(provide 'benedict-chat-render)
;;; benedict-chat-render.el ends here
