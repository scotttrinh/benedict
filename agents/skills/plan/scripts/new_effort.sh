#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") \"effort name\" [file]"
  echo "Default file is plan.md"
}

if [[ ${1:-} == "" ]]; then
  usage >&2
  exit 1
fi

name="$1"
file_name="${2:-plan.md}"
file_name="$(basename "$file_name")"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root=""
search_dir="$script_dir"
while [[ "$search_dir" != "/" ]]; do
  if [[ -d "$search_dir/efforts" ]]; then
    repo_root="$search_dir"
    break
  fi
  search_dir="$(dirname "$search_dir")"
done
if [[ -z "$repo_root" ]]; then
  echo "Could not locate efforts directory above $script_dir." >&2
  exit 1
fi
efforts_dir="$repo_root/efforts"
counter_file="$efforts_dir/.counter"
lock_dir="$efforts_dir/.counter.lock"

mkdir -p "$efforts_dir"

while ! mkdir "$lock_dir" 2>/dev/null; do
  sleep 0.05
done

cleanup() {
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

current="0"
if [[ -f "$counter_file" ]]; then
  current="$(cat "$counter_file")"
  if [[ ! "$current" =~ ^[0-9]+$ ]]; then
    echo "Counter file contains non-numeric value: $current" >&2
    exit 1
  fi
fi

next=$((10#$current + 1))
printf "%d" "$next" > "$counter_file"

prefix="$(printf "%05d" "$next")"
slug="$(printf "%s" "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]-]+/_/g; s/^_+//; s/_+$//')"
if [[ -z "$slug" ]]; then
  echo "Effort name normalized to empty string; provide a more specific name." >&2
  exit 1
fi

effort_dir="$efforts_dir/${prefix}-${slug}"
mkdir -p "$effort_dir"
touch "$effort_dir/$file_name"

echo "$effort_dir"
