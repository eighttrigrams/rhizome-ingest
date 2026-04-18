#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") --port <port> <command> [options]

Commands:
  contexts                     List all contexts
  contexts --search <query>    Search contexts by name
  add-item <title> --contexts <id1,id2,...>
                               Add an item linked to given context IDs
  add-context <title>          Create a new context
  get-item <id>                Get an item by ID

Examples:
  $(basename "$0") --port 3006 contexts
  $(basename "$0") --port 3006 contexts --search "Books"
  $(basename "$0") --port 3006 add-context "My New Context"
  $(basename "$0") --port 3006 add-item "Some interesting article" --contexts 42,17
  $(basename "$0") --port 3006 get-item 123
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

if [[ "$1" != "--port" ]] || [[ -z "${2:-}" ]]; then
  echo "Error: --port <port> is required as the first argument" >&2
  usage
fi

BASE_URL="http://127.0.0.1:$2"
shift 2

[[ $# -lt 1 ]] && usage

cmd_contexts() {
  if [[ "${1:-}" == "--search" ]] && [[ -n "${2:-}" ]]; then
    local encoded
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$2'))")
    curl -sf "${BASE_URL}/rest/contexts?q=${encoded}" | python3 -m json.tool
  else
    curl -sf "${BASE_URL}/rest/contexts" | python3 -m json.tool
  fi
}

cmd_add_item() {
  local title="$1"
  shift
  local context_ids=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --contexts)
        context_ids="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$context_ids" ]]; then
    echo "Error: --contexts <id1,id2,...> is required" >&2
    exit 1
  fi

  local ids_json
  ids_json=$(echo "$context_ids" | python3 -c "
import sys, json
ids = [int(x.strip()) for x in sys.stdin.read().split(',')]
print(json.dumps(ids))
")

  local payload
  payload=$(python3 -c "
import json
print(json.dumps({'title': $(python3 -c "import json; print(json.dumps('$title'))"), 'context-ids': $ids_json}))
")

  curl -sf -X POST "${BASE_URL}/rest/items" \
    -H "Content-Type: application/json" \
    -d "$payload" | python3 -m json.tool
}

cmd_add_context() {
  local title="$1"
  local payload
  payload=$(python3 -c "import json; print(json.dumps({'title': '$title'}))")

  curl -sf -X POST "${BASE_URL}/rest/contexts" \
    -H "Content-Type: application/json" \
    -d "$payload" | python3 -m json.tool
}

cmd_get_item() {
  curl -sf "${BASE_URL}/rest/items/$1" | python3 -m json.tool
}

case "$1" in
  contexts)
    shift
    cmd_contexts "$@"
    ;;
  add-item)
    shift
    [[ $# -lt 1 ]] && usage
    cmd_add_item "$@"
    ;;
  add-context)
    shift
    [[ $# -lt 1 ]] && usage
    cmd_add_context "$@"
    ;;
  get-item)
    shift
    [[ $# -lt 1 ]] && usage
    cmd_get_item "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    ;;
esac
