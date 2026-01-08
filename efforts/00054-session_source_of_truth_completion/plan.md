# Session Source of Truth Completion - Implementation Plan

## Overview

Complete the session-as-source-of-truth refactoring started in effort 00047. The chat buffer becomes a pure reactive view on session state, subscribing to session events rather than maintaining parallel state. Attaching a buffer to a session renders all messages and continues reacting to state updates.

## Current State Analysis

From `research.md`:

**Dual-write architecture** (`benedict-chat.el:2978-3038`): Both headless handlers (update session) and buffer handlers (update buffer-local state) are called on provider callbacks. The buffer maintains 9 variables that duplicate session state:

| Buffer Variable | Session Equivalent |
|-----------------|-------------------|
| `benedict-chat--messages` (line 465) | `(benedict-session-messages session)` |
| `benedict-chat--streaming-message` (line 487) | `(benedict-session-draft session)` |
| `benedict-chat--pending-request` (line 472) | `(benedict-session-inflight session)` |
| `benedict-chat--active-request-id` (line 490) | `(plist-get inflight :request-id)` |
| `benedict-chat--telemetry` (line 711) | **Missing from session** |
| `benedict-chat-profile` (line 739) | `(benedict-session-profile session)` |
| `benedict-chat--provider-override` (line 726) | `(benedict-session-provider session)` |
| `benedict-chat--loop-turn-count` (line 733) | `(plist-get inflight :loop-state)` |
| `benedict-chat--loop-start-time` (line 730) | `(plist-get inflight :loop-state)` |

**Event system exists but unused** (`benedict-session.el:89-102`): `benedict-session-event-hook` is defined and events are emitted, but no code subscribes to them.

**Telemetry is buffer-only** (`benedict-chat.el:1161-1260`): Token counts and timing data are lost when buffer dies.

## Desired End State

1. **Session owns all persistent state**: messages, draft, telemetry, inflight metadata
2. **Buffer subscribes to session events**: `message-added`, `draft-updated`, `draft-finalized`, `state-changed`
3. **Buffer is stateless except for UI**: items, markers, sections, spinner-index
4. **Attach renders full history**: `benedict-chat--sync-from-session` reconstructs buffer from session
5. **Multiple buffers can view same session**: each independently subscribed

### Verification

```elisp
;; Attaching to streaming session shows accumulated content
(let ((session (benedict-session-create)))
  (benedict-session-add-message session '(:role user :content "Hello"))
  (benedict-session-start-draft session "Partial response...")
  (let ((buf (benedict-chat--buffer-for-session session)))
    ;; Buffer shows user message + streaming draft
    ))

;; Killing buffer preserves telemetry
(let ((session ...))
  (with-temp-buffer
    (benedict-chat--attach-session session)
    (benedict-chat--send-text "test")
    ;; ... streaming completes ...
    )
  ;; Buffer dead, but:
  (should (benedict-session-accumulated-usage session)))
```

## What We're NOT Doing

1. **Multi-cursor streaming** - All buffers show same content, no independent cursors
2. **Undo/redo** - Message history is append-only
3. **Lazy rendering** - All messages rendered on attach (pagination deferred)
4. **Telemetry UI redesign** - Keep existing header-line format, just source from session

## Implementation Approach

**Phased migration** to maintain test stability:

1. **Phase 1**: Add missing fields to session struct (telemetry accumulation)
2. **Phase 2**: Implement event subscription infrastructure
3. **Phase 3**: Convert buffer handlers to event observers
4. **Phase 4**: Eliminate duplicate buffer-local variables
5. **Phase 5**: Fix attach flow to render full history and subscribe

Each phase ends with all tests passing.

---

## Phase 1: Extend Session Struct for Telemetry

### Overview

Add fields to `benedict-session` to hold accumulated usage and timing data that currently only exists in buffer-local telemetry.

### Changes Required

- **File**: `benedict-session.el`
  - **Changes**: Add two new fields to struct, add helper functions

