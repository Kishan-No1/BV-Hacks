#!/bin/bash
# Plays Claude Code hook payloads into a running Nod, without Claude Code.
#
#   scripts/simulate.sh [--port N] [--session ID] [--fast] <fixture-name-or-path>...
#   scripts/simulate.sh [--port N] [--session ID] [--fast] story
#
# A fixture name resolves to Tests/NodCoreTests/Fixtures/<name>.json. Each payload is POSTed to
# http://127.0.0.1:<port>/hook/<hook_event_name> (port: --port, else $NOD_PORT, else 47474) and the status
# and body are printed. A PermissionRequest blocks until it is answered in Nod and prints the decision.
# --session overrides session_id so several sessions can run side by side. --fast skips the story's pauses.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FIXTURES="$SCRIPT_DIR/../Tests/NodCoreTests/Fixtures"
PORT="${NOD_PORT:-47474}"
SESSION=""
FAST=0

usage() {
  cat <<'EOF'
Usage: simulate.sh [--port N] [--session ID] [--fast] <fixture-name-or-path>...
       simulate.sh [--port N] [--session ID] [--fast] story

  --port N      Nod's port (default: $NOD_PORT, else 47474)
  --session ID  replace session_id in every payload (simulate several sessions)
  --fast        no pauses between story steps
  story         session start, prompt, read, bash, an npm test request (blocks until answered),
                an edit, an rm -rf request (blocks), stop

Fixture names: ls Tests/NodCoreTests/Fixtures
EOF
}

die() {
  echo "simulate: $*" >&2
  exit 1
}

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] || die "--port needs a number"
      PORT="$2"
      shift 2
      ;;
    --port=*)
      PORT="${1#--port=}"
      shift
      ;;
    --session)
      [ $# -ge 2 ] || die "--session needs an id"
      SESSION="$2"
      shift 2
      ;;
    --session=*)
      SESSION="${1#--session=}"
      shift
      ;;
    --fast)
      FAST=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

case "$PORT" in
  '' | *[!0-9]*) die "--port must be a number: $PORT" ;;
esac
[ ${#ARGS[@]} -gt 0 ] || {
  usage >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || die "jq is required"

BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nod-simulate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pause() {
  if [ "$FAST" -eq 0 ]; then sleep "$1"; fi
}

resolve() {
  local f="$1"
  if [ -f "$f" ]; then
    echo "$f"
  elif [ -f "$FIXTURES/$f.json" ]; then
    echo "$FIXTURES/$f.json"
  elif [ -f "$FIXTURES/$f" ]; then
    echo "$FIXTURES/$f"
  else
    die "no such fixture: $f (see $FIXTURES)"
  fi
}

send() {
  local file event name status body
  file="$(resolve "$1")"
  name="$(basename "$file" .json)"
  if [ -n "$SESSION" ]; then
    jq --arg s "$SESSION" '.session_id = $s' "$file" >"$WORK/payload"
  else
    jq . "$file" >"$WORK/payload"
  fi
  event="$(jq -r '.hook_event_name // empty' "$WORK/payload")"
  [ -n "$event" ] || die "$name has no hook_event_name"
  case "$event" in
    *[!A-Za-z0-9_]*) die "$name has an odd hook_event_name: $event" ;;
  esac

  if [ "$event" = "PermissionRequest" ]; then
    printf '%-20s %-40s waiting for a decision in Nod...\n' "$event" "$name"
  fi
  : >"$WORK/body"
  if ! status="$(curl -sS --noproxy '*' --connect-timeout 1 --max-time 600 \
    -H 'Content-Type: application/json' -H 'Expect:' \
    --data-binary @"$WORK/payload" -o "$WORK/body" -w '%{http_code}' "$BASE/hook/$event")"; then
    die "could not reach Nod at $BASE (is it running? NOD_PORT=$PORT)"
  fi
  body="$(cat "$WORK/body")"
  if [ "$event" = "PermissionRequest" ]; then
    local decision
    if [ "$status" = "200" ] && [ -n "$body" ]; then
      decision="$(printf '%s' "$body" | jq -r '.hookSpecificOutput.decision | .behavior + (if .message then " (\(.message))" else "" end)' 2>/dev/null || echo "?")"
    else
      decision="no decision (Claude Code would show its own prompt)"
    fi
    printf '%-20s %-40s %s -> %s\n' "$event" "$name" "$status" "$decision"
    [ -z "$body" ] || printf '    %s\n' "$body"
  else
    printf '%-20s %-40s %s %s\n' "$event" "$name" "$status" "$body"
  fi
}

story() {
  send session-start
  pause 0.6
  send user-prompt-submit
  pause 0.8
  send pre-tool-use-read
  pause 1.2
  send post-tool-use-read
  pause 0.4
  send pre-tool-use-bash
  pause 2.0
  send post-tool-use-bash
  pause 0.6
  send permission-request-bash-npm-test
  pause 0.8
  send post-tool-use-edit
  pause 0.8
  send permission-request-bash-rm-rf-outside
  pause 0.8
  send stop
}

if ! curl -sS --noproxy '*' --connect-timeout 1 --max-time 2 -o /dev/null "$BASE/health" 2>/dev/null; then
  die "Nod is not reachable at $BASE (start Nod, or pass --port / NOD_PORT)"
fi

for arg in "${ARGS[@]}"; do
  if [ "$arg" = "story" ]; then
    story
  else
    send "$arg"
  fi
done
