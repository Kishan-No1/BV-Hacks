#!/usr/bin/env bash
# Generate the placeholder voiceover with macOS `say`, one WAV per line, then
# measure every line so the video's scene timing follows the audio.
#
#   scripts/make-vo.sh            # only creates missing files (keeps swapped-in VO)
#   scripts/make-vo.sh --force    # regenerate every line with `say`
#   VOICE="Daniel" RATE=175 scripts/make-vo.sh --force
#
# Lines live in src/data/vo-lines.json. Output: public/vo/<id>.wav (48 kHz mono).
set -euo pipefail
cd "$(dirname "$0")/.."

LINES=src/data/vo-lines.json
OUT=public/vo
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1
VOICE="${VOICE:-$(jq -r '.voice' "$LINES")}"
RATE="${RATE:-$(jq -r '.rate' "$LINES")}"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

jq -c '.lines[]' "$LINES" | while read -r line; do
  id="$(jq -r '.id' <<<"$line")"
  text="$(jq -r '.say // .text' <<<"$line")"
  wav="$OUT/$id.wav"
  if [[ -f "$wav" && $FORCE -eq 0 ]]; then
    echo "keep  $wav"
    continue
  fi
  say -v "$VOICE" -r "$RATE" -o "$TMP/$id.aiff" "$text"
  # trim leading/trailing silence, add 60 ms of air on each side, normalise loudness
  ffmpeg -hide_banner -loglevel error -y -i "$TMP/$id.aiff" \
    -af "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse,adelay=60,apad=pad_dur=0.06,loudnorm=I=-16:TP=-1.5:LRA=11" \
    -ar 48000 -ac 1 -c:a pcm_s16le "$wav"
  echo "say   $wav"
done

scripts/measure-vo.sh