```elisp
;; benedict-session.el:13-19 - Extend struct
(cl-defstruct (benedict-session (:constructor benedict-session--create))
  "In-memory session owning conversation state and runtime."
  id created-at updated-at title
  messages (message-seq 0)
  (state 'idle) draft pending-question inflight last-error last-request
  root provider model profile meta
  flywire-session attached-frontends
  ;; NEW: Telemetry fields
  (accumulated-usage nil)   ; plist: :prompt :completion :total :cost
  (accumulated-seconds 0.0)) ; float: total elapsed time

;; Add accumulation helper after line ~205
(defun benedict-session-accumulate-usage (session usage elapsed)
  "Accumulate USAGE plist and ELAPSED seconds into SESSION totals."
  (when usage
    (let ((current (or (benedict-session-accumulated-usage session)
                       '(:prompt 0 :completion 0 :total 0 :cost 0.0))))
      (setf (benedict-session-accumulated-usage session)
            (list :prompt (+ (or (plist-get current :prompt) 0)
                            (or (plist-get usage :prompt-tokens) 0))
                  :completion (+ (or (plist-get current :completion) 0)
                                (or (plist-get usage :completion-tokens) 0))
                  :total (+ (or (plist-get current :total) 0)
                           (or (plist-get usage :total-tokens) 0))
                  :cost (+ (or (plist-get current :cost) 0.0)
                          (or (plist-get usage :cost) 0.0))))))
  (when elapsed
    (cl-incf (benedict-session-accumulated-seconds session) elapsed)))
```

- **File**: `benedict-session.el`
  - **Changes**: Extend `inflight` plist to include `:started-at` for timing (already exists at line 198)

- **File**: `test/benedict-session-test.el`
  - **Changes**: Add tests for telemetry accumulation

```elisp
(ert-deftest benedict-session-test-accumulate-usage ()
  "Usage accumulates across multiple calls."
  (let ((session (benedict-session-create)))
    (benedict-session-accumulate-usage session
      '(:prompt-tokens 100 :completion-tokens 50 :total-tokens 150) 1.5)
    (should (= 100 (plist-get (benedict-session-accumulated-usage session) :prompt)))
    (should (= 1.5 (benedict-session-accumulated-seconds session)))
    ;; Second call accumulates
    (benedict-session-accumulate-usage session
      '(:prompt-tokens 200 :completion-tokens 100 :total-tokens 300) 2.0)
    (should (= 300 (plist-get (benedict-session-accumulated-usage session) :prompt)))
    (should (= 3.5 (benedict-session-accumulated-seconds session)))))
```

### Success Criteria

#### Automated Verification
- [x] `nix run .#test:benedict-session` - All session tests pass
- [x] `nix run .#test:benedict-chat-session` - Integration tests still pass

#### Manual Verification
- [ ] Evaluate `(benedict-session-accumulated-usage session)` returns plist after streaming

---

## Phase 2: Event Subscription Infrastructure

### Overview

Implement the event observer pattern: buffers subscribe on attach, unsubscribe on detach.

### Changes Required

- **File**: `benedict-chat.el`
  - **Changes**: Add subscription management functions

```elisp
;; New buffer-local variable for cleanup
(defvar-local benedict-chat--session-subscription nil
  "Function to call to unsubscribe from session events.")

(defun benedict-chat--subscribe-to-session (session)
  "Subscribe current buffer to SESSION events.
Returns unsubscribe function."
  (let ((buffer (current-buffer)))
    (lambda (sess event-type payload)
      (when (and (eq sess session)
                 (buffer-live-p buffer))
        (with-current-buffer buffer
          (benedict-chat--handle-session-event event-type payload))))))

(defun benedict-chat--unsubscribe-from-session ()
  "Unsubscribe current buffer from session events."
  (when benedict-chat--session-subscription
    (remove-hook 'benedict-session-event-hook
                 benedict-chat--session-subscription)
    (setq benedict-chat--session-subscription nil)))

(defun benedict-chat--handle-session-event (event-type payload)
  "Dispatch session EVENT-TYPE with PAYLOAD to appropriate handler."
  (pcase event-type
    ('state-changed
     (benedict-chat--observe-state-changed
      (plist-get payload :old) (plist-get payload :new)))
    ('message-added
     (benedict-chat--observe-message-added (plist-get payload :message)))
    ('draft-started
     (benedict-chat--observe-draft-started))
    ('draft-updated
     (benedict-chat--observe-draft-updated payload))
    ('draft-finalized
     (benedict-chat--observe-draft-finalized payload))
    ('destroyed
     (benedict-chat--observe-session-destroyed))))
```

