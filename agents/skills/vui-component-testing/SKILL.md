---
name: vui-component-testing
description: Concise guidance for testing VUI components by rendering into real buffers and asserting behavior through user-like interactions. Includes patterns for simple render checks and state-driven interaction tests.
---

# vui-component-testing

Concise guidance for writing VUI component tests that render into real buffers and assert behavior from the user's perspective.

## When to use
- You want behavior tests that reflect real rendering, not just helper functions.
- You need to verify text, badges, or UI state changes after interactions.
- You need to simulate user actions like clicking buttons or changing fields.

## Core pattern
1) Mount the component into a temp buffer with `vui-mount`.
2) Assert buffer contents and text properties.
3) For interactions, trigger button actions via widget and flush renders.

## Minimal setup
```elisp
(require 'ert)
(require 'widget)
(require 'vui)
(require 'your-component)
```

## Helper: click a VUI button
```elisp
(defun your-test--click-button-at (pos)
  "Invoke the button widget at POS."
  (let ((widget (widget-at pos)))
    (when widget
      (widget-apply widget :action))))
```

## Rendering tests (simple)

### Simple text render
```elisp
(ert-deftest your-component-render-text ()
  "Renders content into the buffer."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'your-component :content "Hello")
       buffer-name)
      (should (string-match-p "Hello" (buffer-string))))))
```

### Verify text properties
```elisp
(ert-deftest your-component-renders-properties ()
  "Applies message metadata as text properties."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'your-component :message-key "msg-1" :block-id "block-1")
       buffer-name)
      (let ((text (buffer-string)))
        (should (equal (get-text-property 0 'benedict-message-key text) "msg-1"))
        (should (equal (get-text-property 0 'benedict-block-id text) "block-1"))))))
```

### Verify badges or labels
```elisp
(ert-deftest your-component-renders-status-label ()
  "Renders the expected status label in the buffer."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount
       (vui-component 'your-component :status 'running)
       buffer-name)
      (should (string-match-p "RUNNING" (buffer-string))))))
```

## Interaction tests (state-driven)

### Controlled toggle with harness
Create a tiny harness component that owns state and passes it down.
```elisp
(vui-defcomponent your-test--harness ()
  :state ((collapsed t))
  :render
  (vui-component 'your-component
                 :collapsed collapsed
                 :on-toggle (lambda (next)
                              (vui-set-state :collapsed next))))

(ert-deftest your-component-toggle-test ()
  "Clicking the toggle reveals hidden content."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount (vui-component 'your-test--harness) buffer-name)
      (should-not (string-match-p "Details" (buffer-string)))
      (your-test--click-button-at (point-min))
      (vui-flush-sync)
      (should (string-match-p "Details" (buffer-string))))))
```

### Button click updates state
```elisp
(vui-defcomponent your-test--counter ()
  :state ((count 0))
  :render
  (vui-vstack
   (vui-text (format "Count: %d" count))
   (vui-button "Inc" :on-click (lambda () (vui-set-state :count (1+ count))))))

(ert-deftest your-component-counter-click-test ()
  "Clicking increments the counter."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount (vui-component 'your-test--counter) buffer-name)
      (should (string-match-p "Count: 0" (buffer-string)))
      (your-test--click-button-at (point-min))
      (vui-flush-sync)
      (should (string-match-p "Count: 1" (buffer-string))))))
```

### Field change flow
```elisp
(vui-defcomponent your-test--field ()
  :state ((value ""))
  :render
  (vui-vstack
   (vui-field :value value :on-change (lambda (v) (vui-set-state :value v)))
   (vui-text value)))

(ert-deftest your-component-field-change-test ()
  "Typing updates state and renders the new value."
  (with-temp-buffer
    (let ((buffer-name (buffer-name)))
      (vui-mount (vui-component 'your-test--field) buffer-name)
      (let ((widget (car widget-field-list)))
        (widget-value-set widget "changed")
        (widget-apply widget :notify widget))
      (vui-flush-sync)
      (should (string-match-p "changed" (buffer-string))))))
```

## Rendering delay notes
- VUI defers re-rendering by default (`vui-render-delay`), so after clicks or field updates call `vui-flush-sync` before assertions.
- Avoid direct helper calls in tests when you want behavior coverage.

## Test hygiene
- Use `with-temp-buffer` to avoid side effects.
- Keep assertions on buffer contents or properties; avoid testing internal helpers unless you need a pure unit test.
- Prefer harness components for stateful behavior tests.
