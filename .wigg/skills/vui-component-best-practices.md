# Skill: vui.el Component Best Practices

This skill provides guidance for writing well-structured vui.el components.

## When to Use This Skill

Apply these practices when:
- Creating new vui.el components
- Refactoring existing components
- Reviewing component code
- Debugging component issues

## Core Component Structure

### Basic Component Template

```elisp
(vui-defcomponent my-component (props state)
  "Docstring describing the component's purpose."
  (let ((prop-value (plist-get props :prop-name))
        (state-value (plist-get state :state-name)))
    ;; Hooks go here (always called, same order)
    ;; Render return value
    (vui-vstack
      ;; ... children
      )))
```

### Component with State

```elisp
(vui-defcomponent counter (props state)
  :state ((count 0))  ; Initial state declaration
  :render
  (vui-hstack
    (vui-text (format "Count: %d" (plist-get state :count)))
    (vui-button "+"
      :on-click (lambda ()
                  (vui-set-state :count #'1+)))))
```

### Component with Lifecycle

```elisp
(vui-defcomponent data-loader (props state)
  :state ((data nil) (loading t))
  :on-mount
  (progn
    (fetch-data-async
      (vui-async-callback
        (lambda (result)
          (vui-batch
            (vui-set-state :data result)
            (vui-set-state :loading nil)))))
    ;; Return cleanup function
    (lambda () (cancel-pending-requests)))
  :render
  (if (plist-get state :loading)
      (vui-text "Loading...")
    (data-view :data (plist-get state :data))))
```

## Hook Rules (Critical)

### Rule 1: Always Call Hooks Unconditionally

```elisp
;; WRONG - conditional hook
(when show-data
  (vui-use-effect ...))

;; RIGHT - condition inside hook
(vui-use-effect
  (lambda ()
    (when show-data
      (do-something)))
  (list show-data))
```

### Rule 2: Maintain Consistent Hook Order

```elisp
;; WRONG - hooks inside loops
(dolist (item items)
  (vui-use-effect ...))

;; RIGHT - single hook, handle all items
(vui-use-effect
  (lambda ()
    (dolist (item items)
      (do-something item)))
  (list items))
```

### Rule 3: Always Return Cleanup Functions

```elisp
;; WRONG - no cleanup
(vui-use-effect
  (lambda ()
    (add-hook 'post-command-hook #'my-handler))
  (list))

;; RIGHT - cleanup returned
(vui-use-effect
  (lambda ()
    (add-hook 'post-command-hook #'my-handler nil t)
    (lambda ()
      (remove-hook 'post-command-hook #'my-handler t)))
  (list))
```

## State Management

### Use Functional Updates for Async

```elisp
;; WRONG - captures stale value
(lambda (chunk)
  (vui-set-state :content (concat content chunk)))

;; RIGHT - receives current value
(lambda (chunk)
  (vui-set-state :content
    (lambda (current)
      (concat current chunk))))
```

### Batch Multiple State Changes

```elisp
;; WRONG - multiple re-renders
(vui-set-state :loading nil)
(vui-set-state :data result)
(vui-set-state :error nil)

;; RIGHT - single re-render
(vui-batch
  (vui-set-state :loading nil)
  (vui-set-state :data result)
  (vui-set-state :error nil))
```

### Never Mutate State Directly

```elisp
;; WRONG - mutation
(vui-set-state :items
  (lambda (items)
    (setcar items new-first)  ; Mutates!
    items))

;; RIGHT - create new structure
(vui-set-state :items
  (lambda (items)
    (cons new-first (cdr items))))
```

## Performance Optimization

### Memoize Expensive Computations

```elisp
(vui-defcomponent search-results (props state)
  (let* ((items (plist-get props :items))
         (query (plist-get props :query))
         ;; Only recompute when items or query change
         (filtered (vui-use-memo
                     (lambda ()
                       (expensive-filter items query))
                     (list items query))))
    (render-list filtered)))
```

### Stabilize Callback References

