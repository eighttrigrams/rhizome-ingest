#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DB_CONF="${SCRIPT_DIR}/db.conf"
if [ ! -f "$DB_CONF" ]; then
  echo "Missing config: $DB_CONF"
  echo "Copy db.conf.template to db.conf and fill in the values."
  exit 1
fi
source "$DB_CONF"
: "${DB_NAME:?DB_NAME not set}"
: "${DB_USER:?DB_USER not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_HOST:?DB_HOST not set}"

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER $DB_NAME"
export PGPASSWORD="$DB_PASSWORD"

echo "Resetting database: $DB_NAME"
echo ""

$PSQL -c "DELETE FROM relations WHERE target_id > 0 OR owner_id > 0;" -q
$PSQL -c "DELETE FROM history;" -q
$PSQL -c "DELETE FROM items WHERE id > 0;" -q
echo "Cleared all items and relations."

create_context() {
  local title="$1"
  local id
  id=$($PSQL -t -c "INSERT INTO items (title, short_title, data, is_context, inserted_at, updated_at, updated_at_ctx) VALUES ('$title', '', '{}', true, NOW(), NOW(), NOW()) RETURNING id;" | head -1 | tr -d ' ')
  echo "  $title -> id $id"
  eval "$2=$id"
}

echo ""
echo "Creating contexts..."

create_context "Books" BOOKS_ID
create_context "Pages" PAGES_ID
create_context "The Book" BOOK_ID
create_context "Chapter 1" CHAPTER_ID

INGEST_CONF="${SCRIPT_DIR}/ingest.conf"
if [ -f "$INGEST_CONF" ]; then
  sed -i '' "s/^BOOK_ID=.*/BOOK_ID=$BOOK_ID/" "$INGEST_CONF"
  sed -i '' "s/^PAGES_ID=.*/PAGES_ID=$PAGES_ID/" "$INGEST_CONF"
  if grep -q "^CHAPTER_ID=" "$INGEST_CONF"; then
    sed -i '' "s/^CHAPTER_ID=.*/CHAPTER_ID=$CHAPTER_ID/" "$INGEST_CONF"
  else
    echo "CHAPTER_ID=$CHAPTER_ID" >> "$INGEST_CONF"
  fi
  echo ""
  echo "Updated ingest.conf:"
  echo "  BOOK_ID=$BOOK_ID"
  echo "  PAGES_ID=$PAGES_ID"
  echo "  CHAPTER_ID=$CHAPTER_ID"
else
  echo ""
  echo "No ingest.conf found. Create it with:"
  echo "  BOOK_ID=$BOOK_ID"
  echo "  PAGES_ID=$PAGES_ID"
  echo "  CHAPTER_ID=$CHAPTER_ID"
fi

echo ""
echo "Done."
