# Session Dispatch Extraction Implementation Plan

## Overview

Extract dispatch logic from `benedict-chat.el` into `benedict-session.el` to make the session a fully autonomous agent engine that can be driven by any frontend—not just the chat buffer. This transforms the chat buffer from a middle-man that calls provider dispatch directly into a pure reactive view that observes session events.

## Current State Analysis

The session module is **complete as a state container** but **incomplete as an agent dispatcher** (see `research.md:26-33`).

### Current Architecture Problems

1. **Chat buffer calls provider directly** (`benedict-chat.el:2953-2978`)
   - `benedict-chat--start-dispatch` invokes `benedict-provider-dispatch`
   - Callbacks are defined inline in the chat module

2. **"Headless" handlers live in wrong module** (`benedict-chat.el:2853-2924`)
   - `benedict-chat--handle-provider-delta-headless` - appends to draft
   - `benedict-chat--handle-provider-success-headless` - finalizes draft, accumulates telemetry
   - `benedict-chat--handle-provider-error-headless` - sets error state

3. **Tool execution in chat** (`benedict-chat.el:2086-2150`)
   - `benedict-chat--invoke-tool-call` - executes single tool
   - `benedict-chat--process-tool-calls` - iterates over tool calls

4. **Agent loop in chat** (`benedict-chat.el:775-843`)
   - `benedict-chat--loop-step` - decides continuation
   - `benedict-chat--check-loop-constraints` - turn/time/token limits
   - `benedict-chat--check-repetition-guard` - detects stuck loops

5. **Request building in chat** (`benedict-chat.el:2633-2652`)
   - `benedict-chat--build-request` - assembles provider request

### What Session CAN Do (Already Implemented)

| Capability | Location | Function |
|------------|----------|----------|
| Registry management | `benedict-session.el:27-88` | create, get, list, delete |
| Message storage | `benedict-session.el:117-145` | add, get, update, chronological |
| Draft management | `benedict-session.el:147-192` | start, append, finalize, discard |
| Inflight tracking | `benedict-session.el:194-228` | start-request, clear, cancel, active-p |
| Telemetry | `benedict-session.el:230-287` | accumulate-usage |
| Events | `benedict-session.el:93-115` | emit, state-changed |
| Frontend management | `benedict-session.el:289-314` | add/remove/list frontends |

## Desired End State

```
┌─────────────────────────────────────────────────────────────────────┐
│                        benedict-chat.el                             │
│                                                                     │
│  compose-send ─→ add-user-message ─→ session-run()                  │
│                                                                     │
│  OBSERVES session events:                                           │
│   • draft-started → create streaming UI                             │
│   • draft-updated → append text to UI                               │
│   • message-added → render message                                  │
│   • state-changed → update status line                              │
│   • tool-started → show tool block                                  │
│   • tool-completed → update tool block                              │
│   • checkpoint-requested → prompt user                              │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (calls)
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       benedict-session.el                           │
│                                                                     │
│  benedict-session-run(session):                                     │
│   → build request from session config                               │
│   → dispatch to provider                                            │
│   → execute tools                                                   │
│   → loop until done or checkpoint                                   │
│   → emit events throughout                                          │
│                                                                     │
│  Session is ACTIVE - owns full agent lifecycle                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Verification of End State

1. **Headless agent test passes**: Session can run multi-turn tool-using conversation without any buffer
2. **New session tests pass**: All 16 new tests demonstrate correct behavior
3. **Chat works via events**: Chat buffer renders entirely from session events
4. **Code is deleted**: Headless handlers, loop functions, and tool execution removed from chat

## What We're NOT Doing

1. **Flywire integration** - Stays in chat module (separate concern)
2. **Profile resolution** - Stays in chat module (UI configuration)
3. **Rendering logic** - Stays in chat-render module
4. **Compose buffer** - Stays in chat module (input UI)

## Approach: Bold Refactoring

**We do NOT care about backward compatibility.** When moving functionality:

1. **Write new tests first** that demonstrate the desired behavior
2. **Delete conflicting old tests** that test the old architecture
3. **Delete old code immediately** - no deprecation warnings, no dual paths
4. **Move aggressively** - if code belongs in session, move it now

This means:
- No `DEPRECATED` docstrings
- No "keep for backwards compatibility" phases
- No callback wrapping to preserve old behavior
- Delete headless handlers from chat immediately after adding to session
- Delete loop functions from chat immediately after adding to session

---

## Phase 1: Core Dispatch in Session

### Overview

Move dispatch callbacks to session and add `benedict-session-dispatch` function.

### Phase 1.1: Add Internal Callback Functions to Session

- **File**: `benedict-session.el`
- **Location**: After line 228 (after `benedict-session-request-active-p`)
- **Changes**: Add three internal callback functions

```elisp
;;; Internal Dispatch Callbacks

(defun benedict-session--on-delta (session data)
  "Handle streaming delta DATA for SESSION.
Updates draft content. Internal callback for dispatch."
  (when session
    (let ((kind (plist-get data :kind))
          (text (plist-get data :text)))
      (pcase kind
        ('content-delta
         (when text
           (benedict-session-append-draft session text)))))))