- **File**: `benedict-chat.el`
  - **Changes**: Add placeholder observer functions (implemented in Phase 3)

```elisp
(defun benedict-chat--observe-state-changed (old-state new-state)
  "Handle session state transition from OLD-STATE to NEW-STATE."
  ;; Phase 3: Update status display, telemetry phase
  (ignore old-state new-state))

(defun benedict-chat--observe-message-added (message)
  "Handle new MESSAGE added to session."
  ;; Phase 3: Render message to buffer
  (ignore message))

(defun benedict-chat--observe-draft-started ()
  "Handle streaming draft started."
  ;; Phase 3: Initialize streaming UI
  )

(defun benedict-chat--observe-draft-updated (payload)
  "Handle draft update with PAYLOAD (:delta or :tool-call)."
  ;; Phase 3: Append to streaming display
  (ignore payload))

(defun benedict-chat--observe-draft-finalized (payload)
  "Handle draft finalized (PAYLOAD may have :discarded t)."
  ;; Phase 3: Close streaming UI
  (ignore payload))

(defun benedict-chat--observe-session-destroyed ()
  "Handle session destruction."
  ;; Kill buffer or show tombstone
  )
```

- **File**: `benedict-chat.el`
  - **Changes**: Wire subscription into attach/detach

```elisp
;; In benedict-chat--init-buffer, after session creation:
(setq-local benedict-chat--session-subscription
            (benedict-chat--subscribe-to-session benedict-chat--session))
(add-hook 'benedict-session-event-hook
          benedict-chat--session-subscription)

;; In benedict-chat--detach-session:
(defun benedict-chat--detach-session ()
  "Detach the current buffer from its session."
  (when benedict-chat--session
    (benedict-chat--unsubscribe-from-session)
    (benedict-session--remove-frontend benedict-chat--session (current-buffer))))
```

- **File**: `test/benedict-chat-session-test.el`
  - **Changes**: Add subscription test

```elisp
(ert-deftest benedict-chat-session-test-subscription-lifecycle ()
  "Buffer subscribes on attach, unsubscribes on kill."
  (let ((benedict-session--registry (make-hash-table :test 'equal))
        (events nil))
    (with-temp-buffer
      (benedict-chat-mode)
      (benedict-chat--init-buffer)
      ;; Subscription active
      (should benedict-chat--session-subscription)
      (should (memq benedict-chat--session-subscription
                    benedict-session-event-hook))
      ;; Events reach the buffer
      (let ((session benedict-chat--session))
        (benedict-session-set-state session 'streaming)))
    ;; After kill, subscription removed
    (should-not (memq (car events) benedict-session-event-hook))))
```

### Success Criteria

#### Automated Verification
- [x] `nix run .#test:benedict-chat-session` - All tests pass including new subscription test

#### Manual Verification
- [ ] In `*scratch*`: `(length benedict-session-event-hook)` increases after opening chat, decreases after killing

---

## Phase 3: Convert Buffer Handlers to Event Observers

### Overview

Make observer functions actually work, calling existing rendering code. Keep dual-write temporarily for safety.

### Changes Required

- **File**: `benedict-chat.el`
  - **Changes**: Implement `benedict-chat--observe-state-changed`

```elisp
(defun benedict-chat--observe-state-changed (old-state new-state)
  "Handle session state transition from OLD-STATE to NEW-STATE."
  ;; Update telemetry phase display
  (pcase new-state
    ('idle
     (when (eq old-state 'streaming)
       ;; Request finished - accumulate usage to session
       (when-let* ((session benedict-chat--session)
                   (inflight (benedict-session-inflight session)))
         (let* ((started (plist-get inflight :started-at))
                (elapsed (when started (float-time (time-subtract nil started)))))
           ;; Telemetry will be accumulated by headless handler
           )))
     (benedict-chat--status-stop-timer))
    ('streaming
     (benedict-chat--status-start-timer))
    ('error
     (benedict-chat--status-stop-timer)))
  ;; Refresh header line
  (force-mode-line-update))
```

