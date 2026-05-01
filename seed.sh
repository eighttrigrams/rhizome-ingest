#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DB_CONF="${SCRIPT_DIR}/db.conf"
if [ ! -f "$DB_CONF" ]; then
  echo "Missing config: $DB_CONF"
  exit 1
fi
source "$DB_CONF"
: "${DB_NAME:?DB_NAME not set}"
: "${DB_USER:?DB_USER not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_HOST:?DB_HOST not set}"

if [ "$DB_NAME" != "cometoid_dev" ]; then
  echo "Refusing to seed: DB_NAME is '$DB_NAME', expected 'cometoid_dev'."
  exit 1
fi

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER $DB_NAME"
export PGPASSWORD="$DB_PASSWORD"

echo "Clearing $DB_NAME..."
$PSQL -c "DELETE FROM relations WHERE target_id > 0 OR owner_id > 0;" -q
$PSQL -c "DELETE FROM history;" -q
$PSQL -c "DELETE FROM items WHERE id > 0;" -q

create_context() {
  local title="$1"
  local id
  id=$($PSQL -t -c "INSERT INTO items (title, short_title, data, is_context, inserted_at, updated_at, updated_at_ctx) VALUES (\$\$${title}\$\$, '', '{}', true, NOW(), NOW(), NOW()) RETURNING id;" | head -1 | tr -d ' ')
  echo "  $title -> id $id"
}

echo ""
echo "Creating contexts..."
create_context "📚❝❞ Excerpt"
create_context "📖 Books"
create_context "Pages"
create_context "Chapter"
create_context "Named Section"

echo ""
echo "Done."
