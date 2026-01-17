# Skill: vui.el Application Patterns

Architecture patterns for building vui.el applications: component tree planning, state placement, context boundaries, and UI↔domain integration.

## When to Use

- Designing a new vui.el application or feature
- Planning component hierarchies
- Deciding where state should live
- Refactoring imperative code to declarative

## Role Boundaries

- Produce architecture that is incremental and refactor-friendly
- Keep UI rendering decoupled from provider/network/process code
- Do not implement large refactors unless explicitly requested
- Focus on structure and patterns, not implementation details

---

## Mental Model: Declarative UI

### The Paradigm Shift

**Traditional Emacs (Imperative):**
```elisp
;; Describe HOW to update
(defun update-status (new-status)
  (save-excursion
    (goto-char status-marker)
    (delete-region (point) (line-end-position))
    (insert new-status)
    (put-text-property ... 'face 'status-face)))
```

**vui.el (Declarative):**
```elisp
;; Describe WHAT should be displayed
(vui-defcomponent status-bar (props state)
  (vui-text (plist-get props :status) :face 'status-face))
```

The framework handles diffing and applying minimal changes.

## Application Architecture

### Component Hierarchy Design

Plan your hierarchy before coding using ASCII diagrams:

```
AppRoot
├── Header
│   ├── Logo
│   ├── NavMenu
│   └── UserInfo
├── MainContent
│   ├── Sidebar
│   │   └── FilterPanel
│   └── ContentArea
│       └── ItemList
│           └── Item (×n)
└── StatusBar
```

### Root Component Pattern

The root component owns shared application state:

```elisp
(vui-defcomponent app-root (props state)
  :state ((items nil)
          (selected-id nil)
          (filter "")
          (loading nil)
          (error nil))
  :render
  (vui-vstack
    (app-header
      :filter (plist-get state :filter)
      :on-filter-change (lambda (f) (vui-set-state :filter f)))
    (app-content
      :items (plist-get state :items)
      :selected-id (plist-get state :selected-id)
      :filter (plist-get state :filter)
      :on-select (lambda (id) (vui-set-state :selected-id id)))
    (app-status-bar
      :loading (plist-get state :loading)
      :error (plist-get state :error))))
```

## State Management

### State Location Decision Tree

```
Is this state used by only one component?
├── YES → Component-local state
└── NO → Is it used by siblings?
    ├── YES → Lift to nearest common parent
    └── NO → Is it passed through 3+ levels?
        ├── YES → Consider Context
        └── NO → Use props
```

### State Placement Guide

| State Type | Location | Example |
|------------|----------|---------|
| UI-only, single component | Component `:state` | Form input value |
| Shared by siblings | Parent component | Selected list item |
| App-wide, rarely changes | Context | Theme, locale, auth |
| App-wide, changes often | Root state + props | Search results |

### Context for Cross-Cutting Concerns

```elisp
;; Define context
(vui-defcontext theme-context
  :default '(:mode light :accent blue))

;; Provide at root
(vui-defcomponent app-root (props state)
  (vui-with-theme-context (plist-get state :theme)
    (vui-vstack
      (header ...)
      (content ...))))

;; Consume anywhere below
(vui-defcomponent deep-child (props state)
  (let ((theme (vui-use-theme-context)))
    (vui-box :face (theme-face-for (plist-get theme :mode))
      ...)))
```

**When to use Context:**
- Theme/appearance settings
- Localization strings
- User authentication state
- Feature flags

**When NOT to use Context:**
- Frequently changing values (causes cascading re-renders)
- Data needed by only one subtree
- Simple cases where props work fine

### Derived State

Calculate values, don't store redundant state:

```elisp
;; WRONG - storing derived state
:state ((items ...)
        (item-count 0)      ; Redundant!
        (has-items nil))    ; Redundant!

;; RIGHT - compute on render
:render
(let* ((items (plist-get state :items))
       (item-count (length items))
       (has-items (> item-count 0)))
  ...)
```

For expensive computations, memoize:

```elisp
(let ((filtered-items (vui-use-memo
                        (lambda ()
                          (expensive-filter items query))
                        (list items query))))
  ...)
```

## Data Flow Patterns

### Unidirectional Flow

Props flow down, callbacks flow up:

```elisp
(vui-defcomponent parent (props state)
  :state ((value ""))
  :render
  (child
    :value (plist-get state :value)           ; Props down
    :on-change (lambda (v)                    ; Callbacks up
                 (vui-set-state :value v))))

(vui-defcomponent child (props state)
  (vui-text-field
    :value (plist-get props :value)
    :on-change (plist-get props :on-change)))
```

### Action Dispatch Pattern

For complex state updates, use an action dispatcher:

```elisp
(vui-defcomponent app-root (props state)
  :state ((items nil) (filter "") (selected nil))
  :render
  (let ((dispatch (vui-use-callback
                    (lambda (action payload)
                      (pcase action
                        ('set-filter (vui-set-state :filter payload))
                        ('select-item (vui-set-state :selected payload))
                        ('add-item (vui-set-state :items
                                     (lambda (items)
                                       (cons payload items))))
                        ('remove-item (vui-set-state :items
                                        (lambda (items)
                                          (remove payload items))))))
                    (list))))
    (vui-vstack
      (filter-bar :filter (plist-get state :filter)
                  :dispatch dispatch)
      (item-list :items (plist-get state :items)
                 :selected (plist-get state :selected)
                 :dispatch dispatch))))

;; Children dispatch actions
(vui-defcomponent filter-bar (props state)
  (vui-text-field
    :value (plist-get props :filter)
    :on-change (lambda (v)
                 (funcall (plist-get props :dispatch) 'set-filter v))))
```

## Async Data Patterns

### Loading/Error/Success States

```elisp
(vui-defcomponent data-container (props state)
  :state ((status 'idle)  ; idle | loading | success | error
          (data nil)
          (error nil))
  :on-mount
  (progn
    (vui-set-state :status 'loading)
    (fetch-data
      (vui-async-callback
        (lambda (result)
          (vui-batch
            (vui-set-state :status 'success)
            (vui-set-state :data result))))
      (vui-async-callback
        (lambda (err)
          (vui-batch
            (vui-set-state :status 'error)
            (vui-set-state :error err))))))
  :render
  (pcase (plist-get state :status)
    ('idle (vui-text ""))
    ('loading (loading-spinner))
    ('error (error-display :error (plist-get state :error)
                           :on-retry (lambda () ...)))
    ('success (data-view :data (plist-get state :data)))))
```

### Using vui-use-async

```elisp
(vui-defcomponent user-profile (props state)
  (let* ((user-id (plist-get props :user-id))
         (result (vui-use-async
                   (list 'user user-id)  ; Re-fetch when user-id changes
                   (lambda (resolve reject)
                     (fetch-user user-id resolve reject)))))
    (pcase (plist-get result :status)
      ('pending (loading-spinner))
      ('error (error-display :error (plist-get result :error)))
      ('ready (profile-view :user (plist-get result :data))))))
```

### Streaming Updates

For real-time data like streaming responses:

```elisp
(vui-defcomponent stream-viewer (props state)
  :state ((content "") (status 'idle))
  :render
  (let* ((stream-ref (vui-use-ref nil))
         (start-stream (plist-get props :start-stream)))
    (vui-use-effect
      (lambda ()
        (setcar stream-ref
          (funcall start-stream
            :on-chunk (vui-async-callback
                        (lambda (chunk)
                          (vui-set-state :content
                            (lambda (c) (concat c chunk)))
                          (vui-set-state :status 'streaming)))
            :on-done (vui-async-callback
                       (lambda ()
                         (vui-set-state :status 'complete)))))
        ;; Cleanup
        (lambda ()
          (when (car stream-ref)
            (cancel-stream (car stream-ref)))))
      (list start-stream))

    (vui-vstack
      (status-indicator :status (plist-get state :status))
      (vui-text (plist-get state :content)))))
```

## Code Organization

### Feature-Based Structure

Organize by feature, not by type:

```
my-app/
├── my-app.el              ; Entry point, root component
├── my-app-context.el      ; Shared contexts
├── my-app-users/          ; User feature
│   ├── user-list.el
│   ├── user-profile.el
│   └── user-api.el
├── my-app-items/          ; Items feature
│   ├── item-list.el
│   ├── item-editor.el
│   └── item-api.el
└── my-app-shared/         ; Shared components
    ├── button.el
    ├── modal.el
    └── spinner.el
```