```elisp
(vui-defcomponent item-list (props state)
  (let ((on-item-click (plist-get props :on-item-click))
        ;; Stable reference - won't cause child re-renders
        (handle-click (vui-use-callback
                        (lambda (item)
                          (funcall on-item-click item))
                        (list on-item-click))))
    (vui-list items
      :key-fn #'item-id
      :render-fn (lambda (item)
                   (item-row :item item :on-click handle-click)))))
```

### Use Refs for Non-Render State

```elisp
(vui-defcomponent scroll-tracker (props state)
  ;; Scroll position changes shouldn't trigger re-renders
  (let ((scroll-ref (vui-use-ref 0)))
    (vui-box
      :on-scroll (lambda (pos)
                   (setcar scroll-ref pos))  ; No re-render
      (vui-text "Content..."))))
```

## Async Operations

### Wrap Callbacks with Async Context

```elisp
(vui-defcomponent async-loader (props state)
  :on-mount
  (vui-with-async-context
    (make-process
      :name "loader"
      :filter (vui-async-callback
                (lambda (proc output)
                  (vui-set-state :output
                    (lambda (current)
                      (concat current output)))))
      :sentinel (vui-async-callback
                  (lambda (proc event)
                    (vui-set-state :done t)))))
  :render ...)
```

### Handle All Async States

```elisp
(vui-defcomponent data-view (props state)
  (let ((result (vui-use-async
                  (list 'data (plist-get props :id))
                  (lambda (resolve reject)
                    (fetch-data (plist-get props :id) resolve reject)))))
    (pcase (plist-get result :status)
      ('pending (loading-spinner))
      ('error (error-display :error (plist-get result :error)))
      ('ready (content-view :data (plist-get result :data))))))
```

## List Rendering

### Always Provide Stable Keys

```elisp
;; WRONG - index-based keys
(vui-list items
  :key-fn (lambda (item idx) idx))

;; WRONG - content-derived keys
(vui-list items
  :key-fn (lambda (item) (md5 (item-content item))))

;; RIGHT - stable IDs from data
(vui-list items
  :key-fn (lambda (item) (plist-get item :id)))
```

### Generate IDs at Creation Time

```elisp
(defun make-item (content)
  "Create an item with a stable ID."
  (list :id (generate-unique-id)
        :content content
        :created-at (current-time)))
```

## Composition Patterns

### Container/Presentational Split

```elisp
;; Container: handles data and state
(vui-defcomponent user-list-container (props state)
  :state ((users nil) (loading t))
  :on-mount (fetch-users ...)
  :render
  (user-list-view
    :users (plist-get state :users)
    :loading (plist-get state :loading)
    :on-select (plist-get props :on-select)))

;; Presentational: pure rendering
(vui-defcomponent user-list-view (props state)
  (if (plist-get props :loading)
      (loading-spinner)
    (vui-list (plist-get props :users)
      :key-fn (lambda (u) (plist-get u :id))
      :render-fn (lambda (u)
                   (user-row :user u
                             :on-click (plist-get props :on-select))))))
```

### Slots Pattern

```elisp
(vui-defcomponent card (props state)
  "A card with header and content slots."
  (vui-box :class "card"
    (vui-vstack
      (vui-box :class "card-header"
        (funcall (plist-get props :header)))
      (vui-box :class "card-content"
        (funcall (plist-get props :content))))))

;; Usage
(card
  :header (lambda () (vui-text "Title" :face 'bold))
  :content (lambda () (vui-text "Body content here")))
```

## Common Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Conditional hooks | Inconsistent behavior, crashes | Move condition inside hook |
| Missing cleanup | Memory leaks, stale subscriptions | Return cleanup from effects |
| Stale closures | Wrong values in async callbacks | Use functional state updates |
| Missing keys | List items lose state on reorder | Use stable IDs from data |
| Direct mutation | UI doesn't update | Create new data structures |
| No async context | State updates fail silently | Use `vui-with-async-context` |

## Debugging

Enable debug logging:
```elisp
(setq vui-debug-enabled t)
(setq vui-timing-enabled t)
```

Inspect component tree:
```elisp
(vui-inspect)
```

Check for:
1. Unexpected re-renders (timing logs)
2. State not updating (check async context)
3. Keys changing between renders (key stability)
4. Effects running too often (dependency arrays)
