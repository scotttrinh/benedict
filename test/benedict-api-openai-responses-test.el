;;; benedict-api-openai-responses-test.el --- Tests for the Responses adapter  -*- lexical-binding: t; -*-

;;; Commentary:

;; The adapter is tested by replaying the recorded fixtures in
;; `test/fixtures/' through the same path `benedict-api-stream' takes: the SSE
;; framer delivers events to the parser, and the parser returns the normalized
;; event vocabulary the kernel understands.  No socket is opened and no
;; credential is read — the fixtures are real captured bytes (SPEC-001 12.5),
;; and asserting on the events they produce is what keeps the adapter working
;; after the wire format changes, without spending tokens.
;;
;; The hardest property — and the one with a dedicated test — is that BLOCK
;; STATE IS KEYED ON `output_index', not on arrival order.  Two of five
;; models in the spike opened a function_call item while a message was still
;; streaming, and a single "current block" pointer produced garbage there
;; (SPEC-001 7.4.1).  The interleaved tool-call fixture is the captured
;; evidence.
;;
;; Request bodies are round-tripped through `json-serialize' rather than
;; compared as plists, because SPEC-001 6.1 is explicit that a plist
;; satisfying `equal' can still fail at request time (nil serializes to {},
;; not null).
;;
;; See SPEC-001 7.3, 7.4, 7.4.1, 7.8.5.

;;; Code:

(require 'ert)
(require 'json)
(require 'test-helper)

;;;; Fixture replay

(defun benedict-api-openai-responses-test--replay (fixture-name)
  "Return the normalized events from replaying FIXTURE-NAME through the adapter."
  (let ((parser (benedict-api-openai-responses--make-parser))
        (events nil))
    (let ((framer (benedict-http-sse-parser
                   (lambda (type data)
                     (let ((result (funcall parser
                                            (list :event type :data data))))
                       (setq events (append events result)))))))
      (funcall framer (benedict-test-fixture-contents fixture-name))
      (funcall framer nil))
    events))

(defun benedict-api-openai-responses-test--events-of-type (events type)
  "Return the members of EVENTS whose `:type' is TYPE."
  (seq-filter (lambda (e) (eq (plist-get e :type) type)) events))

(defun benedict-api-openai-responses-test--terminal (events)
  "Return the single terminal event in EVENTS."
  (car (benedict-api-openai-responses-test--events-of-type
        events :done)))

;;;;; Exit criterion: the text fixture produces the right events

(ert-deftest benedict-api-openai-responses-text-fixture-starts-with-response-id ()
  "The `:start' event carries the response id from `response.created'."
  (let ((start (car (benedict-api-openai-responses-test--events-of-type
                     (benedict-api-openai-responses-test--replay
                      "openai-responses-text.sse")
                     :start))))
    (should (plist-member start :response-id))
    (should (string-prefix-p "gen_" (plist-get start :response-id)))))

(ert-deftest benedict-api-openai-responses-text-fixture-emits-thinking-then-text ()
  "The text fixture emits a thinking block (index 0) then a text block (index 1)."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-text.sse"))
         (starts (benedict-api-openai-responses-test--events-of-type
                  events :block-start)))
    (should (= (length starts) 2))
    (should (eq (plist-get (nth 0 starts) :block-type) 'thinking))
    (should (eq (plist-get (nth 1 starts) :block-type) 'text))
    (should (= (plist-get (nth 0 starts) :index) 0))
    (should (= (plist-get (nth 1 starts) :index) 1))))

(ert-deftest benedict-api-openai-responses-text-fixture-accumulates-text-deltas ()
  "Text deltas concatenate into the final answer."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-text.sse"))
         (deltas (seq-filter
                  (lambda (e)
                    (and (eq (plist-get e :type) :block-delta)
                         (= (plist-get e :index) 1)))
                  events)))
    (should (string= (apply #'concat
                            (mapcar (lambda (e) (plist-get e :delta)) deltas))
                     "pong"))))