- **File**: `benedict-chat.el`
  - **Changes**: Implement `benedict-chat--observe-message-added`

```elisp
(defun benedict-chat--observe-message-added (message)
  "Handle new MESSAGE added to session."
  ;; Don't duplicate if we just added it ourselves
  (unless (cl-find (plist-get message :id) benedict-chat--messages
                   :key (lambda (m) (plist-get m :id)) :test #'equal)
    ;; Add to local cache for rendering
    (push message benedict-chat--messages)
    ;; Render to buffer
    (benedict-chat--render-message (current-buffer) message)))
```

- **File**: `benedict-chat.el`
  - **Changes**: Implement draft observers

```elisp
(defun benedict-chat--observe-draft-started ()
  "Handle streaming draft started."
  ;; Initialize streaming UI state
  (benedict-chat--ensure-streaming-section))

(defun benedict-chat--observe-draft-updated (payload)
  "Handle draft update with PAYLOAD (:delta or :tool-call)."
  (when-let ((delta (plist-get payload :delta)))
    ;; Stream the delta to the display
    (benedict-chat--stream-append delta))
  (when-let ((tool-call (plist-get payload :tool-call)))
    ;; Add tool call indicator
    (benedict-chat--stream-tool-call tool-call)))

(defun benedict-chat--observe-draft-finalized (payload)
  "Handle draft finalized (PAYLOAD may have :discarded t)."
  (if (plist-get payload :discarded)
      (benedict-chat--streaming-cancel-ui)
    (benedict-chat--streaming-finalize-ui)))
```

- **File**: `benedict-chat.el`
  - **Changes**: Modify headless success handler to accumulate telemetry

```elisp
;; In benedict-chat--handle-provider-success-headless (line ~2939)
;; After finalizing draft, accumulate usage:
(when-let* ((usage (plist-get metadata :usage))
            (started (plist-get (benedict-session-inflight session) :started-at)))
  (let ((elapsed (float-time (time-subtract nil started))))
    (benedict-session-accumulate-usage session usage elapsed)))
```

### Success Criteria

#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-session-test.el` - All existing tests pass
- [x] `nix run .#test -- benedict-chat-integration-test.el` - Streaming tests pass

#### Manual Verification
- [ ] Open chat, send message, see streaming response
- [ ] Kill buffer during streaming, reattach, see completed message

---

## Phase 4: Eliminate Duplicate Buffer-Local Variables

### Overview

Remove buffer-local variables that duplicate session state. Buffer reads directly from session.

### Changes Required

- **File**: `benedict-chat.el`
  - **Changes**: Remove these buffer-local variable definitions:
    - `benedict-chat--messages` (line 465) - **REMOVE**
    - `benedict-chat--streaming-message` (line 487) - **REMOVE**
    - `benedict-chat--pending-request` (line 472) - **REMOVE**
    - `benedict-chat--active-request-id` (line 490) - **REMOVE**

- **File**: `benedict-chat.el`
  - **Changes**: Update functions that read from these variables

```elisp
;; benedict-chat--message-history (line ~1749)
;; Change from reading benedict-chat--messages to:
(defun benedict-chat--message-history ()
  "Return message history for current buffer's session."
  (when benedict-chat--session
    (benedict-session-messages-chronological benedict-chat--session)))

;; benedict-chat--find-last-assistant (line ~3557)
;; Change to read from session:
(defun benedict-chat--find-last-assistant ()
  "Find last assistant message from session."
  (when benedict-chat--session
    (cl-find 'assistant (benedict-session-messages benedict-chat--session)
             :key (lambda (m) (plist-get m :role)))))
```

- **File**: `benedict-chat.el`
  - **Changes**: Update streaming checks to use session

```elisp
;; Replace checks like (benedict-chat--pending-request) with:
(benedict-session-request-active-p benedict-chat--session)

;; Replace reads of benedict-chat--streaming-message with:
(benedict-session-draft benedict-chat--session)
```

- **File**: `benedict-chat.el`
  - **Changes**: Remove telemetry functions that mutate buffer state

