#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
devlogs_dir="$repo_root/devlogs"
efforts_dir="$repo_root/efforts"
new_effort_script="$repo_root/agents/skills/plan/scripts/new_effort.sh"
dry_run=false
force_grouping=false
counter_file="$efforts_dir/.counter"
dry_counter="0"
codex_cmd="${CODEX_CMD:-codex}"
grouping_file="$efforts_dir/normalize-grouping.json"

usage() {
  echo "Usage: $(basename "$0") [--dry-run] [--force-grouping]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --force-grouping)
      force_grouping=true
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  shift
done

file_birth_time() {
  local path="$1"
  local ts=""

  if ts=$(stat -f '%B' "$path" 2>/dev/null); then
    :
  elif ts=$(stat -c '%W' "$path" 2>/dev/null); then
    :
  fi

  if [[ -z "$ts" || "$ts" == "0" ]]; then
    if ts=$(stat -f '%m' "$path" 2>/dev/null); then
      :
    else
      ts=$(stat -c '%Y' "$path" 2>/dev/null || echo "0")
    fi
  fi

  printf '%s' "$ts"
}

normalize_effort_name() {
  local name="$1"
  printf '%s' "$name" | sed -E 's/^[0-9]+[-_]//'
}

effort_slug() {
  local name="$1"
  printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]-]+/_/g; s/^_+//; s/_+$//'
}

if [[ ! -d "$efforts_dir" ]]; then
  echo "Missing efforts directory at $efforts_dir" >&2
  exit 1
fi

if [[ ! -x "$new_effort_script" ]]; then
  echo "Missing new effort script at $new_effort_script" >&2
  exit 1
fi

if [[ ! -d "$devlogs_dir" ]]; then
  echo "Missing devlogs directory at $devlogs_dir" >&2
  exit 1
fi

if ! command -v "$codex_cmd" >/dev/null 2>&1; then
  echo "Missing codex command: $codex_cmd" >&2
  exit 1
fi

entries_file="$(mktemp -t normalize-efforts.XXXXXX)"
codex_input_file="$(mktemp -t normalize-efforts-input.XXXXXX)"
codex_prompt_file="$(mktemp -t normalize-efforts-prompt.XXXXXX)"
codex_output_file="$(mktemp -t normalize-efforts-output.XXXXXX)"
codex_stdout_file="$(mktemp -t normalize-efforts-codex-stdout.XXXXXX)"
codex_schema_file="$(mktemp -t normalize-efforts-schema.XXXXXX)"
groups_file="$(mktemp -t normalize-efforts-groups.XXXXXX)"
cleanup() {
  rm -f "$entries_file" "$codex_input_file" "$codex_prompt_file" "$codex_output_file" "$codex_stdout_file" "$codex_schema_file" "$groups_file"
}
trap cleanup EXIT

while IFS= read -r -d '' path; do
  ts="$(file_birth_time "$path")"
  printf '%s\tdevlog\t%s\n' "$ts" "$path" >> "$entries_file"
done < <(find "$devlogs_dir" -type f -print0)

while IFS= read -r -d '' path; do
  base="$(basename "$path")"
  if [[ "$base" == ".counter" || "$base" == ".counter.lock" ]]; then
    continue
  fi
  ts="$(file_birth_time "$path")"
  printf '%s\teffort\t%s\n' "$ts" "$path" >> "$entries_file"
done < <(find "$efforts_dir" -mindepth 1 -maxdepth 1 -type d -print0)

echo "Items sorted by creation time:"
sort -n -k1,1 -k3,3 "$entries_file" | awk -F '\t' '{print $1 "\t" $2 "\t" $3}'

echo ""

python3 - "$entries_file" "$codex_input_file" <<'PY'
import json
import sys

entries_path, output_path = sys.argv[1:3]

items = []
with open(entries_path, "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        ts, kind, path = line.split("\t", 2)
        entry = {"timestamp": int(ts), "kind": kind, "path": path}
        if kind == "devlog":
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as log_handle:
                    preview = log_handle.read(4000)
            except FileNotFoundError:
                preview = ""
            entry["preview"] = preview
        items.append(entry)

payload = {"items": items}
with open(output_path, "w", encoding="utf-8") as out:
    json.dump(payload, out, indent=2)
PY

cat > "$codex_prompt_file" <<'EOF'
You are grouping legacy devlog and effort items into normalized efforts.

Rules:
- Only group devlogs together. Existing effort directories (kind == "effort") must each be in their own group with only that single item.
- You may group multiple devlogs into a single effort when they appear related by filename or preview content.
- Provide a concise effort name for each group; the name will be slugged.
- Keep the overall ordering stable: groups should be sorted by the earliest timestamp of their items.
- Items inside each group should be in ascending timestamp order.
- Return ONLY a JSON array with objects of the form:
  {"groups": [{"name": "effort name", "items": [{"path": "..."}]}]}

Input JSON:
EOF
cat "$codex_input_file" >> "$codex_prompt_file"

cat > "$codex_schema_file" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["groups"],
  "properties": {
    "groups": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "items"],
        "properties": {
          "name": { "type": "string", "minLength": 1 },
          "items": {
            "type": "array",
            "minItems": 1,
            "items": {
              "type": "object",
              "additionalProperties": false,
              "required": ["path"],
              "properties": {
                "path": { "type": "string", "minLength": 1 }
              }
            }
          }
        }
      }
    }
  }
}
EOF

