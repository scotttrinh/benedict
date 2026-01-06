#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <effort-number> \"log message\""
  echo "Example: $(basename "$0") 12 \"Phase 1 started; clarified scope; completed tests.\""
}

if [[ ${1:-} == "" || ${2:-} == "" ]]; then
  usage >&2
  exit 1
fi

effort_number="$1"
shift
message="$*"

if [[ ! "$effort_number" =~ ^[0-9]+$ ]]; then
  echo "Effort number must be numeric." >&2
  exit 1
fi

prefix="$(printf "%05d" "$effort_number")"

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

matches=("$efforts_dir/${prefix}-"*)
if [[ ${#matches[@]} -eq 0 || ! -e "${matches[0]}" ]]; then
  echo "No effort directory found for prefix $prefix." >&2
  exit 1
fi
if [[ ${#matches[@]} -gt 1 ]]; then
  echo "Multiple effort directories found for prefix $prefix." >&2
  printf "%s\n" "${matches[@]}" >&2
  exit 1
fi

effort_dir="${matches[0]}"
log_file="$effort_dir/log.md"
timestamp="$(date "+%Y-%m-%d %H:%M")"

printf "[%s] %s\n" "$timestamp" "$message" >> "$log_file"
echo "$log_file"