Delete or repurpose:
- `benedict-chat--telemetry-reset` (line 1161)
- `benedict-chat--telemetry-update` (line 1178)
- `benedict-chat--telemetry-begin` (line 1238)
- `benedict-chat--telemetry-streaming` (line 1253)
- `benedict-chat--telemetry-finish` (line 1260)

Replace with session-reading functions:

```elisp
(defun benedict-chat--telemetry-for-display ()
  "Return telemetry plist for header-line display.
Reads from session state."
  (when benedict-chat--session
    (let* ((session benedict-chat--session)
           (state (benedict-session-state session))
           (inflight (benedict-session-inflight session))
           (usage (benedict-session-accumulated-usage session))
           (seconds (benedict-session-accumulated-seconds session)))
      (list :phase (pcase state
                     ('streaming 'streaming)
                     ('idle 'idle)
                     (_ 'idle))
            :session-usage usage
            :session-seconds seconds
            :started-at (plist-get inflight :started-at)))))
```

### Success Criteria

#### Automated Verification
- [X] `nix run .#test` - All tests pass
- [X] `nix run .#lint` (if exists) - No warnings about undefined variables

#### Manual Verification
- [ ] `M-x describe-variable RET benedict-chat--messages` shows "void variable" (removed)
- [ ] Chat still works normally

---

## Phase 5: Fix Attach Flow for Full History Render

### Overview

When attaching to an existing session (new buffer or reattach), render all messages and current draft state, then subscribe for future updates.

### Changes Required

- **File**: `benedict-chat.el`
  - **Changes**: Rewrite `benedict-chat--render-session-history`

```elisp
(defun benedict-chat--sync-from-session (session)
  "Synchronize buffer state from SESSION.
Renders all messages and current streaming state."
  (let ((inhibit-read-only t))
    ;; Clear any existing items
    (setq benedict-chat--items nil)
    (setq benedict-chat--thinking-items (make-hash-table :test 'equal))
    (setq benedict-chat--item-counter 0)

    ;; Render all messages in chronological order
    (dolist (msg (benedict-session-messages-chronological session))
      (benedict-chat--render-message (current-buffer) msg))

    ;; If streaming, render accumulated draft
    (when (eq 'streaming (benedict-session-state session))
      (when-let ((draft (benedict-session-draft session)))
        (benedict-chat--observe-draft-started)
        (when-let ((content (plist-get draft :content)))
          (unless (string-empty-p content)
            (benedict-chat--stream-append content)))
        (dolist (tc (plist-get draft :tool-calls))
          (benedict-chat--stream-tool-call tc))))

    ;; Scroll to end
    (goto-char (point-max))))
```

- **File**: `benedict-chat.el`
  - **Changes**: Update `benedict-chat--buffer-for-session`

```elisp
;; In benedict-chat--buffer-for-session (line ~3949)
;; After attaching to session:
(with-current-buffer buf
  ;; ... existing code ...
  (setq-local benedict-chat--session session)
  (benedict-session--add-frontend session (current-buffer))
  ;; Subscribe to events
  (setq-local benedict-chat--session-subscription
              (benedict-chat--subscribe-to-session session))
  (add-hook 'benedict-session-event-hook
            benedict-chat--session-subscription)
  ;; Sync buffer from session
  (benedict-chat--sync-from-session session))
```

- **File**: `test/benedict-chat-session-test.el`
  - **Changes**: Add comprehensive attach tests

