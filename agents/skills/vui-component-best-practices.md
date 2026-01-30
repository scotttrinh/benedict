# Skill: vui.el Component Best Practices

Best practices for authoring vui.el components: props/state boundaries, hooks/effects/async patterns, list keys, and predictable renders.

## When to Use

- Creating new vui.el components
- Refactoring existing components
- Reviewing component code for correctness
- Debugging component behavior

## Role Boundaries

- Prefer small, composable components over monolith render functions
- Keep behavior consistent with vui.el semantics (stable hook call order)
- Do not refactor unrelated code unless explicitly requested
- Focus on component correctness and patterns, not application architecture

---

## Important: vui.el Component Definition Model

### Current Implementation (Benedict codebase)

In the Benedict codebase, `vui-defcomponent` does **not** create a callable function. It registers a component definition in a registry:

```elisp
(vui-defcomponent my-component (props state)
  :state ((count 0))
  :render
  (vui-hstack
    (vui-text (format "Count: %d" (plist-get state :count)))
    (vui-button "+"
      :on-click (lambda () (vui-set-state :count #'1+)))))
```

After macro expansion, the component is **registered** but not directly callable as a function. Components are rendered through vui's rendering system (e.g., `vui-mount`, `vui-render`).

### Testing Pattern

Since components aren't directly callable:
- Test helper functions and component logic separately (unit tests)
- Integration tests should use vui rendering functions to test full component behavior
- Mock child components to verify prop passing and composition

Example of helper function test:
```elisp
(ert-deftest my-component-helper-fn ()
  "Helper function works correctly."
  (should (equal (my-component--helper "test") "expected")))
```

Example of integration test:
```elisp
(ert-deftest my-component-integration ()
  "Component renders correctly through vui system."
  (vui-with-test-buffer
    (vui-render (my-component :prop "value"))
    ;; verify rendered output
    ))
```

---

## Core Component Structure

### Basic Component Template

```elisp
(vui-defcomponent my-component (props state)
  "Docstring describing the component's purpose."
  :state ((count 0))  ; Initial state declaration
  :render
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
      (vui-async-callback (result)
        (vui-batch
          (vui-set-state :data result)
          (vui-set-state :loading nil))))
    ;; Return cleanup function
    (lambda () (cancel-pending-requests)))
  :render
  (if (plist-get state :loading)
      (vui-text "Loading...")
    (data-view :data (plist-get state :data)))))
```

## Hook Rules (Critical)

### Rule 1: Always Call Hooks Unconditionally

```elisp
;; WRONG - conditional hook
(when show-data
  (vui-use-effect ...))

;; RIGHT - condition inside hook
(vui-use-effect (show-data)
  (when show-data
    (do-something)))
```

### Rule 2: Maintain Consistent Hook Order

```elisp
;; WRONG - hooks inside loops
(dolist (item items)
  (vui-use-effect ...))

;; RIGHT - single hook, handle all items
(vui-use-effect (items)
  (dolist (item items)
    (do-something item)))
```

### Rule 3: Always Return Cleanup Functions

```elisp
;; WRONG - no cleanup
(vui-use-effect ()
  (add-hook 'post-command-hook #'my-handler))

;; RIGHT - cleanup returned
(vui-use-effect ()
  (add-hook 'post-command-hook #'my-handler)
  (lambda ()
    (remove-hook 'post-command-hook #'my-handler)))
```

### Rule 4: Hook Argument Order (Deps First)

All hooks (`vui-use-effect`, `vui-use-memo`, `vui-use-callback`) take dependencies as the FIRST argument and the body as remaining arguments. The macro automatically wraps the body in a lambda.

```elisp
;; WRONG - lambda passed as first argument, deps as second
(vui-use-effect (lambda () (do-something)) (list count))

;; RIGHT - deps first, then naked body
(vui-use-effect (count)
  (do-something))
```

For computed dependencies, use double parentheses:
```elisp
(vui-use-effect ((compute-deps messages))
  (do-something))
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
         (filtered (vui-use-memo (items query)
                     (expensive-filter items query))))
    (render-list filtered)))
```

### Stabilize Callback References

```elisp
(vui-defcomponent item-list (props state)
  (let ((on-item-click (plist-get props :on-item-click))
        ;; Stable reference - won't cause child re-renders
        (handle-click (vui-use-callback (on-item-click)
                        (lambda (item)
                          (funcall on-item-click item)))))
    (vui-list items
              (lambda (item)
                (item-row :item item :on-click handle-click))
              #'item-id)))
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
      :filter (vui-async-callback (proc output)
                (vui-set-state :output
                  (lambda (current)
                    (concat current output))))
      :sentinel (vui-async-callback (proc event)
                  (vui-set-state :done t))))
  :render ...)
```

### Handle All Async States

```elisp
(vui-defcomponent data-view (props state)
  (let ((result (vui-use-async (list 'data (plist-get props :id))
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
          render-fn
          (lambda (item idx) idx))

;; WRONG - content-derived keys
(vui-list items
          render-fn
          (lambda (item) (md5 (item-content item))))

;; RIGHT - stable IDs from data
(vui-list items
          render-fn
          (lambda (item) (plist-get item :id)))
```

### Argument Order for vui-list

`vui-list` uses positional arguments for the main parameters:
1. `items`
2. `render-fn`
3. `key-fn` (optional)

```elisp
(vui-list items
          (lambda (item) (vui-text item))
          (lambda (item) (plist-get item :id)))
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
              (lambda (u)
                (user-row :user u
                          :on-click (plist-get props :on-select)))
              (lambda (u) (plist-get u :id)))))
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
  :header (lambda () (vui-text "Title"))
  :content (lambda () (vui-text "Body content")))
```

## Common Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Wrong hook argument order | `(void-variable lambda)` | Use `(deps &rest body)` pattern |
| `vui-list` with keywords | Wrong render/key logic | Use positional arguments |
| Conditional hooks | Inconsistent behavior, crashes | Move condition inside hook |
| Missing cleanup | Memory leaks, stale subscriptions | Return cleanup from effects |
| Stale closures | Wrong values in async callbacks | Use functional state updates |
| Missing keys | List items lose state on reorder | Use stable IDs from data |
| Direct mutation | UI doesn't update | Create new data structures |
| No async context | State updates fail silently | Use `vui-async-callback` or `vui-with-async-context` |

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

---

## Component Checklist

Before completing a component, verify:

- [ ] Hook arguments use `(deps &rest body)` pattern (Rule 4)
- [ ] `vui-list` uses positional arguments
- [ ] Props are extracted with `plist-get` at component start
- [ ] Local state is minimal and UI-only (not duplicating parent/session data)
- [ ] Render is pure (no side effects outside hooks)
- [ ] Effects return cleanup functions
- [ ] List items have stable keys
- [ ] Async callbacks use `vui-async-callback` or `vui-with-async-context`
- [ ] Multiple state updates are wrapped in `vui-batch`
- [ ] Hooks are never called conditionally or in loops
