---
name: vui-component-best-practices
description: >-
  Best practices for authoring vui.el components: props/state boundaries,
  hooks/effects/async patterns, list keys, and predictable renders. Use when
  creating new vui.el components, refactoring existing components, reviewing
  component code for correctness, or debugging component behavior.
---
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
      (vui-async-callback (result)
        (vui-batch
          (vui-set-state :data result)
          (vui-set-state :loading nil))))
    ;; Return cleanup function
    (lambda () (cancel-pending-requests)))
  :render
  (if (plist-get state :loading)
      (vui-text "Loading...")
    (data-view :data (plist-get state :data))))
```

### Simple Presentational Component

For components that just render props without state, effects, or lifecycle hooks:

```elisp
(vui-defcomponent badge (props)
  "A simple badge that displays a label with a face."
  :render
  (let ((label (plist-get props :label))
        (face (plist-get props :face)))
    (vui-text label :face face)))
```

Note: Presentational components should not have local state - they render purely from props. Extract logic into helper functions for easier testing.

## Component Invocation

`vui-defcomponent` registers a component in vui's registry. Components are invoked by name directly, not as function references:

```elisp
;; Component is registered by vui-defcomponent
(vui-defcomponent my-badge (props)
  :render ...)

;; Invoke by name in render expressions
(vui-vstack
  (my-badge :label "Status" :face 'bold)
  (other-component :data some-data))
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
  (add-hook 'post-command-hook #'my-handler nil t)
  (lambda ()
    (remove-hook 'post-command-hook #'my-handler t)))
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
                        (lambda (item) ; Use lambda if callback takes arguments
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
  :header (lambda () (vui-text "Title" :face 'bold))
  :content (lambda () (vui-text "Body content here")))
```

## Testing Components

### Component vs Function

**Important**: Components defined with `vui-defcomponent` are NOT functions. Do not use `fboundp` or expect them to be callable as function symbols. Components are registered in vui's component registry and invoked by name.

### Testing Strategies

#### Test Helper Functions Directly

Most components have helper functions for formatting, validation, or prop transformation. Test these directly - they're easier to verify and don't require vui's rendering machinery:

```elisp
;; In component file
(defun my-component--format-label (value)
  "Format VALUE for display."
  (if value (upcase (symbol-name value)) "UNKNOWN"))

;; In test file
(ert-deftest my-component-format-label ()
  "Label formatting handles various inputs."
  (should (equal (my-component--format-label 'user) "USER"))
  (should (equal (my-component--format-label nil) "UNKNOWN")))
```

#### Simple Presentational Components

For pure presentational components (no state, no effects), helper tests are usually sufficient. You don't need to test that the component can be rendered - vui handles that:

```elisp
;; Component
(vui-defcomponent status-badge (props)
  :render
  (vui-text (status-badge--label (plist-get props :status))
            :face (status-badge--face (plist-get props :status))))

;; Test only the helpers - no need to test component rendering
(ert-deftest status-badge-labels ()
  "Badge labels are correct for known statuses."
  (should (equal (status-badge--label 'success) "SUCCESS")))
```

#### Complex Components with State

For components with state or effects, test the behavior by:
1. Testing helper functions directly
2. Testing state transitions (if state logic is complex)
3. Optionally testing vnode structure after rendering (advanced)

```elisp
;; Test state transition logic if complex
(ert-deftest my-component-state-updates ()
  "State updates follow expected patterns."
  (let ((state (list :count 0)))
    (should (equal (my-component--update-count state #'1+) '(:count 1)))))
```

### What NOT to Test

- Do NOT use `fboundp` to check if a component exists
- Do NOT try to call components as functions
- Do NOT test vui's internal rendering logic (that's vui's responsibility)
- Do NOT over-test - focus on your component's specific behavior

### Test File Structure

```elisp
;;; my-component-test.el --- Tests for My Component -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the My Component.

;;; Code:

(require 'ert)
(require 'my-component)

;; Helper function tests
(ert-deftest my-component-helper-does-thing ()
  "Helper function behavior is correct."
  (should (equal (my-component--helper "input") "expected-output")))

;; Component-specific behavior tests
(ert-deftest my-component-handles-edge-case ()
  "Component handles edge cases correctly."
  (should (equal (my-component--format-value nil) "fallback")))

(provide 'test/my-component-test)
;;; my-component-test.el ends here
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
| No async context | State updates fail silently | Use `vui-with-async-context` |
| Testing components with `fboundp` | Tests fail - components aren't functions | Test helper functions directly; components are invoked by name in render expressions |

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
- [ ] Tests cover helper functions (formatting, validation, prop transformation)
- [ ] Simple presentational components use only helper function tests
- [ ] No tests use `fboundp` on component names (components aren't functions)
