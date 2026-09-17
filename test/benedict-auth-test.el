;;; benedict-auth-test.el --- Tests for the credential store  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every test here points `benedict-auth-file' at a temporary directory before
;; it does anything else.  A suite that reads the developer's real credentials
;; would pass on one machine, and a suite that WROTE them would be a bug worth
;; more than the test.
;;
;; Three claims carry most of the weight.
;;
;; A CREDENTIAL FILE OUTLIVES THE VERSION THAT WROTE IT.  The file this project
;; is developed against already holds an entry in an older shape than SPEC-001
;; 8.2 describes.  So there are two tolerance tests, and they are different
;; claims: an unknown entry must be IGNORED when resolving, and PRESERVED when
;; something else is written.  Passing the first while failing the second means
;; the first write of an API key silently deletes an OAuth login.
;;
;; A STORED CREDENTIAL OWNS ITS PROVIDER.  The environment speaks only when
;; nothing is stored -- never after a stored credential turned out to be
;; unusable, and never when the file will not parse.  Both fallbacks are
;; tempting, both make things work more often, and both turn an auth error into
;; a request authenticated as the wrong account, which is a much worse failure
;; because it succeeds.
;;
;; RESOLUTION NEVER SIGNALS FOR A MISSING CREDENTIAL.  It reports through the
;; callback, because its caller is `benedict-api-stream', which owns the
;; SPEC-001 7.3 rule that a stream ends in exactly one terminal event.  A
;; signal there would give the kernel a second error path.
;;
;; The OAuth tests assert that the machinery is REGISTERED and NOT YET
;; RESOLVABLE.  That is the SPEC-001 8.7 sequencing exactly: the split is
;; designed in now because retrofitting it is expensive, and the flow itself
;; waits for a real subscription provider.
;;
;; See SPEC-001 8 and 12.4.

;;; Code:

(require 'ert)
(require 'test-helper)

(defmacro benedict-auth-test--with-file (&rest body)
  "Evaluate BODY with the credential file inside a fresh temporary directory.

The file's parent directories do not exist yet, so the code under test is
the thing that creates them -- which is what makes the mode assertions
mean anything.  Logging is off: these tests are not about it, and the
unparsable-file case logs at a level that would otherwise print."
  (declare (indent 0) (debug body))
  (let ((root (make-symbol "root")))
    `(let* ((,root (file-name-as-directory (make-temp-file "benedict-auth-" t)))
            (benedict-auth-file
             (expand-file-name "config/benedict/auth.json" ,root))
            (benedict-log-level nil)
            (benedict-log-echo-level nil))
       (unwind-protect (progn ,@body)
         (delete-directory ,root t)))))

(defmacro benedict-auth-test--with-provider (auth &rest body)
  "Register a provider whose `:auth' is AUTH, evaluate BODY, then remove it."
  (declare (indent 1) (debug (form body)))
  `(unwind-protect
       (progn
         (benedict-defprovider benedict-test-auth-provider
           :name "Auth test provider"
           :base-url "https://example.invalid/v1"
           :api 'benedict-test-auth-api
           :auth ,auth)
         ,@body)
     (benedict-provider-unregister 'benedict-test-auth-provider)))

(defmacro benedict-auth-test--with-environment (settings &rest body)
  "Evaluate BODY with SETTINGS, a list of \"NAME=VALUE\" strings, in the environment.
`process-environment' is rebound rather than mutated, so nothing leaks
into the next test or into the process that runs the suite."
  (declare (indent 1) (debug (form body)))
  `(let ((process-environment (append ,settings process-environment)))
     ,@body))

(defun benedict-auth-test--write (json)
  "Write JSON, a string, to the credential file, creating its directory."
  (let ((directory (file-name-directory benedict-auth-file)))
    (unless (file-directory-p directory)
      (make-directory directory t)))
  (write-region json nil benedict-auth-file nil 'silent))

(defun benedict-auth-test--resolve (provider)
  "Resolve PROVIDER and return the (AUTH ERROR) list its callback received."
  (let ((received 'never-called))
    (benedict-auth-resolve provider
                           (lambda (auth error) (setq received (list auth error))))
    received))

(defconst benedict-auth-test-legacy-json
  "{\"gemini\":{\"oauth\":{\"access\":\"a-token\",\"refresh\":\"r-token\",\
\"scopes\":[\"one\",\"two\"],\"verified\":true,\"revoked\":null}}}"
  "A credential file in a shape this version does not know.

Modelled on the entry in the developer's real file: an older writer nested
the credential under a key of its own instead of tagging it with a
SPEC-001 8.2 `type'.  It carries an array, a boolean, and a null so that
preserving it means preserving JSON types and not merely strings.")

;;;; Exit criterion: a credential round-trips and resolves

(ert-deftest benedict-auth-stores-a-key-and-resolves-it ()
  "Storing an API key and resolving the provider yields that key."
  (benedict-auth-test--with-file
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Test key" :env '("BENEDICT_TEST_KEY"))
      (benedict-auth-set-api-key 'benedict-test-auth-provider "sk-stored")
      (should (equal (benedict-auth-credential-api-key
                      (benedict-auth-read 'benedict-test-auth-provider))
                     "sk-stored"))
      (should (equal (benedict-auth-test--resolve 'benedict-test-auth-provider)
                     '((:api-key "sk-stored") nil))))))

;;;; The file on disk

(ert-deftest benedict-auth-writes-the-file-unreadable-to-anyone-else ()
  "A credential file readable by other users is a leaked credential."
  (benedict-auth-test--with-file
    (benedict-auth-set-api-key 'benedict-test-auth-provider "sk-secret")
    (should (equal (file-modes benedict-auth-file) #o600))
    (should (equal (file-modes (file-name-directory benedict-auth-file)) #o700))))

(ert-deftest benedict-auth-modify-is-given-the-current-credential ()
  "The read half of read-modify-write happens inside the lock, not before it."
  (benedict-auth-test--with-file
    (let ((seen 'never-called))
      (benedict-auth-set-api-key 'benedict-test-auth-provider "first")
      (benedict-auth-modify 'benedict-test-auth-provider
                            (lambda (current)
                              (setq seen current)
                              (benedict-auth-api-key-credential "second")))
      (should (equal (benedict-auth-credential-api-key seen) "first"))
      (should (equal (benedict-auth-credential-api-key
                      (benedict-auth-read 'benedict-test-auth-provider))
                     "second")))))

(ert-deftest benedict-auth-modify-passes-the-new-credential-to-its-callback ()
  (benedict-auth-test--with-file
    (let ((received 'never-called))
      (benedict-auth-set-api-key 'benedict-test-auth-provider "sk-1"
                                 (lambda (credential) (setq received credential)))
      (should (equal (benedict-auth-credential-api-key received) "sk-1")))))

(ert-deftest benedict-auth-delete-removes-only-its-own-entry ()
  (benedict-auth-test--with-file
    (benedict-auth-set-api-key 'one "sk-one")
    (benedict-auth-set-api-key 'two "sk-two")
    (benedict-auth-delete 'one)
    (should-not (benedict-auth-read 'one))
    (should (equal (benedict-auth-credential-api-key (benedict-auth-read 'two))
                   "sk-two"))))

(ert-deftest benedict-auth-read-returns-nil-for-a-provider-with-nothing-stored ()
  (benedict-auth-test--with-file
    (should-not (benedict-auth-read 'benedict-test-auth-provider))
    (should-not (benedict-auth-list))))

;;;; Entries this version does not understand

(ert-deftest benedict-auth-preserves-entries-it-does-not-understand ()
  "Writing one credential must not discard another that could not be read.

The failure this prevents is total: storing an API key would delete an
OAuth login written by a newer version, and nothing would say so until
the next time that provider was used."
  (benedict-auth-test--with-file
    (benedict-auth-test--write benedict-auth-test-legacy-json)
    (let ((before (benedict-auth-read 'gemini)))
      (benedict-auth-set-api-key 'benedict-test-auth-provider "sk-new")
      (should (equal (benedict-auth-read 'gemini) before))
      ;; Not merely present: the array, the boolean, and the null all came
      ;; back as themselves rather than as strings or as nil.
      (let ((oauth (plist-get (benedict-auth-read 'gemini) :oauth)))
        (should (equal (plist-get oauth :scopes) ["one" "two"]))
        (should (eq (plist-get oauth :verified) t))
        (should (eq (plist-get oauth :revoked) :null))))))

(ert-deftest benedict-auth-ignores-an-entry-in-a-shape-it-does-not-know ()
  "An unreadable entry is not a credential, so it does not own its provider.

It cannot be used and it cannot be reported as a mismatch either, because
nothing here knows what it is.  Resolution therefore continues to the
environment, and never signals."
  (benedict-auth-test--with-file
    (benedict-auth-test--write benedict-auth-test-legacy-json)
    (should-not (benedict-auth-credential-type (benedict-auth-read 'gemini)))
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Gemini key" :env '("BENEDICT_TEST_KEY"))
      (benedict-auth-test--with-environment '("BENEDICT_TEST_KEY=sk-env")
        (should (equal (benedict-auth-test--resolve 'benedict-test-auth-provider)
                       '((:api-key "sk-env") nil)))))))

(ert-deftest benedict-auth-list-reports-what-it-cannot-read ()
  "An entry with no recognizable type is listed with a nil type, not hidden.
A credential the user believes is stored, and that nothing can use, is
worth being able to see."
  (benedict-auth-test--with-file
    (benedict-auth-test--write benedict-auth-test-legacy-json)
    (should (equal (benedict-auth-list) '((:provider gemini :type nil))))))

;;;; Listing leaks nothing

(ert-deftest benedict-auth-list-shows-no-secrets ()
  "`benedict-auth-list' is the safe half of the store, and has to stay safe.
Its output is meant for a user, a frontend, or a model."
  (benedict-auth-test--with-file
    (benedict-auth-set-api-key 'one "sk-do-not-print-me")
    (benedict-auth-modify 'two (lambda (_)
                                 (list :type "oauth" :access "at" :refresh "refresh-do-not-print-me"
                                       :expires 1785000000)))
    (let ((printed (format "%S" (benedict-auth-list))))
      (should-not (string-match-p "sk-do-not-print-me" printed))
      (should-not (string-match-p "refresh-do-not-print-me" printed)))
    (should (equal (benedict-auth-list)
                   '((:provider one :type api-key)
                     (:provider two :type oauth :expires 1785000000))))))

;;;; Where a credential may come from, and in what order

(ert-deftest benedict-auth-consults-the-environment-only-when-nothing-is-stored ()
  (benedict-auth-test--with-file
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Test key" :env '("BENEDICT_TEST_KEY"))
      (benedict-auth-test--with-environment '("BENEDICT_TEST_KEY=sk-env")
        (should (equal (benedict-auth-test--resolve 'benedict-test-auth-provider)
                       '((:api-key "sk-env") nil)))
        (benedict-auth-set-api-key 'benedict-test-auth-provider "sk-stored")
        (should (equal (benedict-auth-test--resolve 'benedict-test-auth-provider)
                       '((:api-key "sk-stored") nil)))))))

(ert-deftest benedict-auth-reads-environment-variables-in-order ()
  "The first variable that is set and non-empty wins; an empty one is unset."
  (benedict-auth-test--with-file
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Test key"
                                   :env '("BENEDICT_TEST_FIRST"
                                          "BENEDICT_TEST_SECOND"))
      (benedict-auth-test--with-environment '("BENEDICT_TEST_FIRST=sk-first"
                                              "BENEDICT_TEST_SECOND=sk-second")
        (should (equal (car (benedict-auth-test--resolve
                             'benedict-test-auth-provider))
                       '(:api-key "sk-first"))))
      (benedict-auth-test--with-environment '("BENEDICT_TEST_FIRST="
                                              "BENEDICT_TEST_SECOND=sk-second")
        (should (equal (car (benedict-auth-test--resolve
                             'benedict-test-auth-provider))
                       '(:api-key "sk-second")))))))

(ert-deftest benedict-auth-does-not-fall-back-after-a-usable-credential ()
  "A stored credential of the wrong kind is an error, not a reason to guess.

Falling through to the environment here would authenticate the request as
whatever account happens to be exported -- an error that succeeds, which
is far harder to diagnose than one that fails."
  (benedict-auth-test--with-file
    (benedict-auth-modify 'benedict-test-auth-provider
                          (lambda (_) (list :type "oauth" :access "at")))
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Test key" :env '("BENEDICT_TEST_KEY"))
      (benedict-auth-test--with-environment '("BENEDICT_TEST_KEY=sk-env")
        (pcase-let ((`(,auth ,error)
                     (benedict-auth-test--resolve 'benedict-test-auth-provider)))
          (should-not auth)
          (should (eq (plist-get error :reason) 'mismatch)))))))

(ert-deftest benedict-auth-reports-an-unparsable-file-rather-than-guessing ()
  "Credentials that exist and cannot be reached are not the same as none."
  (benedict-auth-test--with-file
    (benedict-auth-test--write "{ this is not json")
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Test key" :env '("BENEDICT_TEST_KEY"))
      (benedict-auth-test--with-environment '("BENEDICT_TEST_KEY=sk-env")
        (pcase-let ((`(,auth ,error)
                     (benedict-auth-test--resolve 'benedict-test-auth-provider)))
          (should-not auth)
          (should (eq (plist-get error :reason) 'unreadable))
          (should (string-match-p "auth.json" (plist-get error :error))))))
    ;; The reading half is quiet about it, so that a frontend listing
    ;; credentials does not signal on a file it did not write.
    (should-not (benedict-auth-read 'benedict-test-auth-provider))
    (should-not (benedict-auth-list))))

;;;; The resolution contract

(ert-deftest benedict-auth-reports-a-missing-credential-through-the-callback ()
  "Resolution never signals for a missing credential; its caller is a stream.

The message has to be actionable: it names the credential and the
environment variable, because the person reading it is being asked to
supply one."
  (benedict-auth-test--with-file
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Vercel AI Gateway API key"
                                   :env '("BENEDICT_TEST_KEY"))
      (pcase-let ((`(,auth ,error)
                   (benedict-auth-test--resolve 'benedict-test-auth-provider)))
        (should-not auth)
        (should (eq (plist-get error :reason) 'missing))
        (should (string-match-p "Vercel AI Gateway API key" (plist-get error :error)))
        (should (string-match-p "BENEDICT_TEST_KEY" (plist-get error :error)))))))

(ert-deftest benedict-auth-resolves-a-provider-that-needs-nothing ()
  "The fake provider authenticates nothing, and that is a success, not a gap."
  (benedict-auth-test--with-file
    (benedict-auth-test--with-provider nil
      (should (equal (benedict-auth-test--resolve 'benedict-test-auth-provider)
                     '(nil nil))))))

(ert-deftest benedict-auth-accepts-a-provider-struct-or-an-id ()
  (benedict-auth-test--with-file
    (benedict-auth-test--with-provider
        (benedict-auth-env-api-key :name "Test key" :env '("BENEDICT_TEST_KEY"))
      (benedict-auth-test--with-environment '("BENEDICT_TEST_KEY=sk-env")
        (should (equal (benedict-auth-test--resolve
                        (benedict-provider-get 'benedict-test-auth-provider))
                       (benedict-auth-test--resolve
                        'benedict-test-auth-provider)))))))

(ert-deftest benedict-auth-signals-for-a-provider-that-is-not-registered ()
  "An unregistered provider is a programming error, not a credential problem."
  (benedict-auth-test--with-file
    (should-error (benedict-auth-resolve 'benedict-test-no-such-provider #'ignore)
                  :type 'benedict-provider-unknown)))

;;;; The auth value type

(ert-deftest benedict-auth-refuses-a-value-with-a-fourth-field ()
  "SPEC-001 8.1 permits three keys, and the fourth is always plausible.

An organization id, a region, a model prefix: each is provider
configuration wearing an auth costume, and each is how this layer becomes
a settings dumping ground."
  (should (equal (benedict-auth-check-value '(:api-key "k")) '(:api-key "k")))
  (should (benedict-auth-check-value
           '(:api-key "k" :headers (("X-Foo" . "bar")) :base-url "https://x")))
  (should-error (benedict-auth-check-value '(:api-key "k" :organization "acme"))
                :type 'benedict-auth-invalid-value))

;;;; OAuth: registered, not yet resolvable

(ert-deftest benedict-auth-registers-an-oauth-method-with-its-split-intact ()
  "The `refresh'/`to-auth' split is what a provider is written against.
SPEC-001 8.7 designs it in now because retrofitting it means rewriting
every provider that guessed at the boundary."
  (unwind-protect
      (let ((method (benedict-defoauth benedict-test-oauth
                      :name "Test OAuth"
                      :subscription-p t
                      :login #'ignore
                      :refresh #'ignore
                      :to-auth (lambda (_credential) '(:api-key "derived")))))
        (should (eq (benedict-auth-oauth-get 'benedict-test-oauth) method))
        (should (benedict-auth-oauth-subscription-p method))
        (should (functionp (benedict-auth-oauth-refresh method)))
        (should (equal (funcall (benedict-auth-oauth-to-auth method) nil)
                       '(:api-key "derived"))))
    (benedict-auth-oauth-unregister 'benedict-test-oauth)))

(ert-deftest benedict-auth-says-oauth-is-not-implemented-yet ()
  "An OAuth provider fails through the callback with a reason, not a signal."
  (benedict-auth-test--with-file
    (benedict-auth-test--with-provider
        (benedict-auth-oauth-method 'benedict-test-oauth :name "Test OAuth")
      (pcase-let ((`(,auth ,error)
                   (benedict-auth-test--resolve 'benedict-test-auth-provider)))
        (should-not auth)
        (should (eq (plist-get error :reason) 'unsupported))))))

;;;; The interaction protocol

(ert-deftest benedict-auth-prompt-reaches-the-frontend-that-supplied-it ()
  "SPEC-001 8.5: the flow describes what it needs and never touches Emacs UI.
A test supplies a scripted answer exactly as a frontend supplies a real
one, which is the property that makes a login flow testable at all."
  (let ((asked nil)
        (answer nil))
    (benedict-auth-prompt
     (list :prompt (lambda (request)
                     (setq asked request)
                     (funcall (plist-get request :callback) "typed")))
     :type 'secret :message "Enter API key"
     :callback (lambda (value) (setq answer value)))
    (should (eq (plist-get asked :type) 'secret))
    (should (equal (plist-get asked :message) "Enter API key"))
    (should (equal answer "typed"))))

(ert-deftest benedict-auth-prompt-declines-when-nobody-is-listening ()
  "A headless caller gets nil, which a flow must read as a cancellation."
  (let ((answer 'never-called))
    (benedict-test-with-quiet-log
      (benedict-auth-prompt nil :type 'text :message "Who?"
                            :callback (lambda (value) (setq answer value))))
    (should-not answer)))

(ert-deftest benedict-auth-notify-does-not-need-a-frontend ()
  (let ((told nil))
    (should-not (benedict-auth-notify
                 (list :notify (lambda (message) (setq told message)))
                 :type 'auth-url :url "https://example.invalid/authorize"))
    (should (eq (plist-get told :type) 'auth-url))
    (benedict-test-with-quiet-log
      (should-not (benedict-auth-notify nil :type 'info :message "no frontend")))))

;;;; Locking

(ert-deftest benedict-auth-holds-the-lock-across-read-modify-write ()
  "The lock is held while FUNCTION runs, which is what serializes a refresh."
  (benedict-auth-test--with-file
    (let ((lock (concat benedict-auth-file ".lock"))
          (held nil))
      (benedict-auth-modify 'benedict-test-auth-provider
                            (lambda (_current)
                              (setq held (file-directory-p lock))
                              (benedict-auth-api-key-credential "sk-1")))
      (should held)
      (should-not (file-exists-p lock)))))

(ert-deftest benedict-auth-releases-the-lock-when-modify-signals ()
  "A failed write must not leave the credentials permanently unwritable."
  (benedict-auth-test--with-file
    (let ((lock (concat benedict-auth-file ".lock")))
      (should-error (benedict-auth-modify 'benedict-test-auth-provider
                                          (lambda (_) (error "Refresh failed")))
                    :type 'error)
      (should-not (file-exists-p lock))
      (should-not (benedict-auth-read 'benedict-test-auth-provider)))))

(ert-deftest benedict-auth-signals-when-another-process-holds-the-lock ()
  (benedict-auth-test--with-file
    (let ((lock (concat benedict-auth-file ".lock"))
          (benedict-auth-lock-timeout 0.1))
      (make-directory lock t)
      (unwind-protect
          (should-error (benedict-auth-set-api-key 'benedict-test-auth-provider "x")
                        :type 'benedict-auth-locked)
        (delete-directory lock t)))))

(ert-deftest benedict-auth-breaks-a-lock-that-was-abandoned ()
  "An Emacs that died holding the lock must not wedge credentials forever.
That failure needs one process to have crashed; the race the lock exists
for needs two to refresh the same token in the same moment."
  (benedict-auth-test--with-file
    (let ((lock (concat benedict-auth-file ".lock"))
          (benedict-auth-lock-timeout 0.1)
          (benedict-auth-lock-stale-seconds 60))
      (make-directory lock t)
      (set-file-times lock (time-subtract nil 3600))
      (benedict-auth-set-api-key 'benedict-test-auth-provider "sk-after")
      (should (equal (benedict-auth-credential-api-key
                      (benedict-auth-read 'benedict-test-auth-provider))
                     "sk-after"))
      (should-not (file-exists-p lock)))))

(provide 'benedict-auth-test)

;;; benedict-auth-test.el ends here
