#!/bin/bash
# notch-agent-hook.sh <EventName>   (hook JSON on stdin)
#
# Claude Code command hook for notchAgent. POSTs the payload to notchAgent's local server at
# http://127.0.0.1:${NOTCH_AGENT_PORT:-47474}/hook/<EventName> and prints notchAgent's answer ONLY for a
# PermissionRequest that notchAgent decided (HTTP 200 with a non-empty body). Everything else prints nothing.
#
# Contract: docs/superpowers/plans/hook-contract.md sections 4 and 7.
# - ALWAYS exits 0. Exit 2 would BLOCK Claude Code on PreToolUse, UserPromptSubmit and Stop.
# - stdout carries nothing but the decision JSON. No output = no decision = Claude Code's normal prompt.
# - notchAgent not running: curl fails to connect within milliseconds, nothing is printed.
# - No jq here: this runs on every tool call.

EVENT="${1:-}"
PORT="${NOTCH_AGENT_PORT:-47474}"

# The event name goes into the URL: letters, digits and underscores only.
case "$EVENT" in
  '' | *[!A-Za-z0-9_]*) exit 0 ;;
esac
case "$PORT" in
  '' | *[!0-9]*) PORT=47474 ;;
esac

if [ "$EVENT" = "PermissionRequest" ]; then
  MAX_TIME=590 # notchAgent holds 580 s < curl 590 s < hook timeout 600 s
else
  MAX_TIME=1
fi

WORK=""
CURL_PID=""
WATCHDOG_PID=""
cleanup() {
  if [ -n "$CURL_PID" ]; then kill "$CURL_PID" 2>/dev/null; fi
  if [ -n "$WATCHDOG_PID" ]; then kill "$WATCHDOG_PID" 2>/dev/null; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
# Claude Code ends the hook (for example when the user answers in the terminal): stop curl too, so the
# connection drops and notchAgent removes the request from the notch. Then exit 0 via the EXIT trap.
trap 'exit 0' HUP INT TERM PIPE

WORK=$(mktemp -d "${TMPDIR:-/tmp}/notch-agent-hook.XXXXXX" 2>/dev/null) || exit 0

cat >"$WORK/in" 2>/dev/null || exit 0

# curl runs in the background so a signal to this script is handled at once (bash defers traps
# while a foreground child runs). --noproxy: never send localhost traffic through a configured proxy.
# 'Expect:' disables curl's 100-continue wait on large bodies.
curl -sS --noproxy '*' --connect-timeout 0.3 --max-time "$MAX_TIME" \
  -H 'Content-Type: application/json' -H 'Expect:' -H "X-Notch-Agent-PID: $PPID" \
  --data-binary @"$WORK/in" -o "$WORK/body" -w '%{http_code}' \
  "http://127.0.0.1:$PORT/hook/$EVENT" >"$WORK/status" 2>/dev/null </dev/null &
CURL_PID=$!

# A held PermissionRequest can last minutes. If this script is SIGKILLed (or its parent dies without
# signalling it) no trap runs, so a watchdog ends curl and removes the payload within about a second.
# notchAgent then sees the connection drop and takes the card out of the notch.
if [ "$EVENT" = "PermissionRequest" ]; then
  (
    while kill -0 "$$" 2>/dev/null; do sleep 1; done
    kill "$CURL_PID" 2>/dev/null
    rm -rf "$WORK"
  ) </dev/null >/dev/null 2>&1 &
  WATCHDOG_PID=$!
fi

wait "$CURL_PID" 2>/dev/null
CURL_RC=$?
CURL_PID=""

# Print only a complete, decided answer: curl succeeded, HTTP 200, non-empty body.
if [ "$EVENT" = "PermissionRequest" ] && [ "$CURL_RC" -eq 0 ] && [ -s "$WORK/body" ]; then
  STATUS=$(cat "$WORK/status" 2>/dev/null)
  if [ "$STATUS" = "200" ]; then
    cat "$WORK/body" 2>/dev/null
  fi
fi
exit 0
