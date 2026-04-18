#!/bin/bash
set -euo pipefail

PORT=3006

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod) PORT=3007; shift ;;
    *) break ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INGEST_CONF="${SCRIPT_DIR}/ingest.conf"
if [ ! -f "$INGEST_CONF" ]; then
  echo "Missing config: $INGEST_CONF"
  exit 1
fi
source "$INGEST_CONF"
: "${BOOK_ID:?BOOK_ID not set in $INGEST_CONF}"
: "${BOOKQUOTES_ID:?BOOKQUOTES_ID not set in $INGEST_CONF}"

INPUT="${SCRIPT_DIR}/extracted-bookquotes.md"
if [ ! -f "$INPUT" ]; then
  echo "No extracted-bookquotes.md found."
  exit 1
fi

BASE_URL="http://127.0.0.1:${PORT}"
CLI="${SCRIPT_DIR}/rhizome-cli.sh"

fetch_title() {
  local id="$1"
  local result title
  result=$("$CLI" --port "$PORT" get-item "$id" 2>/dev/null) || return 1
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
echo "  BOOK_ID=$BOOK_ID         -> $BOOK_TITLE"

BOOKQUOTES_TITLE=$(fetch_title "$BOOKQUOTES_ID") || { echo "Error: BOOKQUOTES_ID ($BOOKQUOTES_ID) not found"; exit 1; }
echo "  BOOKQUOTES_ID=$BOOKQUOTES_ID  -> $BOOKQUOTES_TITLE"

if [ -n "${CHAPTER_ID:-}" ]; then
  CHAPTER_TITLE=$(fetch_title "$CHAPTER_ID") || { echo "Error: CHAPTER_ID ($CHAPTER_ID) not found"; exit 1; }
  echo "  CHAPTER_ID=$CHAPTER_ID       -> $CHAPTER_TITLE"
fi

entries=$(python3 -c "
import sys

entries = []
current = {}
for line in open(sys.argv[1]):
    line = line.rstrip('\n')
    if line.strip() == '-----':
        continue
    if line.startswith('PAGE: '):
        if current and 'page' in current:
            entries.append(current)
            current = {}
        current['page'] = line[6:]
    elif line.startswith('MARK TYPE: '):
        current['mark_type'] = line[11:]
    elif line.startswith('PASSAGE: '):
        current['passage'] = line[9:]
    elif line.startswith('CONTEXT: '):
        current['context'] = line[9:]
    elif line.startswith('WHY NOTABLE: '):
        current['why'] = line[13:]
if current:
    entries.append(current)
print(len(entries))
" "$INPUT")

echo ""
echo "Found $entries bookquote(s) to ingest."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

ok=0
fail=0

python3 -c "
import json, sys

entries = []
current = {}
for line in open(sys.argv[1]):
    line = line.rstrip('\n')
    if line.strip() == '-----':
        continue
    if line.startswith('PAGE: '):
        if current and 'page' in current:
            entries.append(current)
            current = {}
        current['page'] = line[6:]
    elif line.startswith('MARK TYPE: '):
        current['mark_type'] = line[11:]
    elif line.startswith('PASSAGE: '):
        current['passage'] = line[9:]
    elif line.startswith('CONTEXT: '):
        current['context'] = line[9:]
    elif line.startswith('WHY NOTABLE: '):
        current['why'] = line[13:]
if current:
    entries.append(current)

for e in entries:
    print(json.dumps(e))
" "$INPUT" | while IFS= read -r entry; do
  page=$(echo "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin).get('page','?'))")
  passage=$(echo "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin).get('passage','')[:60])")

  context_ids="[$BOOK_ID, $BOOKQUOTES_ID"
  if [ -n "${CHAPTER_ID:-}" ]; then
    context_ids="$context_ids, $CHAPTER_ID"
  fi
  context_ids="$context_ids]"

  payload=$(echo "$entry" | python3 -c "
import sys, json, re

def roman_to_int(s):
    vals = {'i':1,'v':5,'x':10,'l':50,'c':100,'d':500,'m':1000}
    s = s.lower()
    result = 0
    for i in range(len(s)):
        if i+1 < len(s) and vals.get(s[i],0) < vals.get(s[i+1],0):
            result -= vals.get(s[i],0)
        else:
            result += vals.get(s[i],0)
    return result

e = json.load(sys.stdin)
context_ids = json.loads(sys.argv[1])
page = e.get('page', '?').strip()
title = 'p.' + page + ': ' + e.get('passage', '')[:80]
description = '**Mark type:** ' + e.get('mark_type', '') + '\n\n'
description += '**Passage:** ' + e.get('passage', '') + '\n\n'
description += '**Context:** ' + e.get('context', '') + '\n\n'
description += '**Why notable:** ' + e.get('why', '')
obj = {'title': title, 'description': description, 'context-ids': context_ids}
if page.isdigit():
    obj['sort-idx'] = int(page)
elif re.match(r'^[ivxlcdmIVXLCDM]+$', page):
    obj['sort-idx'] = roman_to_int(page) - 1000001
print(json.dumps(obj))
" "$context_ids")

  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/rest/items" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [ "$http_code" = "201" ]; then
    echo "OK   p.$page: $passage..."
    ok=$((ok + 1))
  else
    echo "FAIL p.$page: $passage... (HTTP $http_code)"
    fail=$((fail + 1))
  fi
done

echo ""
echo "Done."
