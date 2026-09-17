#!/usr/bin/env python3
"""Probe several Vercel AI Gateway models with one identical Responses request
and report the STRUCTURAL differences between their streams.

The point is not what each model says -- it is which wire shapes an adapter has
to survive. Run from the repo root; writes raw SSE to the scratch dir.
"""
import json, os, pathlib, subprocess, sys, collections

# Raw SSE is cached here so re-running is free until the cache is cleared.
# Repo-local and gitignored: the captures are large and only the curated ones
# in test/fixtures/ belong in git.
SCRATCH = pathlib.Path(__file__).resolve().parent.parent / ".probe-cache"
SCRATCH.mkdir(parents=True, exist_ok=True)

MODELS = [
    "deepseek/deepseek-v4-flash-0731",
    "openai/gpt-5.6-luna",
    "xai/grok-4.5",
    "alibaba/qwen3.7-flash",
    "xai/grok-4.20-non-reasoning",   # control: no `reasoning` tag
]

KEY = json.loads(
    (pathlib.Path.home() / ".config/benedict/auth.json").read_text()
)["vercel-ai-gateway"]["key"]

TOOLS = [{
    "type": "function", "name": "eval_elisp",
    "description": "Evaluate an Emacs Lisp form and return the result.",
    "parameters": {"type": "object",
                   "properties": {"form": {"type": "string",
                                           "description": "A single Emacs Lisp form."}},
                   "required": ["form"]},
}]
PROMPT = "Use the eval_elisp tool to compute (+ 1 2). Then tell me the answer."


def fetch(model):
    """POST the same streaming tool request to MODEL; return raw SSE text."""
    cached = SCRATCH / (model.replace("/", "_") + ".sse")
    if cached.exists() and cached.stat().st_size:
        return cached.read_text()
    body = json.dumps({
        "model": model, "stream": True,
        "input": [{"type": "message", "role": "user",
                   "content": [{"type": "input_text", "text": PROMPT}]}],
        "tools": TOOLS,
    })
    out = subprocess.run(
        ["curl", "-sN", "--max-time", "120", "-X", "POST",
         "https://ai-gateway.vercel.sh/v1/responses",
         "-H", f"Authorization: Bearer {KEY}",
         "-H", "content-type: application/json",
         "--data-binary", body],
        capture_output=True, text=True).stdout
    cached.write_text(out)
    return out


def frames(sse):
    """Yield (event-name, parsed-data) for each SSE frame."""
    for block in sse.split("\n\n"):
        ev = data = None
        for line in block.split("\n"):
            if line.startswith("event: "):
                ev = line[7:]
            elif line.startswith("data: "):
                data = line[6:]
        if ev:
            try:
                yield ev, (json.loads(data) if data else {})
            except json.JSONDecodeError:
                yield ev, {}


def profile(model, sse):
    """Return the structural profile of one model's stream."""
    p = {"model": model, "events": [], "item_types": {}, "reasoning_events": set(),
         "usage": None, "tool": None, "interleaved": False, "text_blocks": [],
         "error": None, "open": {}}
    if sse.lstrip().startswith("{"):
        try:
            p["error"] = json.loads(sse).get("error", sse[:200])
        except json.JSONDecodeError:
            p["error"] = sse[:200]
        return p

    order, live = [], set()
    for ev, d in frames(sse):
        p["events"].append(ev)
        if "reasoning" in ev and ev.endswith((".delta", ".done")):
            p["reasoning_events"].add(ev)
        idx = d.get("output_index")

        if ev == "response.output_item.added":
            item = d.get("item", {})
            p["item_types"].setdefault(item.get("type"), item.get("id", "")[:4])
            live.add(idx)
            # an item opening while another is still open == interleaving
            if len(live) > 1:
                p["interleaved"] = True
        elif ev == "response.output_item.done":
            item = d.get("item", {})
            live.discard(idx)
            if item.get("type") == "function_call":
                p["tool"] = {"id": item.get("id"), "call_id": item.get("call_id"),
                             "arguments": item.get("arguments"),
                             "has_both": bool(item.get("id") and item.get("call_id"))}
            if item.get("type") == "message":
                for c in item.get("content", []):
                    if c.get("type") == "output_text":
                        p["text_blocks"].append(c.get("text"))
        elif ev == "response.completed":
            p["usage"] = d.get("response", {}).get("usage")
        elif ev in ("response.failed", "response.error"):
            p["error"] = d
        order.append((ev, idx))
    p["order"] = order
    return p


def main():
    profiles = []
    for m in MODELS:
        sys.stderr.write(f"probing {m} ...\n")
        profiles.append(profile(m, fetch(m)))

    print("=" * 100)
    print(f"{'MODEL':34} {'REASONING EVENT':34} {'INTERLEAVE':11} {'ITEM ID PREFIXES'}")
    print("=" * 100)
    for p in profiles:
        if p["error"]:
            print(f"{p['model']:34} ERROR: {json.dumps(p['error'])[:60]}")
            continue
        re_ev = ",".join(sorted(e.replace("response.", "") for e in p["reasoning_events"])) or "(none)"
        pref = " ".join(f"{k}={v!r}" for k, v in p["item_types"].items())
        print(f"{p['model']:34} {re_ev:34} {str(p['interleaved']):11} {pref}")

    print("\n--- TOOL CALL IDS ---")
    for p in profiles:
        if p["error"]:
            continue
        t = p["tool"]
        print(f"{p['model']:34} {'MISSING' if not t else ''}")
        if t:
            print(f"{'':34} id      = {t['id']}")
            print(f"{'':34} call_id = {t['call_id']}")
            print(f"{'':34} args    = {t['arguments']!r}")

    print("\n--- USAGE SHAPE ---")
    for p in profiles:
        if not p["error"]:
            print(f"{p['model']:34} {json.dumps(p['usage'])}")

    print("\n--- TEXT BLOCKS ALONGSIDE THE TOOL CALL ---")
    for p in profiles:
        if not p["error"]:
            print(f"{p['model']:34} {p['text_blocks']!r}")

    print("\n--- EVENT VOCABULARY (union, with per-model presence) ---")
    allev = sorted({e for p in profiles if not p["error"] for e in p["events"]})
    names = [p["model"].split("/")[-1][:14] for p in profiles if not p["error"]]
    print(f"{'EVENT':46} " + " ".join(f"{n:>15}" for n in names))
    for ev in allev:
        row = []
        for p in profiles:
            if p["error"]:
                continue
            c = collections.Counter(p["events"])[ev]
            row.append(f"{(str(c) if c else '-'):>15}")
        print(f"{ev:46} " + " ".join(row))


if __name__ == "__main__":
    main()
