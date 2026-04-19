#!/bin/bash
set -euo pipefail

OVERRIDE_PAGES=false
PORT=3006

while [[ $# -gt 0 ]]; do
  case "$1" in
    --override-pages) OVERRIDE_PAGES=true; shift ;;
    --prod) PORT=3007; shift ;;
    *) break ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORKING_DIR_CONF="${SCRIPT_DIR}/working-dir.conf"
if [ ! -f "$WORKING_DIR_CONF" ]; then
  echo "Missing config: $WORKING_DIR_CONF"
  exit 1
fi
source "$WORKING_DIR_CONF"
: "${DIR:?DIR not set in $WORKING_DIR_CONF}"

INGEST_CONF="${SCRIPT_DIR}/ingest.conf"
if [ ! -f "$INGEST_CONF" ]; then
  echo "Missing config: $INGEST_CONF"
  echo "Copy ingest.conf.template to ingest.conf and fill in the values."
  exit 1
fi
source "$INGEST_CONF"
: "${BOOK_ID:?BOOK_ID not set in $INGEST_CONF}"
: "${PAGES_ID:?PAGES_ID not set in $INGEST_CONF}"

BASE_URL="http://127.0.0.1:${PORT}"

fetch_title() {
  local id="$1"
  local result title
  result=$(curl -sf "${BASE_URL}/rest/items/${id}" 2>/dev/null) || return 1
  title=$(echo "$result" | python3 -c "
import sys,json
d = json.load(sys.stdin)
if 'error' in d or not d.get('title'):
    sys.exit(1)
print(d['title'])
" 2>/dev/null) || return 1
  echo "$title"
}

echo "Verifying context IDs..."
echo ""

BOOK_TITLE=$(fetch_title "$BOOK_ID") || { echo "Error: BOOK_ID ($BOOK_ID) not found"; exit 1; }
echo "  BOOK_ID=$BOOK_ID    -> $BOOK_TITLE"

PAGES_TITLE=$(fetch_title "$PAGES_ID") || { echo "Error: PAGES_ID ($PAGES_ID) not found"; exit 1; }
echo "  PAGES_ID=$PAGES_ID   -> $PAGES_TITLE"

if [ -n "${CHAPTER_ID:-}" ]; then
  CHAPTER_TITLE=$(fetch_title "$CHAPTER_ID") || { echo "Error: CHAPTER_ID ($CHAPTER_ID) not found"; exit 1; }
  echo "  CHAPTER_ID=$CHAPTER_ID -> $CHAPTER_TITLE"
fi

echo ""
read -rp "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

if [ ! -d "$DIR" ]; then
  echo "Directory not found: $DIR"
  exit 1
fi

pages=()
for md in "$DIR"/p.*.md; do
  [ -f "$md" ] || continue
  pages+=("$md")
done

if [ ${#pages[@]} -eq 0 ]; then
  echo "No p.*.md files found in $DIR"
  exit 1
fi

sort_key() {
  local name="$1"
  name="${name#p.}"
  name="${name%.md}"
  if [[ "$name" =~ ^[0-9]+$ ]]; then
    printf "%010d" "$name"
  else
    echo "$name"
  fi
}

sorted_pages=()
while IFS= read -r line; do
  sorted_pages+=("$line")
done < <(
  for md in "${pages[@]}"; do
    f="$(basename "$md")"
    printf '%s\t%s\n' "$(sort_key "$f")" "$md"
  done | sort -k1 | cut -f2
)

echo "Found ${#sorted_pages[@]} pages to ingest"
echo "Book context: $BOOK_ID, Pages context: $PAGES_ID"
echo ""

roman_to_int() {
  local input
  input=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  local result=0 prev=0 val=0
  local i len=${#input}
  for (( i=len-1; i>=0; i-- )); do
    case "${input:$i:1}" in
      i) val=1 ;; v) val=5 ;; x) val=10 ;; l) val=50 ;;
      c) val=100 ;; d) val=500 ;; m) val=1000 ;;
      *) return 1 ;;
    esac
    (( val < prev )) && result=$((result - val)) || result=$((result + val))
    prev=$val
  done
  echo "$result"
}

