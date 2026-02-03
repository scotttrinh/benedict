---
name: vui-basics
description: Comprehensive guide and reference for writing vui.el components. Covers component anatomy, core primitives (text, button, field), layout structures (stacks, tables), hooks for state and side effects, and composition patterns. Use this skill when you need to write, refactor, or understand vui.el UI code, or when asked to create new Emacs UI components using the vui library.
---

# vui.el Component Development Guide

`vui.el` is a declarative, component-based UI library for Emacs, inspired by React.

## 1. Anatomy of a Component

Use `vui-defcomponent` to define components. They are pure functions of props and state.

```elisp
(vui-defcomponent my-component (prop-a prop-b) ;; Props are read-only arguments
  :state ((count 0)                            ;; Local state: (name initial-value)
          (is-active nil))
  :render
  (vui-vstack                                  ;; Return a single vnode (or vui-fragment)
   (vui-text (format "Prop: %s" prop-a))
   (vui-button (format "Count: %d" count)
               :on-click (lambda ()            ;; Update state triggers re-render
                           (vui-set-state :count (1+ count))))))
```

**Key Rules:**
- **Props are immutable.** Do not modify them. Lift state up if siblings need to share data.
- **Render is pure.** No side effects in `:render`. Use hooks for effects.
- **Return one root.** Use `vui-fragment` to group multiple elements without a wrapper.

## 2. Core Primitives

| Primitive | Usage |
|-----------|-------|
| `vui-text` | Display text. Props: `:face`, `:key`. |
| `vui-button` | Interactive button. Props: `:on-click`, `:disabled`, `:face`, `:no-decoration`. |
| `vui-field` | Text input. Props: `:value`, `:on-change`, `:size`, `:placeholder`, `:secret`. |
| `vui-checkbox` | Boolean toggle. Props: `:checked`, `:on-change`, `:label`. |
| `vui-select` | Dropdown. Props: `:value`, `:options`, `:on-change`. |
| `vui-newline` / `vui-space` | Whitespace control. |
| `vui-fragment` | Logical grouping (invisible in DOM). |

## 3. Layout & Structure

Layouts organize primitives. They compose naturally.

```elisp
(vui-vstack :spacing 1 :indent 2       ;; Vertical stack with gaps and indentation
  (vui-text "Header")
  (vui-hstack :spacing 2               ;; Horizontal stack
    (vui-box (vui-text "Left") :width 10 :align :left)
    (vui-box (vui-text "Right") :width 10 :align :right))
  (vui-table                           ;; Data tables
   :columns '((:header "ID" :width 5) (:header "Name" :min-width 20 :grow t))
   :rows '(("1" "Item A") ("2" "Item B"))))
```

## 4. Hooks (Side Effects & Logic)

Manage lifecycle and external data with hooks. **Must be called at the top level of `:render`.**

- **`vui-use-effect`**: Run code after render (APIs, timers, event subs).
  ```elisp
  (vui-use-effect (query) ;; Dependencies: re-run if 'query' changes
    (fetch-results query)
    (lambda () (cleanup))) ;; Optional cleanup function
  ```

- **`vui-use-async`**: Load async data with caching and status tracking.
  ```elisp
  (let ((result (vui-use-async user-id
                  (lambda (resolve reject)
                    (fetch-user-async user-id resolve)))))
    (pcase (plist-get result :status)
      ('pending (vui-text "Loading..."))
      ('ready   (render-user (plist-get result :data)))
      ('error   (vui-text "Failed"))))
  ```

- **`vui-use-ref`**: Mutable values that persist across renders *without* triggering updates.
- **`vui-with-async-context`**: Wrap callbacks (timers, process sentinels) to safely call `vui-set-state`.

## 5. Composition Pattern (Non-Trivial Example)

This "Task Manager" demonstrates **lifting state**, **composition**, and **derived state**.

