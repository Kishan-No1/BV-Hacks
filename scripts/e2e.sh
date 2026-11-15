#!/bin/bash
# End-to-end check of the real path, without Claude Code and without a human:
#
#   hooks/nod-hook.sh -> HookServer -> SessionStore -> island model -> decision -> held HTTP response -> stdout
#
# Launches build/Nod.app with the TEST-ONLY flag `--test-autodecide` (answers each request through the same
# model actions as the buttons and hotkeys), on a private port and with a temp rules file. Never touches
# ~/.claude/settings.json or the real rules file. Kills the app when done.
#
#   scripts/e2e.sh              # bundle first, then run
#   scripts/e2e.sh --no-bundle  # reuse build/Nod.app
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
PORT="${NOD_E2E_PORT:-47491}"
APP_BIN="$ROOT/build/Nod.app/Contents/MacOS/Nod"
HOOK="$ROOT/hooks/nod-hook.sh"
FIX="$ROOT/Tests/NodCoreTests/Fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nod-e2e.XXXXXX")"
RULES="$WORK/rules.json"
APP_PID=""
FAILS=0

ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
DENY='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Nod."}}}'

stop_app() {
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    APP_PID=""
  fi
}
cleanup() {
  stop_app
  if [ "$FAILS" -eq 0 ]; then rm -rf "$WORK"; else echo "logs kept in $WORK"; fi
}
trap cleanup EXIT

ok() { printf 'ok    %s\n' "$1"; }
bad() {
  printf 'FAIL  %s\n' "$1"
  FAILS=$((FAILS + 1))
}
check_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"
    printf '      expected: %s\n      actual:   %s\n' "$2" "$3"
  fi
}

start_app() { # mode
  stop_app
  NOD_PORT="$PORT" NOD_RULES_FILE="$RULES" NOD_LOG=1 NOD_TEST_DECIDE_DELAY=0.5 \
    "$APP_BIN" --test-autodecide "$1" >>"$WORK/app.log" 2>&1 &
  APP_PID=$!
  local i
  for i in $(seq 1 50); do
    if curl -s --noproxy '*' --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok":true'; then return 0; fi
    sleep 0.1
  done
  bad "Nod did not start on port $PORT (mode $1)"
  tail -5 "$WORK/app.log"
  return 1
}

hook() { # event fixture -> stdout of nod-hook.sh; exit code in $HOOK_RC
  NOD_PORT="$PORT" "$HOOK" "$1" <"$FIX/$2.json"
}

fail_open() { # label
  local start end ms out rc
  start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  out="$(hook PermissionRequest permission-request-bash-npm-test)"
  rc=$?
  end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  ms=$((end - start))
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$ms" -lt 1000 ]; then
    ok "fail-open ($1): exit 0, empty stdout, ${ms} ms"
  else
    bad "fail-open ($1): rc=$rc ms=$ms out=$out"
  fi
}

if [ "${1:-}" != "--no-bundle" ]; then
  scripts/bundle.sh >/dev/null || { echo "bundle failed"; exit 1; }
fi
[ -x "$APP_BIN" ] || { echo "no app at $APP_BIN"; exit 1; }
if curl -s --noproxy '*' --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null; then
  echo "port $PORT is already in use; set NOD_E2E_PORT"
  exit 1
fi

echo "== 1. Nod not running"
fail_open "Nod not running"

echo "== 2. story through scripts/simulate.sh (default action: allow low, deny high)"
start_app default || exit 1
# 60 s cap: an unanswered request would otherwise hold the story for the full 580 s.
perl -e 'alarm 60; exec @ARGV' scripts/simulate.sh --port "$PORT" story | tee "$WORK/story.log"
check_eq "story: npm test request allowed" "$ALLOW" "$(grep -A1 'permission-request-bash-npm-test .*200' "$WORK/story.log" | tail -1 | sed 's/^ *//')"
check_eq "story: rm -rf request denied" "$DENY" "$(grep -A1 'permission-request-bash-rm-rf-outside .*200' "$WORK/story.log" | tail -1 | sed 's/^ *//')"

echo "== 3. the same through hooks/nod-hook.sh (what Claude Code runs)"
check_eq "hook: SessionStart prints nothing" "" "$(hook SessionStart session-start)"
check_eq "hook: UserPromptSubmit prints nothing" "" "$(hook UserPromptSubmit user-prompt-submit)"
check_eq "hook: PreToolUse prints nothing" "" "$(hook PreToolUse pre-tool-use-bash)"
check_eq "hook: low-risk request -> allow JSON" "$ALLOW" "$(hook PermissionRequest permission-request-bash-npm-test)"
check_eq "hook: PostToolUse prints nothing" "" "$(hook PostToolUse post-tool-use-bash)"
check_eq "hook: review request (Edit) -> allow JSON" "$ALLOW" "$(hook PermissionRequest permission-request-edit)"
check_eq "hook: high-risk request (rm -rf outside) -> deny JSON" "$DENY" "$(hook PermissionRequest permission-request-bash-rm-rf-outside)"
check_eq "hook: high-risk request (Write .env.local) -> deny JSON" "$DENY" "$(hook PermissionRequest permission-request-write-env)"
check_eq "hook: AskUserQuestion passes through (no output)" "" "$(hook PermissionRequest permission-request-ask-user-question)"
check_eq "hook: Stop prints nothing" "" "$(hook Stop stop)"

echo "== 4. always-allow rules"
start_app always || exit 1
check_eq "always: npm test -> allow JSON" "$ALLOW" "$(hook PermissionRequest permission-request-bash-npm-test)"
if [ -s "$RULES" ] && grep -q 'npm test' "$RULES"; then ok "always: rule saved to the temp rules file"; else bad "always: no rule in $RULES"; fi
start_app deny || exit 1
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
out="$(hook PermissionRequest permission-request-bash-npm-test)"
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
check_eq "rule: npm test auto-allowed although the test mode denies everything" "$ALLOW" "$out"
if [ $((end - start)) -lt 400 ]; then ok "rule: answered in $((end - start)) ms (before the 500 ms auto-decide delay, so by the rule)"; else bad "rule: took $((end - start)) ms"; fi
check_eq "rule: rm -rf is still asked (and denied here)" "$DENY" "$(hook PermissionRequest permission-request-bash-rm-rf-outside)"
hook SessionEnd session-end >/dev/null

echo "== 5. Nod quit"
stop_app
fail_open "after quitting Nod"

echo "== app log (decisions)"
grep -E 'TEST MODE|action:|hook server' "$WORK/app.log" | sed 's/^/    /'

if [ "$FAILS" -eq 0 ]; then echo "E2E PASSED"; else echo "E2E FAILED ($FAILS)"; fi
[ "$FAILS" -eq 0 ]
