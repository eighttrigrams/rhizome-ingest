#!/bin/bash
set -euo pipefail

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
: "${PORT:?PORT not set in $INGEST_CONF}"
: "${BOOK_ID:?BOOK_ID not set in $INGEST_CONF}"
: "${PAGES_ID:?PAGES_ID not set in $INGEST_CONF}"

BASE_URL="http://127.0.0.1:${PORT}"

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

ok=0
fail=0

for md in "${sorted_pages[@]}"; do
  f="$(basename "$md")"
  page_name="${f%.md}"

  content="$(cat "$md")"
  if [ -z "$content" ]; then
    echo "SKIP $page_name (empty)"
    continue
  fi

  page_num="${page_name#p.}"

  payload=$(python3 -c "
import json, sys, re
title = sys.argv[1]
page_num = sys.argv[4]
description = sys.stdin.read()
obj = {'title': title, 'description': description, 'context-ids': [int(sys.argv[2]), int(sys.argv[3])]}

def roman_to_int(s):
    vals = {'i':1,'v':5,'x':10,'l':50,'c':100,'d':500,'m':1000}
    s = s.lower()
    result = 0
    for i in range(len(s)):
        if i+1 < len(s) and vals[s[i]] < vals[s[i+1]]:
            result -= vals[s[i]]
        else:
            result += vals[s[i]]
    return result

if page_num.isdigit():
    obj['sort-idx'] = int(page_num)
elif re.match(r'^[ivxlcdmIVXLCDM]+$', page_num):
    obj['sort-idx'] = roman_to_int(page_num) - 1000001
print(json.dumps(obj))
" "$page_name" "$BOOK_ID" "$PAGES_ID" "$page_num" <<< "$content")

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
done

echo ""
echo "Done. $ok ingested, $fail failed."