is_roman() {
  local lower
  lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$lower" =~ ^[ivxlcdm]+$ ]]
}

compute_sort_idx() {
  local page_num="$1"
  if [[ "$page_num" =~ ^[0-9]+$ ]]; then
    echo "$page_num"
  elif is_roman "$page_num"; then
    echo $(( $(roman_to_int "$page_num") - 1000001 ))
  else
    echo ""
  fi
}

ok=0
fail=0
skip=0

for md in "${sorted_pages[@]}"; do
  f="$(basename "$md")"
  page_name="${f%.md}"

  content="$(cat "$md")"
  if [ -z "$content" ]; then
    echo "SKIP $page_name (empty)"
    skip=$((skip + 1))
    continue
  fi

  page_num="${page_name#p.}"
  sort_idx=$(compute_sort_idx "$page_num")

  existing_id=""
  if [ -n "$sort_idx" ]; then
    match_ids="${BOOK_ID},${PAGES_ID}"
    if [ -n "${CHAPTER_ID:-}" ]; then
      match_ids="${BOOK_ID},${PAGES_ID},${CHAPTER_ID}"
    fi
    existing=$(curl -sf "${BASE_URL}/rest/items/by-sort-idx?sort_idx=${sort_idx}&context_ids=${match_ids}" 2>/dev/null) || existing=""
    if [ -n "$existing" ]; then
      existing_id=$(echo "$existing" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
      existing_title=$(echo "$existing" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title','?'))" 2>/dev/null)
      if [ "$OVERRIDE_PAGES" = false ]; then
        echo "CONFLICT $page_name: item \"$existing_title\" (id=$existing_id) already has sort-idx $sort_idx"
        read -rp "  Overwrite? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
          echo "  Skipped."
          skip=$((skip + 1))
          continue
        fi
      fi
    fi
  fi

  if [ -n "$existing_id" ]; then
    payload=$(python3 -c "
import json, sys
print(json.dumps({'description': sys.stdin.read()}))
" <<< "$content")

    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${BASE_URL}/rest/items/${existing_id}" \
      -H "Content-Type: application/json" \
      -d "$payload")

    if [ "$http_code" = "200" ]; then
      echo "UPD  $page_name (id=$existing_id)"
      ok=$((ok + 1))
    else
      echo "FAIL $page_name update (HTTP $http_code)"
      fail=$((fail + 1))
    fi
  else
    payload=$(python3 -c "
import json, sys
title = sys.argv[1]
sort_idx = sys.argv[4]
description = sys.stdin.read()
context_ids = [int(sys.argv[2]), int(sys.argv[3])]
chapter_id = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
if chapter_id:
    context_ids.append(int(chapter_id))
obj = {'title': title, 'description': description, 'context-ids': context_ids}
if sort_idx:
    obj['sort-idx'] = int(sort_idx)
print(json.dumps(obj))
" "$page_name" "$BOOK_ID" "$PAGES_ID" "$sort_idx" "${CHAPTER_ID:-}" <<< "$content")

    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/rest/items" \
      -H "Content-Type: application/json" \
      -d "$payload")

    if [ "$http_code" = "201" ]; then
      echo "OK   $page_name"
      ok=$((ok + 1))
    else
      echo "FAIL $page_name (HTTP $http_code)"
      fail=$((fail + 1))
    fi
  fi
done

echo ""
echo "Done. $ok ingested, $fail failed."

echo ""
echo "Triggering embedding backfill..."
backfill_resp=$(curl -sf -X POST "${BASE_URL}/rest/backfill/embeddings" || true)
if [ -n "$backfill_resp" ]; then
  embedded=$(echo "$backfill_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('embedded','?'))" 2>/dev/null || echo "?")
  echo "  embedded $embedded item(s)."
else
  echo "  backfill call failed (is the server running? recording-mode on?)"
fi
