#!/usr/bin/env bash
# Measure every public/vo/<id>.wav listed in src/data/vo-lines.json and write
# src/generated/vo-durations.json ({ "<id>": seconds }). The composition reads
# this file to size every scene, so run it after swapping in new VO files.
set -euo pipefail
cd "$(dirname "$0")/.."

LINES=src/data/vo-lines.json
OUTJSON=src/generated/vo-durations.json
mkdir -p "$(dirname "$OUTJSON")"

json="{}"
total=0
for id in $(jq -r '.lines[].id' "$LINES"); do
  wav="public/vo/$id.wav"
  if [[ ! -f "$wav" ]]; then
    echo "missing $wav (run scripts/make-vo.sh)" >&2
    exit 1
  fi
  d="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$wav")"
  json="$(jq --arg id "$id" --argjson d "$d" '. + {($id): ($d * 1000 | round / 1000)}' <<<"$json")"
  total="$(awk -v a="$total" -v b="$d" 'BEGIN { printf "%.3f", a + b }')"
  printf '%-14s %6.2fs\n' "$id" "$d"
done
echo "$json" | jq '.' > "$OUTJSON"
echo "total speech: ${total}s -> $OUTJSON"