```elisp
;; 1. Presentational Component (Stateless)
;; Receives data and callbacks. pure and reusable.
(vui-defcomponent task-row (task on-toggle on-delete)
  :render
  (vui-hstack :spacing 2
    (vui-checkbox :checked (plist-get task :done)
                  :on-change on-toggle)
    (vui-text (plist-get task :title)
              :face (if (plist-get task :done) 'shadow 'default))
    (vui-button "x" :on-click on-delete :face 'error :no-decoration t)))

;; 2. Container Component (Stateful)
;; Manages filtering, state, and rendering logic.
(vui-defcomponent task-manager (initial-tasks)
  :state ((tasks initial-tasks)
          (filter 'all)) ;; 'all, 'active, 'done
  :render
  (let* ((filtered-tasks
          (vui-use-memo (tasks filter) ;; Optimize expensive derived state
            (seq-filter (lambda (t)
                          (pcase filter
                            ('all t)
                            ('active (not (plist-get t :done)))
                            ('done (plist-get t :done))))
                        tasks))))
    (vui-vstack :spacing 1
      ;; Header / Controls
      (vui-hstack :spacing 2
        (vui-text "Tasks" :face 'bold)
        (vui-select :value filter
                    :options '("all" "active" "done")
                    :on-change (lambda (val) (vui-set-state :filter (intern val)))))
      
      ;; List Rendering
      (if (null filtered-tasks)
          (vui-text "No tasks found." :face 'shadow)
        (vui-list filtered-tasks
                  (lambda (task)
                    (vui-component 'task-row
                                   :key (plist-get task :id) ;; Crucial for lists!
                                   :task task
                                   :on-toggle (lambda (val)
                                                (vui-set-state :tasks
                                                  (mapcar (lambda (t)
                                                            (if (eq (plist-get t :id) (plist-get task :id))
                                                                (plist-put (copy-sequence t) :done val)
                                                              t))
                                                          tasks)))
                                   :on-delete (lambda ()
                                                (vui-set-state :tasks
                                                  (seq-remove (lambda (t)
                                                                (eq (plist-get t :id) (plist-get task :id)))
                                                              tasks)))))
                  (lambda (task) (plist-get task :id))))))) ;; Key function
```

## 6. Best Practices

1.  **Keys**: Always provide `:key` in lists (`vui-list`) or when order changes.
2.  **State Granularity**: Keep state as local as possible. Lift it up only when necessary.
3.  **Derived State**: Don't store derived data in state (e.g., `filtered-tasks`). Compute it in render (use `vui-use-memo` if expensive).
4.  **Async Safety**: Always use `vui-with-async-context` (or `vui-use-async`) when updating state from timers/processes.
5.  **Context**: Use `vui-defcontext` for global data (theme, auth) to avoid prop-drilling 3+ levels deep.

## 7. Testing Pure Components

Stateless components can be tested by mounting them into a temporary buffer and asserting on the output.

```elisp
(ert-deftest my-component-test ()
  "Component renders correctly."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      ;; Mount component to temp buffer
      (vui-mount
       (vui-component 'my-component :prop "value")
       buffer-name)
      
      ;; Verify content strings
      (should (string-match-p "value" (buffer-string)))
      
      ;; Verify text properties (faces)
      (goto-char (point-min))
      (let ((face (get-text-property 0 'face (buffer-string))))
        (should (eq face 'my-face))))))
```

## 8. Reference Documentation

For more detailed information, consult the following references available in the `references/` directory:

- **API Reference**: `references/api.org` (Full function and macro reference)
- **Guides**:
  - `references/guide/02-components.org` (Deep dive into components)
  - `references/guide/03-primitives.org` (All UI primitives)
  - `references/guide/04-layout.org` (Layout system)
  - `references/guide/05-hooks.org` (Hooks and state management)
  - `references/guide/06-context.org` (Context system)
- **Examples**:
  - `references/examples/02-todo-app.el` (Complete application structure)
  - `references/examples/05-wine-tasting.el` (Complex tables and interactivity)
