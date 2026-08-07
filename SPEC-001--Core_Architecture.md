# SPEC-001: Benedict Core Architecture

**Status:** Draft
**Scope:** Full-system specification and implementation guidance for the Benedict
kernel, provider framework, extension mechanism, and packaging model.

This document is standalone. It describes the system to be built, not the system
that exists.

---

## Table of Contents

1. [Thesis](#1-thesis)
2. [Design Principles](#2-design-principles)
3. [System Overview](#3-system-overview)
4. [The Kernel](#4-the-kernel)
5. [The Transcript Tree](#5-the-transcript-tree)
6. [Tools](#6-tools)
7. [The Provider Framework](#7-the-provider-framework)
8. [Authentication](#8-authentication)
9. [Extensions](#9-extensions)
10. [Self-Extension](#10-self-extension)
11. [Frontends](#11-frontends)
12. [Packaging and Layout](#12-packaging-and-layout)
13. [Comparison to Pi](#13-comparison-to-pi)
14. [Implementation Plan](#14-implementation-plan)
15. [Resolved Decisions](#15-resolved-decisions)
16. [Open Questions](#16-open-questions)

---

## 1. Thesis

Benedict is an agent runtime whose operating medium is Emacs Lisp.

Every agent harness gives its model an escape hatch into a general-purpose
execution environment — for most, that hatch is `bash` and the environment is a
POSIX shell. Benedict's hatch is `eval` and the environment is the running Emacs
image. This is not a cosmetic substitution. It changes what self-extension costs:

- A shell agent extends itself by writing a file, then reloading a runtime that
  must be designed to be reloadable.
- A Lisp agent extends itself by evaluating a form. The runtime is already live.
  Redefinition is the normal case, not a lifecycle event.

The architecture follows from taking that seriously. The kernel stays small
enough to hold in your head, and everything with an opinion in it — approval
policy, compaction strategy, sandboxing, provider adapters, the chat UI — lives
outside the kernel as ordinary Emacs Lisp that the agent itself can read, write,
and load.

The design borrows heavily from [pi](https://pi.dev), whose central insight is
that an agent harness should be a small loop plus a documented extension surface,
with the harness's own documentation reachable by the agent's own tools. Section
13 covers where Benedict follows pi and where the Emacs medium justifies
divergence.

---

## 2. Design Principles

**P1. The kernel owns mechanism, never policy.**
The kernel provides the point at which a tool call can be intercepted. It has no
opinion about whether `rm -rf` needs confirmation. Policy is an extension.

**P2. Anything the kernel can do, an extension can do.**
The chat frontend is written against the same public API an extension uses. If a
frontend needs private kernel access, the API is wrong and must grow — not the
frontend's privileges.

**P3. The transcript is append-only and durable per entry.**
Because `eval` runs in-process, the agent can break its own runtime. Every
transcript entry is written to disk as it is created, so a corrupted image is
recoverable by restarting and resuming.

**P4. Data structures are the primary contract.**
Frontends and extensions couple to entry structs more tightly than to functions.
Struct shape changes are breaking changes; function additions are not.

**P5. One mechanism per concern.**
Approval, blocking, rewriting, and sandbox routing are all the same thing — an
async filter around tool dispatch. Four features, one mechanism, one thing to
learn.

**P6. Prefer introspection to documentation.**
Where the running image can answer a question about itself, do not write a
markdown file that will drift. Ship the concepts as prose; ship the API surface
as `describe-function`.

**P7. Provider is not API.**
The wire protocol and the service that speaks it are separate concerns. Adding a
service that speaks a known protocol must cost a dozen lines.

**P8. No build step.**
Elisp needs no transpilation. An extension is a file. Loading it is `load-file`.
Resist any design that reintroduces compilation, bundling, or a module loader.

---

## 3. System Overview

### 3.1 Layers

```
┌─────────────────────────────────────────────────────────────┐
│  Frontends          benedict-chat, batch mode, RPC          │
├─────────────────────────────────────────────────────────────┤
│  Distro             approvals, skills, prompts, compaction, │
│  (bundled exts)     eval/files/introspect tools, store       │
├─────────────────────────────────────────────────────────────┤
│  Providers          vercel-ai-gateway, openai-codex, ...     │
│  APIs               openai-responses, anthropic-messages     │
├─────────────────────────────────────────────────────────────┤
│  KERNEL             message · tool · provider · session ·    │
│                     core (reducer + hooks)                   │
└─────────────────────────────────────────────────────────────┘
```

Dependency direction is strictly downward. The kernel requires nothing above it.
Every layer above the kernel is optional: `benedict-core` plus a fake provider is
a complete, testable agent runtime with zero tools and no UI.

### 3.2 Module map

| Module | Layer | Responsibility |
|---|---|---|
| `benedict-message.el` | kernel | Entry structs, content blocks, tree accessors |
| `benedict-session.el` | kernel | Session struct, transcript head, queues, hook definitions and scoping (D15) |
| `benedict-tool.el` | kernel | Tool struct, registry, invocation protocol |
| `benedict-provider.el` | kernel | Provider/API registry, dispatch, model records |
| `benedict-core.el` | kernel | Reducer, run state machine |
| `benedict-schema.el` | kernel | Parameter DSL → JSON Schema |
| `benedict-http.el` | support | SSE reader, retry, error-body extraction |
| `benedict-log.el` | support | Level-gated logging and a debug ring |
| `benedict-api-transform.el` | provider | Canonical→wire lowering, cross-model degradation |
| `benedict-api-stream.el` | provider | The shared auth→build→HTTP→parse path (D19) |
| `benedict-api-*.el` | provider | Wire protocol adapters |
| `benedict-provider-*.el` | provider | Service catalog entries |
| `benedict-auth.el` | provider | Credential store, OAuth refresh serialization |
| `benedict-store.el` | distro | Append-only transcript log |
| `benedict-eval.el` | distro | `eval-elisp` tool |
| `benedict-files.el` | distro | `read-file`, `write-file`, `edit-file`, `search` |
| `benedict-introspect.el` | distro | `describe`, `apropos` tools |
| `benedict-approvals.el` | distro | Permission policy |
| `benedict-compact.el` | distro | Context compaction |
| `benedict-skills.el` | distro | Agent Skills discovery |
| `benedict-prompts.el` | distro | Prompt template commands |
| `benedict-chat*.el`, `ui/` | frontend | Chat buffer and render components |

### 3.3 What the kernel deliberately does not own

Enumerated because the temptation to absorb each of these is strong:

- **Approval, permission, budget, audit.** These are dispatch filters and
  observation hooks. See §6.4.
- **Compaction.** A context filter. See §5.6.
- **Persistence.** The kernel emits entries; the store subscribes. The kernel
  never touches the filesystem.
- **Worker/sandbox delegation.** A tool whose handler routes elsewhere. The
  kernel cannot tell the difference between a local and a remote tool.
- **Provider adapters.** The kernel knows the *protocol*, not any implementation.
- **Model catalogs, pricing, token counting.** Provider-layer concerns.
- **Slash commands, skills, prompt templates.** Text expansion above the kernel.
- **UI of any kind.** Including approval prompts — the approval *extension* owns
  its prompt, and delegates presentation to whatever frontend is attached.

---

## 4. The Kernel

Target size: **under 1,500 lines of code** across the six kernel modules. If it
grows past that, something in §3.3 has leaked in.

*Lines of code*, specifically — not lines of file. §10.2 makes docstrings the
API documentation, written for an agent reading them cold, and they run about
one line for every line of code they explain. Counting them against a budget
whose purpose is to detect leaked policy would punish exactly the thing that
section asks for. Measure by excluding docstrings, comments, and blanks; at the
end of Phase 2 the six modules were 1,226 lines of code in 3,069 lines of file.

### 4.1 Public API

The entire kernel surface:

```elisp
;; Lifecycle
(benedict-session-create &key system-prompt model provider tools store transcript)
(benedict-session-submit session input)      ; user text/content -> starts a run
(benedict-session-steer session content)     ; queue for injection mid-run
(benedict-session-follow-up session content) ; queue for after the run would stop
(benedict-session-abort session)

;; Transcript
(benedict-session-head session)              ; current tip entry id
(benedict-session-path session &optional id) ; root..head list of entries
(benedict-session-entry session id)
(benedict-session-children session id)
(benedict-session-fork session id)           ; move head; next append branches
(benedict-session-streaming-entry session)   ; the live partial entry (§4.3)

;; Scoped hooks (§4.4.1)
(benedict-session-add-hook session hook fn &optional depth)
(benedict-session-remove-hook session hook fn)

;; Extension state
(benedict-session-get session key &optional default)
(benedict-session-put session key value)

;; Registries
(benedict-tool-register tool)
(benedict-tool-get id)
(benedict-tool-list)
(benedict-provider-register provider)
(benedict-api-register api)
(benedict-model-resolve spec)                ; "vercel-ai-gateway/openai/gpt-5" -> model

;; Provider dispatch (§7.2)
(benedict-provider-stream model request handler)  ; -> cancel thunk
```

Plus the hook variables in §4.4, the dynamic variable
`benedict-current-session`, and `benedict-core-defer-function` (D13). That is
the whole contract.

`:transcript` adopts an existing tree rather than creating one, which is how a
session is resumed from a log: `benedict-store-load` returns a transcript and
the session takes it, keeping its session id so that entry ids continue the same
sequence.

`benedict-session-get`/`-put` are on the list because §4.4.1's own example calls
them — a globally registered filter discriminating on
`(benedict-session-get benedict-current-session :trusted)` needs somewhere for
that property to live, and the alternative is every extension maintaining a
weak hash table keyed by session.

`:store` looks like it contradicts §3.3's "the kernel never touches the
filesystem," and does not: it is an **opaque handle**. The kernel keeps it in a
slot so that extensions can find a session's store without a registry, and never
calls anything on it. Persistence happens entirely through the observation hooks,
which is why the store lives in `ext/`.

### 4.2 Run state machine

Emacs is single-threaded and has no `await`. The kernel is therefore a
**reducer**, not a loop: a function that inspects session state, dispatches one
asynchronous action, and arranges to be re-entered from that action's callback.

This is forced by the medium, but it is also better than a loop for this system —
every state transition is an explicit, observable, interceptable point, and the
entire kernel is synchronously testable against a scripted provider.

**States:**

| State | Meaning |
|---|---|
| `idle` | No active run |
| `provider-wait` | Request in flight, stream events arriving |
| `tool-dispatch` | Tool calls passing through the dispatch filter chain |
| `tool-wait` | One or more tools outstanding (executing, or suspended on approval) |
| `stopping` | Abort requested; draining outstanding work |

**Transitions:**

```
idle ──submit──────────────────────────────────► provider-wait
provider-wait ──stream :done, no tool calls────► [continue?] ──► provider-wait
                                                              └► idle
provider-wait ──stream :done, tool calls───────► tool-dispatch
provider-wait ──stream :error──────────────────► idle
tool-dispatch ──all dispatched─────────────────► tool-wait
tool-wait ──last tool result appended──────────► [continue?] ──► provider-wait
                                                              └► idle
any ──abort────────────────────────────────────► stopping ────► idle
```

`[continue?]` runs `benedict-continue-predicate-functions`, then drains the
steering queue, then the follow-up queue. If a predicate vetoes and both queues
are empty, the run ends.

Spelled out, because the compression above hides two rules that matter:

1. **The default depends on the incoming edge.** A turn that produced tool
   results continues by default — the model has not seen them yet, and stopping
   there would strand the work. A turn that produced only text stops by default.
2. **Queued input overrides a veto.** A drained steering or follow-up message
   continues the run whatever a predicate returned. A budget filter is a policy
   about the agent's own momentum; a human's queued message is not the agent's
   momentum. The veto is still recorded as the stop reason, so if the queues
   empty and the predicate still objects, the run ends with the reason intact.

Steering drains before follow-ups, and only when steering had nothing does a
follow-up get taken: a steering message has already kept the run alive, so the
follow-up can wait for the next boundary rather than piling in behind it.

**Central function:**

```elisp
(defun benedict-core--advance (session)
  "Dispatch the next action for SESSION based on its run state.
Called on submit and re-entered from every asynchronous completion."
  (pcase (benedict-session-state session)
    ('provider-wait  (benedict-core--request session))
    ('tool-dispatch  (benedict-core--dispatch-next-tool session))
    ('tool-wait      nil)                       ; waiting on callbacks
    ('stopping       (benedict-core--drain session))
    ('idle           (benedict-core--maybe-start session))))
```

**Turn and run.** A *turn* is one assistant message plus the tool results it
produced. A *run* is the sequence of turns from a submit until the state returns
to `idle`. Both have start/end hooks.

**Queue drain semantics.** Both queues drain **one message per boundary** by
default, controlled by `benedict-queue-drain-mode` (`one-at-a-time` or `all`).

One-at-a-time is the default because it produces finer interleaving: if the user
types three corrections while the agent works, injecting all three at a single
boundary means the agent never gets to act on the first before seeing the third,
and the later messages were often written without knowledge of what the first
would change. Draining one preserves the conversational structure the user
intended. `all` exists for scripted and batch use, where the messages are a
prepared sequence rather than reactions.

**Reentrancy.** `benedict-core--advance` must never be called from within itself.
Asynchronous callbacks that complete synchronously (a fast fake provider, a sync
tool) must defer re-entry via `run-at-time 0 nil` to keep the stack flat and the
state machine legible. This is a hard rule; violating it produces stack overflows
under scripted providers in tests.

### 4.3 Streaming and the partial entry

The kernel owns the accumulator. When a provider stream opens, the kernel creates
an assistant entry with empty content and installs it as the session's
*streaming entry*. Stream events mutate it in place and are then re-emitted as
hooks carrying only a block index and a delta.

```elisp
(benedict-session-streaming-entry session)  ; the live, partially-built entry
```

Frontends re-render the referenced block from the streaming entry rather than
accumulating deltas themselves. This is a deliberate divergence from pi, which
attaches a complete `partial` message to every stream event; that is correct for
an immutable-message TypeScript runtime and wasteful in Emacs, where in-place
mutation plus region re-render is the idiom.

The streaming entry is **not** appended to the transcript or written to the store
until the stream terminates. A failed or aborted stream still produces a terminal
entry (with `stop-reason` of `error` or `aborted` and an `error-message`), so the
transcript never contains a half-written entry and never silently loses a turn.

**A streaming entry has no id.** Ids are minted at append time, so the entry
carried by `benedict-entry-start-functions` for a stream is identified only by
object identity until `benedict-entry-end-functions` fires with the same object,
appended. Renderers must key their regions on the object, not on the id. This is
not an accident of implementation: reserving an id up front would either mint ids
that a failed stream never uses or need a second counter to reconcile, and the
tree's id contract (§5.5) is worth more than saving renderers an `eq`.

**A superseded stream's events are discarded.** The session carries a generation
counter that an abort and each new request bump; the kernel drops any event, and
any tool continuation, arriving under a stale one. Providers are asked to stop
via a cancel thunk (§7.2) but are never trusted to stop promptly, which is what
makes abort correct against an adapter that is mid-buffer when it is cancelled.

### 4.4 Hooks

Emacs already distinguishes the three hook kinds this system needs, and the
kernel uses each idiomatically.

**Observation** — `run-hook-with-args`, return values ignored:

| Hook | Arguments |
|---|---|
| `benedict-run-start-functions` | `(session)` |
| `benedict-run-end-functions` | `(session)` |
| `benedict-turn-start-functions` | `(session)` |
| `benedict-turn-end-functions` | `(session entry results)` |
| `benedict-entry-start-functions` | `(session entry)` |
| `benedict-entry-update-functions` | `(session entry block-index delta)` |
| `benedict-entry-end-functions` | `(session entry)` |
| `benedict-head-change-functions` | `(session old-id new-id)` |
| `benedict-tool-start-functions` | `(session invocation)` |
| `benedict-tool-end-functions` | `(session invocation result)` |
| `benedict-state-change-functions` | `(session old new)` |

`benedict-head-change-functions` fires whenever the transcript head moves other
than by an append — that is, on every fork. Two subscribers need it and neither
can be served by the entry hooks: the store must write a head marker (§5.4) or a
session that ends on a fork reloads on the wrong branch, and the renderer must
re-draw the branch affordance (§11.3). An append moves head too, but
`benedict-entry-end-functions` already covers that case, so this hook fires only
for the moves nothing else reports.

**Veto** — `run-hook-with-args-until-success`, first non-nil wins:

| Hook | Arguments | Non-nil means |
|---|---|---|
| `benedict-continue-predicate-functions` | `(session)` | stop after this turn; value is the reason |

**Transform** — filter chain, each function takes and returns a value:

| Hook | Signature |
|---|---|
| `benedict-context-filter-functions` | `(entries session) -> entries` |
| `benedict-request-filter-functions` | `(request model session) -> request` |
| `benedict-tool-result-filter-functions` | `(result invocation) -> result` |

**Async intercept** — continuation-passing chain:

| Hook | Signature |
|---|---|
| `benedict-tool-dispatch-functions` | `(invocation next)` |

The dispatch chain is the load-bearing one. See §6.4.

#### 4.4.1 Scope: global and session-local

Hooks are global variables, but multiple sessions coexist in one image — an
always-on assistant alongside an ad-hoc coding session, or an interactive session
alongside a sandboxed worker. A project-local extension loaded for one project
must not intercept tool calls in another, and a worker session must not inherit
the interactive session's approval prompts.

Two mechanisms, both cheap:

**Session-local hook lists.** Each session carries its own hook table. Every hook
run concatenates the global list and the session's list.

```elisp
(benedict-session-add-hook session 'benedict-tool-dispatch-functions #'fn &optional depth)
(benedict-session-remove-hook session 'benedict-tool-dispatch-functions #'fn)
```

This is the mechanism for scoped policy. Buffer-local hooks are the tempting
Emacs-native answer and are wrong here: headless sessions have no buffer, and
binding the correct buffer around every asynchronous dispatch is fragile.

**Dynamic binding of the current session.** The kernel binds
`benedict-current-session` around every hook invocation, so a *globally*
registered function can discriminate without every extension author being forced
to thread a session argument.

```elisp
(defun my-approvals--dispatch (invocation next)
  (if (benedict-session-get benedict-current-session :trusted)
      (funcall next invocation)
    (my-approvals--confirm invocation next)))
```

Observation hooks already receive `session` as their first argument; the dynamic
variable exists for the transform and dispatch chains, whose signatures are
shaped by the value they operate on rather than by the session.

**Ordering across scopes.** Global hooks run before session-local hooks at equal
depth. Within each scope, `add-hook`'s `DEPTH` applies. The convention from §9.5
holds in both.

### 4.5 Data model

```elisp
(cl-defstruct (benedict-entry (:constructor benedict-entry-create)
                              (:copier nil))
  id          ; unique string, stable across restarts
  parent      ; id of the preceding entry, nil at root
  role        ; user | assistant | tool-result | note
  content     ; list of content blocks
  timestamp   ; float-time
  meta)       ; plist: provider, api, model, usage, stop-reason, error-message, ...

;; Content blocks are plists tagged by :type.
;;   (:type text     :text "..." :signature "...")
;;   (:type thinking :thinking "..." :signature "..." :redacted nil)
;;   (:type image    :data "<base64>" :mime-type "image/png")
;;   (:type tool-call   :id "..." :name eval-elisp :arguments (:form "...") :signature "...")
;;   (:type tool-result :id "..." :name eval-elisp :content (...) :error-p nil)
```

**Roles are exactly those four.** There is deliberately no `system` role: the
system prompt is a property of the session (§4.1 `:system-prompt`), not an entry
in its transcript. It is not part of the branching history, it is not produced by
a turn, and giving it an entry would mean every consumer of the transcript had to
special-case the first one.

**Origin tagging.** Every assistant entry records the `provider`, `api`, and
`model` that produced it, in `meta`. This is not diagnostic metadata — it is
load-bearing. A transcript may contain entries from several different models, and
each must be lowered to the wire according to its own origin, not the
conversation's current model. See §7.8.

**Signatures** are provider-opaque blobs attached to content blocks: an OpenAI
reasoning item id, an Anthropic thinking signature, a Google thought signature.
They are meaningless to Benedict and must never be interpreted — only stored,
replayed to the model that issued them, and discarded for any other model.

Content blocks are plists rather than structs because they cross the JSON
boundary constantly and because frontends dispatch on `:type` in `pcase`.
Entries are structs because they are long-lived, carry identity, and benefit from
typed accessors.

**`role note`** is for entries that are part of the record but not ordinarily
sent to a provider: extension annotations, git checkpoints, model-change markers
(§7.8.8), UI markers, and evaluated forms that modified the runtime (§10.3).

By default the context filter drops them. A note may opt *into* provider context
with `:context t` in its meta:

```elisp
(benedict-entry-create :role 'note
                       :content '((:type text :text "User prefers ISO dates."))
                       :meta '(:context t :source my-extension))
```

Context-flagged notes are what make durable instructions possible, so they
interact with compaction deliberately: **compaction re-emits context-flagged
notes from the compacted range after the summary entry.** A reminder injected at
turn three survives a compaction at turn forty. Un-flagged notes are summarized
away with everything else. Without this rule, "remember X for the rest of this
session" silently stops working at the first compaction, which is the failure
mode worth engineering against.

---

## 5. The Transcript Tree

### 5.1 Model

Every entry carries a `parent` id. The transcript is a **tree stored as a flat,
append-only log**; the session holds a `head` pointing at the current tip.

- **Append** — create an entry with `:parent head`, write it, set `head` to it.
- **Fork** — set `head` to any earlier entry id. The next append creates a
  sibling.
- **Materialize** — walk `head` → root via `parent`, reverse. That list is the
  conversation.

The log is never rewritten. This makes branching structurally free and makes the
durability guarantee of P3 trivially satisfiable — there is no update-in-place
operation that could tear.

### 5.2 Why day one

Retrofitting a tree means rewriting the store, the reducer, the renderer, and
every extension that walks the transcript. Building it in costs an `id` field, a
`parent` field, a `head` field, and a walk function — roughly sixty lines.

### 5.3 What it buys

| Capability | Implementation |
|---|---|
| Undo | Move `head` to an ancestor |
| Retry with a different model | Fork, change model, resume |
| Edit-and-resubmit | Fork at the user entry's parent, append the edited entry |
| A/B comparison | Two branches from one fork point |
| Non-destructive compaction | §5.6 |

### 5.4 Log format

One `read`-able s-expression per line:

A log holds three kinds of record, told apart by a top-level `:type`. Entry
records have no top-level `:type` — content blocks carry one, entries do not — so
the discriminator needs no version-specific parsing.

```elisp
(:type header :format 1 :session-id "20260806T142530-a3f9" :created 1785...)

(:id "20260806T142530-a3f9-e0002" :parent "20260806T142530-a3f9-e0001"
 :role assistant :timestamp 1785...
 :content ((:type text :text "..."))
 :meta (:model "openai/gpt-5" :usage (:input 1204 :output 88)))

(:type head :id "20260806T142530-a3f9-e0001" :timestamp 1785...)
```

`prin1` out, `read` in. No schema translation, no JSON round-trip, no loss of
elisp types. The store appends with a single `write-region` in append mode per
entry.

**Replay is last-write-wins, with no special cases.** Process records in order:
an entry record inserts the entry and moves `head` to it; a head record moves
`head` to its `:id`; an unrecognized `:type` is ignored, so a record kind added
by a newer writer does not break an older reader. That one rule covers the
awkward case — a session that appends A and B, forks back to A, and quits logs
`A, B, (head A)`, and replay walks head A, B, A and stops where the session
actually left off. A head record is elided when it would only repeat where the
log already is, so it costs a line per fork and nothing otherwise.

**The print bindings are part of the format, not a style choice.** Left at their
defaults each of these silently corrupts a log:

| Binding | What it prevents |
|---|---|
| `print-length`, `print-level` nil | An Emacs configured for interactive printing truncates long content to `...`. The log then reads back wrong with no error anywhere. |
| `print-circle t` | A cyclic structure in an extension-authored entry makes `prin1` loop forever and takes the image with it. The reader understands the labels it emits. |
| `print-escape-newlines`, `print-escape-control-characters` | Assistant text is full of newlines, so without these "one s-expression per line" is simply false. |
| `coding-system-for-write 'utf-8-emacs-unix` | Lossless for Emacs's internal representation, and LF everywhere so the per-line invariant survives Windows. Pair it with an explicit `coding-system-for-read`. |
| `write-region-inhibit-fsync` nil | It defaults to **t in batch**, so every batch and `--script` run would be silently non-durable — exactly the case P3 exists for. |

Session files live under `xdg-data-home` — normally
`~/.local/share/benedict/sessions/<session-id>.eld`, resolved through `xdg.el`
at call time rather than at load time, since `XDG_DATA_HOME` can change after
Emacs starts. Mode `600`: a session log contains whatever the model echoed.

**Malformed logs load anyway.** A crash can leave a partial final record.
Recovering everything before it is worth far more than refusing the session, so
the default is to warn and return what parsed; strictness is opt-in for callers
that need to know a log was clean. The one exception is a `:format` this reader
does not know — that always signals, because guessing at the shapes of a future
format is worse than declining to read it.

### 5.5 Identity

Entry ids must be stable across restarts and unique within a session. A counter
plus the session id is sufficient and keeps logs readable; do not use random
UUIDs, which make manual log inspection painful for no benefit at this scale.

The format is `<session-id>-e<NNNN>`, as in `20260806T142530-a3f9-e0007`. It is
filename-safe, sorts, greps, and — the load-bearing part — lets the counter be
recovered from an id by regexp, so reloading a session restores it without a
sidecar record. Session ids are a UTC timestamp plus four random characters,
enough to separate two sessions started in the same second.

Ids come from one transcript-wide counter, so after forking to an early entry the
next id continues from the highest minted so far rather than from the fork point.
That is what keeps them unique; it does mean ids are not contiguous along any one
branch, which is worth knowing before reading a log and concluding something is
missing.

### 5.6 Compaction as a fork

Compaction does not delete history. It:

1. Summarizes the path from root to a chosen fork point.
2. Appends a new entry whose `parent` is the fork point and whose content is the
   summary.
3. Moves `head` to the summary entry.

The original branch remains in the log, remains navigable, and remains
renderable. This is worth stating explicitly because it is the single best
argument for building the tree first: compaction is otherwise a lossy operation
that users learn to fear.

Context-flagged notes (§4.5) from the compacted range are re-emitted after the
summary entry, so durable instructions survive.

#### Trigger points

Compaction uses **both** available hooks, for different purposes. They are not
alternatives:

| Hook | Role | Fires when |
|---|---|---|
| `benedict-context-filter-functions` | Primary. Compact in place, run continues. | Estimated context exceeds a soft threshold (default 70% of the model's window) |
| `benedict-continue-predicate-functions` | Safety net. Stop the run cleanly. | A hard limit is hit, or compaction itself cannot free enough |

The filter path is transparent — the user sees a compaction marker and the agent
keeps working. The predicate path is the honest failure mode: when a single turn
would not fit even after summarizing, stopping with a clear reason beats silently
truncating something load-bearing.

Only the thresholds are tuning; the two-path structure is the design.

---

## 6. Tools

### 6.1 Definition

```elisp
(benedict-deftool eval-elisp
  :label "Evaluate Elisp"
  :description "Evaluate an Emacs Lisp form in the running image and return the
result. This is the primary mechanism for inspecting and modifying Benedict
itself."
  :parameters '((form :type string :required t
                      :description "A single Emacs Lisp form."))
  :handler (lambda (invocation done)
             (funcall done (benedict-eval--run
                            (benedict-tool-arg invocation :form)))))
```

`benedict-eval--run` returns a whole result rather than content, because it has
to be able to set `error-p`: a form that signals is answered, not raised (§6.4),
and only the handler knows the difference.

`:parameters` is a small DSL compiled by `benedict-schema.el` into JSON Schema.
Supported: `:type` (`string`/`integer`/`number`/`boolean`/`array`/`object`),
`:required`, `:description`, `:enum`, `:items`, `:properties`. Anything more
exotic is passed through as a literal schema fragment.

`:type` is **mandatory** on every parameter (D8), and the six listed types are
the whole set — no `int`/`float`/`bool` aliases, because `describe-function` is
the DSL's documentation (§10.2) and it is worth more that the documented set is
the real one than that a convenience alias happens to work. Pass-through is
**per key** (D7): an unrecognized key is copied verbatim into that parameter's
own fragment, so `:minimum 1` and `:minLength 3` work with no support from the
compiler. Pass-through values are not validated or converted and must already be
JSON-shaped.

`:properties` nests the same DSL recursively, so a nested `:required t` collects
into that object's own `required` array rather than escaping to the top level.

The compiler emits a keyword plist for `json-serialize`, and four of its
behaviors are sharp enough to be worth stating: object keys must be symbols,
JSON arrays must be vectors, symbols are not values (so `:type` is the *string*
`"string"`), and nil serializes to `{}`. That last one is why `required` is
omitted entirely when nothing is required — an emitted `:required nil` becomes
`"required":{}`, which no provider accepts. Each of these produces a schema that
satisfies `equal` in a test and then fails at request time, so schema fixtures
must be round-tripped through `json-serialize`, not merely compared as plists.

### 6.2 Async by contract

**Every** handler takes `(invocation done)` and calls `done` with a result. This
is not negotiable and it is the key to §6.4: a handler that never calls `done`
simply leaves the run suspended, which is exactly what an approval prompt needs.

For the common synchronous case, sugar:

```elisp
(benedict-deftool read-file
  :sync t
  :handler (lambda (invocation) (benedict-tool-result :content ...)))
```

`:sync t` wraps the handler so it still satisfies the async contract. The kernel
has one code path.

### 6.3 Execution order

Tool calls execute **sequentially** in the order the model emitted them. Emacs
cannot run elisp concurrently, and the practical answer to "I need to do many
things" in this medium is one `eval-elisp` call containing a `dolist`, not many
parallel tool calls. Parallelism for process-backed tools is a possible later
addition and is explicitly out of scope for v1.

### 6.4 The dispatch chain

`benedict-tool-dispatch-functions` is a continuation-passing filter chain. Each
member receives the invocation and a `next` continuation, and may:

| Action | How |
|---|---|
| Allow | `(funcall next invocation)` |
| Modify then allow | `(funcall next (modified invocation))` |
| Deny | `(funcall next (benedict-tool-blocked invocation "reason"))` |
| Suspend | Hold `next`; call it later from a callback |
| Reroute | `(funcall next (benedict-tool-retarget invocation 'sandbox))` |

This single mechanism implements approval, permission policy, path protection,
sandbox delegation, and worker routing. There is no separate yield concept, no
approval state in the kernel, and no resume entry point — a suspended run is
simply one where a continuation has not yet been called.

Example — an approval policy as an extension:

```elisp
(defun my-approvals--dispatch (invocation next)
  (if (my-approvals--safe-p invocation)
      (funcall next invocation)
    (benedict-ui-confirm
     (format "Allow %s?" (benedict-invocation-name invocation))
     (lambda (ok)
       (funcall next (if ok invocation
                       (benedict-tool-blocked invocation "Denied by user")))))))

(add-hook 'benedict-tool-dispatch-functions #'my-approvals--dispatch)
```

**Durability caveat.** A continuation is in-memory. If Emacs exits while a run is
suspended on an approval, the continuation is lost. The transcript is intact
(P3), so recovery is: reopen the session, observe the un-answered tool call,
resubmit. This is the same behavior as every other harness and is not worth
engineering around.

### 6.5 Built-in tool set

The distro ships five tools. Deliberately small.

| Tool | Purpose |
|---|---|
| `eval-elisp` | The universal escape hatch. Equivalent to `bash` elsewhere. |
| `read-file` | Token-efficient file read with line ranges and truncation. |
| `write-file` | Whole-file write. |
| `edit-file` | Anchored string replacement, returns a structured diff. |
| `describe` | `describe-function` / `describe-variable` / `apropos` as data. |

`eval-elisp` takes **one** form. Several are the caller's `progn`, which also
makes it explicit which value comes back, and trailing input is refused before
anything is evaluated — a call that is going to be rejected must not have
already had half its effect.

Its result carries the printed value together with whatever the form wrote with
`princ` or logged with `message`, including when the form fails partway: a form
whose work is output returns nil, a result holding only that nil throws away
what was asked for, and the output a half-finished loop produced is often the
only diagnostic there is.

There is no timeout, deliberately. `with-timeout` needs the form to yield and an
elisp loop does not, so one here would look like a safety net without being one.
§13.3 is where that risk is accepted and where the mitigations that do work are
named.

`read`/`write`/`edit` are technically redundant with `eval-elisp`, and are kept
because they produce structured, reviewable, renderable results — a diff the UI
can display and an approval policy can reason about — where an arbitrary elisp
form produces an opaque string.

`describe` is the replacement for shipping a documentation directory. See §10.

---

## 7. The Provider Framework

### 7.1 Provider is not API

Two levels, and conflating them is the single most expensive architectural
mistake available here.

- An **API** is a wire protocol: request shape, header set, streaming event
  grammar. Expensive — roughly 800–1,500 lines each.
- A **Provider** is a service that speaks one: id, base URL, auth method, model
  catalog. Cheap — roughly a dozen lines.

For reference, pi ships 44 providers over ~10 APIs. Vercel AI Gateway,
OpenRouter, Groq, Together, Fireworks, DeepSeek, and Cerebras are all catalog
entries over the same handful of protocol implementations.

### 7.2 Definitions

```elisp
;; benedict-api-openai-responses.el
(benedict-defapi openai-responses
  :endpoint     #'benedict-api-openai-responses--endpoint    ; (model auth) -> url
  :headers      #'benedict-api-openai-responses--headers     ; (model auth) -> alist
  :build        #'benedict-api-openai-responses--build       ; (context model opts) -> alist
  :make-parser  #'benedict-api-openai-responses--parser)     ; () -> (lambda (sse-event) -> events)

;; benedict-provider-vercel.el
(benedict-defprovider vercel-ai-gateway
  :name     "Vercel AI Gateway"
  :base-url "https://ai-gateway.vercel.sh/v1"
  :api      'openai-responses
  :auth     (benedict-auth-env-api-key
             :name "Vercel AI Gateway API key"
             :env '("AI_GATEWAY_API_KEY"))
  :models   #'benedict-provider-vercel--catalog)
```

`:make-parser` returns a **closure** holding the parser's mutable state (partial
JSON accumulators, block index mapping, reasoning-item ids). This is more
idiomatic in elisp than threading an explicit state object and keeps the API
module's internals genuinely private.

**The kernel reaches all of this through exactly one function:**

```elisp
(benedict-provider-stream model request handler)  ; -> cancel thunk or nil
```

`request` is the canonical plist the kernel assembles and
`benedict-request-filter-functions` transforms — `(:entries :system-prompt
:tools :model :session)` — carrying canonical entries, never a wire payload.
`handler` receives §7.3 events. The return value is a nullary thunk that asks
the provider to stop.

A provider may carry a `:stream` function of its own, which is how the fake
provider (§7.7) supplies a transport with no HTTP; when it does not, dispatch
falls through to the shared HTTP path over the provider's `:api`. The kernel
cannot tell the two apart, which is the same property that lets a dispatch
filter reroute a tool call to a sandbox without the kernel learning what a
sandbox is.

### 7.3 Normalized event protocol

Every API adapter emits the same event vocabulary. The kernel and every frontend
know only this:

```elisp
(:type :start)
(:type :block-start   :index 0 :block-type text)
(:type :block-delta   :index 0 :delta "Hel")
(:type :block-end     :index 0)
(:type :done  :reason stop|length|tool-use  :usage (...) :response-id "...")
(:type :error :reason error|aborted :message "...")
```

`block-type` is one of `text`, `thinking`, `tool-call`. Tool-call deltas carry
partial JSON argument text; the adapter is responsible for assembling and parsing
complete arguments before emitting `:block-end`, so the kernel never sees invalid
JSON.

Two events carry more than the skeleton above, and both are consequences of that
last rule:

- `:block-start` for a `tool-call` carries `:id` and `:name`, which are known
  when the item opens.
- `:block-end` carries `:arguments` — the assembled, parsed plist — and
  `:signature` for a block that has one. Arguments arrive here rather than
  through deltas precisely because the deltas are partial text: an adapter that
  emitted them as arguments would be handing the kernel invalid JSON, which is
  the thing the kernel must never see.

The kernel keeps a tool call's raw partial JSON on the block while it streams,
so a frontend can render an argument list arriving, and strips it at
`:block-end`. It is display state and never reaches the transcript or the log.

**Stream contract.** An adapter must never signal an elisp error to its caller
for a request, model, or network failure. Failures are encoded as a terminal
`:error` event. This keeps the reducer's error path singular: every stream ends
in exactly one of `:done` or `:error`, and the kernel finalizes the streaming
entry identically in both cases.

### 7.4 First API: `openai-responses`

Vercel AI Gateway is the initial target and is addressed through the OpenAI
Responses API across its whole catalog — including non-OpenAI models. This is
confirmed against the live service (§7.4.1), not inferred, and it means **v1
needs exactly one wire API.** A second API is a later expansion for a second
provider, not a Phase 4 risk.

Implementation notes for the adapter:

**Request.** `POST /responses` with `input` as an array of typed items (not
`messages`), `stream: t`, `tools` as flat function definitions with
`{type: "function", name, description, parameters}`.

**Stream events to handle.** The Responses grammar is verbose; the subset that
matters:

| Upstream event | Maps to |
|---|---|
| `response.created` | `:start`, capture `response.id` |
| `response.in_progress` | ignored |
| `response.output_item.added` | `:block-start` — inspect `item.type` |
| `response.content_part.added` / `.done` | ignored; the item events bracket the block |
| `response.output_text.delta` | `:block-delta` (text) |
| `response.reasoning.delta` | `:block-delta` (thinking) |
| `response.reasoning_summary_text.delta` | `:block-delta` (thinking) |
| `response.reasoning_summary_part.added` / `.done` | ignored |
| `response.function_call_arguments.delta` | `:block-delta` (tool-call) |
| `response.function_call_arguments.done` | assemble + parse arguments |
| `response.output_item.done` | `:block-end`; capture reasoning item id |
| `response.completed` / `.incomplete` | `:done` with usage |
| `response.failed` | `:error` |

**Reasoning continuity.** Reasoning items must be echoed back on the next request
for multi-turn continuity. Store the item id (and `encrypted_content`, when the
provider returns it) in the thinking block's `:signature`, and re-emit those items
in `input` when building the next request. This is not an optimization: the
gateway returns `store: false` and `previous_response_id: null`, so there is no
server-side conversation state to fall back on. Getting it wrong degrades quality
silently rather than erroring, so it warrants a dedicated test with a scripted
two-turn stream.

**Usage.** `usage.input_tokens` includes cached tokens; subtract
`input_tokens_details.cached_tokens` to get the uncached input count, or
accounting will overstate cost. `input_tokens_details.cache_write_tokens` is
present for some models and absent for others, and
`output_tokens_details.reasoning_tokens` is reported as 0 by some models that
demonstrably reasoned — treat both as optional and never infer behavior from
them.

#### 7.4.1 What the gateway normalizes, and what it does not

Measured across five models with one identical request. The distinction matters
because it is the difference between what an adapter may assume and what it must
detect.

**Normalized — safe to rely on.** Item `type` values (`reasoning`, `message`,
`function_call`), item id prefixes (`rs_`, `msg_`, `fc_`), the presence of both
`id` and `call_id` on a function call, and `arguments` as a JSON string.

**Not normalized — the adapter must handle every variant:**

| Variation | Observed |
|---|---|
| Reasoning event family | `response.reasoning.delta` (DeepSeek, Qwen) vs. `response.reasoning_summary_text.delta` (Grok). Both must be handled; neither is the "real" one. |
| Reasoning at all | A model tagged `reasoning` in the catalog may emit no reasoning items. The tag is a catalog claim, not a guarantee. |
| Item interleaving | Two of five models open a `function_call` item while a `message` item is still streaming. See below. |
| Argument delta count | One delta carrying the whole argument string, or a dozen carrying a character each. |
| `call_id` shape | `call_9b5b…` (underscore, hex), `call_69904KpBB7…` (mixed case), `call-49b6…-0` (**hyphens**, UUID-shaped, 44 chars). |
| Text alongside a tool call | Usually absent; one model emitted a text block containing only `"\n\n"`. |
| `content_part` / `output_text` events | Emitted only when a text block exists. |

**Output items interleave, and this is the sharp one.** An adapter must key block
state on `output_index`, never on arrival order or a single "current block"
pointer:

```
seq 15  response.output_text.delta              output_index 1
seq 16  response.output_item.added              output_index 2   <- opens while 1 is open
seq 17  response.function_call_arguments.delta  output_index 2
seq 26  response.output_text.done               output_index 1   <- 1 closes only now
```

The table above reads as a linear sequence and, taken that way, implies exactly
the parser that breaks here. Recorded fixtures for each of these variants live in
`test/fixtures/`; see its README for provenance and the re-capture command.

### 7.5 Capability flags, not branches

Providers that speak the same protocol still differ. Encode differences as
declarative flags on the provider or model record, consulted by the adapter —
never as `if provider-is-x` branches inside the adapter.

```elisp
(benedict-defprovider vercel-ai-gateway
  ...
  :compat '(:supports-developer-role t
            :supports-strict-tools   nil
            :session-affinity        openai))
```

This is what keeps one adapter serving many services without accumulating
provider-specific conditionals. When a new service needs a behavior no flag
expresses, add a flag; do not add a branch.

### 7.6 Model catalog

pi generates model catalogs at build time from provider APIs. Benedict does not
need a build step (P8): resolve catalogs at runtime with an on-disk cache.

```elisp
(defun benedict-provider-vercel--catalog (&optional force)
  "Return the gateway model catalog, refreshing the cache when stale or FORCE.")
```

Cache at `~/.cache/benedict/models/<provider>.eld` with a TTL. On cache miss or
network failure, fall back to a small hardcoded list of known-good model ids so
the system remains usable offline.

Model records carry: `id`, `name`, `context-window`, `max-tokens`, `reasoning-p`,
`input-modalities`, `cost` (per-million rates for input/output/cache-read/
cache-write), and the `:compat` plist from §7.5.

Two things the Vercel catalog made concrete, both likely to recur:

**Catalog rates are per token, model records are per million.** The gateway
reports `"0.00000013"` — a *string*, at that. Convert on the way in, so that
nothing downstream has to know which unit it is holding.

**A catalog flag describes intent, not behavior.** A model tagged `reasoning`
may emit no reasoning items at all (§7.4.1). `reasoning-p` is therefore a hint
for a frontend and a budget filter, and never a premise an adapter branches on.

Catalog resolution is the one place a **blocking** request is acceptable:
`benedict-model-resolve` is synchronous and the transport is not. Keep it
cache-first so the blocking path is reached only on a cold cache, and never call
it from inside a stream callback.

### 7.7 The fake provider

`benedict-provider-fake` is a first-class deliverable, not a test fixture
afterthought. It takes a script of normalized events (or a higher-level
description — "emit this text, then call this tool with these args") and replays
it synchronously.

Everything in the kernel, the tool layer, the extension mechanism, the store, and
the frontend must be testable against it with no network and no credentials. If a
behavior can only be tested against a live provider, that is a design smell in
the boundary.

The fake provider must be able to impersonate **any** `provider`/`api`/`model`
triple, so that cross-model degradation (§7.8) is testable without a second real
provider.

### 7.8 Model and provider switching within a conversation

Switching models mid-conversation is a first-class operation, not an edge case:
it is how "retry this turn with a stronger model" works, and combined with
forking (§5) it is how A/B comparison works. The transcript must survive it.

#### 7.8.1 One canonical format, N serializers

There is no conversion *between* wire formats. Benedict never turns an
Anthropic-shaped message into an OpenAI-shaped one. There is exactly one
canonical representation — the entry structs of §4.5 — and each API adapter
lowers canonical entries into its own wire format at request time.

```
                        ┌──► openai-responses   ──► wire
canonical transcript ───┼──► anthropic-messages ──► wire
                        └──► google-generative  ──► wire
```

This is why switching models is cheap: the next request simply goes through a
different serializer over the same unchanged transcript. It also means the cost
of adding an API is O(1), not O(N) in the number of existing APIs — the
alternative, pairwise conversion, is the mistake this structure exists to avoid.

The kernel stores canonical entries and never mutates them. Lowering is entirely
a provider-layer concern.

#### 7.8.2 Two distinct pipeline stages

These are separate and must not be conflated:

| Stage | Operates on | Owner | Purpose |
|---|---|---|---|
| **Context filtering** | canonical → canonical | extensions (`benedict-context-filter-functions`) | compaction, injection, pruning |
| **Lowering** | canonical → canonical (degraded) → wire | API adapter | cross-model degradation, structural repair, serialization |

Lowering itself has two steps, and keeping them separate is what makes the logic
testable: **degrade in canonical space first, then serialize.** The shared
degradation pass lives in `benedict-api-transform.el` and is called by every
adapter; only the final serialization is adapter-specific.

```elisp
(benedict-api-lower entries model &optional normalize-tool-call-id)
;; -> degraded canonical entries, ready for this adapter to serialize
```

#### 7.8.3 The origin test

Everything hinges on a per-entry comparison, evaluated at lowering time:

```elisp
(defun benedict-api--same-origin-p (entry model)
  (and (eq    (benedict-entry-meta-get entry :provider) (benedict-model-provider model))
       (eq    (benedict-entry-meta-get entry :api)      (benedict-model-api model))
       (equal (benedict-entry-meta-get entry :model)    (benedict-model-id model))))
```

All three must match. This is evaluated **per entry**, not per conversation — a
transcript containing entries from four different models lowers each according to
its own origin in a single pass.

#### 7.8.4 Degradation rules

When an entry is same-origin, everything is preserved verbatim, including
signatures. When it is foreign:

| Block | Same origin | Foreign origin |
|---|---|---|
| `thinking`, `:redacted t` | keep | **drop entirely** |
| `thinking` with `:signature` | keep, even if text is empty | → plain `text` block |
| `thinking`, empty text | drop | drop |
| `thinking`, ordinary | keep | → plain `text` block |
| `text` | keep with `:signature` | rebuild as bare text, signature stripped |
| `tool-call` | keep | strip `:signature`, rewrite `:id` (§7.8.5) |
| `image`, model lacks vision | → placeholder text | → placeholder text |

Two rules deserve explanation because they look arbitrary:

**Redacted thinking is dropped, not converted.** It is opaque ciphertext that
only the issuing model can decrypt. Sending it to another model is at best a
rejected request and at worst a confusing one.

**Ordinary thinking becomes visible text rather than being dropped.** The
reasoning has value to the new model as context; what it cannot accept is the
*protocol artifact* of a thinking block bearing a signature it did not issue.
Converting preserves the content and discards the protocol.

Empty thinking blocks with signatures are kept same-origin because some providers
(OpenAI with encrypted reasoning) return a signature and no text, and dropping the
block breaks replay continuity.

#### 7.8.5 Tool call identifiers

The sharpest practical hazard. Each API constrains ids differently:

| API | Constraint |
|---|---|
| `anthropic-messages` | `^[a-zA-Z0-9_-]+$`, ≤64 chars |
| `openai-completions` | ≤40 chars |
| `openai-responses` | composite `call_id|item_id`; item id must begin `fc_` |
| `google-generative-ai` | only required for some models |

An OpenAI Responses id can exceed 450 characters and contain `|`. Replaying that
transcript into Anthropic requires rewriting it. The adapter supplies a
normalizer; the shared pass applies it and — critically — **records old→new in a
map and applies the same rewrite to the matching `tool-result` entry.** Rewriting
a call id without rewriting its result produces an orphaned result and a rejected
request.

For a foreign tool call replayed into `openai-responses`, a synthetic item id is
derived from a short hash of the original, since no real upstream item exists.

`benedict-api-lower` therefore takes the normalizer as an argument rather than
owning the policy, and the id map is internal to a single lowering pass.

#### 7.8.6 Structural repair

The same pass repairs transcript states that every API rejects. These apply
regardless of model switching, but a switch makes them more likely:

1. **Orphaned tool calls get synthetic error results.** A tool call with no
   matching result is invalid everywhere. Insert
   `(:content "No result provided" :error-p t)` — at the next assistant entry, at
   the next user entry, and at the end of the transcript. This is what makes
   aborting mid-tool-execution recoverable.
2. **Errored and aborted assistant entries are skipped entirely.** They may carry
   partial content — reasoning with no following item, half-formed tool call
   arguments — that causes provider errors on replay. The transcript keeps them
   (they are real history and the UI shows them); the lowering pass omits them.
3. **Images become placeholder text for non-vision models,** collapsing
   consecutive placeholders so a ten-image turn does not become ten lines of
   noise. Tool results carrying images use a distinct placeholder, so the model
   can tell an image it was shown from one a tool produced.
4. **Nil content is normalized to an empty list,** since hand-built entries and
   older session logs may violate the struct contract. *This rule needs no code
   in elisp: nil is the empty list, and `benedict-entry-create` already runs
   `benedict-entry-normalize-content`. It is retained because it is a real
   requirement of the pass, discharged by the data model rather than by the
   lowering module.*
5. **Tool results orphaned by rule 2 are dropped.** An errored turn whose tools
   had already run leaves results answering a call that rule 2 just removed. A
   provider rejects an orphaned result exactly as hard as an orphaned call, so
   removing one without the other trades a broken request for a different broken
   request. Rules 1 and 5 are the two halves of one invariant: after the pass,
   every tool call has a result and every result has a call.

The set of surviving call ids is computed in its own sweep before the repair
walk, so whether a result is orphaned does not depend on where it sits relative
to its call.

#### 7.8.7 Interaction with forking

Fork-and-switch is the primary use for both features together:

```elisp
(benedict-session-fork session entry-id)
(setf (benedict-session-model session) other-model)
(benedict-session-submit session nil)   ; resume from the fork
```

Because lowering runs at request time over the materialized path (§5.1), and the
path only contains ancestors of the current head, signatures from the abandoned
branch are structurally unreachable. No special handling is required — but this
warrants an explicit test, since a bug here fails at the provider with an opaque
error rather than locally.

#### 7.8.8 What the user sees

Model switching should be visible in the transcript, not silent. When the active
model changes mid-conversation, append a `role note` entry recording the change.
The renderer marks the boundary; the lowering pass ignores it. Without this,
reading back a session where quality changed at turn six is a mystery.

#### 7.8.9 Notes have no wire role

`note` is one of the four canonical roles (§4.5) and none of the wire protocols
have anything to map it to. Lowering is where notes stop existing:

- A note without `:context` is **dropped** — model-change markers, UI markers,
  extension annotations. This is the same decision `benedict-entry-context-p`
  makes for the kernel's context filter, applied again because
  `benedict-api-lower` must be safe to call on a raw transcript path.
- A note with `:context t` becomes a **`user` entry** with its content intact.

The promotion is what makes "remember X for the rest of this session" (D4)
actually reach a model. It happens once here rather than in each adapter for the
same reason the degradation table does: the mapping is not a protocol difference,
so expressing it in canonical space keeps every adapter's serializer dealing only
with roles its protocol has. A promoted note is a user entry in every respect
afterwards, including closing an open tool flow the way a typed message does.

---

## 8. Authentication

### 8.1 The auth value type

Resolved authentication is exactly three fields:

```elisp
(:api-key "..." :headers (("X-Foo" . "bar")) :base-url "https://...")
```

The rule, worth enforcing in review: **if a value cannot be expressed as
`api-key`, `headers`, or `base-url`, it is provider configuration, not auth.**
This prevents the auth layer from becoming a general provider-config dumping
ground, which is how auth code in these systems typically rots.

`base-url` is present because some credentials determine their own endpoint —
GitHub Copilot does this, and subscription-backed providers generally may.

### 8.2 Credential store

```elisp
(benedict-auth-read provider-id)                    ; -> credential or nil
(benedict-auth-list)                                ; -> metadata, no secrets
(benedict-auth-modify provider-id fn callback)      ; the ONLY write path
(benedict-auth-delete provider-id)
```

`benedict-auth-modify` calls `fn` with the current credential and expects the new
one. Making it the sole write path is what allows refresh to be serialized
correctly (§8.4).

Storage is `~/.config/benedict/auth.json`, mode `600`:

```json
{
  "vercel-ai-gateway": { "type": "api_key", "key": "..." },
  "openai-codex": { "type": "oauth", "refresh": "...", "access": "...", "expires": 1785000000 }
}
```

Environment variables and `auth-source` are consulted only when nothing is
stored. A stored credential owns its provider — no silent env fallback after a
failed refresh, because that turns an auth error into a confusing
wrong-account error.

### 8.3 The OAuth contract

An OAuth method is three functions. This factoring is the important part: it
leaves the *hard* part — serialized refresh — owned by the framework, so a
provider never writes locking code.

```elisp
(benedict-defoauth openai-codex
  :name    "OpenAI Codex"
  :subscription-p t
  :login   (lambda (interaction callback) ...)   ; -> credential
  :refresh (lambda (credential callback) ...)    ; -> credential; errors on invalid_grant
  :to-auth (lambda (credential) ...))            ; -> auth plist; PURE
```

- `login` runs the interactive flow.
- `refresh` exchanges the refresh token. Network call. Fails loudly.
- `to-auth` derives request auth from a valid credential. Must be pure and
  side-effect free — it runs on every request, and it is where per-credential
  `base-url` is handled.

### 8.4 The refresh race

Emacs is single-threaded, which makes it tempting to skip refresh locking. Do
not.

The reducer is callback-driven. Two in-flight requests can both observe an
expiring token, both call `refresh`, and the second can persist a credential
derived from a refresh token the first already rotated — invalidating the
session. The concurrency is real; it is just cooperative rather than preemptive.

Required behavior in `benedict-auth-resolve`:

1. Read the credential. If it is an API key, resolve and return.
2. If OAuth and expiry is more than five minutes out, `to-auth` and return.
3. Otherwise, check a per-provider **in-flight table**. If a refresh is already
   pending for this provider, enqueue this request's callback on it and return.
4. Otherwise, register in-flight, call `refresh`, and on completion: persist via
   `benedict-auth-modify`, then flush every enqueued callback with the new
   credential.
5. Re-check expiry inside `modify` before refreshing — another Emacs process may
   have rotated it.

Cross-process safety needs a lock file around `auth.json` read-modify-write. A
`.lock` directory created with `make-directory` is atomic on POSIX and adequate.

### 8.5 Interactive login

Login flows are **headless**. The provider describes what it needs; a frontend
supplies the interaction:

```elisp
;; Interaction protocol
(benedict-auth-prompt interaction
                      :type 'secret        ; text | secret | select | manual-code
                      :message "Enter API key"
                      :callback fn)
(benedict-auth-notify interaction
                      :type 'auth-url      ; info | auth-url | device-code | progress
                      :url "https://...")
```

The chat frontend maps these to `read-passwd`, `completing-read`, `browse-url`,
and a status line. A batch-mode frontend maps them to stdin. Tests supply a stub.
The OAuth implementation itself never touches Emacs UI, which is what makes it
testable.

### 8.6 OAuth in Emacs — mechanics

Everything needed is native to Emacs 29:

| Requirement | Primitive |
|---|---|
| PKCE verifier | random bytes → `base64url-encode-string` |
| PKCE challenge | `(base64url-encode-string (secure-hash 'sha256 v nil nil t) t)` |
| Loopback redirect server | `make-network-process :server t :service port :family 'ipv4` |
| Open browser | `browse-url` |
| Token exchange | `benedict-http` POST |
| JSON | `json-parse-string` / `json-serialize` |

No shelling out to `openssl` for any part of the cryptography — PKCE verifier,
challenge, and base64url are all native, and a subprocess for them would be
embarrassing rather than pragmatic. The *transport* is a separate question and
is answered by `benedict-http` (D18), which does use `curl`; token exchange
goes through it like every other request. The loopback flow —
which OpenAI Codex, Google Antigravity, and similar subscription providers use —
is: start the server on a fixed or ephemeral port, `browse-url` the authorize URL
with `redirect_uri=http://localhost:<port>/callback`, parse the code from the
first request's query string, respond with a small HTML page, close the server,
exchange the code.

Provide a shared `benedict-oauth-loopback-flow` helper so each OAuth provider
supplies only its URLs, scopes, and client id.

### 8.7 Sequencing

API-key auth for Vercel AI Gateway is the v1 requirement and is roughly thirty
lines. The OAuth machinery in §8.3–§8.6 should be **designed** into the interfaces
from the start — specifically the `refresh`/`to-auth` split, the in-flight table,
and the headless interaction protocol — but implemented against real subscription
providers only after the kernel is proven. Retrofitting the split is cheap;
retrofitting the serialization is not.

---

## 9. Extensions

### 9.1 What an extension is

An Emacs Lisp file that requires `benedict` and registers things. There is no
manifest format, no build, no sandbox, and no lifecycle protocol.

```elisp
;;; benedict-ext-checkpoint.el --- Git checkpoints per turn -*- lexical-binding: t; -*-
(require 'benedict)

(benedict-defextension checkpoint
  :description "Stash a git checkpoint at each turn boundary"
  :version "1.0")

(benedict-deftool checkpoint-restore
  :description "Restore the working tree to a prior turn's checkpoint."
  :parameters '((turn :type integer :required t))
  :sync t
  :handler #'checkpoint--restore)

(defun checkpoint--on-turn-start (session)
  (checkpoint--stash session))

(add-hook 'benedict-turn-start-functions #'checkpoint--on-turn-start)

(provide 'benedict-ext-checkpoint)
```

`benedict-defextension` is metadata only — it exists so extensions are listable
and toggleable in a UI. It has no effect on behavior. Everything else is ordinary
elisp using ordinary Emacs mechanisms.

### 9.2 Reload by idempotence

Reloading is `load-file`. There is no unregister protocol, because every
registration primitive is idempotent:

- `defun` — redefinition replaces.
- `add-hook` with a named function symbol — no-op if already present.
- `benedict-tool-register` — keyed by tool id, replaces.
- `benedict-defprovider` / `benedict-defapi` — keyed by id, replaces.

The rule for extension authors: **never `add-hook` a lambda.** Always a named
function. That one convention is the entire reload story, and it is worth stating
in the extension-authoring skill in bold.

### 9.3 Capabilities

An extension can:

| Capability | Mechanism |
|---|---|
| Add a tool | `benedict-deftool` |
| Intercept, block, or reroute a tool call | `benedict-tool-dispatch-functions` |
| Rewrite a tool result | `benedict-tool-result-filter-functions` |
| Transform context before a request | `benedict-context-filter-functions` |
| Stop a run early | `benedict-continue-predicate-functions` |
| Observe anything | The observation hooks (§4.4) |
| Add a provider or wire API | `benedict-defprovider` / `benedict-defapi` |
| Add a slash command | `benedict-defcommand` (distro) |
| Add an interactive command | Ordinary `defun` + `interactive` |
| Change rendering | Frontend-provided renderer hooks |
| Persist state across restarts | Append `role note` entries |

Because everything is elisp, the honest answer to "can an extension do X" is
"yes, including things this table does not anticipate." `advice-add` on kernel
functions is available and occasionally correct. The hooks exist so that the
common cases do not require advice, not to prevent it.

### 9.4 Discovery

| Location | Scope | Trust |
|---|---|---|
| `~/.config/benedict/extensions/*.el` | Global | Trusted |
| `~/.config/benedict/extensions/*/init.el` | Global, multi-file | Trusted |
| `<project>/.benedict/extensions/*.el` | Project | Gated |
| Anything on `load-path` | Package-installed | Trusted |
| `benedict-extension-files` | Explicit | Trusted |

Project-local extensions load only after the project is marked trusted, recorded
in `~/.config/benedict/trust.eld`. The prompt is one-time per project root.

Package-installed extensions need no discovery mechanism at all — they are Emacs
packages, so `package.el`, `straight`, `elpaca`, and Doom already handle
installation, versioning, and load order. This is a significant simplification
over harnesses that must invent an npm-alike; §12 covers it.

### 9.5 Ordering

Hook order matters for dispatch filters — a sandbox router should run after an
approval gate, not before. `add-hook`'s `DEPTH` argument covers this. Document
the convention: approval-type filters at depth 0, routing filters at depth 90,
observation-only wrappers at depth -90.

---

## 10. Self-Extension

This is the point of the architecture. It deserves an explicit specification
rather than being left to emerge.

### 10.1 The loop

A user asks for a capability that does not exist. The agent:

1. **Reads the concepts.** The `benedict-extension` skill explains what a
   dispatch filter is, what `next` means, the named-function rule, and where
   files go.
2. **Reads the live API.** `describe` on `benedict-tool-dispatch-functions`,
   `apropos` on `benedict-tool-`, `describe-function` on `benedict-deftool`.
3. **Writes the file** to `~/.config/benedict/extensions/`.
4. **Loads it.** `eval-elisp` → `(load-file "...")`.
5. **Tests it** by invoking the new tool or triggering the hook.

Step 4 is the payoff and the reason the medium was chosen. There is no reload
subsystem to design, no restart, no lost session.

One gap this loop has today: a tool registered by an evaluated form is callable
immediately — an invocation resolves its tool through the registry — but a
session's tool list is resolved once at creation, so no subsequent request tells
the model that the tool it just wrote exists. Step 5 therefore works only
because the agent remembers what it registered, which is not a property to build
on. See §16.

### 10.2 Introspection over documentation

A TypeScript runtime cannot answer "what does `registerTool` accept?" at runtime,
so pi ships `docs/extensions.md` and points the system prompt at its path on
disk. Emacs can answer, so Benedict splits the problem:

| Question | Source |
|---|---|
| "What is a dispatch filter? Why would I write one?" | Skill file (prose, hand-written) |
| "What arguments does `benedict-deftool` take?" | `describe-function` |
| "What hooks exist?" | `apropos` `"benedict-.*-functions"` |
| "What does this hook's contract say?" | `describe-variable` docstring |

The second column can never drift from the implementation. This makes docstring
quality a **load-bearing engineering requirement**, not a nicety: every kernel
hook variable, every public function, and every struct accessor needs a docstring
written for an agent reading it cold. Hook variable docstrings in particular must
state the exact calling convention and what return values mean.

### 10.3 Ephemeral extension

A capability unique to this medium and worth designing for: the agent can `eval`
a change into the live image *without writing a file*, verify it works, and only
then persist it. Redefining a function to add a trace, running one turn, and
reverting is a normal debugging workflow here.

The implication for the store: `role note` entries should record evaluated forms
that modify the runtime, so a session transcript explains why the running image
differs from what is on disk. Nothing does this yet, because an extension has no
sanctioned way to append an entry — §16 Q1.

### 10.4 System prompt

Kept small. It states: you are running inside a live Emacs image; `eval-elisp`
evaluates in that image; introspection tools are the way to learn the API;
extensions live at these paths and are loaded with `load-file`; here are the
available skills (name, description, path only).

Skill contents are **not** included — only descriptions. The agent reads the full
skill with `read-file` when a task matches. This is the Agent Skills
progressive-disclosure model and Benedict should implement the standard as
published, so skills are shared with other harnesses (§12.4).

---

## 11. Frontends

### 11.1 The falsifiable boundary

**The chat UI must be implementable using only the public API of §4.1 and the
hooks of §4.4.** If it needs a private accessor, the kernel API is incomplete and
grows. This is the test that keeps P2 honest, and it should be checked at every
milestone rather than asserted once.

The corollary is that a second frontend must be cheap. A batch/non-interactive
mode — submit a prompt, print the result, exit — is worth building early
specifically as a boundary check, not because anyone will use it much.

### 11.2 Rendering model

The chat buffer renders **a path**, not the whole tree. It subscribes to:

- `benedict-entry-start-functions` — insert a region for the new entry
- `benedict-entry-update-functions` — re-render block `index` from the streaming
  entry (§4.3)
- `benedict-entry-end-functions` — finalize the region
- `benedict-tool-start/end-functions` — render tool call and result blocks
- `benedict-state-change-functions` — status line

Because the kernel owns the accumulator, the update handler re-renders one block
rather than reconstructing the message. Keeping re-render scoped to a block is
what makes streaming feel responsive in a buffer.

### 11.3 Branch affordances

Since the transcript is a tree, the renderer needs to indicate when an entry has
siblings — "2/3" with bindings to cycle. `benedict-session-children` provides
this. The affordance should be present from the first version of the UI; it is
much harder to add to a renderer built around a linear list.

### 11.4 Approval UI

The approval extension owns the *decision*; the frontend owns the *presentation*.
The extension calls an abstract `benedict-ui-confirm` that the attached frontend
implements — an inline region with keybindings in chat, `y-or-n-p` in batch, a
stub in tests. The kernel is not involved at any point.

---

## 12. Packaging and Layout

### 12.1 Repository layout

```
benedict/
  core/          benedict.el, -message, -session, -tool, -provider, -core, -schema
  support/       benedict-http.el, benedict-auth.el, benedict-log.el
  api/           benedict-api-openai-responses.el, ...
  providers/     benedict-provider-vercel.el, benedict-provider-fake.el, ...
  ext/           benedict-eval, -files, -introspect, -store, -approvals,
                 -compact, -skills, -prompts
  ui/            benedict-chat*.el and render components
  skills/        benedict-extension/SKILL.md, ...
  test/          ERT suites mirroring the above
```

Subdirectories are added to `load-path` at build and test time. File name
prefixes remain globally unique, so the layout is organizational rather than
semantic.

### 12.2 Package boundaries

Ship as separate packages once the shape settles:

| Package | Contains | Depends on |
|---|---|---|
| `benedict` | `core/`, `support/` | Emacs 29.1, `curl` (D18) |
| `benedict-distro` | `ext/`, `ui/`, `skills/` | `benedict` |
| `benedict-vercel` | `api/openai-responses`, `providers/vercel` | `benedict` |
| `benedict-anthropic` | `api/anthropic-messages`, `providers/anthropic` | `benedict` |

A user who wants the kernel and nothing else installs `benedict`. The default
experience is `benedict-distro`. Provider packages are independent, which is the
whole point of §7.1 — a fifth provider never touches the core.

`curl` is a *system* dependency, not a `Package-Requires` entry — package.el has
no vocabulary for one. `benedict-http` must therefore fail with a message naming
`curl` and `benedict-http-curl-program` when it is absent, rather than with
whatever `make-process` signals; a missing binary is the one dependency failure
a user can act on immediately.

Until the split is worth the friction, a single package with these boundaries
enforced by discipline and dependency tests is acceptable. The boundaries must be
real in the dependency graph even when they are not yet real in the package
manifest.

### 12.3 Distribution

Extensions distribute as **Emacs packages**. `package.el`, `straight`, `elpaca`,
and Doom already solve installation, versioning, pinning, and load ordering.
Benedict adds nothing here and must resist the urge to. This is one of the
clearest wins the medium provides: pi needs `pi install`, npm/git source
resolution, shrinkwrap generation, and a lifecycle-script allowlist. Benedict
needs `(package-install 'benedict-ext-foo)`.

### 12.4 User-facing paths

| Path | Contents |
|---|---|
| `~/.config/benedict/auth.json` | Credentials, mode 600 |
| `~/.config/benedict/settings.eld` | Settings |
| `~/.config/benedict/extensions/` | User extensions |
| `~/.config/benedict/prompts/*.md` | Prompt templates → slash commands |
| `~/.config/benedict/trust.eld` | Trusted project roots |
| `~/.local/share/benedict/sessions/` | Session logs |
| `~/.cache/benedict/models/` | Model catalog cache |
| `~/.agents/skills/`, `<project>/.agents/skills/` | Skills, shared across harnesses |

Reading the standard `~/.agents/skills/` location means skills written for Claude
Code or pi work in Benedict unmodified, and vice versa. This is free
interoperability and should not be given up for a bespoke location.

### 12.5 Testing

ERT throughout, run by `nix run .#test`. Requirements:

- Kernel, tools, store, extensions, and frontend are all testable against
  `benedict-provider-fake` with no network and no credentials.
- Provider adapters are tested against **recorded** SSE streams checked into the
  repo — real captured bytes, replayed through the parser. This catches wire
  format drift without spending tokens. Fixtures live in `test/fixtures/` with a
  README recording, per fixture, which model produced it and the command that
  re-captures it; recorded bytes with no provenance rot silently.
- **`nix run .#test` never touches the network and never reads a credential.**
  Every ERT suite runs unconditionally — no skips, no tags, no environment
  probes. A suite that would need a key belongs outside `test/`.
- Exercising a real service is a **script**, not a test: `nix run .#live` runs
  `scripts/live-smoke.el` against whatever is in `auth.json`. It is how a phase
  demonstrates its exit criterion once, not something CI runs. The separation is
  deliberate — a credentialed test in the suite makes the suite's guarantees
  conditional on the runner's environment, and the whole value of the fake
  provider is that they are not.
- A dependency test asserts the §12.2 boundaries: no kernel file may `require` a
  file from `ext/`, `ui/`, `api/`, or `providers/`.
- The reducer is tested by driving it with synthetic events and asserting state
  transitions directly, independent of any provider.

The boundary test constrains `require` and nothing else. `declare-function` and
an `autoload` cookie pointing at a higher layer create no load-time dependency
and are the intended way for a lower layer to name something above it — the
store does exactly that for the session accessor it consults. Say so in the test
itself, or someone will eventually "fix" those by adding a `require`, which is
the thing the test exists to prevent. The test should walk read forms rather than
grep, so that a `require` inside `eval-when-compile`, `eval-and-compile`,
`with-eval-after-load`, or a conditional is caught — those are where a violation
would actually hide.

---

## 13. Comparison to Pi

Benedict's architecture is derived from pi's. This section records what carries
over and what changes, so that future divergence is deliberate.

### 13.1 What carries over

| Concept | Benedict form |
|---|---|
| Tiny core, large periphery | §3.1 — kernel under 1,500 lines |
| Core owns mechanism, extensions own policy | §2 P1, §6.4 |
| Provider/API separation | §7.1 |
| Normalized stream event vocabulary | §7.3 |
| One canonical format, N serializers | §7.8.1 |
| Per-entry origin tagging and degradation | §7.8.3–§7.8.4 |
| Tool-call id normalization with result remapping | §7.8.5 |
| Structural repair of replayed transcripts | §7.8.6 |
| `refresh`/`to-auth`/`login` OAuth split | §8.3 |
| Three-field resolved auth | §8.1 |
| `modify` as the sole credential write path | §8.2 |
| Headless auth interaction protocol | §8.5 |
| Capability flags instead of provider branches | §7.5 |
| Agent Skills, progressive disclosure | §10.4, §12.4 |
| Prompt templates as markdown slash commands | §12.4 |
| A first-class fake provider | §7.7 |
| Tree-structured sessions with forking | §5 |
| No permission system in the core | §3.3 |
| Documentation addressed to the agent | §10 |

### 13.2 What changes, and why

**Reducer instead of an async loop.**
pi's `runAgentLoop` is a `while` loop with `await`. Emacs has no `await`, so the
kernel is a state machine re-entered from callbacks (§4.2). Forced by the medium,
but it yields better observability — every transition is an explicit,
interceptable point — and makes the kernel synchronously testable.

**Async tools subsume yields, approvals, and delegation.**
pi handles approval by awaiting a UI promise inside `beforeToolCall`. Without
`await`, Benedict makes every tool handler continuation-passing, which turns
suspension into "the continuation has not been called yet" (§6.4). The result is
strictly smaller: no yield concept, no approval state, no resume entry point, and
one mechanism covering approval, blocking, rewriting, and sandbox routing.

**The kernel owns the stream accumulator.**
pi attaches a full `partial` message to every stream event, correct for an
immutable-message runtime. Benedict mutates a streaming entry in place and emits
`(index, delta)`, because in-place mutation with scoped region re-render is the
Emacs idiom and avoids per-token consing (§4.3).

**Session tree lives in the kernel, not a layer above.**
pi's agent core holds a flat `messages` array; branching lives in the harness's
session layer. Benedict puts `parent`/`head` in the kernel's entry struct because
retrofitting a tree through a reducer, a store, and a renderer is expensive, and
because compaction-as-fork (§5.6) depends on it (§5.2).

**Introspection replaces the documentation directory.**
pi's system prompt carries filesystem paths to `README.md`, `docs/`, and
`examples/`. Benedict ships prose concepts as skills and exposes the API surface
through `describe`/`apropos` (§10.2). Trades a maintenance burden for a docstring
quality requirement.

**`load-file` replaces the reload subsystem.**
pi's `/reload` has documented footguns around stale in-memory state and handler
call frames. Benedict requires idempotent registration and a named-function
convention, and reload becomes a one-line operation with no lifecycle (§9.2).

**Emacs packages replace the package manager.**
pi implements npm/git package installation, filtering, shrinkwrap, and a
lifecycle-script allowlist. Benedict uses the existing Emacs ecosystem (§12.3).

**Sequential tool execution.**
pi executes tool calls in parallel by default. Emacs cannot run elisp
concurrently, and the natural expression of bulk work here is one `eval-elisp`
containing a loop (§6.3).

**Runtime model catalogs.**
pi generates catalogs at build time. Benedict resolves them at runtime with an
on-disk cache and an offline fallback, preserving P8 (§7.6).

**S-expression session logs.**
pi uses JSONL. Benedict uses one `read`-able form per line — native types, no
schema translation, and `read` reconstructs the entry directly (§5.4).

### 13.3 One risk pi does not have

`bash` runs in a subprocess; a catastrophic command cannot corrupt the harness's
own memory. `eval-elisp` runs in-process and *can* redefine `benedict-core--advance`
mid-run.

This is accepted rather than prevented — preventing it would forfeit the entire
advantage of the medium. It is mitigated structurally:

- **P3, write-through durability.** Every entry hits disk as it is created, so a
  corrupted image loses at most the in-flight turn.
- **Sessions are resumable.** Restart, reload the log, continue.
- **Sandboxing is available when wanted.** A dispatch filter can route
  `eval-elisp` to a subordinate Emacs (§6.4). This is an extension, and the
  kernel never learns it exists.

The posture is pi's: unrestricted by default, isolation available by
configuration. The difference is that Benedict's isolation boundary is a
subordinate Emacs process rather than a container, and it is reachable through
the same dispatch chain that implements approvals.

---

## 14. Implementation Plan

Each phase has an exit criterion that is a *test*, not a feeling.

**Phase 0 — Data model**
`benedict-message.el`, `benedict-schema.el`. Entry structs, content blocks, tree
accessors, parameter DSL → JSON Schema.
*Exit:* build a branching transcript in a test, materialize two different paths,
assert both.

**Phase 1 — Store**
`benedict-store.el`. Append-only s-expression log, per-entry write-through, load
and reconstruct.
*Exit:* write a forked session, reload from disk, assert the tree and head are
identical.

**Phase 2 — Reducer**
`benedict-session.el`, `benedict-core.el`, `benedict-tool.el`,
`benedict-provider.el`, `benedict-provider-fake.el`. Run state machine, hooks
(global and session-local, §4.4.1), tool registry, dispatch chain, queue drain.
`benedict-provider.el` belongs here rather than in Phase 4 because the fake
provider needs a registry to register into and a model record to be resolved
through; only the registries and the §7.2 dispatch function land now, and the
HTTP-backed path waits for the first real adapter.
*Exit:* a multi-turn run with tool calls, driven entirely by the fake provider,
with assertions on the state transition sequence. A dispatch filter that suspends
and later resumes a run. An abort mid-stream that produces a well-formed terminal
entry. Two concurrent sessions where a session-local dispatch filter fires for one
and not the other, and a global filter discriminates via
`benedict-current-session`.

**Phase 2b — Lowering**
`benedict-api-transform.el`. Origin test, degradation rules, note handling,
tool-call id remapping, structural repair.
*Exit:* with the fake provider impersonating two different model triples, build a
transcript containing entries from both, lower it for each, and assert the
degradation table of §7.8.4 holds in both directions. Assert a rewritten tool-call
id propagates to its result. Assert an orphaned tool call yields a synthetic
error result, and that a result orphaned by a skipped errored turn is dropped
(§7.8.6 rule 5). Assert a plain note vanishes and a context-flagged one arrives
as a user entry (§7.8.9). Assert the fork-and-switch case of §7.8.7 — it is a
fork, a model swap, and a lowering assertion, none of which need a network, and
a bug there fails at the provider with an opaque error rather than locally, so
it belongs in the phase that can catch it cheaply. This is pure data
transformation and needs no network — it should be one of the most heavily
tested modules in the system.

**Phase 3 — First tool**
`benedict-eval.el`.
*Exit:* the fake provider requests `eval-elisp`, the result is appended, and the
next request carries it — asserted on the request rather than on the transcript,
since "the next turn sees it" is a claim about what goes out on the wire and a
context filter dropping tool results would satisfy the weaker reading.
Separately: the agent defines a tool by evaluating a form and calls it on the
following turn, which is §10.1 steps 4 and 5 with no file written and no reload.

**Phase 4 — First real provider**
`benedict-http.el`, `benedict-auth.el` (API key path only),
`benedict-api-openai-responses.el`, `benedict-provider-vercel.el`.
*Exit:* a real multi-turn conversation with tool use against a cheap Vercel AI
Gateway model. Separately: the adapter parses a recorded SSE stream fixture with
byte-identical results. A two-turn test asserting reasoning-item continuity
(§7.4). The fork-and-switch case (§7.8.7) re-asserted over the real adapter,
where what Phase 2b proved about the lowered entries is now proved about the
bytes on the wire. This phase answers whether the API/provider split (§7.1) and
the normalized event vocabulary (§7.3) actually hold — and it needs only one wire
API to answer it (§7.4).

**Phase 5 — Frontend**
`benedict-chat` and render components, built only on §4.1 and §4.4.
*Exit:* streaming renders incrementally; branch siblings are visible and
navigable; **no kernel file was modified to add a private accessor.** If one was,
that is the finding, and the API grows.

**Phase 6 — Distro**
`benedict-files`, `benedict-introspect`, `benedict-approvals`, `benedict-skills`,
`benedict-prompts`, `benedict-compact`.
*Exit:* the self-extension loop of §10.1 completes end to end — ask the agent for
a capability, and it reads the skill, introspects the API, writes an extension,
loads it, and uses it, without human intervention.

**Phase 7 — OAuth**
Refresh serialization, loopback flow helper, first subscription provider.
*Exit:* two concurrent in-flight requests against an expiring token produce
exactly one refresh call.

Phases 0–3 require no network and no credentials. Phase 4 is the first point at
which the architecture can be wrong in an expensive way, which is why the fake
provider (§7.7) is built in Phase 2 rather than retrofitted.

---

## 15. Resolved Decisions

Recorded so the reasoning survives, and so a future revisit is a deliberate
reversal rather than a rediscovery.

**D1. One wire API for v1.** *(§7.4, §7.4.1)*
Vercel AI Gateway serves its entire catalog, including non-OpenAI models, through
the OpenAI Responses API. `openai-responses` is the only adapter v1 requires; a
second exists only when a second provider does.

Verified in Phase 4 against the live service across five models from four
vendors — DeepSeek, OpenAI, xAI, and Alibaba — including a full two-turn
tool-use round trip. Worth recording that pi routes this same provider through
`anthropic-messages` instead: the gateway serves several protocol front doors
and either choice works, so this is a decision rather than a discovery. It was
kept because §7.4's grammar is the richer one and therefore the better test of
the §7.1 boundary. What the verification did change is §7.4's event table, which
was written from OpenAI's documentation and did not survive contact — see
§7.4.1 for what the gateway normalizes and what it leaves to vary.

**D2. Fixed degradation rules, no override hook.** *(§7.8.4)*
The cross-model degradation table is not configurable. A hook here is easy to add
and hard to remove, and there is no concrete need without a second real provider.
*Revisit when:* a second provider demonstrably needs different handling — not
speculatively.

**D3. Queues drain one message per boundary.** *(§4.2)*
`benedict-queue-drain-mode` defaults to `one-at-a-time`. Draining all queued
messages at one boundary means the agent never acts on the first before seeing
the third, and later messages were usually written without knowledge of what the
first would change. `all` exists for scripted and batch use.

**D4. Notes may opt into context, and survive compaction.** *(§4.5, §5.6)*
`:context t` in a note's meta includes it in provider context. Compaction
re-emits context-flagged notes from the compacted range after the summary. This
is what makes "remember X for this session" durable; without it, such
instructions silently stop working at the first compaction.

**D5. Hooks are global plus session-local, with a dynamic current session.**
*(§4.4.1)*
Sessions coexist in one image, so scoping is required: session-local hook lists
provide it, and `benedict-current-session` is dynamically bound around every hook
invocation so global functions can discriminate. Buffer-local hooks were rejected
— headless sessions have no buffer, and binding the right buffer around every
asynchronous dispatch is fragile. This is a Phase 2 concern, not Phase 5, because
it shapes the hook-running helpers themselves.

**D6. Compaction uses both trigger points.** *(§5.6)*
Not either/or. `benedict-context-filter-functions` compacts in place at a soft
threshold and the run continues; `benedict-continue-predicate-functions` stops
the run cleanly at a hard limit or when compaction cannot free enough. The two
serve different failure modes. Only the thresholds are tuning.

**D7. Schema pass-through is per key, not per parameter.** *(§6.1)*
"Anything more exotic is passed through as a literal schema fragment" reads two
ways. It means an unrecognized *key* is copied into that parameter's own
fragment, not that a parameter carrying one is emitted wholesale. Per key means
`:minimum 1` composes with `:type` and `:description` instead of replacing them,
and it keeps the compiler's behavior describable in one sentence.

**D8. `:type` is mandatory, and the six types are the whole set.** *(§6.1)*
A typeless property is unusable by a provider's strict-tool mode, so a missing
`:type` is an error rather than an open schema. No `int`/`float`/`bool` aliases:
`describe-function` is the DSL's documentation (§10.2), and a documented set that
is also the real set is worth more than a convenience that only some authors find.

**D9. Entry ids are `<session-id>-e<NNNN>`.** *(§5.5)*
§5.5 fixes the ingredients but not the format. This one is filename-safe, sorts,
greps, and lets the counter be recovered by regexp — so a reload restores it from
the ids themselves rather than from a sidecar record that could disagree with
them. Ids come from one transcript-wide counter, so they are unique but not
contiguous along a branch.

**D10. Malformed session logs load; unreadable formats do not.** *(§5.4, P3)*
A crash can truncate the final record. Warning and returning everything that
parsed is strictly better than refusing the session, since recoverability is the
entire justification for write-through in the first place;
`benedict-store-strict-load` exists for callers that need to know a log was
clean. The exception is a `:format` the reader does not know, which always
signals — mis-parsing a future format silently is worse than declining to read
it. `write-region-inhibit-fsync` defaults to `t` in batch and must be bound back
to nil, or P3 holds only in interactive sessions.

**D11. The transcript tree is session-independent.** *(§3.2, §4.1)*
§3.2 assigns tree accessors to `benedict-message.el` and §4.1 lists them on the
session. Both: `benedict-message.el` owns a `benedict-transcript` with no
knowledge of sessions, and `benedict-session.el` holds one in a slot and
delegates. The tree is then testable, forkable, and serializable with no session
at all — which is what let Phase 0 land before Phase 2 existed.

**D12. One `tool-result` entry per tool call.** *(§4.5, §6.3)*
A turn emitting three tool calls appends three `tool-result` entries as each
completes, not one entry holding three blocks. Tools run sequentially, so a
per-call entry is durable the moment its call returns rather than only once the
slowest sibling has; a frontend subscribed to the entry hooks shows results
appearing rather than a batch materializing; and an abort partway leaves a clean
prefix instead of losing the results already computed. The tidier tree the
alternative produces is not worth any of that.

**D13. The reducer's deferral is a variable, not a convention.** *(§4.2)*
`benedict-core-defer-function` is called with a thunk and must never run it
synchronously; the default wraps `run-at-time 0 nil`. §4.2's "must never be
called from within itself" is otherwise a rule enforced by review, and the
failure it prevents — a stack overflow under a fast provider — appears only
under load. Making it a variable also makes the machine steppable: a test binds
it to a queue, runs one transition at a time, and asserts on the sequence,
which is what turns "abort mid-stream" from a race into an assertion.
The fake provider paces itself through the same variable for the same reason.

**D14. The store is wired at Phase 2, not later.** *(§3.3, P3)*
`benedict-store-install` subscribes `benedict-store-on-entry-end` and
`benedict-store-on-head-change` to the kernel's hooks. Phase 2 is the first
point at which P3 can be demonstrated rather than asserted — run a session, drop
it, reload the log, compare the tree and the head — and the store's handlers
already existed with the right arities, so leaving them unsubscribed would have
meant shipping dead code past the phase that could prove it. The kernel gained
nothing but an opaque `:store` slot.

**D15. Hook variables live with the session, not the reducer.** *(§3.2, §4.4)*
§3.2's module map assigns "hook definitions" to `benedict-core.el`; they are in
`benedict-session.el` instead. Every hook is scoped by a session (§4.4.1) and
the session owns that scoping mechanism, so a session cannot announce a fork
without the hook — and the reducer already requires the session, so putting the
variables with the reducer creates a cycle. Firing a hook is not owning it.
Nothing is lost for a reader, because §10.2 makes `apropos` on
`"benedict-.*-functions"` the way these are found and it does not care which
file they are in.

**D16. Notes are dropped or promoted to `user` at lowering.** *(§7.8.9, §4.5)*
§7.8.8 said the lowering pass "ignores" model-change notes and §4.5 said a note
may opt into provider context; together they left a role no wire protocol can
express arriving at every adapter. Lowering resolves it in canonical space:
plain notes are dropped, context-flagged notes become `user` entries. The
alternative — each adapter inventing the same note-to-message mapping — is a
protocol difference that is not one, and D4's durable instructions would depend
on every adapter having remembered to implement it.

**D17. The tool-call id map is collected in its own pass.** *(§7.8.5, §7.8.6)*
pi builds its id map while rewriting, in a single forward walk, so a result is
only rewritten when its call was already visited. The same is true of its
orphaned-call bookkeeping. Both are correct for a well-ordered transcript and
fragile otherwise, and a transcript is exactly the thing this pass exists
because it cannot assume about. Collecting the id map, and separately the set of
surviving call ids, before either is applied costs a few lines in elisp and
makes both rules order-independent.

**D18. `benedict-http` shells out to `curl`.** *(§8.6, §12.2)*
Emacs has no usable native SSE story. `url.el` can be made to stream by
attaching a filter to its internal process, but the internals are undocumented
and the attachment is delicate; raw `make-network-process` means owning chunked
transfer-encoding, redirects, and proxies. `curl` is what gptel and plz both do,
and it is what this project's own pre-reset transport did successfully across
four providers. It costs a **system** dependency — not a `Package-Requires`
entry, since it is not an Emacs package — which is the price of not
reimplementing HTTP. §8.6's prohibition is narrowed to the cryptography, which
is where it was actually load-bearing.
*Revisit when:* a supported platform lacks `curl`, or Emacs grows a real
streaming HTTP primitive.

**D19. The shared HTTP path is `benedict-api-stream.el`, in `api/`.** *(§3.2, §7.2)*
`benedict-provider.el` reaches it by `fboundp` precisely so the kernel does not
depend on it. It needs the core registries *and* `support/`, which puts it in
`api/` — it is the composition of auth, an adapter's `endpoint`/`headers`/
`build`, the transport, and the adapter's parser, and it is where §7.3's "an
adapter must never signal" is actually enforced, by wrapping the parser in
`condition-case`. That wrapper is not defensive tidiness: an error signalled
inside a process filter propagates nowhere useful, so without it a parser bug
leaves the session wedged in `provider-wait` rather than failing visibly.

**D20. Retry happens only before the first emitted event.** *(§3.2)*
Retrying a stream that has already delivered deltas would append the retried
content on top of what the kernel accumulated. The transport therefore retries
on connection failures and on a non-2xx status — both of which are known before
any event is emitted — and never once the stream has produced one. A mid-stream
failure is a terminal `:error`, which the reducer already handles.

**D21. Live service exercise is a script, not a test.** *(§12.5)*
`nix run .#live` over `scripts/live-smoke.el`, outside `test/`. The alternative
— an ERT test gated on an environment variable — would have made `test/` gain
its first conditional suite and made the suite's guarantees depend on the
runner's environment. The fake provider exists so those guarantees are
unconditional; a credentialed test in the same directory quietly undoes that.
The cost is that the script is not maintained by the test runner and can rot,
which is accepted because its job is to demonstrate a phase exit once, not to
guard against regression — the recorded fixtures do that.

---

## 16. Open Questions

New questions are added here and promoted to §15 when resolved, with the
rationale preserved.

**Q1. How does an extension append an entry?** *(§4.1, §9.3, §10.3)*
§9.3 lists "append `role note` entries" as the way an extension persists state
across restarts, and §10.3 asks `eval-elisp` to record runtime-modifying forms
that way — but §4.1 publishes no function that appends an entry *and* announces
it. `benedict-session-append` is a tree operation and fires nothing, so a note
written through it reaches neither the store nor a renderer; the kernel's own
path is private. Either the API grows a public entry-emitting function or the
two sections above are promising something the kernel does not offer. This is
what deferred §10.3 out of Phase 3.

An answer also has to say where a note appended mid-turn lands. Head is the
assistant entry that made the call, so the note falls between the call and its
result — harmless on the wire, since lowering drops it (§7.8.9), but the
renderer and the tree both see it.

**Q2. How does a session learn about a tool registered mid-run?** *(§10.1, §4.1)*
`benedict-session-create` resolves `:tools` once. A tool the agent defines by
evaluating a form is callable but never advertised, so the self-extension loop
completes only for an agent that remembers its own registration. The candidates
are a session tool list that resolves lazily from the registry, an explicit
refresh on the public API, or making the tool list a request filter's business.
The choice matters more than it looks: it decides whether a session's offered
tools are a snapshot or a view, and every frontend that renders a tool list
depends on the answer.