```elisp
(ert-deftest benedict-chat-session-test-attach-renders-history ()
  "Attaching to session with messages renders them."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Test")))
      (benedict-session-add-message session '(:role user :content "Hello"))
      (benedict-session-add-message session '(:role assistant :content "Hi there"))
      (let ((buf (benedict-chat--buffer-for-session session)))
        (with-current-buffer buf
          ;; Buffer should show both messages
          (should (= 2 (length benedict-chat--items)))
          (goto-char (point-min))
          (should (search-forward "Hello" nil t))
          (should (search-forward "Hi there" nil t)))
        (kill-buffer buf)))))

(ert-deftest-async benedict-chat-session-test-attach-during-streaming (done)
  "Attaching mid-stream shows accumulated content."
  (benedict-test-with-bindings done
      ((benedict-session--registry (make-hash-table :test 'equal))
       (benedict-provider 'fake)
       (benedict-provider-fake-script
        (list (list :type 'success
                    :chunks '("Part1 " "Part2 " "Part3")
                    :chunk-delay 0.02
                    :delay 0.1))))
    (let ((session nil))
      ;; Start streaming headlessly
      (with-temp-buffer
        (benedict-chat-mode)
        (benedict-chat--init-buffer)
        (setq session benedict-chat--session)
        (benedict-chat--send-text "Test"))
      ;; Wait for chunks, then attach new buffer
      (run-at-time 0.05 nil
        (lambda ()
          (let ((buf (benedict-chat--buffer-for-session session)))
            (with-current-buffer buf
              ;; Should see accumulated content
              (should (search-forward "Part1" nil t)))
            ;; Wait for completion
            (run-at-time 0.1 nil
              (lambda ()
                (with-current-buffer buf
                  ;; Full content visible
                  (goto-char (point-min))
                  (should (search-forward "Part3" nil t)))
                (kill-buffer buf)
                (funcall done)))))))))

(ert-deftest benedict-chat-session-test-multi-buffer-same-session ()
  "Multiple buffers can view the same session."
  (let ((benedict-session--registry (make-hash-table :test 'equal)))
    (let ((session (benedict-session-create :title "Multi")))
      (benedict-session-add-message session '(:role user :content "Test"))
      (let ((buf1 (benedict-chat--buffer-for-session session)))
        ;; Force second buffer creation
        (let ((buf2 (get-buffer-create "*test-second*")))
          (with-current-buffer buf2
            (benedict-chat-mode)
            (setq-local benedict-chat--session session)
            (benedict-session--add-frontend session (current-buffer))
            (setq-local benedict-chat--session-subscription
                        (benedict-chat--subscribe-to-session session))
            (add-hook 'benedict-session-event-hook
                      benedict-chat--session-subscription)
            (benedict-chat--sync-from-session session))
          ;; Both buffers attached
          (should (= 2 (length (benedict-session-frontends session))))
          ;; Add message, both should see it
          (benedict-session-add-message session '(:role user :content "Second"))
          (with-current-buffer buf1
            (should (search-forward "Second" nil t)))
          (with-current-buffer buf2
            (should (search-forward "Second" nil t)))
          (kill-buffer buf2))
        (kill-buffer buf1)))))
```

### Success Criteria

#### Automated Verification
- [x] `nix run .#test -- test/benedict-chat-session-test.el` - Attach/streaming tests pass
- [x] `nix run .#test` - All tests pass including new attach tests

#### Manual Verification
- [ ] Start streaming, kill buffer, run `(benedict-chat--buffer-for-session session)` - see content
- [ ] Two `M-x benedict-chat` on same session shows same messages

---

## Testing Strategy

### Unit Tests (per phase)
- Phase 1: `benedict-session-test-accumulate-usage`
- Phase 2: `benedict-chat-session-test-subscription-lifecycle`
- Phase 3: Existing streaming tests verify observer wiring
- Phase 4: Existing tests catch regressions from variable removal
- Phase 5: `benedict-chat-session-test-attach-*`, `*-multi-buffer-*`

### Integration Tests
- `benedict-chat-integration-test.el` covers marker stability during streaming
- `benedict-chat-session-test-headless-*` verify session survives buffer kill

### Property Tests
- `benedict-chat-session-prop-messages-sync` verifies message count consistency

### Manual Testing Checklist
1. Open chat, send message, get response - works as before
2. Kill buffer during streaming, open new chat for same session - shows content
3. Check header line shows token counts - reads from session
4. Run `(benedict-session-accumulated-usage session)` - shows totals
5. Two windows viewing same session - both update on new message

## References

- Research: `efforts/00054-session_source_of_truth_completion/research.md`
- Previous effort: `efforts/00047-effort_benedict_session/plan.md`
- Session module: `benedict-session.el`
- Chat module: `benedict-chat.el`
- Session tests: `test/benedict-session-test.el`
- Integration tests: `test/benedict-chat-session-test.el`
