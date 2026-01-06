# Emacs Face and Overlay Application Guide: How markdown-mode Works

Based on analysis of markdown-mode's implementation, here's a comprehensive guide to understanding how faces and overlays are applied in Emacs, and how this integrates with the buffer lifecycle and update loop.

## Quick Overview

Faces (colors/styling) are applied through **font-lock**, a sophisticated system that:
1. Runs on-demand during buffer changes (JIT-lock)
2. Uses regex matchers to find text patterns
3. Applies `face` properties and other text properties to marked regions
4. Updates incrementally as you type

Overlays are used less frequently in markdown-mode but are available for:
- Inline images (hidden/shown with overlays)
- Temporary visual feedback
- More advanced display properties

## The Emacs Update Loop and Face Application

### The Display Pipeline

When you type in Emacs:

```
User edits buffer
    ↓
`after-change-functions` hooks fire
    ↓
JIT-lock detects changed region
    ↓
JIT-lock calls `syntax-propertize-function`
    ↓
JIT-lock calls `font-lock-default-function`
    ↓
Font-lock matchers find patterns & apply faces
    ↓
Display engine renders with applied faces
    ↓
User sees styled text on screen
```

### Key Components

**1. JIT-Lock (Just-In-Time Lock)**
- Not font-lock, but the *trigger* for font-lock
- Monitors buffer modifications
- Identifies regions needing fontification
- Calls font-lock lazily (only visible + nearby regions)

**2. Syntax Properties** (pre-processing step)
- Applied before font-lock via `syntax-propertize-function`
- Sets `syntax-table` property to modify comment/string detection
- Helps font-lock understand structure

**3. Font-Lock** (the actual styling system)
- Pattern matchers search for text
- Return match data that font-lock processes
- Font-lock applies faces based on group numbers

## How markdown-mode Implements This

### Phase 1: Syntax Propertization

In markdown-mode's initialization (line 10382):
```elisp
(setq-local syntax-propertize-function #'markdown-syntax-propertize)
```

The `markdown-syntax-propertize` function (line 1856) is called for regions needing updates:
```elisp
(defun markdown-syntax-propertize (start end)
  (with-silent-modifications
    (save-excursion
      (remove-text-properties start end markdown--syntax-properties)
      (markdown-syntax-propertize-fenced-block-constructs start end)
      (markdown-syntax-propertize-list-items start end)
      (markdown-syntax-propertize-pre-blocks start end)
      (markdown-syntax-propertize-blockquotes start end)
      (markdown-syntax-propertize-headings start end)
      (markdown-syntax-propertize-hrs start end)
      (markdown-syntax-propertize-comments start end))))
```

**What happens here:**
- `with-silent-modifications`: Doesn't trigger undo/modification hooks
- Each function scans its region and applies `syntax-table` properties
- These properties tell Emacs how to parse code blocks, lists, etc.
- Example: Marks code blocks so content inside isn't treated as Markdown

### Phase 2: JIT-Lock Extension

When text is modified, JIT-lock needs to know what region to refontify. Markdown-mode hooks into this:

```elisp
(add-hook 'jit-lock-after-change-extend-region-functions
          #'markdown-font-lock-extend-region-function t t)
```

The `markdown-font-lock-extend-region-function` (line 1250) tells JIT-lock:
- Extend the region to include complete blocks
- Don't fontify mid-block (causes visual artifacts)
- Uses double-newlines as block boundaries

**Key code:**
```elisp
(defun markdown-font-lock-extend-region-function (start end _)
  (let ((res (markdown-syntax-propertize-extend-region start end)))
    (when res
      (setq jit-lock-start (car res)
            jit-lock-end (cdr res)))))
```

This prevents situations like:
- User types "`code`" and only the backtick gets colored (wrong!)
- Instead: entire phrase is recognized as code block

### Phase 3: Font-Lock Configuration

Setup at mode initialization (lines 10385-10392):
```elisp
(setq font-lock-defaults
      '(markdown-mode-font-lock-keywords
        nil nil nil nil
        (font-lock-multiline . t)
        (font-lock-syntactic-face-function . markdown-syntactic-face)
        (font-lock-extra-managed-props
         . (composition display invisible rear-nonsticky
                        keymap help-echo mouse-face))))
```

**Breaking this down:**

- `markdown-mode-font-lock-keywords`: The giant list of patterns and how to apply them
- `nil nil nil nil`: Uses default case-sensitive, keyword-based matching
- `font-lock-multiline . t`: Patterns can span multiple lines
- `font-lock-syntactic-face-function`: Custom function to color comments
- `font-lock-extra-managed-props`: Properties that font-lock will manage (won't let other code break)

### Phase 4: The Font-Lock Keywords

This is the core (lines 2226-2333). Each entry is:
```elisp
(MATCHER . SUBEXP-HIGHLIGHTER)
```

**Example - Inline code:**
```elisp
(markdown-match-code . ((1 markdown-markup-properties prepend)
                        (2 'markdown-inline-code-face prepend)
                        (3 markdown-markup-properties prepend)))
```

**What this means:**
1. Call `markdown-match-code` function to find matches
2. Apply `markdown-markup-properties` to group 1 (the opening backtick)
   - `prepend`: Add to any existing faces (don't override)
3. Apply `'markdown-inline-code-face` to group 2 (the code text)
4. Apply properties to group 3 (closing backtick)

**Pattern-finding example - Bold text:**
```elisp
(defun markdown-match-bold (last)
  (let (done retval last-inline-code)
    (while (not done)
      ;; Search for **bold** or __bold__ pattern
      (if (markdown-match-inline-generic markdown-regex-bold last)
          ;; Complex logic to check if truly bold:
          ;; - Not inside inline code
          ;; - Not in comment
          ;; - Not in URL
          ;; - GFM rules about underscores apply
          (if (valid-bold-position?)
              (progn (setq done t retval t))
            ;; Keep searching if false positive
            (goto-char (min (1+ begin) last)))
        (setq done t)))
    retval))
```

The matcher:
- Searches forward from point to `last` position
- Returns non-nil if found (match data set via `set-match-data`)
- Font-lock extracts groups and applies the faces

### Phase 5: Advanced - Fontify Functions

Some patterns are too complex for regex. Markdown-mode provides custom fontify functions:

**Example - Headings (line 3581):**
```elisp
(defun markdown-fontify-headings (last)
  (when (markdown-match-propertized-text 'markdown-heading last)
    (let* ((level (markdown-outline-level))
           (heading-face (intern (format "markdown-header-face-%d" level))))
      (add-text-properties
       (match-beginning 4) (match-end 4) left-markup-props)
      ;; Apply level-specific face
      (add-text-properties fontified-start fontified-end 
                          `(face ,heading-face)))))
