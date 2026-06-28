#!/usr/bin/env bash
#
# gen-summary.sh — regenerate src/SUMMARY.md from the .md files in src/.
#
# Title resolution per file:
#   1. first Markdown H1 (`# Title`) in the file, if present
#   2. otherwise the filename, de-slugged ("my_cool_page.md" -> "My Cool Page")
#
# Ordering: alphabetical by filename. SUMMARY.md and README.md are skipped.
#
# Usage:
#   ./scripts/gen-summary.sh          # write src/SUMMARY.md
#   ./scripts/gen-summary.sh --check  # exit 1 if SUMMARY.md is out of date (CI)

set -euo pipefail

# Resolve repo-relative paths regardless of where the script is called from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"
SUMMARY="$SRC_DIR/SUMMARY.md"

prettify() {
  # strip extension, replace -/_ with spaces, title-case each word
  local name="$1"
  name="${name%.md}"
  name="${name//_/ }"
  name="${name//-/ }"
  echo "$name" | awk '{ for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2) }1'
}

title_for() {
  local file="$1"
  # First non-empty H1, trimmed.
  local h1
  h1="$(grep -m1 -E '^#[[:space:]]+' "$file" 2>/dev/null | sed -E 's/^#[[:space:]]+//; s/[[:space:]]+$//' || true)"
  if [[ -n "$h1" ]]; then
    echo "$h1"
  else
    prettify "$(basename "$file")"
  fi
}

generate() {
  echo "# Summary"
  echo
  # Sort by filename for stable output.
  while IFS= read -r file; do
    local base title
    base="$(basename "$file")"
    case "$base" in
      SUMMARY.md|README.md) continue ;;
    esac
    title="$(title_for "$file")"
    echo "- [${title}](./${base})"
  done < <(find "$SRC_DIR" -maxdepth 1 -name '*.md' | sort)
}

new_content="$(generate)"

if [[ "${1:-}" == "--check" ]]; then
  if ! diff -q <(printf '%s\n' "$new_content") "$SUMMARY" >/dev/null 2>&1; then
    echo "SUMMARY.md is out of date. Run scripts/gen-summary.sh to update it." >&2
    diff <(printf '%s\n' "$new_content") "$SUMMARY" || true
    exit 1
  fi
  echo "SUMMARY.md is up to date."
else
  printf '%s\n' "$new_content" > "$SUMMARY"
  echo "Wrote $SUMMARY"
fi