(defun benedict-session--on-success (session result)
  "Handle successful response RESULT for SESSION.
Finalizes draft, accumulates telemetry. Internal callback for dispatch."
  (when session
    (let* ((message (plist-get result :message))
           (content (or (plist-get message :content) ""))
           (tool-calls (plist-get message :tool-calls))
           (usage (plist-get result :usage))
           (metadata (list :provider (plist-get result :provider)
                           :model (plist-get result :model)
                           :latency (plist-get result :latency)
                           :usage usage)))
      ;; Update session provider/model from response
      (when-let ((provider (plist-get result :provider)))
        (setf (benedict-session-provider session) provider))
      (when-let ((model (plist-get result :model)))
        (setf (benedict-session-model session) model))
      ;; Accumulate telemetry before clearing request
      (when-let* ((inflight (benedict-session-inflight session))
                  (started (plist-get inflight :started-at)))
        (let* ((elapsed (float-time (time-subtract (current-time) started)))
               (duration (or (plist-get result :latency) elapsed)))
          (setf (benedict-session-last-phase session) 'complete)
          (setf (benedict-session-last-elapsed session) elapsed)
          (setf (benedict-session-last-usage session) usage)
          (benedict-session-accumulate-usage session usage duration)))
      ;; Clear request state
      (benedict-session-clear-request session)
      ;; Finalize or create message
      (if (and (benedict-session-draft session)
               (> (length (plist-get (benedict-session-draft session) :content)) 0))
          (benedict-session-finalize-draft session metadata)
        (when (benedict-session-draft session)
          (setf (benedict-session-draft session) nil)
          (benedict-session-set-state session 'idle))
        (benedict-session-add-message
         session
         (list :role 'assistant
               :content content
               :tool-calls tool-calls
               :metadata metadata)))
      ;; Emit completion event
      (benedict-session--emit session 'request-completed :success t))))

(defun benedict-session--on-error (session payload)
  "Handle error PAYLOAD for SESSION.
Clears request, discards draft. Internal callback for dispatch."
  (when session
    (when-let ((provider (plist-get payload :provider)))
      (setf (benedict-session-provider session) provider))
    (when-let* ((inflight (benedict-session-inflight session))
                (started (plist-get inflight :started-at)))
      (setf (benedict-session-last-phase session) 'error)
      (setf (benedict-session-last-elapsed session)
            (float-time (time-subtract (current-time) started)))
      (setf (benedict-session-last-usage session) nil))
    (benedict-session-clear-request session)
    (benedict-session-discard-draft session)
    (setf (benedict-session-last-error session) payload)
    (benedict-session-set-state session 'error)
    (benedict-session--emit session 'request-completed :success nil :error payload)))
```

**Constraints**:
- DO NOT add any `require` statements
- MUST emit `request-completed` event

**Success Criteria**:
- [x] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 1.2: Add Busy Check and Dispatch Wrapper

- **File**: `benedict-session.el`
- **Location**: After internal callbacks
- **Changes**: Add public dispatch API

```elisp
;;; Dispatch API

(defun benedict-session-busy-p (session)
  "Return non-nil if SESSION has an active request or is streaming."
  (or (benedict-session-request-active-p session)
      (eq (benedict-session-state session) 'streaming)))

(cl-defun benedict-session-dispatch (session request &key dispatch-fn)
  "Send REQUEST through the provider for SESSION.
Updates session state and emits events throughout the lifecycle.

REQUEST is a plist with at minimum :provider, :model, :messages.
DISPATCH-FN is the provider dispatch function (default: benedict-provider-dispatch).

Returns the request ID on success.
Signals error if session is busy.

Events emitted:
- `request-started` with (:request-id N) after dispatch begins
- `draft-started` when streaming begins
- `draft-updated` for each content delta
- `request-completed` with (:success BOOL) after success/error
- `message-added` when response is finalized"
  (when (benedict-session-busy-p session)
    (error "Session is busy with an active request"))
  (let* ((dispatch (or dispatch-fn
                       (and (fboundp 'benedict-provider-dispatch)
                            #'benedict-provider-dispatch)))
         (handle (funcall dispatch
                          request
                          :on-success (lambda (result)
                                        (benedict-session--on-success session result))
                          :on-error (lambda (payload)
                                      (benedict-session--on-error session payload))
                          :on-delta (lambda (&rest payload)
                                      (let ((data (if (and (listp payload)
                                                           (not (keywordp (car payload)))
                                                           (listp (car payload)))
                                                      (car payload)
                                                    payload)))
                                        (benedict-session--on-delta session data)))))
         (request-id (benedict-session-start-request session handle)))
    (benedict-session-start-draft session)
    (when-let ((provider (plist-get request :provider)))
      (setf (benedict-session-provider session) provider))
    (when-let ((model (plist-get request :model)))
      (setf (benedict-session-model session) model))
    (when-let ((profile (plist-get request :profile)))
      (setf (benedict-session-profile session) profile))
    (benedict-session--emit session 'request-started :request-id request-id)
    request-id))
```

**Constraints**:
- MUST use `cl-defun` for keyword arguments
- MUST accept `:dispatch-fn` parameter for testing
- MUST signal error when session is busy
- DO NOT add `(require 'benedict-provider)` at top level

**Success Criteria**:
- [x] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 1.3: Add Session Dispatch Tests

- **File**: `test/benedict-session-test.el`
- **Location**: Before `(provide 'benedict-session-test)`
- **Changes**: Add dispatch tests

```elisp
;;; Dispatch Tests

(ert-deftest benedict-session-test-busy-p-idle ()
  "Idle session is not busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (should-not (benedict-session-busy-p session)))))

(ert-deftest benedict-session-test-busy-p-streaming ()
  "Streaming session is busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-draft session)
      (should (benedict-session-busy-p session)))))

(ert-deftest benedict-session-test-busy-p-request ()
  "Session with active request is busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (should (benedict-session-busy-p session)))))

(ert-deftest benedict-session-test-dispatch-rejects-busy ()
  "Dispatch signals error when session is busy."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-start-request session 'handle)
      (should-error
       (benedict-session-dispatch session '(:provider test :model test :messages []))))))

(ert-deftest benedict-session-test-dispatch-headless ()
  "Dispatch works without any buffer (headless operation)."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (captured-callbacks nil)
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let ((mock-dispatch
             (lambda (request &rest callbacks)
               (setq captured-callbacks callbacks)
               'mock-handle)))
        (let ((request-id (benedict-session-dispatch
                           session
                           '(:provider mock :model mock :messages [(:role user :content "test")])
                           :dispatch-fn mock-dispatch)))
          (should (numberp request-id))
          (should (benedict-session-busy-p session))
          (should (cl-find 'request-started events :key #'car))
          (funcall (plist-get captured-callbacks :on-delta)
                   '(:kind content-delta :text "Hello "))
          (funcall (plist-get captured-callbacks :on-delta)
                   '(:kind content-delta :text "world"))
          (should (string= "Hello world"
                           (plist-get (benedict-session-draft session) :content)))
          (funcall (plist-get captured-callbacks :on-success)
                   '(:message (:role assistant :content "Hello world")
                     :provider mock :model mock
                     :usage (:prompt_tokens 10 :completion_tokens 5 :total_tokens 15)))
          (should-not (benedict-session-busy-p session))
          (should (eq 'idle (benedict-session-state session)))
          (should (= 1 (length (benedict-session-messages session))))
          (should (cl-find 'request-completed events :key #'car)))))))

(ert-deftest benedict-session-test-dispatch-error-headless ()
  "Dispatch handles errors correctly without buffer."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (captured-callbacks nil))
    (let ((session (benedict-session-create)))
      (let ((mock-dispatch
             (lambda (_request &rest callbacks)
               (setq captured-callbacks callbacks)
               'mock-handle)))
        (benedict-session-dispatch
         session '(:provider mock :model mock :messages [])
         :dispatch-fn mock-dispatch)
        (funcall (plist-get captured-callbacks :on-error)
                 '(:type api :message "Rate limited" :retryable t))
        (should-not (benedict-session-busy-p session))
        (should (eq 'error (benedict-session-state session)))
        (should (equal "Rate limited"
                       (plist-get (benedict-session-last-error session) :message)))))))

(ert-deftest benedict-session-test-dispatch-non-streaming ()
  "Dispatch handles non-streaming responses."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (captured-callbacks nil))
    (let ((session (benedict-session-create)))
      (let ((mock-dispatch
             (lambda (_request &rest callbacks)
               (setq captured-callbacks callbacks)
               'mock-handle)))
        (benedict-session-dispatch
         session '(:provider mock :model mock :messages [])
         :dispatch-fn mock-dispatch)
        (funcall (plist-get captured-callbacks :on-success)
                 '(:message (:role assistant :content "Direct response")
                   :provider mock :model mock))
        (should (= 1 (length (benedict-session-messages session))))
        (should (string= "Direct response"
                         (plist-get (car (benedict-session-messages session)) :content)))))))
```

**Success Criteria**:
- [x] `nix run .#test -- test/benedict-session-test.el` passes with new tests
- [x] All 7 new dispatch tests pass

### Phase 1.4: Update Chat Module to Use Session Dispatch and Delete Old Handlers

- **File**: `benedict-chat.el`
- **Location**: `benedict-chat--start-dispatch` (around line 2926)
- **Changes**:
  1. Rewrite dispatch to simply call session
  2. **DELETE** the three headless handlers entirely
  3. **DELETE or UPDATE** any tests that depend on the old handlers

**Delete these functions from `benedict-chat.el`:**
- `benedict-chat--handle-provider-delta-headless`
- `benedict-chat--handle-provider-success-headless`
- `benedict-chat--handle-provider-error-headless`

**New `benedict-chat--start-dispatch`:**

```elisp
(defun benedict-chat--start-dispatch (buffer request &optional retry)
  "Send REQUEST through the provider for BUFFER."
  (unless (and buffer (buffer-live-p buffer))
    (user-error "Chat buffer is unavailable"))
  (with-current-buffer buffer
    (let* ((provider-id (or (plist-get request :provider) benedict-provider))
           (provider-label (benedict-chat--provider-label provider-id))
           (session benedict-chat--session))
      (unless session
        (user-error "No session attached to buffer"))
      ;; Reset UI state
      (setq benedict-chat--request-seq (1+ benedict-chat--request-seq))
      (setq benedict-chat--thinking-temp-counter 0)
      (benedict-chat--streaming-reset buffer)
      (benedict-chat--status-reset)
      (benedict-chat--status-start-timer)
      (benedict-chat--status-refresh)
      (setq benedict-chat--last-dispatch
            (list :request request :timestamp (current-time) :retry retry))
      (message "Benedict: contacting %s%s..."
               provider-label (if retry " (retry)" ""))
      (condition-case err
          (let ((request-id (benedict-session-dispatch session request)))
            (when benedict-chat--last-dispatch
              (setq benedict-chat--last-dispatch
                    (plist-put benedict-chat--last-dispatch :request-id request-id))))
        (error
         (benedict-chat--handle-provider-error
          buffer
          (list :message (error-message-string err)
                :type 'dispatch
                :provider provider-id
                :retryable nil)))))))
```

**Chat buffer UI updates via events.** The chat module must observe session events for UI:
- `draft-started` → call `benedict-chat--handle-provider-delta` setup
- `draft-updated` → call `benedict-chat--handle-provider-delta`
- `request-completed` → call `benedict-chat--handle-provider-success` or `error`
- `message-added` → render message

**Constraints**:
- Session is REQUIRED - error if no session attached
- Chat only handles UI via event observation
- No callback wrapping - session owns the callbacks

**Success Criteria**:
- [x] `nix run .#test -- test/benedict-session-test.el` passes (new dispatch tests)
- [x] `nix run .#test -- test/benedict-chat-*-test.el` passes (may need to delete/update old tests)
- [x] `grep -r "headless" benedict-chat.el` returns nothing

---

## Phase 2: Tool Execution in Session

### Overview

Move tool execution from chat module to session so tools can run headlessly.

### Phase 2.1: Add Tool Execution Infrastructure to Session

- **File**: `benedict-session.el`
- **Location**: After dispatch API section
- **Changes**: Add tool execution functions

```elisp
;;; Tool Execution

(defvar benedict-session-tool-invoke-fn nil
  "Function to invoke tools. Set by tool module.
Called as (funcall fn TOOL-ID ARGUMENTS).
Returns tool output or signals error.")

(defun benedict-session--invoke-tool (session tool-call)
  "Execute TOOL-CALL plist for SESSION.
Returns plist (:status :output :error).
Emits tool-started and tool-completed events."
  (let* ((tool-id (or (plist-get tool-call :name)
                      (plist-get tool-call :tool)))
         (call-id (plist-get tool-call :id))
         (arguments (plist-get tool-call :arguments))
         (status 'success)
         (output nil)
         (error-info nil))
    ;; Emit start event
    (benedict-session--emit session 'tool-started
                            :tool-call tool-call
                            :tool-id tool-id)
    ;; Execute tool
    (condition-case err
        (if benedict-session-tool-invoke-fn
            (setq output (funcall benedict-session-tool-invoke-fn tool-id arguments))
          (error "No tool invoke function configured"))
      (error
       (setq status 'failure)
       (setq error-info (list :message (error-message-string err)
                              :type (car err)
                              :data (cdr err)))))
    ;; Emit completion event
    (benedict-session--emit session 'tool-completed
                            :tool-call tool-call
                            :tool-id tool-id
                            :status status
                            :output output
                            :error error-info)
    (list :status status
          :output output
          :error error-info
          :call-id call-id
          :tool-id tool-id)))

(defun benedict-session--format-tool-result (tool-id call-id output error-info)
  "Format tool result as message for provider.
Returns plist suitable for adding to message history."
  (let ((content (if error-info
                     (format "Tool error: %s" (plist-get error-info :message))
                   (cond
                    ((stringp output) output)
                    ((plist-get output :text) (plist-get output :text))
                    (t (format "%S" output))))))
    (list :role 'tool
          :tool-call-id call-id
          :name tool-id
          :content content)))

(defun benedict-session--process-tool-calls (session tool-calls)
  "Execute TOOL-CALLS for SESSION and record results.
Returns list of result plists."
  (let (results)
    (dolist (call tool-calls)
      (let* ((result (benedict-session--invoke-tool session call))
             (call-id (plist-get result :call-id))
             (tool-id (plist-get result :tool-id))
             (output (plist-get result :output))
             (error-info (plist-get result :error))
             (message (benedict-session--format-tool-result
                       tool-id call-id output error-info)))
        (benedict-session-add-message session message)
        (push result results)))
    (nreverse results)))
```

**Constraints**:
- MUST use configurable `benedict-session-tool-invoke-fn` (no hard dependency)
- MUST emit `tool-started` and `tool-completed` events
- MUST record tool result messages in session
- DO NOT include UI-specific formatting (that stays in chat)

**Success Criteria**:
- [x] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 2.2: Add Tool Execution Tests

- **File**: `test/benedict-session-test.el`
- **Changes**: Add tool execution tests

```elisp
;;; Tool Execution Tests

(ert-deftest benedict-session-test-invoke-tool-success ()
  "Tool invocation records result and emits events."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (id args)
                                           (format "Result for %s" id)))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let ((result (benedict-session--invoke-tool
                     session '(:id "call-1" :name read_file :arguments (:path "/tmp")))))
        (should (eq 'success (plist-get result :status)))
        (should (string-match "Result for" (plist-get result :output)))
        (should (cl-find 'tool-started events :key #'car))
        (should (cl-find 'tool-completed events :key #'car))))))

(ert-deftest benedict-session-test-invoke-tool-failure ()
  "Tool failure is captured and emitted."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (_id _args)
                                           (error "Tool failed")))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (let ((result (benedict-session--invoke-tool
                     session '(:id "call-1" :name broken_tool :arguments nil))))
        (should (eq 'failure (plist-get result :status)))
        (should (plist-get result :error))
        (should (cl-find 'tool-completed events :key #'car))))))

(ert-deftest benedict-session-test-process-tool-calls ()
  "Processing multiple tool calls records all results."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (benedict-session-tool-invoke-fn (lambda (id _args)
                                           (format "Output from %s" id))))
    (let ((session (benedict-session-create)))
      (benedict-session--process-tool-calls
       session
       '((:id "call-1" :name tool_a :arguments nil)
         (:id "call-2" :name tool_b :arguments nil)))
      ;; Should have 2 tool result messages
      (should (= 2 (length (benedict-session-messages session))))
      (should (eq 'tool (plist-get (car (benedict-session-messages session)) :role))))))
```

**Success Criteria**:
- [x] `nix run .#test -- test/benedict-session-test.el` passes with tool tests

### Phase 2.3: Wire Tool Invoke Function

- **File**: `benedict-chat.el`
- **Location**: Mode initialization or setup function
- **Changes**: Set `benedict-session-tool-invoke-fn` to `benedict-tool-invoke`

```elisp
;; In benedict-chat-mode or session setup:
(setq benedict-session-tool-invoke-fn #'benedict-tool-invoke)
```

- **File**: `benedict.el` (main entry point)
- **Changes**: Ensure tool invoke function is available globally

```elisp
(with-eval-after-load 'benedict-session
  (with-eval-after-load 'benedict-tools
    (setq benedict-session-tool-invoke-fn #'benedict-tool-invoke)))
```

**Constraints**:
- Use `with-eval-after-load` to avoid load order issues
- Keep it optional—session should work without tools

**Success Criteria**:
- [x] `nix run .#test` passes

### Phase 2.4: Move Tool Processing to Session, Delete from Chat

- **File**: `benedict-chat.el`
- **Changes**:
  1. **DELETE** `benedict-chat--invoke-tool-call` (execution moved to session)
  2. **DELETE** `benedict-chat--process-tool-calls` (moved to session)
  3. Tool UI rendering happens via `tool-started` and `tool-completed` events

**Chat observes tool events for UI:**

```elisp
;; In event handler:
('tool-started
 (let* ((tool-call (plist-get payload :tool-call))
        (tool-id (plist-get payload :tool-id)))
   (benedict-chat--record-tool-block buffer tool-call
                                     (benedict-chat--tool-call-metadata
                                      tool-id tool-call 'in-progress nil))))
('tool-completed
 (let* ((tool-call (plist-get payload :tool-call))
        (status (plist-get payload :status))
        (output (plist-get payload :output)))
   ;; Update existing tool block with result
   (benedict-chat--update-tool-block-from-event buffer tool-call status output)))
```

**Constraints**:
- Session executes tools and emits events
- Chat only handles UI via event observation
- No tool execution code in chat module

**Success Criteria**:
- [x] `nix run .#test -- test/benedict-session-test.el` passes (tool tests)
- [x] `grep -r "invoke-tool-call\|process-tool-calls" benedict-chat.el` returns nothing (except possibly UI helpers)

---

## Phase 3: Agent Loop in Session

### Overview

Move the autonomous agent loop from chat to session.

### Phase 3.1: Add Loop State to Session Struct

- **File**: `benedict-session.el`
- **Location**: Session struct definition (line 13)
- **Changes**: Add loop-related fields

```elisp
(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state and runtime."
  id created-at updated-at title
  messages (message-seq 0)
  (state 'idle) draft pending-question inflight last-error last-request
  root provider model profile meta
  flywire-session attached-frontends
  ;; Telemetry fields
  (accumulated-usage nil)
  (accumulated-seconds 0.0)
  last-phase last-usage last-elapsed
  ;; Loop state (NEW)
  (loop-turn-count 0)
  loop-start-time
  loop-config)           ; plist with :max-turns :max-time :max-tokens
```

**Constraints**:
- Add fields to existing struct definition
- Initialize with sensible defaults

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 3.2: Add Loop Constraint Checking

- **File**: `benedict-session.el`
- **Location**: After tool execution section
- **Changes**: Add loop constraint functions

```elisp
;;; Loop Management

(defun benedict-session--check-repetition (session tool-calls)
  "Return non-nil if TOOL-CALLS match previous assistant message."
  (let* ((messages (benedict-session-messages session))
         (assistants (cl-remove-if-not
                      (lambda (m) (eq (plist-get m :role) 'assistant))
                      messages))
         (previous (cadr assistants)))  ; Second-most-recent
    (when previous
      (equal tool-calls (plist-get previous :tool-calls)))))

(defun benedict-session--check-turn-limit (session)
  "Return non-nil if turn limit reached. Emits checkpoint-requested if so."
  (let* ((config (benedict-session-loop-config session))
         (limit (plist-get config :max-turns))
         (count (benedict-session-loop-turn-count session)))
    (when (and limit (> count 0) (= 0 (mod count limit)))
      (benedict-session--emit session 'checkpoint-requested
                              :reason 'turn-limit
                              :turn-count count
                              :limit limit)
      t)))

(defun benedict-session--check-time-limit (session)
  "Return non-nil if time limit reached. Emits checkpoint-requested if so."
  (let* ((config (benedict-session-loop-config session))
         (limit (plist-get config :max-time))
         (start (benedict-session-loop-start-time session)))
    (when (and limit start)
      (let ((elapsed (float-time (time-subtract (current-time) start))))
        (when (> elapsed limit)
          (benedict-session--emit session 'checkpoint-requested
                                  :reason 'time-limit
                                  :elapsed elapsed
                                  :limit limit)
          t)))))

(defun benedict-session--check-token-limit (session)
  "Return non-nil if token limit reached. Emits checkpoint-requested if so."
  (let* ((config (benedict-session-loop-config session))
         (limit (plist-get config :max-tokens))
         (usage (benedict-session-accumulated-usage session))
         (total (or (plist-get usage :total) 0)))
    (when (and limit (> total limit))
      (benedict-session--emit session 'checkpoint-requested
                              :reason 'token-limit
                              :total-tokens total
                              :limit limit)
      t)))

(defun benedict-session--check-constraints (session)
  "Check all loop constraints. Returns non-nil if any limit reached."
  (or (benedict-session--check-turn-limit session)
      (benedict-session--check-time-limit session)
      (benedict-session--check-token-limit session)))
```

**Constraints**:
- Emit `checkpoint-requested` events, don't prompt directly
- Return boolean, let caller decide how to handle
- Include all relevant info in event payload

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 3.3: Add Loop Step and Run Functions

- **File**: `benedict-session.el`
- **Location**: After constraint checking
- **Changes**: Add loop control functions

```elisp
(defvar benedict-session-checkpoint-handler nil
  "Function called when checkpoint is requested.
Called as (funcall fn SESSION REASON).
Should return non-nil to continue, nil to stop.
If nil, loop waits for `benedict-session-continue' call.")

(defun benedict-session--should-continue (session assistant-message)
  "Decide whether loop should continue after ASSISTANT-MESSAGE.
Returns: 'continue, 'stop, or 'checkpoint."
  (let ((tool-calls (plist-get assistant-message :tool-calls)))
    (cond
     ;; No tool calls = done
     ((not tool-calls) 'stop)
     ;; Repetition detected = stop
     ((benedict-session--check-repetition session tool-calls)
      (benedict-session--emit session 'loop-stopped :reason 'repetition)
      'stop)
     ;; Constraint hit = checkpoint
     ((benedict-session--check-constraints session) 'checkpoint)
     ;; Continue
     (t 'continue))))

(defun benedict-session--loop-step (session)
  "Execute one step of the agent loop.
Processes tool calls from last message, then dispatches if should continue."
  (let* ((messages (benedict-session-messages session))
         (last-msg (car messages))
         (tool-calls (plist-get last-msg :tool-calls)))
    (when tool-calls
      ;; Process tools
      (benedict-session--process-tool-calls session tool-calls)
      ;; Check if we should continue
      (let ((decision (benedict-session--should-continue session last-msg)))
        (pcase decision
          ('continue
           (cl-incf (benedict-session-loop-turn-count session))
           ;; Schedule next dispatch (will be implemented in 3.4)
           (benedict-session--dispatch-next session))
          ('checkpoint
           (benedict-session-set-state session 'checkpoint))
          ('stop
           (benedict-session-set-state session 'idle)))))))

(defun benedict-session--dispatch-next (session)
  "Dispatch next request in the loop.
Builds request from session state and dispatches."
  ;; This will be fully implemented in Phase 4
  ;; For now, emit event that chat can observe
  (benedict-session--emit session 'dispatch-needed))

(defun benedict-session-continue (session)
  "Continue SESSION after a checkpoint.
Resets time limit and continues the loop."
  (when (eq (benedict-session-state session) 'checkpoint)
    (setf (benedict-session-loop-start-time session) (float-time))
    (benedict-session-set-state session 'running)
    (benedict-session--dispatch-next session)))

(defun benedict-session-stop (session)
  "Stop SESSION's agent loop."
  (benedict-session-set-state session 'idle)
  (benedict-session--emit session 'loop-stopped :reason 'user-stopped))

(cl-defun benedict-session-run (session &key request config)
  "Start the agent loop for SESSION.
REQUEST is the initial request plist.
CONFIG is loop config plist (:max-turns :max-time :max-tokens)."
  (when (benedict-session-busy-p session)
    (error "Session is busy"))
  ;; Initialize loop state
  (setf (benedict-session-loop-turn-count session) 0)
  (setf (benedict-session-loop-start-time session) (float-time))
  (when config
    (setf (benedict-session-loop-config session) config))
  (benedict-session-set-state session 'running)
  ;; Dispatch initial request
  (if request
      (benedict-session-dispatch session request)
    (benedict-session--dispatch-next session)))
```

**Constraints**:
- `checkpoint-requested` event lets frontend decide
- `benedict-session-continue` and `benedict-session-stop` for frontend to call
- `dispatch-needed` event bridges to chat until Phase 4

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 3.4: Add Loop Tests

- **File**: `test/benedict-session-test.el`
- **Changes**: Add loop management tests

```elisp
;;; Loop Management Tests

(ert-deftest benedict-session-test-check-repetition ()
  "Repetition detection finds duplicate tool calls."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      ;; Add two assistant messages with same tool calls
      (benedict-session-add-message
       session '(:role assistant :content "" :tool-calls [(:name foo)]))
      (benedict-session-add-message
       session '(:role tool :content "result"))
      (benedict-session-add-message
       session '(:role assistant :content "" :tool-calls [(:name foo)]))
      (should (benedict-session--check-repetition session '[(:name foo)])))))

(ert-deftest benedict-session-test-check-turn-limit ()
  "Turn limit emits checkpoint event."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (setf (benedict-session-loop-config session) '(:max-turns 5))
      (setf (benedict-session-loop-turn-count session) 5)
      (should (benedict-session--check-turn-limit session))
      (should (cl-find 'checkpoint-requested events :key #'car)))))

(ert-deftest benedict-session-test-continue-after-checkpoint ()
  "Session can continue after checkpoint."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (benedict-session-set-state session 'checkpoint)
      (benedict-session-continue session)
      (should (eq 'running (benedict-session-state session)))
      (should (cl-find 'dispatch-needed events :key #'car)))))

(ert-deftest benedict-session-test-stop-loop ()
  "Session can be stopped."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (let ((session (benedict-session-create)))
      (add-hook 'benedict-session-event-hook
                (lambda (_s type payload) (push (cons type payload) events)))
      (benedict-session-set-state session 'running)
      (benedict-session-stop session)
      (should (eq 'idle (benedict-session-state session)))
      (should (cl-find 'loop-stopped events :key #'car)))))
```

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes with loop tests

### Phase 3.5: Delete Loop Functions from Chat, Add Event Handlers

- **File**: `benedict-chat.el`
- **Changes**:
  1. **DELETE** `benedict-chat--loop-step`
  2. **DELETE** `benedict-chat--check-loop-constraints`
  3. **DELETE** `benedict-chat--check-repetition-guard`
  4. **DELETE** buffer-local variables: `benedict-chat--loop-start-time`, `benedict-chat--loop-turn-count`, `benedict-chat--loop-canceled`
  5. Add event handlers for loop events

**Add to event handler:**

```elisp
('checkpoint-requested
 (let* ((reason (plist-get payload :reason))
        (prompt (pcase reason
                  ('turn-limit
                   (format "Benedict has run %d autonomous steps. Continue? "
                           (plist-get payload :turn-count)))
                  ('time-limit
                   (format "Time limit (%.1fs) reached. Continue? "
                           (plist-get payload :limit)))
                  ('token-limit
                   (format "Token limit (%d) exceeded. Continue? "
                           (plist-get payload :limit))))))
   (if (y-or-n-p prompt)
       (benedict-session-continue session)
     (benedict-session-stop session))))
('loop-stopped
 (message "Benedict: loop stopped (%s)" (plist-get payload :reason)))
```

**Constraints**:
- All loop logic lives in session
- Chat only handles UI prompts via events
- No loop state in chat module

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes (loop tests)
- [ ] `grep -r "loop-step\|check-loop-constraints\|check-repetition-guard" benedict-chat.el` returns nothing

---

## Phase 4: Request Building in Session

### Overview

Move request building to session so it can dispatch autonomously.

### Phase 4.1: Add Configuration Storage to Session

- **File**: `benedict-session.el`
- **Location**: Session struct and create function
- **Changes**: Add configuration fields

```elisp
;; In struct (already have provider, model, profile):
;; Add:
  tools                   ; list of tool definitions
  system-prompt           ; system messages
  autonomy                ; autonomy level symbol
  verbosity              ; verbosity level symbol

;; Update benedict-session-create:
(cl-defun benedict-session-create (&key id title root provider model profile
                                        meta tools system-prompt autonomy verbosity)
  "Create and register a new session.
..."
  (let* ((now (current-time))
         (session-id (or id (benedict-session--generate-id)))
         (session (benedict-session--create
                   :id session-id
                   :created-at now
                   :updated-at now
                   :title title
                   :root root
                   :provider provider
                   :model model
                   :profile profile
                   :meta meta
                   :tools tools
                   :system-prompt system-prompt
                   :autonomy autonomy
                   :verbosity verbosity)))
    (puthash session-id session benedict-session--registry)
    session))

(defun benedict-session-configure (session &rest config)
  "Update SESSION configuration.
CONFIG is a plist with keys: :provider :model :profile :tools
:system-prompt :autonomy :verbosity :loop-config."
  (cl-loop for (key value) on config by #'cddr
           do (pcase key
                (:provider (setf (benedict-session-provider session) value))
                (:model (setf (benedict-session-model session) value))
                (:profile (setf (benedict-session-profile session) value))
                (:tools (setf (benedict-session-tools session) value))
                (:system-prompt (setf (benedict-session-system-prompt session) value))
                (:autonomy (setf (benedict-session-autonomy session) value))
                (:verbosity (setf (benedict-session-verbosity session) value))
                (:loop-config (setf (benedict-session-loop-config session) value))))
  (benedict-session-touch session)
  session)
```

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 4.2: Add Request Building to Session

- **File**: `benedict-session.el`
- **Location**: After configuration functions
- **Changes**: Add request building

```elisp
;;; Request Building

(defun benedict-session--message->provider (message)
  "Convert internal MESSAGE to provider format."
  (let* ((role (plist-get message :role))
         (content (plist-get message :content))
         (tool-calls (plist-get message :tool-calls))
         (tool-call-id (plist-get message :tool-call-id))
         (name (plist-get message :name))
         (payload (list :role role :content (or content ""))))
    (when tool-calls
      (setq payload (plist-put payload :tool-calls tool-calls)))
    (when tool-call-id
      (setq payload (plist-put payload :tool-call-id tool-call-id)))
    (when name
      (setq payload (plist-put payload :name name)))
    payload))

(defun benedict-session--build-request (session)
  "Build a provider request plist from SESSION state."
  (let* ((provider (benedict-session-provider session))
         (model (benedict-session-model session))
         (profile (benedict-session-profile session))
         (tools (benedict-session-tools session))
         (system (benedict-session-system-prompt session))
         (autonomy (benedict-session-autonomy session))
         (verbosity (benedict-session-verbosity session))
         (history (mapcar #'benedict-session--message->provider
                          (benedict-session-messages-chronological session)))
         (messages (if system (append system history) history)))
    (list :provider provider
          :model model
          :profile profile
          :tools tools
          :autonomy autonomy
          :verbosity verbosity
          :messages messages)))
```

**Constraints**:
- Use session's stored configuration
- Read messages from session history
- Match format expected by provider

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 4.3: Update dispatch-next to Build Request

- **File**: `benedict-session.el`
- **Location**: `benedict-session--dispatch-next`
- **Changes**: Build and dispatch request

```elisp
(defun benedict-session--dispatch-next (session)
  "Dispatch next request in the loop.
Builds request from session state and dispatches."
  (let ((request (benedict-session--build-request session)))
    (if (and (plist-get request :provider)
             (plist-get request :model))
        (benedict-session-dispatch session request)
      ;; Not configured - emit event for frontend to handle
      (benedict-session--emit session 'dispatch-needed))))
```

**Constraints**:
- Only auto-dispatch if provider and model are configured
- Fall back to event if not configured

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 4.4: Add Request Building Tests

- **File**: `test/benedict-session-test.el`
- **Changes**: Add request building tests

```elisp
;;; Request Building Tests

(ert-deftest benedict-session-test-build-request ()
  "Request building uses session state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create
                    :provider 'openrouter
                    :model "claude-3"
                    :tools '((:name read_file)))))
      (benedict-session-add-message session '(:role user :content "Hello"))
      (let ((request (benedict-session--build-request session)))
        (should (eq 'openrouter (plist-get request :provider)))
        (should (string= "claude-3" (plist-get request :model)))
        (should (= 1 (length (plist-get request :messages))))))))

(ert-deftest benedict-session-test-configure ()
  "Configuration updates session state."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create)))
      (benedict-session-configure session
                                  :provider 'anthropic
                                  :model "claude-4"
                                  :loop-config '(:max-turns 10))
      (should (eq 'anthropic (benedict-session-provider session)))
      (should (string= "claude-4" (benedict-session-model session)))
      (should (= 10 (plist-get (benedict-session-loop-config session) :max-turns))))))
```

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-session-test.el` passes

### Phase 4.5: Update Chat to Configure Session

- **File**: `benedict-chat.el`
- **Location**: Session creation/initialization
- **Changes**: Pass configuration to session

```elisp
;; When creating or configuring session:
(defun benedict-chat--configure-session ()
  "Configure the session with current buffer settings."
  (when-let ((session benedict-chat--session))
    (let* ((profile (benedict-chat--effective-profile))
           (provider (benedict-chat--resolve-provider profile))
           (model (benedict-chat--resolve-model provider profile nil))
           (tools (benedict-chat--resolve-tools profile))
           (system (benedict-chat--system-messages profile))
           (autonomy (benedict-chat--profile-autonomy profile))
           (verbosity (benedict-chat--profile-verbosity profile))
           (loop-config (list :max-turns (benedict-chat--effective-limit
                                          :max-turns benedict-chat-loop-checkpoint-interval)
                              :max-time (benedict-chat--effective-limit
                                         :max-time benedict-chat-loop-max-time)
                              :max-tokens (benedict-chat--effective-limit
                                           :max-tokens benedict-chat-loop-max-tokens))))
      (benedict-session-configure session
                                  :provider provider
                                  :model model
                                  :tools tools
                                  :system-prompt system
                                  :autonomy autonomy
                                  :verbosity verbosity
                                  :loop-config loop-config))))
```

**Constraints**:
- Call when profile changes or at dispatch time
- Chat still resolves configuration (profile/model/tools)
- Session stores resolved values

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-chat-*-test.el` passes

---

## Phase 5: Final Integration and Cleanup

### Overview

By this point, most code has already been moved/deleted in earlier phases. This phase focuses on final integration, simplifying the entry point, and verifying everything works.

### Phase 5.1: Simplify Chat Send to Use Session Run

- **File**: `benedict-chat.el`
- **Location**: `benedict-chat--send-text`
- **Changes**: Simplify to just add message and call session-run

```elisp
(defun benedict-chat--send-text (text &optional buffer)
  "Send TEXT to provider via SESSION."
  (let ((chat (or buffer (benedict-chat--resolve-chat-buffer))))
    (unless (and chat (buffer-live-p chat))
      (user-error "Not in a Benedict chat buffer"))
    (with-current-buffer chat
      (unless (derived-mode-p 'benedict-chat-mode)
        (user-error "Not in a Benedict chat buffer"))
      (when (string-blank-p text)
        (user-error "Prompt is empty"))
      (let ((session benedict-chat--session))
        (unless session
          (user-error "No session attached"))
        (when (benedict-session-busy-p session)
          (user-error "A provider request is already in flight"))
        ;; Reset UI state
        (setq benedict-chat--request-seq (1+ benedict-chat--request-seq))
        (benedict-chat--streaming-reset chat)
        (benedict-chat--status-reset)
        (benedict-chat--status-start-timer)
        ;; Add user message to session
        (benedict-session-add-message session
                                      (list :role 'user :content text :time (current-time)))
        ;; Configure and run session
        (benedict-chat--configure-session)
        (benedict-session-run session)))))
```

**Success Criteria**:
- [ ] `nix run .#test -- test/benedict-chat-*-test.el` passes

### Phase 5.2: Verify Complete Event Handler Coverage

- **File**: `benedict-chat.el`
- **Location**: Event subscription handler
- **Changes**: Ensure all session events are handled for UI

**Required event handlers:**

| Event | UI Action |
|-------|-----------|
| `request-started` | Show spinner, update status |
| `draft-started` | Create streaming message placeholder |
| `draft-updated` | Append text to streaming message |
| `request-completed` | Finalize message, stop spinner |
| `message-added` | Render new message |
| `tool-started` | Create tool block |
| `tool-completed` | Update tool block with result |
| `checkpoint-requested` | Prompt user to continue/stop |
| `loop-stopped` | Update status, log reason |

**Success Criteria**:
- [ ] Manual test: Send message, streaming works
- [ ] Manual test: Tool calls display correctly
- [ ] Manual test: Checkpoint prompts appear

### Phase 5.3: Delete Any Remaining Dead Code

- **File**: `benedict-chat.el`
- **Changes**: Search for and remove any orphaned code

**Check for orphaned functions:**
```bash
# Functions that should be gone:
grep -E "handle-provider-(delta|success|error)-headless" benedict-chat.el
grep -E "loop-step|check-loop-constraints|check-repetition-guard" benedict-chat.el
grep -E "invoke-tool-call|process-tool-calls" benedict-chat.el
```

**Check for orphaned variables:**
```bash
grep -E "loop-start-time|loop-turn-count|loop-canceled" benedict-chat.el
```

All should return empty.

**Success Criteria**:
- [ ] `nix run .#test` passes (full test suite)
- [ ] All grep checks return empty
- [ ] `wc -l benedict-chat.el` shows significant line count reduction

---

## Testing Strategy

### Approach: New Tests First, Delete Conflicting Old Tests

For each phase:
1. **Write new session tests** that demonstrate the desired behavior
2. **Run new tests** - they should pass
3. **Run full test suite** - identify failing tests
4. **Delete or rewrite failing tests** that test old architecture
5. **Verify full suite passes**

### New Tests by Phase

| Phase | Test File | New Tests |
|-------|-----------|-----------|
| 1 | benedict-session-test.el | 7 dispatch tests |
| 2 | benedict-session-test.el | 3 tool execution tests |
| 3 | benedict-session-test.el | 4 loop management tests |
| 4 | benedict-session-test.el | 2 request building tests |
| 5 | (verification only) | - |

### Tests Likely to Need Deletion/Rewrite

After each phase, check these test files for failures:
- `test/benedict-chat-logic-test.el` - may test old dispatch flow
- `test/benedict-chat-integration-test.el` - may test old tool execution
- `test/benedict-chat-session-test.el` - should be fine (tests session integration)

**When a test fails:** Ask whether it's testing:
1. **Old architecture** → DELETE the test
2. **Correct behavior that's broken** → FIX the implementation

### Manual Testing Checklist

- [ ] Fresh Emacs, send message, streaming works
- [ ] Kill buffer mid-stream, re-attach, message visible
- [ ] Tool call executes and displays correctly
- [ ] Multi-turn agent loop completes task
- [ ] Checkpoint prompt appears at turn limit
- [ ] Cancel (C-c C-c) stops loop cleanly
- [ ] Error displays correctly

---

## References

- Research: `efforts/00055-session_dispatch/research.md`
- Session: `benedict-session.el`
- Chat: `benedict-chat.el`
- Provider: `benedict-provider.el:58-74`
- Tools: `benedict-tools.el:403`
- Tests: `test/benedict-session-test.el`

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking tests | Write new tests first, delete conflicting old tests |
| Missing event handlers | Phase 5.2 explicitly verifies coverage |
| Tool execution errors | Comprehensive error handling in session |
| Loop state issues | All loop state in session, single source of truth |
| Event ordering | Session controls sequencing, chat just observes |

---

## Summary: What Gets Deleted from Chat

### Functions to DELETE from `benedict-chat.el`

| Function | Phase | Moved To |
|----------|-------|----------|
| `benedict-chat--handle-provider-delta-headless` | 1.4 | `benedict-session--on-delta` |
| `benedict-chat--handle-provider-success-headless` | 1.4 | `benedict-session--on-success` |
| `benedict-chat--handle-provider-error-headless` | 1.4 | `benedict-session--on-error` |
| `benedict-chat--invoke-tool-call` | 2.4 | `benedict-session--invoke-tool` |
| `benedict-chat--process-tool-calls` | 2.4 | `benedict-session--process-tool-calls` |
| `benedict-chat--loop-step` | 3.5 | `benedict-session--loop-step` |
| `benedict-chat--check-loop-constraints` | 3.5 | `benedict-session--check-constraints` |
| `benedict-chat--check-repetition-guard` | 3.5 | `benedict-session--check-repetition` |

### Variables to DELETE from `benedict-chat.el`

| Variable | Phase | Moved To |
|----------|-------|----------|
| `benedict-chat--loop-start-time` | 3.5 | `benedict-session-loop-start-time` |
| `benedict-chat--loop-turn-count` | 3.5 | `benedict-session-loop-turn-count` |
| `benedict-chat--loop-canceled` | 3.5 | Session state + `benedict-session-stop` |

### Estimated Line Reduction

- **~200 lines** of dispatch/callback code
- **~100 lines** of tool execution code
- **~80 lines** of loop management code
- **Total: ~380 lines** moved from chat to session