(ert-deftest benedict-api-openai-responses-text-fixture-done-has-usage ()
  "The terminal event carries uncached usage (SPEC-001 7.4)."
  (let ((done (benedict-api-openai-responses-test--terminal
               (benedict-api-openai-responses-test--replay
                "openai-responses-text.sse"))))
    (should (eq (plist-get done :reason) 'stop))
    (should (equal (plist-get done :usage)
                   '(:input 10 :output 39 :cache-read 0)))))

(ert-deftest benedict-api-openai-responses-thinking-block-carries-item-id-in-signature ()
  "A reasoning item's id becomes the thinking block's signature (SPEC-001 7.4).

DeepSeek returns no `encrypted_content' — only an id — so the signature
carries the item id without one."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-text.sse"))
         (end (car (seq-filter
                    (lambda (e)
                      (and (eq (plist-get e :type) :block-end)
                           (= (plist-get e :index) 0)))
                    events))))
    (should (plist-member end :signature))
    (let ((sig (plist-get end :signature)))
      (should (string-prefix-p "rs_" (plist-get sig :item-id))))))

;;;;; The interleaved tool-call fixture

(ert-deftest benedict-api-openai-responses-tool-call-opens-block-while-another-is-open ()
  "A function_call opens at output_index 2 while index 1 is still streaming.

This is the sharp case from SPEC-001 7.4.1: items interleave, and a parser
that keeps a single current-block pointer produces garbage.  The test asserts
that the block-start at index 2 arrives BEFORE the block-end at index 1."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-tool-call.sse"))
         (types (mapcar (lambda (e)
                          (cons (plist-get e :type)
                                (plist-get e :index)))
                        events))
         (start-2-pos (seq-position types '(:block-start . 2)
                                    (lambda (a b) (and (eq (car a) (car b))
                                                       (= (cdr a) (cdr b))))))
         (end-1-pos (seq-position types '(:block-end . 1)
                                  (lambda (a b) (and (eq (car a) (car b))
                                                     (= (cdr a) (cdr b)))))))
    (should start-2-pos)
    (should end-1-pos)
    (should (< start-2-pos end-1-pos))))

(ert-deftest benedict-api-openai-responses-tool-call-emits-parsed-arguments ()
  "Tool-call arguments are assembled and parsed before block-end (SPEC-001 7.3)."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-tool-call.sse"))
         (end (car (seq-filter
                    (lambda (e)
                      (and (eq (plist-get e :type) :block-end)
                           (eq (plist-get e :index) 2)))
                    events))))
    (should (equal (plist-get end :arguments)
                   '(:form "(+ 1 2)")))
    (should (plist-member end :id))
    (should (string-prefix-p "call_" (plist-get end :id)))))

(ert-deftest benedict-api-openai-responses-tool-call-reason-is-tool-use ()
  "A turn that called a tool ends with reason `tool-use'."
  (let ((done (benedict-api-openai-responses-test--terminal
               (benedict-api-openai-responses-test--replay
                "openai-responses-tool-call.sse"))))
    (should (eq (plist-get done :reason) 'tool-use))))

;;;;; The reasoning-summary fixture (Grok)

(ert-deftest benedict-api-openai-responses-reasoning-summary-carries-encrypted-content ()
  "The Grok reasoning-summary family produces a signature with encrypted_content.

This is the reasoning-continuity payload: item id plus encrypted content,
stored as a plist in the thinking block's `:signature' so it round-trips
through the store and can be re-emitted in the next request's input."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-reasoning-summary.sse"))
         (end (car (seq-filter
                    (lambda (e)
                      (and (eq (plist-get e :type) :block-end)
                           (= (plist-get e :index) 0)))
                    events))))
    (should (plist-member end :signature))
    (let ((sig (plist-get end :signature)))
      (should (string-prefix-p "rs_" (plist-get sig :item-id)))
      (should (stringp (plist-get sig :encrypted-content)))
      (should (< 0 (length (plist-get sig :encrypted-content)))))))

(ert-deftest benedict-api-openai-responses-reasoning-summary-handles-hyphenated-call-id ()
  "Grok's call_id uses hyphens and is 44 characters (SPEC-001 7.4.1).
The adapter does not constrain call_id shape — it stores whatever the
stream sent."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-reasoning-summary.sse"))
         (start (car (seq-filter
                      (lambda (e)
                       (and (eq (plist-get e :type) :block-start)
                            (eq (plist-get e :block-type) 'tool-call)))
                      events))))
    (should (string-prefix-p "call-" (plist-get start :id)))))

;;;;; The no-reasoning fixture

(ert-deftest benedict-api-openai-responses-no-reasoning-emits-no-thinking-block ()
  "A model tagged `reasoning' may emit no reasoning items (SPEC-001 7.4.1)."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-no-reasoning.sse"))
         (starts (benedict-api-openai-responses-test--events-of-type
                  events :block-start)))
    (should (= (length starts) 1))
    (should (eq (plist-get (car starts) :block-type) 'tool-call))))

(ert-deftest benedict-api-openai-responses-no-reasoning-assembles-character-deltas ()
  "Argument deltas arriving one character at a time assemble correctly."
  (let* ((events (benedict-api-openai-responses-test--replay
                  "openai-responses-no-reasoning.sse"))
         (end (car (seq-filter
                    (lambda (e)
                      (and (eq (plist-get e :type) :block-end)
                           (= (plist-get e :index) 0)))
                    events))))
    (should (equal (plist-get end :arguments)
                   '(:form "(+ 1 2)")))))

;;;;; The tool-result continuation fixture

(ert-deftest benedict-api-openai-responses-subtracts-cached-tokens-from-input ()
  "Usage subtracts `cached_tokens' from `input_tokens' (SPEC-001 7.4).
The continuation fixture reports 468 input with 256 cached."
  (let ((done (benedict-api-openai-responses-test--terminal
               (benedict-api-openai-responses-test--replay
                "openai-responses-tool-result-continuation.sse"))))
    (should (equal (plist-get done :usage)
                   '(:input 212 :output 7 :cache-read 256)))))

;;;; Golden request bodies

(defun benedict-api-openai-responses-test--model ()
  "Return a model for the openai-responses API over the vercel-ai-gateway provider."
  (benedict-model-create
   :id "deepseek/deepseek-v4-flash-0731"
   :name "Test"
   :provider 'vercel-ai-gateway
   :api 'openai-responses))

(ert-deftest benedict-api-openai-responses-build-round-trips-through-json ()
  "The build output is valid JSON with the expected top-level keys.
SPEC-001 6.1: round-trip through `json-serialize', not plist comparison."
  (let* ((body (benedict-api-openai-responses--build
                (list :entries (list (benedict-test-entry 'user "Hello"))
                      :system-prompt "Be brief."
                      :tools nil)
                (benedict-api-openai-responses-test--model)))
         (json (json-parse-string body
                                  :object-type 'plist
                                  :null-object nil :false-object nil)))
    (should (equal (plist-get json :model) "deepseek/deepseek-v4-flash-0731"))
    (should (equal (plist-get json :instructions) "Be brief."))
    (should (eq (plist-get json :stream) t))
    (should-not (plist-get json :store))))

(ert-deftest benedict-api-openai-responses-build-omits-instructions-when-absent ()
  "No `:instructions' key when the request carries no system prompt."
  (let* ((body (benedict-api-openai-responses--build
                (list :entries (list (benedict-test-entry 'user "Hi"))
                      :tools nil)
                (benedict-api-openai-responses-test--model)))
         (json (json-parse-string body
                                  :object-type 'plist
                                  :null-object nil :false-object nil)))
    (should-not (plist-member json :instructions))))

(ert-deftest benedict-api-openai-responses-build-serializes-user-input-text ()
  "A user entry serializes as a message item with `input_text' content."
  (let* ((body (benedict-api-openai-responses--build
                (list :entries (list (benedict-test-entry 'user "Hello world"))
                      :tools nil)
                (benedict-api-openai-responses-test--model)))
         (json (json-parse-string body
                                  :object-type 'plist
                                  :null-object nil :false-object nil))
         (input (append (plist-get json :input) nil))
         (item (car input)))
    (should (equal (plist-get item :type) "message"))
    (should (equal (plist-get item :role) "user"))
    (let ((content (append (plist-get item :content) nil)))
      (should (equal (plist-get (car content) :type) "input_text"))
      (should (equal (plist-get (car content) :text) "Hello world")))))

;;;;; Reasoning continuity

(ert-deftest benedict-api-openai-responses-build-echoes-reasoning-signature ()
  "A same-origin thinking block's signature produces a reasoning input item.

The item carries the id and encrypted_content, which is what maintains
reasoning continuity across turns when `store' is false (SPEC-001 7.4)."
  (let* ((model (benedict-api-openai-responses-test--model))
         (entry (benedict-entry-create
                 :role 'assistant
                 :content (list (benedict-block-thinking
                                 "Let me think."
                                 :signature '(:item-id "rs_test123"
                                              :encrypted-content "enc-blob"))
                        (benedict-block-text "Answer."))
                 :meta (list :provider 'vercel-ai-gateway
                             :api 'openai-responses
                             :model "deepseek/deepseek-v4-flash-0731")))
         (body (benedict-api-openai-responses--build
                (list :entries (list entry)
                      :tools nil)
                model))
         (json (json-parse-string body
                                  :object-type 'plist
                                  :null-object nil :false-object nil))
         (input (append (plist-get json :input) nil))
         (reasoning (seq-find (lambda (item)
                                (equal (plist-get item :type) "reasoning"))
                              input)))
    (should reasoning)
    (should (equal (plist-get reasoning :id) "rs_test123"))
    (should (equal (plist-get reasoning :encrypted_content) "enc-blob"))))

;;;;; Tool call round-trip

(ert-deftest benedict-api-openai-responses-build-serializes-tool-call-and-result ()
  "A tool-call block and matching result serialize as function_call and output."
  (let* ((model (benedict-api-openai-responses-test--model))
         (assistant (benedict-entry-create
                     :role 'assistant
                     :content (list (benedict-block-text "")
                                    (benedict-block-tool-call
                                     "call_test123"
                                     'eval-elisp
                                     '(:form "(+ 1 2)")
                                     :signature "fc_item456"))
                     :meta (list :provider 'vercel-ai-gateway
                                 :api 'openai-responses
                                 :model "deepseek/deepseek-v4-flash-0731")))
         (result (benedict-entry-create
                  :role 'tool-result
                  :content (list (benedict-block-tool-result
                                  "call_test123"
                                  'eval-elisp
                                  "3"))))
         (body (benedict-api-openai-responses--build
                (list :entries (list assistant result)
                      :tools nil)
                model))
         (json (json-parse-string body
                                  :object-type 'plist
                                  :null-object nil :false-object nil))
         (input (append (plist-get json :input) nil))
         (call (seq-find (lambda (item)
                           (equal (plist-get item :type) "function_call"))
                         input))
         (output (seq-find (lambda (item)
                             (equal (plist-get item :type) "function_call_output"))
                           input)))
    (should call)
    (should (equal (plist-get call :id) "fc_item456"))
    (should (equal (plist-get call :call_id) "call_test123"))
    (should (equal (plist-get call :name) "eval-elisp"))
    (should output)
    (should (equal (plist-get output :call_id) "call_test123"))
    (should (equal (plist-get output :output) "3"))))

(ert-deftest benedict-api-openai-responses-build-synthesizes-fc-id-for-foreign-call ()
  "A tool call with no signature (foreign, stripped by lowering) gets a
synthetic `fc_'-prefixed id derived from a hash of the call id."
  (let* ((model (benedict-model-create
                 :id "other/model"
                 :name "Other"
                 :provider 'other-provider
                 :api 'openai-responses))
         ;; This entry has a foreign origin, so lowering strips the signature.
         ;; But here we test the serializer directly: it should synthesize
         ;; an fc_ id when the signature is absent.
         (entry (benedict-entry-create
                 :role 'assistant
                 :content (list (benedict-block-tool-call
                                 "call_abc"
                                 'some-tool
                                 '(:x 1)))))
         (body (benedict-api-openai-responses--build
                (list :entries (list entry)
                      :tools nil)
                model))
         (json (json-parse-string body
                                  :object-type 'plist
                                  :null-object nil :false-object nil))
         (input (append (plist-get json :input) nil))
         (call (seq-find (lambda (item)
                           (equal (plist-get item :type) "function_call"))
                         input)))
    (should call)
    (should (string-prefix-p "fc_" (plist-get call :id)))
    (should (equal (plist-get call :call_id) "call_abc"))))

;;;;; Tools

(ert-deftest benedict-api-openai-responses-build-serializes-tools ()
  "Tools serialize as flat function definitions (SPEC-001 7.4)."
  (let* ((tool (benedict-tool-create
                :id 'eval-elisp
                :description "Evaluate elisp"
                :parameters '((form :type string :required t))
                :handler (lambda (_invocation))))
         (body (benedict-api-openai-responses--build
                (list :entries (list (benedict-test-entry 'user "Hi"))
                      :tools (list tool))
                (benedict-api-openai-responses-test--model)))
         (json (json-parse-string body
                                  :object-type 'plist
                                  :null-object nil :false-object nil))
         (tools (append (plist-get json :tools) nil))
         (fn (car tools)))
    (should (= (length tools) 1))
    (should (equal (plist-get fn :type) "function"))
    (should (equal (plist-get fn :name) "eval-elisp"))))

;;;; Endpoint and headers

(ert-deftest benedict-api-openai-responses-endpoint-appends-responses-path ()
  (should (equal (benedict-api-openai-responses--endpoint
                  nil '(:base-url "https://example.invalid/v1"))
                 "https://example.invalid/v1/responses")))

(ert-deftest benedict-api-openai-responses-headers-include-bearer-token ()
  (let ((headers (benedict-api-openai-responses--headers
                  nil '(:api-key "sk-test"))))
    (should (equal (cdr (assoc "Authorization" headers)) "Bearer sk-test"))
    (should (equal (cdr (assoc "content-type" headers)) "application/json"))))

;;;; Parser robustness

(ert-deftest benedict-api-openai-responses-parser-ignores-unknown-event-types ()
  "An unknown event type produces no events rather than signalling."
  (let ((parser (benedict-api-openai-responses--make-parser)))
    (should-not (funcall parser
                         (list :event "response.unknown_future_event"
                               :data "{\"type\":\"response.unknown_future_event\"}")))))

(ert-deftest benedict-api-openai-responses-parser-ignores-data-only-frame ()
  "A data-only SSE frame (nil event type) produces nothing."
  (let ((parser (benedict-api-openai-responses--make-parser)))
    (should-not (funcall parser (list :event nil :data "[DONE]")))))

(ert-deftest benedict-api-openai-responses-parser-ignores-malformed-json ()
  "Malformed JSON data does not signal; the parser returns nil."
  (let ((parser (benedict-api-openai-responses--make-parser)))
    (should-not (funcall parser
                         (list :event "response.created"
                               :data "not json at all")))))

(provide 'benedict-api-openai-responses-test)

;;; benedict-api-openai-responses-test.el ends here
