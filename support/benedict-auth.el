;;; benedict-auth.el --- Credential store and resolution  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Where credentials live, and how a provider's credential becomes the three
;; values a request needs.
;;
;; RESOLVED AUTH IS EXACTLY THREE FIELDS (SPEC-001 8.1):
;;
;;   (:api-key "..." :headers (("X-Foo" . "bar")) :base-url "https://...")
;;
;; The rule that keeps this layer from rotting: if a value cannot be expressed
;; as `api-key', `headers', or `base-url', it is PROVIDER CONFIGURATION, not
;; auth.  Auth code in these systems typically becomes a general settings
;; dumping ground, one plausible field at a time.  `benedict-auth--check-value'
;; refuses the fourth field rather than trusting review to catch it.  `base-url'
;; earns its place because some credentials determine their own endpoint --
;; GitHub Copilot does, and subscription-backed providers generally may.
;;
;; Note what is NOT here: nothing builds an `Authorization' header.  Which
;; header carries a key, and in what form, is a property of the WIRE PROTOCOL,
;; not of the credential -- Anthropic wants `x-api-key', OpenAI wants a bearer,
;; Google wants a query parameter.  The adapter reads `:api-key' and decides.
;; A credential that needs extra headers of its own supplies them through
;; `:headers', which is a different claim and a rarer one.
;;
;; ONLY THE API-KEY PATH IS IMPLEMENTED.  SPEC-001 8.7 sequences it that way:
;; API-key auth is the v1 requirement and is about thirty lines, while the
;; OAuth machinery is worth building only against a real subscription provider.
;; What is designed in now, deliberately, is the part that is expensive to
;; retrofit -- the `refresh'/`to-auth' split of `benedict-defoauth', the
;; in-flight refresh table, and the headless interaction protocol.  Retrofitting
;; the split is cheap; retrofitting the serialization is not.
;;
;; THE REFRESH RACE IS REAL (SPEC-001 8.4).  Emacs is single-threaded, which
;; makes it tempting to skip refresh locking.  Two in-flight requests can both
;; observe an expiring token, both refresh, and the second can persist a
;; credential derived from a refresh token the first already rotated --
;; invalidating the session.  The concurrency is cooperative rather than
;; preemptive, but it is concurrency.  `benedict-auth-modify' is the only write
;; path precisely so that the serialization has one place to live, and the
;; cross-process half is a `.lock' directory, which `make-directory' makes
;; atomic on POSIX.
;;
;; A STORED CREDENTIAL OWNS ITS PROVIDER.  The environment is consulted only
;; when nothing is stored -- never as a fallback after a stored credential
;; failed, because that turns an auth error into a wrong-account error, which
;; is far harder to diagnose.  The one exception is an entry this file cannot
;; interpret at all: an unrecognized shape is not a credential, so it does not
;; own anything.  Real credential files accumulate entries from older versions
;; of the software that wrote them, and refusing to work because of one is
;; worse than ignoring it.  Nothing here signals on a malformed entry.
;;
;; See SPEC-001 8, 12.4, and 7.2.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'xdg)
(require 'benedict)
(require 'benedict-log)
(require 'benedict-provider)

;;;; Errors

(define-error 'benedict-auth-error
  "Benedict authentication error"
  'benedict-error)

(define-error 'benedict-auth-locked
  "Could not lock the Benedict credential file"
  'benedict-auth-error)

(define-error 'benedict-auth-invalid-value
  "Not a Benedict auth value"
  'benedict-auth-error)

;;;; Configuration

(defcustom benedict-auth-file nil
  "File holding Benedict credentials, or nil for the standard location.

When nil, resolved at call time to \"benedict/auth.json\" under
`xdg-config-home' -- normally ~/.config/benedict/auth.json.  Resolved at
call time rather than at load time so that XDG_CONFIG_HOME can change
after Emacs starts, and so a test can redirect writes without reloading.

The file is written mode 600 and its directory mode 700."
  :type '(choice (const :tag "XDG config directory" nil) file)
  :group 'benedict)

(defcustom benedict-auth-lock-timeout 5
  "Seconds to wait for the credential file lock before giving up.
Exceeding it signals `benedict-auth-locked'.  The lock is held only
across a read-modify-write of a small file, so waiting this long means
another process is wedged rather than busy."
  :type 'number
  :group 'benedict)

(defcustom benedict-auth-lock-stale-seconds 60
  "Age in seconds at which a credential file lock is presumed abandoned.

An Emacs that crashed holding the lock would otherwise make every
credential permanently unwritable, which is a worse failure than the race
the lock prevents -- the race needs two processes refreshing the same
token in the same second, and this needs only one process to have died."
  :type 'number
  :group 'benedict)

(defconst benedict-auth-value-keys '(:api-key :headers :base-url)
  "The only keys a resolved auth value may carry.
SPEC-001 8.1: anything else is provider configuration, not auth.")

;;;; Auth methods

;; What a provider declares in its `:auth' slot.  Opaque to the kernel, which
;; is why `benedict-provider' documents the slot as "interpreted by
;; `benedict-auth'" and never looks inside it.

(cl-defstruct (benedict-auth-method
               (:constructor benedict-auth-method-create)
               (:copier nil))
  "How one provider's credential is obtained.

Deliberately thin.  A method says what KIND of credential a service uses
and where to look for one; it says nothing about how the credential is
presented on the wire, because that is the wire protocol's business and
one protocol serves many services."
  (kind nil
        :documentation "Symbol `api-key' or `oauth'.
`oauth' is accepted and registered but not yet resolvable; see SPEC-001
8.7 for why the split exists before the implementation does.")
  (name nil
        :documentation "Human-readable name of the credential, for a login prompt.
Shown to a person: \"Vercel AI Gateway API key\", not a variable name.")
  (env nil
       :documentation "Environment variable names to consult, in order.
Consulted only when nothing is stored, and an empty value counts as
unset.  See SPEC-001 8.2.")
  (oauth nil
         :documentation "Symbol naming the `benedict-defoauth' method, when KIND is `oauth'."))

;;;###autoload
(cl-defun benedict-auth-env-api-key (&key name env)
  "Return an auth method for a plain API key called NAME, found in ENV.

ENV is a list of environment variable names, consulted in order and only
when no credential is stored for the provider.  This is what a provider
puts in its `:auth' slot:

  (benedict-defprovider vercel-ai-gateway
    ...
    :auth (benedict-auth-env-api-key
           :name \"Vercel AI Gateway API key\"
           :env \\='(\"AI_GATEWAY_API_KEY\")))"
  (benedict-auth-method-create :kind 'api-key :name name :env env))

;;;###autoload
(cl-defun benedict-auth-oauth-method (id &key name)
  "Return an auth method using the `benedict-defoauth' method ID, called NAME.

Providers may declare this today; resolving it signals through the
callback until Phase 7 implements the refresh path (SPEC-001 8.7)."
  (benedict-auth-method-create :kind 'oauth :oauth id :name name))

;;;; OAuth methods

;; Registered but never resolved.  The factoring is the point (SPEC-001 8.3):
;; splitting `refresh' from `to-auth' leaves the hard part -- serialized
;; refresh -- owned by this file, so that a provider never writes locking code.
;; Getting that boundary right later means rewriting every provider that
;; guessed at it; getting it right now costs a struct.

(cl-defstruct (benedict-auth-oauth
               (:constructor benedict-auth-oauth--create)
               (:copier nil))
  "One OAuth method: how a credential is obtained, renewed, and used."
  (id nil
      :documentation "Symbol naming this method, such as `openai-codex'.")
  (name nil
        :documentation "Human-readable name, shown during login.")
  (subscription-p nil
                  :documentation "Non-nil when this credential comes from a paid subscription.
A frontend may want to say so; nothing here branches on it.")
  (login nil
         :documentation "Function of (INTERACTION CALLBACK) running the interactive flow.
Calls CALLBACK with the new credential.  Reaches a person only through
INTERACTION -- see `benedict-auth-prompt' -- so it never touches Emacs UI
directly and stays testable with a stub.")
  (refresh nil
           :documentation "Function of (CREDENTIAL CALLBACK) exchanging the refresh token.
A network call, and the one place here that is allowed to fail loudly: an
`invalid_grant' means the credential is dead and the user must log in
again.  Never called concurrently for one provider; `benedict-auth-resolve'
serializes it.")
  (to-auth nil
           :documentation "Function of (CREDENTIAL) returning an auth value.
MUST BE PURE.  It runs on every request, and it is where a credential
that determines its own endpoint supplies `:base-url'."))

(defvar benedict-auth-oauth--registry (make-hash-table :test #'eq)
  "Hash table mapping an OAuth method id symbol to its `benedict-auth-oauth'.")

(defun benedict-auth-oauth-register (method)
  "Add METHOD to the registry, replacing any with the same id.  Return METHOD."
  (unless (benedict-auth-oauth-p method)
    (signal 'benedict-auth-error (list "Not an OAuth method" method)))
  (puthash (benedict-auth-oauth-id method) method benedict-auth-oauth--registry)
  method)

(defun benedict-auth-oauth-get (id)
  "Return the registered OAuth method named ID, or nil when there is none."
  (gethash id benedict-auth-oauth--registry))

(defun benedict-auth-oauth-unregister (id)
  "Remove the OAuth method named ID.  Return non-nil when one was removed."
  (let ((present (and (gethash id benedict-auth-oauth--registry) t)))
    (remhash id benedict-auth-oauth--registry)
    present))

;;;###autoload
(defmacro benedict-defoauth (name &rest body)
  "Define and register the OAuth method NAME.

BODY is a plist accepting `:name', `:subscription-p', `:login',
`:refresh', and `:to-auth', with the meanings given by the
`benedict-auth-oauth' slot documentation.

  (benedict-defoauth openai-codex
    :name    \"OpenAI Codex\"
    :subscription-p t
    :login   (lambda (interaction callback) ...)
    :refresh (lambda (credential callback) ...)
    :to-auth (lambda (credential) ...))

Re-evaluating replaces the previous definition.  Returns the method."
  (declare (indent 1))
  `(benedict-auth-oauth-register (benedict-auth-oauth--create :id ',name ,@body)))

;;;; The headless interaction protocol

;; A login flow needs a person; the OAuth implementation must never know which
;; kind (SPEC-001 8.5).  A frontend supplies an interaction, the flow asks it
;; for what it needs, and the chat frontend maps that to `read-passwd' and
;; `browse-url' while a batch frontend maps it to stdin and a test maps it to a
;; scripted answer.  This is what keeps the flow testable without a display.

(cl-defun benedict-auth-prompt (interaction &key type message choices callback)
  "Ask the person behind INTERACTION for something, and pass it to CALLBACK.

INTERACTION is a plist a frontend supplies, carrying `:prompt' and
`:notify' functions; nil means nobody is available.  TYPE is one of
`text', `secret', `select', or `manual-code'.  MESSAGE is shown as-is.
CHOICES is the list to choose from when TYPE is `select'.

CALLBACK receives the answer, or nil when the person declined -- which is
also what happens when INTERACTION offers no way to ask.  A flow must
treat nil as a cancellation rather than as an empty answer, since the two
are indistinguishable to the person and only one of them is safe to
retry."
  (if-let* ((handler (plist-get interaction :prompt)))
      (funcall handler (list :type type :message message :choices choices
                             :callback callback))
    (benedict-log-warn "auth: nobody to ask: %s" message)
    (when callback (funcall callback nil))))

(cl-defun benedict-auth-notify (interaction &key type message url code)
  "Tell the person behind INTERACTION something, without waiting for an answer.

TYPE is one of `info', `auth-url', `device-code', or `progress'.  MESSAGE,
URL, and CODE carry the detail; which are meaningful depends on TYPE.
Returns nil.  A missing INTERACTION is not an error: a headless flow that
cannot show a URL has still made progress worth logging."
  (if-let* ((handler (plist-get interaction :notify)))
      (funcall handler (list :type type :message message :url url :code code))
    (benedict-log-info "auth: %s %s" (or type 'info) (or message url code "")))
  nil)

;;;; Credentials on disk

;; The stored shape, per SPEC-001 8.2:
;;
;;   {"vercel-ai-gateway": {"type": "api_key", "key": "..."},
;;    "openai-codex": {"type": "oauth", "refresh": "...", "access": "...",
;;                     "expires": 1785000000}}
;;
;; Parsed as plists with keyword keys, so an entry written by a future version
;; keeps its unknown fields and is written back unchanged.  Null and false are
;; parsed to `:null' and `:false' for the same reason: a round trip through
;; this file must not quietly rewrite somebody else's entry.

(defun benedict-auth--file ()
  "Return the path of the credential file."
  (or benedict-auth-file
      (expand-file-name "benedict/auth.json" (xdg-config-home))))

(defun benedict-auth--read-file ()
  "Return every stored credential as a plist of provider keyword to credential.

Returns nil when the file does not exist, and the symbol `unreadable'
when it exists but does not parse.  The distinction matters: nothing
stored means the environment may speak, while a file that will not parse
means the user's credentials exist and cannot be reached, and quietly
falling back to an environment variable there is how a request ends up
authenticated as the wrong account."
  (let ((file (benedict-auth--file)))
    (when (file-readable-p file)
      (condition-case error
          (json-parse-string
           (with-temp-buffer
             (let ((coding-system-for-read 'utf-8))
               (insert-file-contents file))
             (buffer-string))
           :object-type 'plist :null-object :null :false-object :false)
        (error
         (benedict-log-error "auth: %s does not parse: %s"
           file (error-message-string error))
         'unreadable)))))

(defun benedict-auth--write-file (credentials)
  "Write CREDENTIALS to the credential file, replacing it.

Written through a temporary file in the same directory and renamed into
place, so a crash mid-write cannot leave a truncated credential file, and
so the secrets are never briefly world-readable: `make-temp-file' creates
mode 600 and the rename carries it over."
  (let* ((file (benedict-auth--file))
         (directory (benedict-auth--ensure-directory)))
    (let ((temporary (make-temp-file (expand-file-name "auth-" directory)))
          ;; Batch Emacs defaults this to t.  A rotated refresh token that
          ;; did not reach the disk is a session that cannot be resumed.
          (write-region-inhibit-fsync nil)
          (coding-system-for-write 'utf-8-unix))
      (unwind-protect
          (progn
            (write-region (json-serialize (or credentials '())
                                          :null-object :null :false-object :false)
                          nil temporary nil 'silent)
            (set-file-modes temporary #o600)
            (rename-file temporary file t)
            (setq temporary nil))
        (when temporary (ignore-errors (delete-file temporary)))))
    (set-file-modes file #o600)
    credentials))

(defun benedict-auth--ensure-directory ()
  "Create the credential file's directory if it does not exist.  Return it.

Created mode 700 when this function creates it, and left alone when it
already exists -- the directory may hold more than Benedict's file, and
tightening somebody else's configuration directory is not this function's
call to make.  The file's own 600 is the guarantee that matters."
  (let ((directory (file-name-directory (benedict-auth--file))))
    (unless (file-directory-p directory)
      (make-directory directory t)
      (set-file-modes directory #o700))
    directory))

(defun benedict-auth--key (provider-id)
  "Return the plist keyword PROVIDER-ID is stored under."
  (intern (concat ":" (symbol-name provider-id))))

;;;; Locking

(defmacro benedict-auth--with-lock (&rest body)
  "Evaluate BODY holding the credential file lock, and release it afterwards.

Signals `benedict-auth-locked' when the lock cannot be taken within
`benedict-auth-lock-timeout' seconds.  The lock is a directory because
`make-directory' either creates one or signals, atomically, on every
POSIX filesystem -- which a file plus a check is not."
  (declare (indent 0) (debug body))
  (let ((lock (make-symbol "lock")))
    `(let ((,lock (benedict-auth--acquire-lock)))
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory ,lock t))))))

(defun benedict-auth--acquire-lock ()
  "Take the credential file lock and return its path.
Signal `benedict-auth-locked' on timeout."
  (benedict-auth--ensure-directory)
  (let* ((lock (concat (benedict-auth--file) ".lock"))
         (deadline (+ (float-time) benedict-auth-lock-timeout))
         (taken nil))
    (while (not taken)
      (condition-case nil
          (progn
            ;; Without PARENTS, and that is the whole mechanism: with it,
            ;; `make-directory' succeeds on a directory that already exists,
            ;; and the lock silently stops locking anything.
            (make-directory lock)
            (setq taken t))
        (file-already-exists
         (cond
          ((benedict-auth--lock-stale-p lock)
           (benedict-log-warn "auth: breaking a lock left behind at %s" lock)
           (ignore-errors (delete-directory lock t)))
          ((> (float-time) deadline)
           (signal 'benedict-auth-locked (list lock)))
          (t (sleep-for 0.05))))))
    lock))

(defun benedict-auth--lock-stale-p (lock)
  "Return non-nil when LOCK is old enough to have been abandoned."
  (when-let* ((attributes (file-attributes lock))
              (modified (file-attribute-modification-time attributes)))
    (> (float-time (time-subtract nil modified)) benedict-auth-lock-stale-seconds)))

;;;; Reading and writing credentials

(defun benedict-auth-read (provider-id)
  "Return the credential stored for PROVIDER-ID, or nil when there is none.

The credential is a plist in the stored shape, including its secret --
`:type', plus whatever that type carries.  An entry in a shape this
version does not recognize is returned as it stands rather than refused;
use `benedict-auth-credential-type' to ask whether it means anything.
Returns nil, never signals, when the file itself does not parse."
  (let ((credentials (benedict-auth--read-file)))
    (unless (eq credentials 'unreadable)
      (plist-get credentials (benedict-auth--key provider-id)))))

(defun benedict-auth-list ()
  "Return metadata for every stored credential, with NO secrets.

Each element is a plist of `:provider', `:type', and, for a credential
that has one, `:expires'.  A `:type' of nil marks an entry this version
does not understand, which is information rather than a fault -- the file
is shared with older and newer versions of this software.

Safe to show a user or hand to a model; nothing in the result is secret."
  (let ((credentials (benedict-auth--read-file))
        (entries nil))
    (unless (eq credentials 'unreadable)
      (while credentials
        (let* ((key (pop credentials))
               (credential (pop credentials))
               (expires (and (listp credential) (plist-get credential :expires))))
          (push (append (list :provider (intern (substring (symbol-name key) 1))
                              :type (benedict-auth-credential-type credential))
                        (when (numberp expires) (list :expires expires)))
                entries))))
    (nreverse entries)))

(defun benedict-auth-modify (provider-id function &optional callback)
  "Replace PROVIDER-ID's credential with the result of calling FUNCTION on it.

FUNCTION receives the current credential, or nil when there is none, and
returns the new one; returning nil deletes the entry.  CALLBACK, when
given, is called with the new credential once it is on disk.  Returns the
new credential.

THIS IS THE ONLY WRITE PATH, which is what allows a token refresh to be
serialized correctly (SPEC-001 8.4).  The read, the call, and the write
all happen while holding the lock, so FUNCTION sees what is on disk right
now and not what was there when the caller decided to refresh.  FUNCTION
must therefore be quick and must not itself write credentials.

Signals `benedict-auth-locked' when another process holds the lock, and
leaves the file untouched when FUNCTION signals."
  (let ((result
         (benedict-auth--with-lock
           (let* ((credentials (benedict-auth--read-file))
                  (credentials (if (eq credentials 'unreadable) nil credentials))
                  (key (benedict-auth--key provider-id))
                  (credential (funcall function (plist-get credentials key))))
             (benedict-auth--write-file
              (if credential
                  (plist-put credentials key credential)
                (benedict-auth--without credentials key)))
             credential))))
    (benedict-log-info "auth: %s credential for %s"
      (if result "stored" "removed") provider-id)
    (when callback (funcall callback result))
    result))

(defun benedict-auth-delete (provider-id)
  "Remove PROVIDER-ID's stored credential.  Return nil."
  (benedict-auth-modify provider-id #'ignore))

(defun benedict-auth--without (plist key)
  "Return PLIST with KEY and its value removed.  PLIST is not modified."
  (let ((result nil))
    (while plist
      (let ((this (pop plist))
            (value (pop plist)))
        (unless (eq this key)
          (setq result (append result (list this value))))))
    result))

;;;; Credential accessors

;; The stored spellings -- "api_key", "key" -- appear here and nowhere else, so
;; that the disk format has one definition rather than a dozen string literals
;; spread across providers.

(defconst benedict-auth--type-names
  '(("api_key" . api-key) ("oauth" . oauth))
  "Alist of the stored `type' string to the symbol this file uses.")

(defun benedict-auth-credential-type (credential)
  "Return CREDENTIAL's type as `api-key', `oauth', or nil.

Nil means the entry is not in a shape this version understands, which is
never an error: a credential file outlives the version of the software
that wrote it, and an entry nothing here can read is an entry to leave
alone."
  (and (listp credential)
       (alist-get (plist-get credential :type) benedict-auth--type-names
                  nil nil #'equal)))

(defun benedict-auth-credential-api-key (credential)
  "Return the API key in CREDENTIAL, or nil when it carries none."
  (when (eq (benedict-auth-credential-type credential) 'api-key)
    (let ((key (plist-get credential :key)))
      (and (stringp key) (not (string-empty-p key)) key))))

(defun benedict-auth-api-key-credential (key)
  "Return a storable credential holding the API key KEY."
  (list :type "api_key" :key key))

(defun benedict-auth-set-api-key (provider-id key &optional callback)
  "Store KEY as PROVIDER-ID's API key, replacing any credential it had.
CALLBACK is as `benedict-auth-modify'.  Returns the new credential."
  (benedict-auth-modify provider-id
                        (lambda (_current) (benedict-auth-api-key-credential key))
                        callback))

;;;; Resolution

(defvar benedict-auth--in-flight (make-hash-table :test #'eq)
  "Provider id to the list of callbacks waiting on a refresh in progress.

Unused until Phase 7 and present because SPEC-001 8.7 says the
serialization is the expensive thing to retrofit.  The algorithm it
belongs to, from SPEC-001 8.4, is:

  1. Read the credential.  An API key resolves and returns.
  2. OAuth with expiry more than five minutes out: `to-auth' and return.
  3. A refresh already pending for this provider: enqueue this request\\='s
     callback here and return.
  4. Otherwise register here, call `refresh', and on completion persist
     through `benedict-auth-modify', then flush every enqueued callback
     with the new credential.
  5. Re-check expiry inside `modify' -- another Emacs may have rotated it
     since this one decided to refresh.

Step 3 is the whole point.  Two in-flight requests both observing an
expiring token, both refreshing, and the second persisting a credential
derived from a refresh token the first already rotated is how a session
invalidates itself.")

(defun benedict-auth-resolve (provider callback)
  "Resolve PROVIDER's credential and call CALLBACK with the result.

PROVIDER is a `benedict-provider' or a provider id symbol.  CALLBACK is
called with two arguments, (AUTH ERROR), exactly one of which is
meaningful:

  AUTH   the auth value of SPEC-001 8.1 -- a plist of `:api-key',
         `:headers', and `:base-url', any of which may be absent -- or
         nil when PROVIDER needs no credentials at all.
  ERROR  nil, or a plist of `:error' and `:reason', where `:reason' is
         one of `missing', `unreadable', `mismatch', or `unsupported'.

CHECK ERROR FIRST.  An AUTH of nil with no ERROR is a provider that
authenticates nothing, such as the fake provider, and is a success.

CALLBACK MAY BE CALLED BEFORE THIS FUNCTION RETURNS.  The API-key path
touches only the filesystem and has nothing to wait for; the callback
exists because the OAuth path will have to refresh a token over the
network, and a caller written against a synchronous return would have to
be rewritten then.

Never signals for a missing or unusable credential -- those arrive
through ERROR, so that a caller inside a stream has one failure path
rather than two.  Signals `benedict-provider-unknown' only when PROVIDER
names a provider that is not registered, which is a programming error."
  (let* ((provider (if (benedict-provider-p provider)
                       provider
                     (benedict-provider-get-or-signal provider)))
         (id (benedict-provider-id provider))
         (method (benedict-provider-auth provider)))
    (cond
     ((null method) (funcall callback nil nil))
     ((not (benedict-auth-method-p method))
      (funcall callback nil
               (benedict-auth--error
                'unsupported
                (format "Provider %s declares an auth method this version does not understand"
                        id))))
     ((eq (benedict-auth-method-kind method) 'api-key)
      (benedict-auth--resolve-api-key id method callback))
     ((eq (benedict-auth-method-kind method) 'oauth)
      (funcall callback nil
               (benedict-auth--error
                'unsupported
                (format "OAuth login for %s is not implemented yet (SPEC-001 8.7); \
store an API key for it instead" id))))
     (t
      (funcall callback nil
               (benedict-auth--error
                'unsupported
                (format "Provider %s declares auth of unknown kind %s"
                        id (benedict-auth-method-kind method))))))))

(defun benedict-auth--resolve-api-key (id method callback)
  "Resolve ID's API key under METHOD and call CALLBACK with (AUTH ERROR)."
  (let ((credentials (benedict-auth--read-file)))
    (if (eq credentials 'unreadable)
        ;; Deliberately NOT falling through to the environment: the user has
        ;; credentials, they are unreachable, and authenticating as whatever
        ;; happens to be exported is a worse outcome than saying so.
        (funcall callback nil
                 (benedict-auth--error
                  'unreadable
                  (format "%s does not parse; fix or remove it"
                          (benedict-auth--file))))
      (let* ((credential (plist-get credentials (benedict-auth--key id)))
             (type (benedict-auth-credential-type credential))
             (key (benedict-auth-credential-api-key credential)))
        (cond
         (key (funcall callback (benedict-auth--value :api-key key) nil))
         ;; A credential we understand, of the wrong kind, or with no usable
         ;; key: it owns the provider, so the environment does not get a turn.
         (type
          (funcall callback nil
                   (benedict-auth--error
                    'mismatch
                    (format "The stored credential for %s is %s, not a usable API key"
                            id type))))
         (t
          (when credential
            (benedict-log-warn
                "auth: ignoring the entry for %s; its shape is not one this version knows"
              id))
          (if-let* ((key (benedict-auth--from-environment method)))
              (funcall callback (benedict-auth--value :api-key key) nil)
            (funcall callback nil
                     (benedict-auth--error 'missing
                                           (benedict-auth--missing-message id method))))))))))

(defun benedict-auth--from-environment (method)
  "Return the first non-empty value of METHOD's environment variables, or nil."
  (seq-some (lambda (name)
              (let ((value (getenv name)))
                (and (stringp value) (not (string-empty-p value)) value)))
            (benedict-auth-method-env method)))

(defun benedict-auth--missing-message (id method)
  "Return the message for having found no credential for ID under METHOD."
  (let ((env (benedict-auth-method-env method)))
    (format "No %s. %s"
            (or (benedict-auth-method-name method)
                (format "credential for %s" id))
            (if env
                (format "Set %s, or store one with `benedict-auth-set-api-key'"
                        (string-join env " or "))
              "Store one with `benedict-auth-set-api-key'"))))

(defun benedict-auth--error (reason message)
  "Return the error plist for MESSAGE with REASON."
  (benedict-log-warn "auth: %s" message)
  (list :error message :reason reason))

(defun benedict-auth--value (&rest fields)
  "Return the auth value carrying FIELDS, checking that it is one.
Signal `benedict-auth-invalid-value' when FIELDS carries a key that is
not in `benedict-auth-value-keys'."
  (benedict-auth-check-value fields)
  fields)

(defun benedict-auth-check-value (auth)
  "Return AUTH, or signal `benedict-auth-invalid-value' when it is not one.

SPEC-001 8.1 permits exactly `:api-key', `:headers', and `:base-url'.
The check exists because the fourth field is always plausible in the
moment -- an organization id, a region, a model prefix -- and because
every one of them is provider configuration wearing an auth costume.  A
provider that needs one has a `:meta' slot for it."
  (let ((rest auth))
    (while rest
      (let ((key (pop rest)))
        (pop rest)
        (unless (memq key benedict-auth-value-keys)
          (signal 'benedict-auth-invalid-value (list key auth))))))
  auth)

(provide 'benedict-auth)

;;; benedict-auth.el ends here