codex_response_file="$grouping_file"
if [[ ! -f "$grouping_file" || $force_grouping == true ]]; then
  echo "Running codex for grouping..."
  if ! "$codex_cmd" exec --output-schema "$codex_schema_file" --output-last-message "$codex_output_file" < "$codex_prompt_file" > "$codex_stdout_file"; then
    echo "Codex grouping failed." >&2
    exit 1
  fi

  codex_response_file="$codex_output_file"
  if [[ ! -s "$codex_response_file" ]]; then
    codex_response_file="$codex_stdout_file"
  fi
  cp "$codex_response_file" "$grouping_file"
  codex_response_file="$grouping_file"
else
  echo "Using cached grouping from $grouping_file"
fi

python3 - "$entries_file" "$codex_response_file" "$groups_file" <<'PY'
import json
import re
import sys

entries_path, output_path, groups_path = sys.argv[1:4]

entries = {}
with open(entries_path, "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        ts, kind, path = line.split("\t", 2)
        entries[path] = {"timestamp": int(ts), "kind": kind}

raw = open(output_path, "r", encoding="utf-8").read().strip()
if raw.startswith("```"):
    raw = re.sub(r"^```[a-zA-Z0-9]*\\s*", "", raw)
    raw = re.sub(r"```\\s*$", "", raw)

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    match = re.search(r"\\{[\\s\\S]*\\}", raw)
    if not match:
        raise
    data = json.loads(match.group(0))

if not isinstance(data, dict):
    raise SystemExit("Codex output is not a JSON object.")

data_groups = data.get("groups")
if not isinstance(data_groups, list):
    raise SystemExit("Codex output missing groups array.")

seen = set()
groups = []
for group in data_groups:
    name = group.get("name")
    items = group.get("items", [])
    if not name or not isinstance(items, list):
        raise SystemExit("Each group must have a name and items array.")
    group_entries = []
    for item in items:
        path = item.get("path")
        if not path:
            raise SystemExit("Group item missing path.")
        if path not in entries:
            raise SystemExit(f"Unknown path in group: {path}")
        if path in seen:
            raise SystemExit(f"Duplicate path in groups: {path}")
        seen.add(path)
        group_entries.append(path)

    for path in group_entries:
        if entries[path]["kind"] == "effort" and len(group_entries) != 1:
            raise SystemExit(f"Effort path grouped with others: {path}")

    groups.append({"name": name, "items": group_entries})

missing = set(entries.keys()) - seen
if missing:
    missing_list = ", ".join(sorted(missing))
    raise SystemExit(f"Missing paths in groups: {missing_list}")

def group_sort_key(group):
    return min(entries[path]["timestamp"] for path in group["items"])

groups.sort(key=group_sort_key)

with open(groups_path, "w", encoding="utf-8") as out:
    for idx, group in enumerate(groups):
        items = sorted(group["items"], key=lambda p: entries[p]["timestamp"])
        for path in items:
            kind = entries[path]["kind"]
            out.write(f"{idx}\t{group['name']}\t{path}\t{kind}\n")
PY

if $dry_run; then
  echo "Dry run: no changes will be made."
  if [[ -f "$counter_file" ]]; then
    dry_counter="$(cat "$counter_file")"
    if [[ ! "$dry_counter" =~ ^[0-9]+$ ]]; then
      echo "Counter file contains non-numeric value: $dry_counter" >&2
      exit 1
    fi
  fi
else
  echo "Normalizing..."
fi

current_group=""
current_dir=""

while IFS=$'\t' read -r group_id effort_name path kind; do
  base="$(basename "$path")"

  if [[ "$group_id" != "$current_group" ]]; then
    current_group="$group_id"
    current_dir=""

    if $dry_run; then
      dry_counter=$((10#$dry_counter + 1))
      prefix="$(printf "%05d" "$dry_counter")"
      slug="$(effort_slug "$effort_name")"
      if [[ -z "$slug" ]]; then
        echo "Effort name normalized to empty string; provide a more specific name." >&2
        exit 1
      fi
      current_dir="$efforts_dir/${prefix}-${slug}"
    else
      current_dir="$(bash "$new_effort_script" "$effort_name")"
      rm -f "$current_dir/plan.md"
    fi
  fi

  if $dry_run; then
    echo "Would move $path -> $current_dir"
  else
    if [[ "$kind" == "devlog" ]]; then
      mv "$path" "$current_dir/"
    else
      shopt -s dotglob nullglob
      mv "$path"/* "$current_dir/" || true
      shopt -u dotglob nullglob
      rmdir "$path" 2>/dev/null || true
    fi
    echo "Moved $path -> $current_dir"
  fi
done < "$groups_file"

echo "Done."
