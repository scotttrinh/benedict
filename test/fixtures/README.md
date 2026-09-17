# Recorded wire fixtures

Real captured bytes, per SPEC-001 12.5: provider adapters are tested by
replaying these through the parser, so wire format drift is caught without
spending tokens or needing credentials in the test suite.

Captured 2026-08-06 against Vercel AI Gateway
(`https://ai-gateway.vercel.sh/v1`) using `deepseek/deepseek-v4-flash-0731`.

None of these contain credentials. Verify before adding another:

```sh
grep -F "$KEY" test/fixtures/*.sse   # must find nothing
```

## Files

| File | What it is |
|---|---|
| `openai-responses-text.sse` | Reasoning followed by a plain text answer. The simplest complete stream. |
| `openai-responses-tool-call.sse` | Reasoning, a text block, and a function call — **with the message and function-call items interleaved**. The important one; see below. |
| `openai-responses-tool-result-continuation.sse` | Turn two: the reasoning item, assistant message, function call, and `function_call_output` echoed back in `input`. Proves reasoning continuity. |
| `openai-responses-error-404.json` | An error body. Note it is plain JSON, **not** SSE, even though `stream: true` was requested. |
| `vercel-ai-gateway-models.json` | Trimmed `/v1/models` response — 5 of 317 entries, chosen to cover reasoning/non-reasoning, vision/text-only, and a non-`language` model that catalog parsing must filter out. |

## Why the tool-call fixture matters

Output items **interleave**. In that stream, `output_index` 1 (the assistant
message) and `output_index` 2 (the function call) are open at the same time:

```
seq 15  response.output_text.delta              output_index 1
seq 16  response.output_item.added              output_index 2   <- opens while 1 is still open
seq 17  response.function_call_arguments.delta  output_index 2
...
seq 26  response.output_text.done               output_index 1   <- 1 closes only now
seq 29  response.function_call_arguments.done   output_index 2
```

A parser that keeps a single "current block" pointer produces garbage here. Block
state must be keyed on `output_index`.

## Re-capturing

```sh
KEY=$(python3 -c "import json,pathlib;print(json.loads((pathlib.Path.home()/'.config/benedict/auth.json').read_text())['vercel-ai-gateway']['key'])")

curl -sN -X POST https://ai-gateway.vercel.sh/v1/responses \
  -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"model":"deepseek/deepseek-v4-flash-0731","stream":true,
       "input":[{"type":"message","role":"user","content":[{"type":"input_text",
                 "text":"Use the eval_elisp tool to compute (+ 1 2). Then tell me the answer."}]}],
       "tools":[{"type":"function","name":"eval_elisp",
                 "description":"Evaluate an Emacs Lisp form and return the result.",
                 "parameters":{"type":"object",
                               "properties":{"form":{"type":"string","description":"A single Emacs Lisp form."}},
                               "required":["form"]}}]}' \
  > test/fixtures/openai-responses-tool-call.sse
```

Ids inside a fixture (`rs_…`, `msg_…`, `fc_…`, `call_…`) are from the recorded
run. Tests must not depend on their literal values beyond their prefixes.

## Finding new variation

`scripts/probe-models.py` sends one identical tool-use request to several models
and diffs the *structural* result — reasoning event family, item interleaving,
argument delta count, `call_id` shape, usage fields. It is what produced the
table in SPEC-001 §7.4.1, and it is the thing to re-run when adding a provider
or when a stream stops parsing.

```sh
python3 scripts/probe-models.py       # edit MODELS at the top to change the set
```

It caches raw SSE per model, so re-running costs nothing until the cache is
cleared. Python rather than Elisp because it analyses captured bytes offline and
is not part of the runtime; nothing in the package depends on it.
