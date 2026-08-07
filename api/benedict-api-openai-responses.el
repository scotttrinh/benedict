;;; benedict-api-openai-responses.el --- The OpenAI Responses wire adapter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Scott Trinh

;; Author: Scott Trinh <scott@scotttrinh.com>
;; Keywords: tools, convenience, ai
;; URL: https://github.com/scotttrinh/benedict

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The first — and for v1, the only — wire protocol adapter.  Vercel AI
;; Gateway serves its entire catalog through the OpenAI Responses API across
;; `/v1/responses`, including non-OpenAI models (SPEC-001 7.4, D1), so one
;; adapter is the whole requirement.
;;
;; The adapter is four functions registered through `benedict-defapi':
;; `endpoint', `headers', `build', and `make-parser'.  Nothing else in the tree
;; calls them directly — `benedict-api-stream' composes them with auth
;; resolution, the transport, and the terminal-event contract (SPEC-001 7.3).
;; The adapter owns ONLY the protocol: how a canonical request becomes a POST
;; body, and how a Responses SSE stream becomes the normalized event vocabulary.
;;
;; What the adapter does NOT own, because Step 4 already handles it:
;;
;;   - auth resolution, base-url precedence, header/body delivery to curl
;;   - SSE framing (the adapter sees `(:event TYPE :data DATA)', never bytes)
;;   - terminal-event discipline — the adapter may return `[]' from any event,
;;     and anything it returns after a `:done' is dropped
;;   - signalling: a signal from `build' or the parser becomes a terminal
;;     `:error' naming the adapter
;;
;; Two things from the Step 0 spike shape the parser and are where the adapter
;; earns its keep (SPEC-001 7.4.1):
;;
;;   - BLOCK STATE IS KEYED ON `output_index', not on arrival order.  Items
;;     interleave — a function_call opens while a message is still streaming —
;;     and a single "current block" pointer produces garbage in 2 of 5 models.
;;   - BOTH reasoning event families are handled: `response.reasoning.delta'
;;     (DeepSeek, Qwen) and `response.reasoning_summary_text.delta' (Grok).
;;     Neither is the "real" one, and a model tagged `reasoning' may emit
;;     neither.
;;
;; See SPEC-001 7.3, 7.4, 7.4.1, 7.8.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'benedict-provider)
(require 'benedict-message)
(require 'benedict-api-transform)

;;;; Configuration

(defconst benedict-api-openai-responses--path "/responses"
  "Path appended to the base URL for the Responses endpoint.")

;;;; Endpoint and headers

(defun benedict-api-openai-responses--endpoint (_model auth)
  "Return the request URL for MODEL authenticated by AUTH.

The URL is AUTH's `:base-url' with the Responses path.  `_model' is
ignored because the Responses API addresses a model by name in the
request body, not in the URL."
  (concat (plist-get auth :base-url)
          benedict-api-openai-responses--path))

(defun benedict-api-openai-responses--headers (_model auth)
  "Return the HTTP headers for MODEL authenticated by AUTH.

Which header carries a key is a property of the wire protocol, not of the
credential: the Responses API reads a bearer token, so this function reads
`:api-key' off AUTH and builds the `Authorization' header here rather than
in `benedict-auth'."
  (let ((key (plist-get auth :api-key)))
    `(("Authorization" . ,(format "Bearer %s" key))
      ("content-type" . "application/json"))))

;;;; Building the request body

(defun benedict-api-openai-responses--build (request model)
  "Return the JSON request body for REQUEST to MODEL.

REQUEST is the canonical plist the kernel assembles: `:entries' carrying
canonical entries, `:system-prompt', and `:tools'.  Entries are lowered
through `benedict-api-lower' — the shared degradation and repair pass — and
then serialized as typed items in the Responses `input' array.  Tools are
serialized as flat function definitions."
  (let* ((entries (benedict-api-lower (plist-get request :entries) model))
         (items (apply #'append (mapcar
                                 #'benedict-api-openai-responses--entry-items
                                 entries)))
         (system-prompt (plist-get request :system-prompt))
         (tools (plist-get request :tools))
         (body (list :model (benedict-model-id model)
                     :input (if items (vconcat items) (vector))
                     :stream t
                     :store :false)))
    (when system-prompt
      (setq body (plist-put body :instructions system-prompt)))
    (when tools
      (setq body (plist-put body :tools
                            (vconcat (mapcar
                                      #'benedict-api-openai-responses--tool-item
                                      tools)))))
    (json-serialize body :false-object :false)))

