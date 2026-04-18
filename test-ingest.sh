#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/db.conf"
: "${DB_NAME:?DB_NAME not set}"
export PGPASSWORD="$DB_PASSWORD"
PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER $DB_NAME -t"

BASE_URL="http://127.0.0.1:3006"
CLI="${SCRIPT_DIR}/rhizome-cli.sh"

pass=0
fail=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label (expected=$expected actual=$actual)"
    fail=$((fail + 1))
  fi
}

item_count() {
  $PSQL -c "SELECT count(*) FROM items WHERE is_context = false" | tr -d ' '
}

item_count_by_sort_idx() {
  $PSQL -c "SELECT count(*) FROM items WHERE sort_idx = $1 AND is_context = false" | tr -d ' '
}

item_desc() {
  $PSQL -c "SELECT substring(description from 1 for 20) FROM items WHERE id = $1" | head -1 | sed 's/^ *//'
}

wait_for_server() {
  echo "Waiting for server..."
  for i in $(seq 1 20); do
    if curl -sf "${BASE_URL}/rest/contexts" >/dev/null 2>&1; then
      echo "Server ready."
      return
    fi
    sleep 1
  done
  echo "Server not responding. Abort."
  exit 1
}

# --- Setup ---

echo "=== Setup ==="
wait_for_server

$PSQL -c "DELETE FROM relations WHERE target_id > 0 OR owner_id > 0;" -q
$PSQL -c "DELETE FROM history;" -q
$PSQL -c "DELETE FROM items WHERE id > 0;" -q
echo "DB cleared."

BOOKS_ID=$($PSQL -c "INSERT INTO items (title, short_title, data, is_context, inserted_at, updated_at, updated_at_ctx) VALUES ('Books', '', '{}', true, NOW(), NOW(), NOW()) RETURNING id;" | head -1 | tr -d ' ')
PAGES_ID=$($PSQL -c "INSERT INTO items (title, short_title, data, is_context, inserted_at, updated_at, updated_at_ctx) VALUES ('Pages', '', '{}', true, NOW(), NOW(), NOW()) RETURNING id;" | head -1 | tr -d ' ')
BOOK_ID=$($PSQL -c "INSERT INTO items (title, short_title, data, is_context, inserted_at, updated_at, updated_at_ctx) VALUES ('Test Book', '', '{}', true, NOW(), NOW(), NOW()) RETURNING id;" | head -1 | tr -d ' ')
CHAPTER_ID=$($PSQL -c "INSERT INTO items (title, short_title, data, is_context, inserted_at, updated_at, updated_at_ctx) VALUES ('Ch 1', '', '{}', true, NOW(), NOW(), NOW()) RETURNING id;" | head -1 | tr -d ' ')
OTHER_BOOK_ID=$($PSQL -c "INSERT INTO items (title, short_title, data, is_context, inserted_at, updated_at, updated_at_ctx) VALUES ('Other Book', '', '{}', true, NOW(), NOW(), NOW()) RETURNING id;" | head -1 | tr -d ' ')

echo "Contexts: Books=$BOOKS_ID Pages=$PAGES_ID Book=$BOOK_ID Chapter=$CHAPTER_ID OtherBook=$OTHER_BOOK_ID"

cat > "${SCRIPT_DIR}/ingest.conf" <<EOF
BOOK_ID=$BOOK_ID
PAGES_ID=$PAGES_ID
CHAPTER_ID=$CHAPTER_ID
EOF

echo ""

# --- Test 1: Fresh ingest ---

echo "=== Test 1: Fresh ingest ==="
result=$(echo "y" | ./ingest-pages.sh 2>&1)
count=$(item_count)
assert_eq "32 items created" "32" "$count"
assert_eq "1 item with sort_idx=3" "1" "$(item_count_by_sort_idx 3)"
assert_eq "1 item with sort_idx=10" "1" "$(item_count_by_sort_idx 10)"
echo ""

# --- Test 2: Re-run detects conflicts ---

echo "=== Test 2: Conflict detection ==="
conflicts=$(printf 'y\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn' | ./ingest-pages.sh 2>&1 | grep -c "CONFLICT" || true)
assert_eq "conflicts detected for all 32 pages" "32" "$conflicts"
count_after=$(item_count)
assert_eq "still 32 items (no duplicates)" "32" "$count_after"
echo ""

# --- Test 3: Overwrite updates in place ---

echo "=== Test 3: Overwrite updates in place ==="
p3_id=$($PSQL -c "SELECT id FROM items WHERE title = 'p.3' AND is_context = false" | head -1 | tr -d ' ')
desc_before=$(item_desc "$p3_id")

result=$(echo "y" | ./ingest-pages.sh --override-pages 2>&1)
upd_count=$(echo "$result" | grep -c "^UPD" || true)
assert_eq "all 32 pages updated" "32" "$upd_count"
assert_eq "still 32 items" "32" "$(item_count)"
assert_eq "still 1 item with sort_idx=3" "1" "$(item_count_by_sort_idx 3)"
echo ""

# --- Test 4: Cross-book isolation ---

echo "=== Test 4: Cross-book isolation ==="
curl -sf -X POST "${BASE_URL}/rest/items" \
  -H "Content-Type: application/json" \
  -d "{\"title\": \"other-p.3\", \"context-ids\": [$OTHER_BOOK_ID, $PAGES_ID], \"sort-idx\": 3, \"description\": \"other book\"}" >/dev/null

assert_eq "2 items with sort_idx=3 now" "2" "$(item_count_by_sort_idx 3)"