### Component File Template

```elisp
;;; my-app-users/user-list.el --- User list component  -*- lexical-binding: t -*-

;;; Commentary:
;; Displays a list of users with filtering and selection.

;;; Code:

(require 'vui)
(require 'my-app-context)
(require 'my-app-shared-spinner)

;; Helper functions
(defun user-list--filter-users (users query)
  "Filter USERS by QUERY."
  ...)

;; Presentational component
(vui-defcomponent user-list-item (props state)
  "Renders a single user row."
  ...)

;; Container component
(vui-defcomponent user-list (props state)
  "Displays a filterable list of users."
  :state ((filter-query ""))
  :render
  ...)

(provide 'my-app-users-user-list)
;;; user-list.el ends here
```

## Component Extraction Guidelines

### When to Extract

Extract a new component when:
- Render function exceeds 20-30 lines
- Same pattern repeats in multiple places
- Logic would benefit from isolation
- Component has clear, single responsibility

### Incremental Extraction

Start monolithic, extract as complexity grows:

```elisp
;; Step 1: Everything in one component
(vui-defcomponent app (props state)
  (vui-vstack
    (vui-hstack
      (vui-text "Header")
      (vui-button "Action" ...))
    (vui-list items ...)
    (vui-text "Footer")))

;; Step 2: Extract when sections grow
(vui-defcomponent app (props state)
  (vui-vstack
    (app-header :on-action ...)
    (item-list :items items ...)
    (app-footer)))
```

## Performance Strategies

### Render Scope Minimization

Keep state close to where it's used:

```elisp
;; WRONG - filter state in root causes full re-render
(vui-defcomponent root (props state)
  :state ((items ...) (filter ""))  ; Filter here is too high
  ...)

;; RIGHT - filter state in filter component
(vui-defcomponent root (props state)
  :state ((items ...))
  :render
  (filterable-list :items (plist-get state :items)))

(vui-defcomponent filterable-list (props state)
  :state ((filter ""))  ; Filter state localized
  :render
  (let ((filtered (vui-use-memo ...)))
    ...))
```

### Stabilize Prop References

Child components with `:should-update` won't benefit if props change identity:

```elisp
(vui-defcomponent parent (props state)
  ;; Stable callbacks
  (let ((on-click (vui-use-callback
                    (lambda (id) (handle-click id))
                    (list)))
        ;; Stable derived data
        (processed (vui-use-memo
                     (lambda () (process-items items))
                     (list items))))
    (child-list
      :items processed
      :on-click on-click)))
```

## Testing Strategies

### Test Presentational Components

Presentational components are pure functions - easy to test:

```elisp
(ert-deftest test-user-row-renders-name ()
  (let* ((user '(:id 1 :name "Alice"))
         (tree (vui-render-to-tree
                 (user-row :user user))))
    (should (string-match "Alice" (vui-tree-text tree)))))
```

### Mock Context for Tests

```elisp
(ert-deftest test-themed-component ()
  (vui-with-theme-context '(:mode dark)
    (let ((tree (vui-render-to-tree (themed-button))))
      (should (eq 'dark-button-face (vui-tree-face tree))))))
```

## Debugging Checklist

When things go wrong:

1. **Component not updating?**
   - Check `vui-with-async-context` in callbacks
   - Verify state key spelling
   - Check for direct mutation

2. **Re-rendering too much?**
   - Enable `vui-timing-enabled`
   - Look for unstable callbacks
   - Check if state is too high in tree

3. **List items losing state?**
   - Verify key function returns stable IDs
   - Check IDs aren't changing between renders

4. **Effects running repeatedly?**
   - Check dependency array completeness
   - Verify dependencies are stable references

5. **Memory leaks?**
   - Ensure effects return cleanup functions
   - Check for timers/subscriptions without cleanup

---

## Verification Prompts

After implementing, ask yourself:

- Can the UI re-render from scratch without losing cursor/scroll position?
- Are list items keyed by stable IDs (not indices)?
- Do state updates avoid intermediate renders (using `vui-batch`)?
- Are effects cleaned up on dependency changes and unmount?
- Is state placed at the lowest possible level in the tree?
- Are callbacks stabilized with `vui-use-callback` where children use `:should-update`?