;;;;; Serializing entries to input items

(defun benedict-api-openai-responses--entry-items (entry)
  "Return a list of Responses input items for the canonical ENTRY."
  (pcase (benedict-entry-role entry)
    ('user (list (benedict-api-openai-responses--user-item entry)))
    ('assistant (delq nil
                      (mapcar #'benedict-api-openai-responses--block-item
                              (benedict-entry-content entry))))
    ('tool-result
     (delq nil
           (mapcar #'benedict-api-openai-responses--result-item
                   (seq-filter #'benedict-block-tool-result-p
                               (benedict-entry-content entry)))))
    (_ nil)))

(defun benedict-api-openai-responses--user-item (entry)
  "Return the Responses message item for the user ENTRY."
  (list :type "message"
        :role "user"
        :content (vconcat
                  (delq nil
                        (mapcar #'benedict-api-openai-responses--user-part
                                (benedict-entry-content entry))))))

(defun benedict-api-openai-responses--user-part (block)
  "Return the Responses content part for a user BLOCK, or nil to skip."
  (pcase (benedict-block-type block)
    ('text (list :type "input_text" :text (plist-get block :text)))
    ('image (list :type "input_image"
                  :image_url (format "data:%s;base64,%s"
                                     (plist-get block :mime-type)
                                     (plist-get block :data))))))

(defun benedict-api-openai-responses--block-item (block)
  "Return the Responses input item for an assistant BLOCK, or nil to skip.

A thinking block without a `:signature' never survives lowering for a
foreign model (it is degraded to text), and a same-origin thinking block
without a `:signature' has no item id to replay, so both are skipped.

A tool-call block's `:id' is the `call_id' the wire returned — it is what
matches a `function_call_output'.  Its `:signature' is the item `id'
(beginning `fc_').  A same-origin call keeps the signature; a foreign call's
signature is stripped by lowering, so a synthetic `fc_' id is derived from
a hash of the call id.  See SPEC-001 7.8.5."
  (pcase (benedict-block-type block)
    ('thinking
     (when-let* ((signature (plist-get block :signature))
                 (item-id (plist-get signature :item-id)))
       (let ((encrypted (plist-get signature :encrypted-content)))
         (if encrypted
             (list :type "reasoning" :id item-id
                   :encrypted_content encrypted)
           (list :type "reasoning" :id item-id)))))
    ('text
     (list :type "message"
           :role "assistant"
           :content (vector (list :type "output_text"
                                  :text (plist-get block :text)))))
    ('tool-call
     (let ((call-id (plist-get block :id))
           (item-id (or (plist-get block :signature)
                        (benedict-api-openai-responses--synthetic-item-id
                         (plist-get block :id)))))
       (list :type "function_call"
             :id item-id
             :call_id call-id
             :name (symbol-name (plist-get block :name))
             :arguments (json-serialize
                         (or (plist-get block :arguments) '())))))
    (_ nil)))

(defun benedict-api-openai-responses--result-item (block)
  "Return the Responses function_call_output item for a tool-result BLOCK."
  (list :type "function_call_output"
        :call_id (plist-get block :id)
        :output (benedict-api-openai-responses--result-output block)))

(defun benedict-api-openai-responses--result-output (block)
  "Return the output string for tool-result BLOCK's content."
  (let ((content (plist-get block :content)))
    (cond
     ((stringp content) content)
     ((null content) "")
     (t (format "%s" content)))))

(defun benedict-api-openai-responses--synthetic-item-id (call-id)
  "Return a synthetic `fc_'-prefixed item id derived from CALL-ID.

A foreign tool call replayed into the Responses API has no real upstream
item id (the signature was stripped by lowering), but the API requires one
beginning `fc_'.  A short hash of the call id is stable: the same call id
always maps to the same synthetic id, so a result replayed after a call
matches.  See SPEC-001 7.8.5."
  (concat "fc_" (substring (secure-hash 'sha256 call-id) 0 24)))

;;;;; Serializing tools

(defun benedict-api-openai-responses--tool-item (tool)
  "Return the Responses function definition for TOOL."
  (list :type "function"
        :name (symbol-name (benedict-tool-id tool))
        :description (or (benedict-tool-description tool) "")
        :parameters (benedict-tool-schema tool)))

;;;; The parser

;; A closure holding mutable state.  The two state pieces are what the spike
;; proved necessary: a map from `output_index' to per-block state (items
;; interleave), and the set of fields that arrive at different times across
;; the event vocabulary.
;;
;; Block state is a plist:
;;   :type        symbol — text, thinking, tool-call
;;   :item-id     the rs_/fc_ id from output_item.added
;;   :call-id     the call_id (tool-call only)
;;   :name        tool name (tool-call only)
;;   :args        accumulated argument JSON string (tool-call only)
;;   :parsed      the parsed arguments from function_call_arguments.done

