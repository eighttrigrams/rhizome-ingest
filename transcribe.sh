#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/transcribe.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG"
  echo "Create it with at least: DIR=/path/to/images"
  exit 1
fi

source "$CONFIG"

: "${DIR:?DIR not set in $CONFIG}"
: "${MAX_PARALLEL:=4}"

if [ ! -d "$DIR" ]; then
  echo "Directory not found: $DIR"
  exit 1
fi

pids=()

for img in "$DIR"/*.jpeg "$DIR"/*.jpg; do
  [ -f "$img" ] || continue
  filename="$(basename "$img")"
  base="${filename%.*}"
  md="$DIR/${base}.md"

  [ -f "$md" ] && echo "SKIP $base (already exists)" && continue

  while [ "${#pids[@]}" -ge "$MAX_PARALLEL" ]; do
    new_pids=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        new_pids+=("$pid")
      fi
    done
    pids=("${new_pids[@]}")
    [ "${#pids[@]}" -ge "$MAX_PARALLEL" ] && sleep 0.5
  done

  echo "START $base"
  claude -p "Read the image and transcribe all text content exactly as it appears on the page. Output only the transcribed text, nothing else. Preserve paragraph breaks." "$img" > "$md" &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" && echo "DONE (pid $pid)" || echo "FAIL (pid $pid)"
done

echo "All done."
