#!/usr/bin/env bash
# Run the test catalogue SEQUENTIALLY (one example at a time, by design).
#
#   ./run-test-catalogue.sh                 # run every example in expectations.md
#   ./run-test-catalogue.sh example-019 example-023   # run only these examples
#
# No -e: we guard each example explicitly so one failure (missing page image,
# model content-filter error, etc.) cannot abort the whole batch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CATALOGUE="${SCRIPT_DIR}/../rhizome-books-test-catalogue"
EXPECTATIONS="${CATALOGUE}/expectations.md"
OUT_DIR="${SCRIPT_DIR}/test-catalogue-out"
RUN_DIR="${SCRIPT_DIR}/.run"   # per-example scratch, output and observation reports (gitignored), kept for debugging

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

# Optional: restrict to the example names passed as arguments, so a prompt tweak
# can be re-checked on just the affected examples instead of the whole catalogue.
if [ $# -gt 0 ]; then
  filtered=()
  for entry in "${entries[@]}"; do
    ex="${entry% *}"
    for want in "$@"; do
      [ "$ex" = "$want" ] && filtered+=("$entry")
    done
  done
  entries=("${filtered[@]}")
fi

# Full run (no example filter): start from a clean slate so no stale per-example
# outputs or ledgers from a previous run linger in test-catalogue-out / .run.
if [ $# -eq 0 ]; then
  rm -f "$OUT_DIR"/*.md "$OUT_DIR"/*.status.tsv 2>/dev/null
  rm -rf "$RUN_DIR"
fi

echo "Running ${#entries[@]} example(s), sequentially..."
echo ""

for entry in "${entries[@]}"; do
  ex="${entry% *}"
  page="${entry#* }"
  dir="${CATALOGUE}/${ex}"
  if [ ! -d "$dir" ]; then
    echo "SKIP $ex (no dir at $dir)"
    continue
  fi

  # Per-example scratch + output: each example's observation reports and the
  # extracted output survive under .run/<example>/ for inspection, instead of
  # being wiped by the next example (current-img was shared and transient).
  work="${RUN_DIR}/${ex}/img"
  out="${RUN_DIR}/${ex}/out.md"
  rm -rf "${RUN_DIR:?}/${ex}"
  mkdir -p "$work"

  echo "==> $ex (p.$page)"
  WORK="$work" OUTPUT="$out" DIR="$dir" "${SCRIPT_DIR}/extract-bookquotes.sh" "$page" \
    || echo "  WARN: $ex did not complete (see ${RUN_DIR}/${ex}/)"

  if [ -f "$out" ]; then
    cp "$out" "${OUT_DIR}/${ex}.md"
  else
    echo "(no output)" > "${OUT_DIR}/${ex}.md"
  fi
  # Carry the per-page status ledger across too, so the scorer can quarantine
  # content-filter / outage failures (the new extract script records them there
  # rather than dumping the error text into the output).
  status_file="${RUN_DIR}/${ex}/out.status.tsv"
  if [ -f "$status_file" ]; then
    cp "$status_file" "${OUT_DIR}/${ex}.status.tsv"
  else
    rm -f "${OUT_DIR}/${ex}.status.tsv"
  fi
done

echo ""
echo "Outputs in: $OUT_DIR"
echo "Per-example scratch / observation reports under: $RUN_DIR"
