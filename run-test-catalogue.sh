#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CATALOGUE="${SCRIPT_DIR}/../rhizome-books-test-catalogue"
EXPECTATIONS="${CATALOGUE}/expectations.md"
OUT_DIR="${SCRIPT_DIR}/test-catalogue-out"

mkdir -p "$OUT_DIR"

# Discover examples by scanning expectations.md for headings of the form:
#   "# <example-name> - subject: p.<page>"
mapfile -t entries < <(
  grep -E '^#[[:space:]]+example-[0-9]+[[:space:]]+-[[:space:]]+subject:[[:space:]]+p\.[A-Za-z0-9]+' "$EXPECTATIONS" \
    | sed -E 's/^#[[:space:]]+(example-[0-9]+)[[:space:]]+-[[:space:]]+subject:[[:space:]]+p\.([A-Za-z0-9]+).*/\1 \2/'
)

if [ ${#entries[@]} -eq 0 ]; then
  echo "No examples found in $EXPECTATIONS"
  exit 1
fi

for entry in "${entries[@]}"; do
  ex="${entry% *}"
  page="${entry#* }"
  dir="${CATALOGUE}/${ex}"
  if [ ! -d "$dir" ]; then
    echo "SKIP $ex (no dir at $dir)"
    continue
  fi
  echo "==> $ex (p.$page)"
  rm -f "${SCRIPT_DIR}/extracted-bookquotes.md"
  DIR="$dir" "${SCRIPT_DIR}/extract-bookquotes.sh" "$page"
  if [ -f "${SCRIPT_DIR}/extracted-bookquotes.md" ]; then
    cp "${SCRIPT_DIR}/extracted-bookquotes.md" "${OUT_DIR}/${ex}.md"
  else
    echo "(no output)" > "${OUT_DIR}/${ex}.md"
  fi
done

echo ""
echo "Outputs in: $OUT_DIR"