(defun benedict-api-openai-responses--make-parser ()
  "Return a closure mapping Responses SSE events to normalized events.

The closure takes one argument, a plist `(:event TYPE :data DATA)' where
TYPE is the SSE event type string (nil when no `event:' field was sent) and
DATA is the raw data string.  It returns a LIST of normalized events,
possibly empty.  The parser never signals: the caller wraps it in a
condition-case, but signalling would still leave the block map in an
inconsistent state, so internal errors are swallowed and logged by the
caller.

See SPEC-001 7.3 and 7.4 for the event vocabulary and the mapping."
  (let ((response-id nil)
        (blocks (make-hash-table :test #'eql))
        (had-tool-call nil))
    (lambda (sse-event)
      (let ((type (plist-get sse-event :event))
            (data (plist-get sse-event :data)))
        (cond
         ((null type) nil)             ; data-only frame (e.g. [DONE])
         ((equal data "[DONE]") nil)
         (t
          (let ((json (benedict-api-openai-responses--parse-json data)))
            (when json
              (benedict-api-openai-responses--dispatch
               type json response-id blocks
               (lambda (id) (setq response-id id))
               (lambda () (setq had-tool-call t))
               (lambda () had-tool-call))))))))))

;;;;; Dispatch

(defun benedict-api-openai-responses--dispatch
    (type json response-id blocks set-response-id set-tool-call get-tool-call)
  "Dispatch on TYPE with parsed JSON, returning a list of normalized events.

RESPONSE-ID, BLOCKS, and the three callbacks thread the parser's mutable
state through a pure dispatch, which is what makes fixture replay testable
without a closure."
  (pcase type
    ("response.created"
     (let ((id (benedict-api-openai-responses--response-id json)))
       (when id (funcall set-response-id id))
       (list (append (list :type :start)
                     (when id (list :response-id id))))))
    ("response.in_progress" nil)
    ("response.output_item.added"
     (benedict-api-openai-responses--item-added json blocks set-tool-call))
    ("response.output_text.delta"
     (benedict-api-openai-responses--text-delta json blocks))
    ("response.reasoning.delta"
     (benedict-api-openai-responses--reasoning-delta json blocks))
    ("response.reasoning_summary_text.delta"
     (benedict-api-openai-responses--reasoning-delta json blocks))
    ("response.function_call_arguments.delta"
     (benedict-api-openai-responses--args-delta json blocks))
    ("response.function_call_arguments.done"
     (benedict-api-openai-responses--args-done json blocks))
    ("response.output_item.done"
     (benedict-api-openai-responses--item-done json blocks))
    ("response.completed"
     (list (benedict-api-openai-responses--done-event
            json response-id get-tool-call 'stop)))
    ("response.incomplete"
     (list (benedict-api-openai-responses--done-event
            json response-id get-tool-call 'length)))
    ("response.failed"
     (list (list :type :error
                 :reason 'error
                 :message (benedict-api-openai-responses--failed-message json))))
    (_ nil)))

;;;;; Item lifecycle

(defun benedict-api-openai-responses--item-added (json blocks set-tool-call)
  "Return the `:block-start' event for an output_item.added, updating BLOCKS."
  (let* ((index (plist-get json :output_index))
         (item (plist-get json :item))
         (item-type (plist-get item :type)))
    (pcase item-type
      ("reasoning"
       (puthash index
                (list :type 'thinking :item-id (plist-get item :id))
                blocks)
       (list (list :type :block-start :index index :block-type 'thinking)))
      ("message"
       (puthash index (list :type 'text) blocks)
       (list (list :type :block-start :index index :block-type 'text)))
      ("function_call"
       (funcall set-tool-call)
       (puthash index
                (list :type 'tool-call
                      :item-id (plist-get item :id)
                      :call-id (plist-get item :call_id)
                      :name (intern (plist-get item :name))
                      :args ""
                      :parsed nil)
                blocks)
       (list (list :type :block-start :index index :block-type 'tool-call
                   :id (plist-get item :call_id)
                   :name (intern (plist-get item :name)))))
      (_ nil))))

(defun benedict-api-openai-responses--text-delta (json blocks)
  "Return the `:block-delta' event for an output_text.delta."
  (let ((index (plist-get json :output_index))
        (delta (plist-get json :delta)))
    (when (and delta (gethash index blocks))
      (list (list :type :block-delta :index index :delta delta)))))

(defun benedict-api-openai-responses--reasoning-delta (json blocks)
  "Return the `:block-delta' event for a reasoning(.summary_text)?.delta."
  (let ((index (plist-get json :output_index))
        (delta (plist-get json :delta)))
    (when (and delta (gethash index blocks))
      (list (list :type :block-delta :index index :delta delta)))))

(defun benedict-api-openai-responses--args-delta (json blocks)
  "Return the `:block-delta' event for a function_call_arguments.delta.

The raw partial JSON is forwarded as the delta text so a frontend can render
the argument string arriving; the adapter parses it at block-end."
  (let ((index (plist-get json :output_index))
        (delta (plist-get json :delta)))
    (let ((block (gethash index blocks)))
      (when (and delta block)
        (plist-put block :args (concat (plist-get block :args) delta))
        (list (list :type :block-delta :index index :delta delta))))))

(defun benedict-api-openai-responses--args-done (json blocks)
  "Record parsed arguments from function_call_arguments.done in BLOCKS.

Returns no events — the block closes at output_item.done, which is where
`:block-end' carries the assembled arguments."
  (let ((index (plist-get json :output_index))
        (arguments (plist-get json :arguments)))
    (let ((block (gethash index blocks)))
      (when block
        (plist-put block :parsed
                   (benedict-api-openai-responses--parse-arguments arguments))
        nil))))

(defun benedict-api-openai-responses--item-done (json blocks)
  "Return the `:block-end' event for an output_item.done, updating BLOCKS."
  (let* ((index (plist-get json :output_index))
         (item (plist-get json :item))
         (item-type (plist-get item :type))
         (block (gethash index blocks)))
    (when block
      (remhash index blocks)
      (pcase item-type
        ("reasoning"
         (let* ((item-id (or (plist-get block :item-id)
                             (plist-get item :id)))
                (encrypted (plist-get item :encrypted_content))
                (signature (append (list :item-id item-id)
                                   (when encrypted
                                     (list :encrypted-content encrypted)))))
           (list (append (list :type :block-end :index index)
                         (list :signature signature)))))
        ("message"
         (list (list :type :block-end :index index)))
        ("function_call"
         (let* ((parsed (or (plist-get block :parsed)
                            (benedict-api-openai-responses--parse-arguments
                             (plist-get item :arguments))))
                (item-id (or (plist-get block :item-id)
                             (plist-get item :id)))
                (call-id (or (plist-get block :call-id)
                             (plist-get item :call_id))))
           (list (append (list :type :block-end :index index
                               :id call-id
                               :arguments parsed)
                         (when item-id (list :signature item-id))))))
        (_ (list (list :type :block-end :index index)))))))

;;;;; Terminal events

(defun benedict-api-openai-responses--done-event
    (json response-id get-tool-call fallback-reason)
  "Return the `:done' event for a completed or incomplete response.

The reason is `tool-use' when the stream opened any function_call item,
otherwise FALLBACK-REASON (`stop' for completed, `length' for incomplete).
The kernel branches on whether the entry carries tool calls, not on this
reason; the reason is the transcript's stop marker."
  (let* ((response (plist-get json :response))
         (usage (benedict-api-openai-responses--usage
                 (plist-get response :usage)))
         (reason (if (funcall get-tool-call) 'tool-use fallback-reason)))
    (append (list :type :done :reason reason)
            (when usage (list :usage usage))
            (when response-id (list :response-id response-id)))))

(defun benedict-api-openai-responses--usage (usage)
  "Return the normalized usage plist for a Responses usage object.

`input_tokens' includes cached tokens; subtracting
`input_tokens_details.cached_tokens' gives the uncached input count so
accounting does not overstate cost.  `cache_write_tokens' and
`reasoning_tokens' are present for some models and absent for others, and
neither is inferred from — see SPEC-001 7.4."
  (when usage
    (let* ((input (or (plist-get usage :input_tokens) 0))
           (output (or (plist-get usage :output_tokens) 0))
           (details (or (plist-get usage :input_tokens_details) '()))
           (cached (or (plist-get details :cached_tokens) 0)))
      (list :input (- input cached)
            :output output
            :cache-read cached))))

(defun benedict-api-openai-responses--failed-message (json)
  "Return the error message for a response.failed event."
  (let* ((response (plist-get json :response))
         (error (and response (plist-get response :error)))
         (message (and error (plist-get error :message))))
    (or message "The model reported a failure")))

;;;;; Parsing helpers

(defun benedict-api-openai-responses--parse-json (string)
  "Parse STRING as JSON to a plist, or return nil."
  (condition-case nil
      (json-parse-string string
                         :object-type 'plist
                         :null-object nil
                         :false-object nil)
    (error nil)))

(defun benedict-api-openai-responses--parse-arguments (string)
  "Parse the tool-call arguments STRING to a plist, or nil when empty.

The adapter assembles and parses arguments before `:block-end' so the kernel
never sees invalid JSON.  An empty argument string is treated as nil (no
arguments) rather than signalled."
  (let ((trimmed (string-trim (or string ""))))
    (unless (string-empty-p trimmed)
      (condition-case nil
          (json-parse-string trimmed
                             :object-type 'plist
                             :null-object nil
                             :false-object nil)
        (error nil)))))

(defun benedict-api-openai-responses--response-id (json)
  "Extract the response id from a response.created payload."
  (let ((response (plist-get json :response)))
    (and response (plist-get response :id))))

;;;; Registration

;;;###autoload
(benedict-defapi openai-responses
  :name "OpenAI Responses API"
  :endpoint #'benedict-api-openai-responses--endpoint
  :headers #'benedict-api-openai-responses--headers
  :build #'benedict-api-openai-responses--build
  :make-parser #'benedict-api-openai-responses--make-parser)

(provide 'benedict-api-openai-responses)

;;; benedict-api-openai-responses.el ends here