```

This:
- Finds heading with custom logic (`markdown-match-propertized-text`)
- Determines level (1-6)
- Applies level-specific face (`markdown-header-face-1`, etc.)
- Conditionally hides markup with `display: ""`

**Example - Native syntax highlighting in code blocks (line 9296):**
```elisp
(defun markdown-fontify-code-block-natively (lang start end)
  ;; Extract language and get its mode
  (let ((lang-mode (markdown-get-lang-mode lang)))
    ;; Remove any previous faces
    (remove-text-properties start end '(face nil))
    ;; Create temp buffer with code
    (with-current-buffer (get-buffer-create " *markdown-code-fontification*")
      ;; Run the language's major mode
      (funcall lang-mode)
      ;; Run its font-lock
      (font-lock-ensure)
      ;; Copy the faces back to markdown buffer
      (while (setq next (next-single-property-change pos 'face))
        (put-text-property (+ start pos) (+ start next) 'face val)))))
```

This is recursive font-locking: markdown-mode calls Python's font-lock, then Python's faces, in a Markdown buffer!

## Text Properties vs Overlays

### Text Properties (What markdown-mode primarily uses)

```elisp
(put-text-property start end 'face 'markdown-bold-face)
(add-text-properties start end '(invisible markdown-markup))
```

**Characteristics:**
- Attached to buffer positions
- Survive undo/copy-paste
- Permanent until removed or region killed
- More memory efficient
- Used for: faces, invisibility, help-echo, keymaps

**In markdown-mode:**
```elisp
(defconst markdown-markup-properties
  '(face markdown-markup-face invisible markdown-markup)
  "List of properties and values to apply to markup.")
```

When `markdown-hide-markup` is enabled, properties include:
- `face markdown-markup-face`: Color
- `invisible markdown-markup`: Hide it!

Then:
```elisp
(if markdown-hide-markup
    (add-to-invisibility-spec 'markdown-markup)
  (remove-from-invisibility-spec 'markdown-markup))
```

This toggles visibility without re-processing text.

### Overlays (Rarely used, but available)

```elisp
(let ((ov (make-overlay start end)))
  (overlay-put ov 'display "image content")
  (overlay-put ov 'face 'markdown-inline-image-face))
```

**Characteristics:**
- Floating objects not tied to specific chars
- Can overlap or conflict
- Don't survive save/restore
- Better for: images, temporary highlighting, tooltips
- More powerful display properties

**In markdown-mode - inline images:**
```elisp
markdown-inline-image-overlays  ;; Variable tracking overlays
(markdown-toggle-inline-images) ;; Creates/destroys overlays
```

When enabled:
- Find `![alt](url)` patterns
- Create overlay from `[` to `]`
- Replace with actual image via `display` property
- Store overlay reference for later removal

## Streaming Text Application (For Your Use Case)

When streaming response text (e.g., from LLM), here's what happens:

### Naive Approach (Bad)
```elisp
(while (read-from-stream)
  (insert text)
  ;; Emacs auto-triggers font-lock
  ;; But entire visible buffer re-fontifies every insert
  ;; = Terrible performance
)
```

### Better Approach
```elisp
(let ((inhibit-modification-hooks t))
  (while (read-from-stream)
    (insert text)))
;; After done: font-lock processes entire new content at once
```

**Why this works:**
- Disables JIT-lock triggers
- Inserts all text without intermediate processing
- When re-enabled, single font-lock pass processes everything

### Best Approach for Streaming
```elisp
(defun stream-response ()
  (let ((start (point)))
    (let ((inhibit-modification-hooks t))
      (while (read-chunk)
        (insert chunk)))
    ;; Force font-lock on just the new region
    (font-lock-flush start (point))
    (font-lock-ensure start (point))))
```

**Key functions:**
- `font-lock-flush`: Clear cached fontification
- `font-lock-ensure`: Ensure region is fontified before display

### For Real-Time Streaming With Incremental Display

If you want to show text *as it arrives* with styling:

```elisp
(defun stream-response-with-display ()
  (let ((start (point)))
    (while (read-chunk)
      (let ((chunk-start (point)))
        (insert chunk)
        ;; Fontify just this chunk (JIT-lock would do this anyway)
        (font-lock-flush chunk-start (point))
        ;; But don't wait - let Emacs continue
        (redisplay t)))))
```

The `redisplay` call:
- Updates display immediately
- Shows newly typed + styled text right away
- Then continues processing

## Practical Implementation for Your Agentic Chat

For an Emacs chat buffer receiving streamed Markdown:

```elisp
(defun stream-insert-response (text)
  "Insert TEXT and apply Markdown styling incrementally."
  (let ((start (point)))
    (insert text)
    ;; Tell Emacs this region needs fontification
    (font-lock-flush start (point))
    ;; Fontify visible region only (performance)
    (font-lock-ensure start (point))))

(defun setup-chat-buffer ()
  (markdown-mode)
  ;; Your buffer now has all markdown-mode styling
  ;; When you call stream-insert-response, it auto-applies
  )
```

**Why this is clean:**
- markdown-mode handles all pattern recognition
- Font-lock handles incremental updates
- JIT-lock ensures only visible regions waste CPU
- No custom face code needed

### Handling Incomplete Markdown During Streaming

Problem: While streaming, you might have incomplete syntax:
- Opened `**` but not closed
- Unclosed ` ```code block ```

Solution: Use `font-lock-extend-region-functions`:

```elisp
(add-hook 'jit-lock-after-change-extend-region-functions
          #'my-extend-region-for-incomplete-markdown nil t)

(defun my-extend-region-for-incomplete-markdown (start end)
  ;; If we're inside unclosed markdown, extend to safe boundary
  (let ((new-start (markdown-extend-to-block-start start))
        (new-end (markdown-extend-to-block-end end)))
    (cons new-start new-end)))
```

This prevents:
- Partial bold text (`**text` without closing) from breaking styling below
- Incomplete code blocks from confusing the fontifier

## Throttled Fontification for Streaming

For visible incremental styling during streaming, use a throttled approach with timers:

### Basic Timer Pattern

```elisp
(defvar my-stream-timer nil
  "Timer for throttled fontification during streaming.")

(defvar my-stream-last-fontified (point-min)
  "Position of last fontified content during streaming.")

(defun stream-with-throttled-fontification (chunk)
  "Insert CHUNK and fontify at throttled intervals."
  (let ((insert-start (point)))
    ;; Insert text without triggering modification hooks
    (let ((inhibit-modification-hooks t))
      (insert chunk))
    ;; Schedule fontification (timer prevents excessive calls)
    (stream--schedule-fontification insert-start (point))))

(defun stream--schedule-fontification (start end)
  "Schedule fontification of START to END region.
Throttles to avoid excessive processing during rapid inserts."
  ;; Cancel previous timer if still pending
  (when my-stream-timer
    (cancel-timer my-stream-timer))
  ;; Schedule next fontification in 50-100ms
  ;; (adjust based on chunk size and desired responsiveness)
  (setq my-stream-timer
        (run-with-timer 0.05 nil
                        #'stream--apply-fontification
                        start end)))

(defun stream--apply-fontification (start end)
  "Actually apply fontification from START to END."
  (setq my-stream-timer nil)
  ;; Only fontify if buffer still exists
  (when (buffer-live-p (current-buffer))
    ;; Clear cached fontification
    (font-lock-flush start end)
    ;; Fontify visible + nearby regions
    (font-lock-ensure start end)
    ;; Force redisplay so user sees styled text
    (redisplay t)
    (setq my-stream-last-fontified end)))
```

### Coalescing Multiple Chunks

If chunks arrive faster than 50ms, batch them:

```elisp
(defvar my-stream-pending-start nil
  "Start position of pending fontification batch.")

(defvar my-stream-pending-end nil
  "End position of pending fontification batch.")

(defun stream-with-coalesced-fontification (chunk)
  "Insert CHUNK, coalescing fontification requests."
  (let ((insert-start (point)))
    (let ((inhibit-modification-hooks t))
      (insert chunk))
    (let ((insert-end (point)))
      ;; Expand pending range
      (setq my-stream-pending-start 
            (or my-stream-pending-start insert-start))
      (setq my-stream-pending-end insert-end)
      ;; Reschedule timer (if already running, this moves it)
      (stream--schedule-fontification 
       my-stream-pending-start my-stream-pending-end))))

(defun stream--apply-fontification (start end)
  "Apply fontification and clear pending state."
  (setq my-stream-timer nil
        my-stream-pending-start nil
        my-stream-pending-end nil)
  (when (buffer-live-p (current-buffer))
    (font-lock-flush start end)
    (font-lock-ensure start end)
    (redisplay t)))
```

### Why This Works

**Problem without throttling:**
- Insert "H", fontify (slow regex pass)
- Insert "e", fontify again (overlapping passes!)
- Insert "l", fontify again
- = O(n²) fontification for n characters

**With throttling:**
- Insert "H", schedule timer for 50ms
- Insert "e", reschedule timer for 50ms (old timer cancels)
- Insert "l", reschedule timer for 50ms
- After 50ms with no new input: fontify all 3 chars at once
- = O(n) total work

**With coalescing + batching:**
- 1000 chars arrive in 10ms bursts
- Each burst cancels/reschedules timer
- After 50ms idle: single fontification pass over entire range
- Perfect for: network streaming, async subprocess output

### Practical Example: LLM Response Streaming

```elisp
(defun my-chat/stream-response (stream-func buffer)
  "Stream response into BUFFER, with styled incremental display.
STREAM-FUNC is a function that calls a callback with text chunks."
  (with-current-buffer buffer
    ;; Setup
    (let ((start-pos (point))
          (inhibit-modification-hooks t))
      ;; Insert without triggering hooks
      (funcall stream-func
               (lambda (chunk)
                 (insert chunk)
                 ;; Schedule (not execute) fontification
                 (stream--schedule-fontification start-pos (point))))
      ;; After streaming done, ensure final fontification happens
      (stream--schedule-fontification start-pos (point-max)))))

;; Usage
(my-chat/stream-response
  (lambda (callback)
    ;; Simulate streaming (replace with actual API call)
    (dolist (chunk (split-string "# Response\n\nThis is **bold** text" ""))
      (sleep-for 0.01)
      (funcall callback chunk)))
  (current-buffer))
```

### Handling Incomplete Markdown

Streamed text might have unclosed syntax. Extend regions to avoid visual glitches:

```elisp
(defun stream--apply-fontification (start end)
  "Apply fontification, extending to block boundaries."
  (setq my-stream-timer nil)
  (when (buffer-live-p (current-buffer))
    ;; Extend to safe boundaries (don't cut mid-block)
    (let* ((extended-start (markdown-syntax-propertize-extend-region start start))
           (extended-end (markdown-syntax-propertize-extend-region end end))
           (final-start (if extended-start (car extended-start) start))
           (final-end (if extended-end (cdr extended-end) end)))
      (font-lock-flush final-start final-end)
      (font-lock-ensure final-start final-end)
      (redisplay t))))
```

### Performance Tuning

Adjust the timer delay based on your needs:

```elisp
;; Fast, responsive (50ms = ~20 updates/sec)
(run-with-timer 0.05 nil #'fontify-func start end)

;; Moderate (100ms = ~10 updates/sec, less CPU)
(run-with-timer 0.10 nil #'fontify-func start end)

;; Lazy (200ms = ~5 updates/sec, minimal CPU)
(run-with-timer 0.20 nil #'fontify-func start end)
```

**Rule of thumb:**
- 50ms: Good balance for UI responsiveness
- Faster than human reading, slow enough for efficient batching
- Faster network might need faster timer
- Slower machines might need slower timer

### Combining With Other Features

```elisp
(defun stream-response-complete ()
  "Called when streaming finishes."
  ;; Cancel pending timer
  (when my-stream-timer
    (cancel-timer my-stream-timer)
    (setq my-stream-timer nil))
  ;; Final fontification pass
  (font-lock-flush (point-min) (point-max))
  (font-lock-ensure (point-min) (point-max))
  ;; Optional: Run hooks for post-processing
  (run-hooks 'my-stream-complete-hook))
```

### Cleanup on Buffer Kill

```elisp
(defun setup-stream-buffer ()
  "Setup for streaming responses."
  (markdown-mode)
  ;; Clean up timer if buffer is killed during streaming
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when my-stream-timer
                (cancel-timer my-stream-timer)))
            nil t))
```

## Key Takeaways

1. **Font-lock is lazy**: Only fontifies when needed (visible region)
2. **Syntax properties prepare the way**: They mark structure before font-lock runs
3. **JIT-lock extends wisely**: Knows to extend regions to avoid mid-block cuts
4. **Text properties are permanent**: Faces survive buffer operations
5. **Overlays are optional**: Use for temporary, image-based, or conflicting styling
6. **Streaming is optimized**: Disable modification hooks, batch insert, then fontify
7. **Pattern matchers are flexible**: Regex + custom validation for complex rules
8. **Throttling prevents O(n²)**: Timer-based fontification batches rapid inserts efficiently
9. **Coalescing saves CPU**: Reschedule timers instead of fontifying every chunk
10. **Redisplay forces update**: `redisplay t` ensures user sees styled text immediately

For your streaming markdown chat with visible incremental styling:

```elisp
(my-chat/stream-response callback-func (current-buffer))
;; Styled text appears as it streams, throttled to ~20 updates/sec
```

No manual face code needed—markdown-mode + throttled fontification handles it all.

## Multi-Region Mode Strategy: Chat Buffer Architecture

For a chat buffer with mixed content (metadata headers, markdown responses, controls), you need to carefully handle which regions get which mode's styling and behavior.

### Strategy 1: Font-Lock Only (Simplest)

Apply markdown-mode's font-lock to specific regions without changing the buffer's major mode:

```elisp
(defun my-chat/setup-buffer ()
  "Setup chat buffer with markdown styling in message regions."
  (text-mode)  ;; Base mode for the whole buffer
  (markdown-mode)  ;; This also enables markdown's font-lock
  ;; But we'll selectively apply it below
  )

(defun my-chat/insert-metadata (content)
  "Insert metadata header (no markdown styling)."
  (let ((start (point)))
    (insert content)
    ;; These properties tell font-lock to skip this region
    (put-text-property start (point) 'font-lock-face nil)
    (put-text-property start (point) 'face 'font-lock-comment-face)))

(defun my-chat/insert-markdown-response (content)
  "Insert AI response with markdown styling."
  (let ((start (point)))
    (let ((inhibit-modification-hooks t))
      (insert content))
    ;; Let markdown-mode's font-lock handle this region
    ;; (no special properties needed)
    (font-lock-flush start (point))
    (font-lock-ensure start (point))))
```

**Pros:**
- Simple, single major mode
- Full markdown-mode benefits
- All content editable in same buffer

**Cons:**
- Font-lock regex still runs on ALL text (slight overhead)
- Can't fully suppress markdown mode behavior in other regions
- Less clean separation of concerns

### Strategy 2: Indirect Buffers (Recommended for Heavy Mixing)

Create invisible indirect buffers for markdown regions, each with its own major mode:

```elisp
(defvar-local my-chat/message-buffers nil
  "List of (start . indirect-buffer) for chat messages.")

(defun my-chat/create-message-buffer (base-name)
  "Create an indirect buffer for a chat message with markdown-mode."
  (let* ((name (format " *%s-msg*" base-name))
         (indirect (make-indirect-buffer (current-buffer) name t)))
    (with-current-buffer indirect
      (markdown-mode))
    indirect))

(defun my-chat/insert-markdown-response (content)
  "Insert AI response using indirect buffer for markdown."
  (let ((msg-start (point))
        (indirect-buf (my-chat/create-message-buffer "response")))
    ;; Insert into main buffer
    (insert content "\n")
    ;; Map the indirect buffer to this region
    (push (cons msg-start indirect-buf) my-chat/message-buffers)
    ;; Sync content to indirect buffer
    (with-current-buffer indirect-buf
      (let ((inhibit-modification-hooks t))
        (erase-buffer)
        (insert content))
      (markdown-mode))))

(defun my-chat/copy-code-block (block-id)
  "Copy code block from markdown region to kill ring.
Called via keymap from markdown region."
  (let* ((msg-buffer (my-chat/find-message-for-block block-id))
         (block (markdown-code-block-at-pos-in-buffer msg-buffer)))
    (when block
      (kill-new (buffer-substring-no-properties
                 (car block) (cdr block))))))

(defun my-chat/find-message-for-block (pos)
  "Find which indirect buffer contains POS."
  (car (cl-find-if (lambda (entry)
                     (let ((buf (cdr entry)))
                       (and buf (buffer-live-p buf)
                            (with-current-buffer buf
                              (<= (point-min) pos (point-max))))))
                   my-chat/message-buffers)))
```

**Pros:**
- Each region has its own major mode
- Clean separation: metadata can be `text-mode`, responses `markdown-mode`
- Can edit markdown region independently
- Full major mode features (keybindings, etc.)

**Cons:**
- More complex setup
- Syncing content between buffers needed
- Indirect buffers add memory overhead (one per message)
- Less suitable if messages are very numerous

**When to use:**
- Few, large messages (e.g., single LLM response per buffer)
- Want full markdown editing in response region
- Need per-region keybindings

### Strategy 3: Font-Lock Extensions (Most Flexible)

Extend markdown-mode's font-lock to recognize and ignore non-markdown regions:

```elisp
(defun my-chat/setup-mixed-buffer ()
  "Setup buffer with markdown-mode aware of chat regions."
  (markdown-mode)
  ;; Add custom font-lock extension
  (add-hook 'font-lock-extend-region-functions
            #'my-chat/extend-region-skip-metadata nil t))

(defun my-chat/extend-region-skip-metadata (start end)
  "Extend region to skip over non-markdown metadata blocks."
  (save-excursion
    (save-match-data
      (let ((new-start start)
            (new-end end))
        ;; Extend backwards to exclude metadata
        (goto-char start)
        (while (and (> (point) (point-min))
                    (get-text-property (1- (point)) 'chat-metadata))
          (backward-char))
        (setq new-start (point))
        
        ;; Extend forwards to exclude metadata
        (goto-char end)
        (while (and (< (point) (point-max))
                    (get-text-property (point) 'chat-metadata))
          (forward-char))
        (setq new-end (point))
        
        (unless (and (eq new-start start) (eq new-end end))
          (cons new-start new-end))))))

(defun my-chat/insert-metadata (content)
  "Insert metadata, marking it to skip markdown fontification."
  (let ((start (point)))
    (insert content)
    (put-text-property start (point) 'chat-metadata t)
    (put-text-property start (point) 'face 'shadow)))

(defun my-chat/insert-markdown (content)
  "Insert markdown that will be styled normally."
  (let ((start (point)))
    (let ((inhibit-modification-hooks t))
      (insert content))
    ;; Regular markdown styling applies
    (font-lock-flush start (point))
    (font-lock-ensure start (point))))
```

**Pros:**
- Single major mode, extends cleanly
- Metadata regions skip expensive regex matching
- Minimal overhead
- Compatible with all markdown-mode features

**Cons:**
- More complex font-lock logic
- Harder to debug
- Limited to markdown-mode's capabilities

**When to use:**
- Many metadata blocks interspersed with markdown
- Want markdown-mode benefits but need to control styling
- Performance is critical

### Adding Interactive Controls to Code Blocks

Regardless of strategy, add clickable controls to code blocks:

```elisp
(defun my-chat/fontify-code-blocks-with-buttons ()
  "Add copy/run buttons to code blocks."
  (save-excursion
    (goto-char (point-min))
    (let ((block-id 0))
      (while (markdown-code-block-at-point-p)
        (let* ((bounds (markdown-code-block-at-point-p))
               (start (car bounds))
               (end (cdr bounds))
               (lang (markdown-code-block-language start end)))
          ;; Add button overlay at block start
          (my-chat/add-code-block-controls start end block-id lang)
          (setq block-id (1+ block-id))
          ;; Move to next block
          (goto-char (1+ end))
          (re-search-forward markdown-regex-gfm-code-blocks nil t))))))

(defun my-chat/add-code-block-controls (start end block-id lang)
  "Add copy/run buttons to code block at START-END."
  ;; Create overlay with buttons
  (let ((ov (make-overlay start start)))
    (overlay-put ov 'before-string
                 (my-chat/make-control-string block-id lang))
    (overlay-put ov 'evaporate nil)))

(defun my-chat/make-control-string (block-id lang)
  "Create button string for code block controls."
  (concat
   "\n"
   (propertize "┌─ Code"
               'face 'font-lock-comment-face)
   " "
   (propertize "[Copy]"
               'face 'button
               'mouse-face 'highlight
               'keymap (make-sparse-keymap)
               'local-map (let ((map (make-sparse-keymap)))
                            (define-key map [mouse-1]
                              (lambda (_) (interactive "e")
                                (my-chat/copy-block block-id)))
                            map))
   (when (member lang '("python" "bash" "sh"))
     (concat
      " "
      (propertize "[Run]"
                  'face 'button
                  'mouse-face 'highlight
                  'keymap (let ((map (make-sparse-keymap)))
                            (define-key map [mouse-1]
                              (lambda (_) (interactive "e")
                                (my-chat/run-block block-id lang)))
                            map))))
   " "
   (propertize "─┐"
               'face 'font-lock-comment-face)
   "\n"))

(defun my-chat/copy-block (block-id)
  "Copy code block BLOCK-ID to kill ring."
  (let ((code (my-chat/get-block-content block-id)))
    (when code
      (kill-new code)
      (message "Copied to kill ring"))))

(defun my-chat/run-block (block-id lang)
  "Run code block BLOCK-ID with language LANG."
  (let ((code (my-chat/get-block-content block-id)))
    (when code
      (cond
       ((member lang '("python" "py"))
        (my-chat/run-python code))
       ((member lang '("bash" "sh"))
        (my-chat/run-shell code))
       (t (message "Language %s not yet supported" lang))))))

(defun my-chat/get-block-content (block-id)
  "Get code content of block BLOCK-ID."
  ;; Search for nth code block and extract content
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (and (< n block-id)
                  (re-search-forward markdown-regex-gfm-code-blocks nil t))
        (setq n (1+ n)))
      (when (re-search-forward markdown-regex-gfm-code-blocks nil t)
        (let ((start (match-beginning 0))
              (end (match-end 0)))
          ;; Extract code between fence markers
          (buffer-substring-no-properties start end))))))
```

**Key techniques:**
- `overlay-put` with `before-string`: Add clickable controls before block
- `propertize` with `keymap`: Make text clickable
- `local-map` property: Define actions on click
- Store `block-id` in closure: Track which block was clicked

### Handling Content Synchronization (Indirect Buffers)

If using indirect buffers, sync changes back:

```elisp
(defun my-chat/setup-message-sync (indirect-buf)
  "Setup indirect buffer to sync changes back to main buffer."
  (with-current-buffer indirect-buf
    (add-hook 'after-change-functions
              (lambda (start end len)
                (my-chat/sync-to-main-buffer indirect-buf start end len))
              nil t)))

(defun my-chat/sync-to-main-buffer (indirect-buf start end len)
  "Sync changes from INDIRECT-BUF back to main buffer."
  ;; Find main buffer region corresponding to this indirect buffer
  (let* ((entry (cl-find indirect-buf my-chat/message-buffers
                          :key #'cdr))
         (main-start (car entry)))
    (when entry
      (let ((offset (- end start len)))
        (with-current-buffer (current-buffer)
          (let ((inhibit-modification-hooks t))
            ;; Copy changed content back
            (delete-region (+ main-start start) (+ main-start end))
            (goto-char (+ main-start start))
            (insert-buffer-substring indirect-buf start end)))
        ;; Update bounds of all subsequent messages
        (setq my-chat/message-buffers
              (mapcar (lambda (entry)
                        (if (< (car entry) main-start)
                            entry
                          (cons (+ (car entry) offset) (cdr entry))))
                      my-chat/message-buffers))))))
```

### Complete Example: Chat Buffer with Markdown Responses

```elisp
(defun my-chat/setup ()
  "Setup chat buffer with mixed content."
  (markdown-mode)
  (setq-local my-chat/message-buffers nil)
  (my-chat/setup-mixed-buffer))

(defun my-chat/add-response (content)
  "Add AI response to chat buffer."
  (goto-char (point-max))
  ;; Add metadata header
  (my-chat/insert-metadata
   (format "── Response from AI (%s) ──\n" (current-time-string)))
  ;; Add markdown content with styling
  (my-chat/insert-markdown content)
  ;; Add controls to code blocks
  (my-chat/fontify-code-blocks-with-buttons)
  (insert "\n"))

;; Usage
(my-chat/setup)
(my-chat/add-response
  "# Solution\n\nHere's Python code:\n\n```python\nprint('hello')\n```")
```

This approach:
- Keeps metadata unstyled
- Applies markdown to responses
- Adds interactive copy/run buttons
- Maintains single-buffer editing experience

Choose Strategy 1 for simplicity, Strategy 2 for heavy text editing in responses, Strategy 3 for complex mixed layouts.

## Strategy 3+: Derived Mode with Extended Capabilities

Rather than patching markdown-mode with hooks, create a derived mode that extends it:

```elisp
(define-derived-mode my-chat-mode markdown-mode "Chat"
  "Major mode for AI chat buffers with markdown responses.
Extends markdown-mode with chat-specific features: code block controls,
region styling, and custom keybindings."
  
  ;; Initialize chat-specific state
  (setq-local my-chat/message-regions nil)  ;; ((start . end) ...)
  (setq-local my-chat/code-block-overlays nil)
  
  ;; Setup custom font-lock
  (my-chat/setup-font-lock)
  
  ;; Setup custom keybindings
  (my-chat/setup-keybindings)
  
  ;; Setup hooks for streaming
  (add-hook 'after-change-functions #'my-chat/on-change nil t)
  
  ;; Run mode hooks
  (run-hooks 'my-chat-mode-hook))

(defvar my-chat-mode-hook nil
  "Hook run when entering my-chat-mode.")

(defvar my-chat-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Inherit markdown-mode's keymap
    (set-keymap-parent map markdown-mode-map)
    ;; Add chat-specific bindings
    (define-key map (kbd "C-c C-c") #'my-chat/send-input)
    (define-key map (kbd "C-c C-k") #'my-chat/copy-last-code-block)
    (define-key map (kbd "C-c C-r") #'my-chat/run-last-code-block)
    (define-key map (kbd "C-c C-x c") #'my-chat/clear-buffer)
    map)
  "Keymap for my-chat-mode.")
```

### Custom Font-Lock with Region Awareness

```elisp
(defun my-chat/setup-font-lock ()
  "Setup markdown-mode's font-lock with custom extensions."
  ;; Keep markdown-mode's font-lock keywords
  ;; Add custom rules for chat regions
  (font-lock-add-keywords nil
    '((my-chat/match-metadata-header
       (0 'font-lock-comment-face t)
       (1 'font-lock-comment-face t)))
    'append)
  
  ;; Add font-lock extension for metadata regions
  (add-hook 'font-lock-extend-region-functions
            #'my-chat/extend-region-skip-metadata nil t))

(defconst my-chat/metadata-header-regex
  "^──.*──$"
  "Regex matching metadata headers like '── Response from AI ──'")

(defun my-chat/match-metadata-header (limit)
  "Match metadata headers up to LIMIT."
  (re-search-forward my-chat/metadata-header-regex limit t))

(defun my-chat/extend-region-skip-metadata (start end)
  "Extend region to skip metadata blocks."
  (save-excursion
    (save-match-data
      (let ((new-start start)
            (new-end end))
        ;; Skip backwards over metadata
        (goto-char start)
        (while (and (> (point) (point-min))
                    (or (looking-at-p my-chat/metadata-header-regex)
                        (get-text-property (1- (point)) 'chat-metadata)))
          (backward-line))
        (setq new-start (point))
        
        ;; Skip forwards over metadata
        (goto-char end)
        (while (and (< (point) (point-max))
                    (or (looking-at-p my-chat/metadata-header-regex)
                        (get-text-property (point) 'chat-metadata)))
          (forward-line))
        (setq new-end (point))
        
        (unless (and (eq new-start start) (eq new-end end))
          (cons new-start new-end))))))
```

### Streaming with Throttled Fontification

```elisp
(defvar-local my-chat/stream-timer nil
  "Timer for throttled fontification during streaming.")

(defvar-local my-chat/stream-pending-start nil
  "Start of pending fontification batch.")

(defvar-local my-chat/stream-pending-end nil
  "End of pending fontification batch.")

(defun my-chat/stream-response (text)
  "Stream TEXT into buffer with throttled fontification."
  (let ((start (point)))
    (let ((inhibit-modification-hooks t))
      (insert text))
    ;; Schedule fontification (throttled)
    (my-chat/schedule-fontification start (point))))

(defun my-chat/schedule-fontification (start end)
  "Schedule fontification, coalescing rapid updates."
  ;; Expand pending range
  (setq my-chat/stream-pending-start
        (or my-chat/stream-pending-start start))
  (setq my-chat/stream-pending-end end)
  
  ;; Cancel old timer
  (when my-chat/stream-timer
    (cancel-timer my-chat/stream-timer))
  
  ;; Schedule new timer (50ms = good balance)
  (setq my-chat/stream-timer
        (run-with-timer 0.05 nil
                        #'my-chat/apply-fontification)))

(defun my-chat/apply-fontification ()
  "Apply fontification to streamed region."
  (setq my-chat/stream-timer nil)
  
  (when (and my-chat/stream-pending-start
             my-chat/stream-pending-end
             (buffer-live-p (current-buffer)))
    (let ((start my-chat/stream-pending-start)
          (end my-chat/stream-pending-end))
      (setq my-chat/stream-pending-start nil
            my-chat/stream-pending-end nil)
      
      ;; Fontify the streamed content
      (font-lock-flush start end)
      (font-lock-ensure start end)
      ;; Force display update
      (redisplay t)
      
      ;; Add code block controls after fontification
      (my-chat/add-code-block-controls-in-range start end))))
```

### Message Tracking and Region Management

```elisp
(defun my-chat/add-message (metadata markdown-content)
  "Add a complete message: METADATA header + MARKDOWN-CONTENT.
Returns (start . end) bounds of message."
  (goto-char (point-max))
  (let ((msg-start (point)))
    ;; Add metadata header
    (my-chat/insert-metadata-header metadata)
    
    ;; Add markdown content
    (my-chat/stream-response markdown-content)
    
    ;; Wait for fontification to complete
    (when my-chat/stream-timer
      (cancel-timer my-chat/stream-timer)
      (my-chat/apply-fontification))
    
    ;; Add footer
    (insert "\n")
    (let ((msg-end (point)))
      ;; Track message region
      (push (cons msg-start msg-end) my-chat/message-regions)
      ;; Return bounds
      (cons msg-start msg-end))))

(defun my-chat/insert-metadata-header (metadata)
  "Insert METADATA header (timestamp, model, etc)."
  (let ((start (point)))
    (insert (format "── %s ──\n" metadata))
    ;; Mark as metadata so font-lock knows to skip it
    (put-text-property start (point) 'chat-metadata t)
    (put-text-property start (point) 'face 'font-lock-comment-face)))

(defun my-chat/get-last-message ()
  "Return (start . end) bounds of last message."
  (car my-chat/message-regions))

(defun my-chat/get-message-at-point ()
  "Return (start . end) bounds of message containing point."
  (let ((pos (point)))
    (cl-find-if (lambda (bounds)
                  (and (<= (car bounds) pos)
                       (<= pos (cdr bounds))))
                my-chat/message-regions)))
```

### Code Block Detection and Controls

```elisp
(defun my-chat/add-code-block-controls-in-range (start end)
  "Add copy/run buttons to code blocks in START-END range."
  (save-excursion
    (goto-char start)
    (let ((block-id 0))
      (while (re-search-forward markdown-regex-gfm-code-blocks end t)
        (let* ((match-start (match-beginning 0))
               (lang (or (match-string-no-properties 2) "text")))
          ;; Create overlay with controls
          (my-chat/create-code-block-overlay match-start lang block-id)
          (setq block-id (1+ block-id)))))))

(defun my-chat/create-code-block-overlay (block-start lang block-id)
  "Create overlay with controls for code block at BLOCK-START."
  (let ((ov (make-overlay block-start block-start)))
    (overlay-put ov 'before-string
                 (my-chat/make-code-block-controls lang block-id))
    (overlay-put ov 'evaporate nil)
    ;; Track for cleanup
    (push ov my-chat/code-block-overlays)))

(defun my-chat/make-code-block-controls (lang block-id)
  "Create control string for code block."
  (let ((copy-btn (my-chat/make-button "[Copy]" 'my-chat/copy-block block-id))
        (run-btn (when (member lang '("python" "bash" "sh"))
                   (concat " " (my-chat/make-button "[Run]" 'my-chat/run-block block-id)))))
    (concat "\n" 
            (propertize "┌─ Code " 'face 'font-lock-comment-face)
            copy-btn
            (or run-btn "")
            (propertize " ─┐\n" 'face 'font-lock-comment-face))))

(defun my-chat/make-button (label action block-id)
  "Create a clickable button with LABEL that calls ACTION with BLOCK-ID."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1]
      (lambda (_) (interactive "e")
        (funcall action block-id)))
    (propertize label
                'face 'button
                'mouse-face 'highlight
                'keymap map)))

(defun my-chat/copy-block (block-id)
  "Copy code block BLOCK-ID to kill ring."
  (let ((code (my-chat/extract-block-content block-id)))
    (when code
      (kill-new code)
      (message "Code block copied to kill ring"))))

(defun my-chat/run-block (block-id)
  "Run code block BLOCK-ID in appropriate interpreter."
  (let ((code (my-chat/extract-block-content block-id)))
    (when code
      (my-chat/execute-code code))))

(defun my-chat/copy-last-code-block ()
  "Copy the last code block in the buffer."
  (interactive)
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward markdown-regex-gfm-code-blocks nil t)
      (let ((lang (or (match-string-no-properties 2) "text"))
            (code-start (match-beginning 0))
            (code-end (match-end 0)))
        (let ((code (buffer-substring-no-properties code-start code-end)))
          (kill-new code)
          (message "Last code block copied"))))))

(defun my-chat/run-last-code-block ()
  "Run the last code block in the buffer."
  (interactive)
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward markdown-regex-gfm-code-blocks nil t)
      (let ((code (buffer-substring-no-properties (match-beginning 0) (match-end 0))))
        (my-chat/execute-code code)))))

(defun my-chat/extract-block-content (block-id)
  "Extract code content from block BLOCK-ID (without fence markers)."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      ;; Find the nth code block
      (while (and (< n block-id)
                  (re-search-forward markdown-regex-gfm-code-blocks nil t))
        (setq n (1+ n)))
      ;; Extract content
      (when (re-search-forward markdown-regex-gfm-code-blocks nil t)
        (let* ((match-start (match-beginning 0))
               (fence-end (match-end 0))
               ;; Find closing fence
               (lang-line-end (line-end-position))
               (block-start (1+ lang-line-end))
               (block-end (progn
                            (goto-char fence-end)
                            (if (re-search-forward "^```" nil t)
                                (match-beginning 0)
                              (point-max)))))
          (buffer-substring-no-properties block-start block-end))))))

(defun my-chat/execute-code (code)
  "Execute CODE using appropriate interpreter.
Detects language from code block or prompts."
  (message "Code execution not yet implemented"))
```

### Chat-Specific Commands

```elisp
(defun my-chat/send-input ()
  "Send user input (or selected region) to AI backend."
  (interactive)
  (let ((input (if (region-active-p)
                   (buffer-substring (region-beginning) (region-end))
                 (read-string "Chat: "))))
    (goto-char (point-max))
    (insert "\n> " input "\n\n")
    ;; Simulate response (replace with actual API call)
    (my-chat/simulate-response)))

(defun my-chat/simulate-response ()
  "Simulate AI response (replace with real API)."
  (let ((metadata (format "AI Response at %s" (format-time-string "%H:%M:%S"))))
    (my-chat/add-message metadata 
      "# Response\n\nHere's some **bold** text and a code block:\n\n```python\nprint('Hello, World!')\n```\n\nMore text.")))

(defun my-chat/clear-buffer ()
  "Clear chat history."
  (interactive)
  (when (yes-or-no-p "Clear chat buffer? ")
    (erase-buffer)
    (setq my-chat/message-regions nil)
    (setq my-chat/code-block-overlays nil)))

(defun my-chat/on-change (_start _end _len)
  "Handle buffer changes (for updating state)."
  ;; Could track user input position, etc.
  nil)
```

### Complete Usage Example

```elisp
(require 'markdown-mode)

;; Create a new chat buffer
(defun my-chat/new-buffer ()
  "Create a new chat buffer."
  (interactive)
  (let ((buf (get-buffer-create "*my-chat*")))
    (with-current-buffer buf
      (my-chat-mode)
      (insert "╔════════════════════════════╗\n")
      (insert "║   AI Chat Buffer           ║\n")
      (insert "║   C-c C-c: Send message    ║\n")
      (insert "║   C-c C-k: Copy last block ║\n")
      (insert "║   C-c C-r: Run last block  ║\n")
      (insert "╚════════════════════════════╝\n\n"))
    (switch-to-buffer buf)))

;; Test it
(my-chat/new-buffer)
(my-chat/add-message 
  "AI Response (python-gpt-4)" 
  "# Factorial Function\n\nHere's a simple factorial:\n\n```python\ndef factorial(n):\n    return 1 if n <= 1 else n * factorial(n-1)\n\nprint(factorial(5))\n```\n\nThis returns 120.")
```

### Advantages of Derived Mode Approach

1. **Inheritance**: Get all markdown-mode features automatically
2. **Extensibility**: Add custom keybindings, commands, hooks without patching
3. **Clean separation**: Mode-specific logic stays in derived mode
4. **Hook system**: `my-chat-mode-hook` for user customization
5. **Keymap inheritance**: `markdown-mode-map` provides base, you add chat keys
6. **Font-lock extension**: Add custom rules without breaking markdown
7. **State management**: Buffer-local variables track messages and overlays
8. **Composability**: Works with other minor modes (lsp-mode, company, etc.)

This is the most "Emacs way" of extending functionality—you're creating a proper mode that builds on markdown-mode rather than monkey-patching it.