result=$(echo "y" | ./ingest-pages.sh --override-pages 2>&1)
assert_eq "still 2 items with sort_idx=3 after ingest" "2" "$(item_count_by_sort_idx 3)"

other_desc=$($PSQL -c "SELECT substring(description from 1 for 10) FROM items WHERE title = 'other-p.3'" | head -1 | sed 's/^ *//')
assert_eq "other book item untouched" "other book" "$other_desc"
echo ""

# --- Test 5: Book-only item not matched ---

echo "=== Test 5: Item in book but not Pages not matched ==="
curl -sf -X POST "${BASE_URL}/rest/items" \
  -H "Content-Type: application/json" \
  -d "{\"title\": \"book-only-p.5\", \"context-ids\": [$BOOK_ID], \"sort-idx\": 5, \"description\": \"book only\"}" >/dev/null

assert_eq "2 items with sort_idx=5 now" "2" "$(item_count_by_sort_idx 5)"

result=$(echo "y" | ./ingest-pages.sh --override-pages 2>&1)
assert_eq "still 2 items with sort_idx=5 after ingest" "2" "$(item_count_by_sort_idx 5)"

bookonly_desc=$($PSQL -c "SELECT substring(description from 1 for 9) FROM items WHERE title = 'book-only-p.5'" | head -1 | sed 's/^ *//')
assert_eq "book-only item untouched" "book only" "$bookonly_desc"
echo ""

# --- Test 6: Invalid context ID rejected ---

echo "=== Test 6: Invalid context ID rejected ==="
cat > "${SCRIPT_DIR}/ingest.conf" <<EOF
PORT=3006
BOOK_ID=999999
PAGES_ID=$PAGES_ID
CHAPTER_ID=$CHAPTER_ID
EOF

result=$(echo "y" | ./ingest-pages.sh 2>&1 || true)
has_error=$(echo "$result" | grep -c "not found\|Error" || true)
assert_eq "invalid BOOK_ID rejected" "1" "$([ "$has_error" -ge 1 ] && echo 1 || echo 0)"

# Restore valid config
cat > "${SCRIPT_DIR}/ingest.conf" <<EOF
BOOK_ID=$BOOK_ID
PAGES_ID=$PAGES_ID
CHAPTER_ID=$CHAPTER_ID
EOF
echo ""

# --- Test 7: Without CHAPTER_ID - fresh ingest ---

echo "=== Test 7: Without CHAPTER_ID - fresh ingest ==="

# Clear non-context items
$PSQL -c "DELETE FROM relations WHERE target_id NOT IN (SELECT id FROM items WHERE is_context = true);" -q
$PSQL -c "DELETE FROM history;" -q
$PSQL -c "DELETE FROM items WHERE is_context = false;" -q

cat > "${SCRIPT_DIR}/ingest.conf" <<EOF
BOOK_ID=$BOOK_ID
PAGES_ID=$PAGES_ID
EOF

result=$(echo "y" | ./ingest-pages.sh 2>&1)
count=$(item_count)
assert_eq "32 items created without chapter" "32" "$count"
assert_eq "1 item with sort_idx=3" "1" "$(item_count_by_sort_idx 3)"
echo ""

# --- Test 8: Without CHAPTER_ID - conflict detection ---

echo "=== Test 8: Without CHAPTER_ID - conflict detection ==="
conflicts=$(printf 'y\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn' | ./ingest-pages.sh 2>&1 | grep -c "CONFLICT" || true)
assert_eq "all 32 conflicts detected without chapter" "32" "$conflicts"
assert_eq "still 32 items" "32" "$(item_count)"
echo ""

# --- Test 9: Without CHAPTER_ID - override updates in place ---

echo "=== Test 9: Without CHAPTER_ID - override updates in place ==="
result=$(echo "y" | ./ingest-pages.sh --override-pages 2>&1)
upd_count=$(echo "$result" | grep -c "^UPD" || true)
assert_eq "all 32 pages updated without chapter" "32" "$upd_count"
assert_eq "still 32 items" "32" "$(item_count)"
echo ""

# --- Test 10: Without CHAPTER_ID - doesn't match items that have a chapter ---

echo "=== Test 10: No-chapter ingest doesn't match chaptered items ==="

# Clear and re-ingest WITH chapter
$PSQL -c "DELETE FROM relations WHERE target_id NOT IN (SELECT id FROM items WHERE is_context = true);" -q
$PSQL -c "DELETE FROM history;" -q
$PSQL -c "DELETE FROM items WHERE is_context = false;" -q

cat > "${SCRIPT_DIR}/ingest.conf" <<EOF
BOOK_ID=$BOOK_ID
PAGES_ID=$PAGES_ID
CHAPTER_ID=$CHAPTER_ID
EOF

echo "y" | ./ingest-pages.sh >/dev/null 2>&1
assert_eq "32 chaptered items" "32" "$(item_count)"

# Now ingest WITHOUT chapter - should create new items (no match due to missing chapter)
cat > "${SCRIPT_DIR}/ingest.conf" <<EOF
BOOK_ID=$BOOK_ID
PAGES_ID=$PAGES_ID
EOF

result=$(echo "y" | ./ingest-pages.sh 2>&1)
ok_count=$(echo "$result" | grep -c "^OK" || true)
assert_eq "32 new items created (no chapter match)" "32" "$ok_count"
assert_eq "64 total items now" "64" "$(item_count)"
echo ""

# Restore config
cat > "${SCRIPT_DIR}/ingest.conf" <<EOF
BOOK_ID=$BOOK_ID
PAGES_ID=$PAGES_ID
CHAPTER_ID=$CHAPTER_ID
EOF

# --- Summary ---

echo "=== Results ==="
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
