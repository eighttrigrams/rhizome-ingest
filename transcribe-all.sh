#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/transcribe.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG"
  exit 1
fi

source "$CONFIG"
: "${DIR:?DIR not set in $CONFIG}"
: "${MAX_PARALLEL:=4}"

roman_to_int() {
  local input="${1,,}"
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
  [[ "${1,,}" =~ ^[ivxlcdm]+$ ]]
}

sort_key() {
  if is_roman "$1"; then
    echo $(( $(roman_to_int "$1") - 10000 ))
  else
    echo "$1"
  fi
}

collect_pages() {
  for img in "$DIR"/p.*.jpeg "$DIR"/p.*.jpg; do
    [ -f "$img" ] || continue
    local f
    f="$(basename "$img")"
    f="${f#p.}"
    f="${f%.*}"
    echo "$(sort_key "$f") $f"
  done | sort -n -k1 | awk '{print $2}'
}

mapfile -t all_pages < <(collect_pages)

if [ ${#all_pages[@]} -eq 0 ]; then
  echo "No p.*.jpeg/jpg files in $DIR"
  exit 1
fi

if [ $# -ge 2 ]; then
  from=$(sort_key "$1")
  to=$(sort_key "$2")
  filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p")
    (( k >= from && k <= to )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
elif [ $# -eq 1 ]; then
  target=$(sort_key "$1")
  filtered=()
  for p in "${all_pages[@]}"; do
    k=$(sort_key "$p")
    (( k == target )) && filtered+=("$p")
  done
  all_pages=("${filtered[@]}")
fi

if [ ${#all_pages[@]} -eq 0 ]; then
  echo "No pages matched the given range."
  exit 1
fi

echo "Pages: ${all_pages[*]}"
echo "Parallel: $MAX_PARALLEL"
echo ""

pids=()
names=()

drain() {
  local keep_pids=() keep_names=()
  for i in "${!pids[@]}"; do
    if kill -0 "${pids[$i]}" 2>/dev/null; then
      keep_pids+=("${pids[$i]}")
      keep_names+=("${names[$i]}")
    else
      wait "${pids[$i]}" && echo "DONE p.${names[$i]}" || echo "FAIL p.${names[$i]}"
    fi
  done
  pids=("${keep_pids[@]}")
  names=("${keep_names[@]}")
}

for page in "${all_pages[@]}"; do
  img=""
  for ext in jpeg jpg; do
    [ -f "$DIR/p.${page}.${ext}" ] && img="$DIR/p.${page}.${ext}" && break
  done
  [ -z "$img" ] && echo "WARN p.$page: no image found" && continue

  md="$DIR/p.${page}.md"
  [ -f "$md" ] && echo "SKIP p.$page" && continue

  while [ "${#pids[@]}" -ge "$MAX_PARALLEL" ]; do
    drain
    [ "${#pids[@]}" -ge "$MAX_PARALLEL" ] && sleep 0.5
  done

  echo "START p.$page"
  tesseract "$img" stdout -l eng > "$md" 2>/dev/null &
  pids+=($!)
  names+=("$page")
done

while [ "${#pids[@]}" -gt 0 ]; do
  drain
  [ "${#pids[@]}" -gt 0 ] && sleep 0.5
done

echo ""
echo "All done."
