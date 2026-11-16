#!/bin/bash
# End-to-end check of the real path, without Claude Code and without a human:
#
#   hooks/notch-agent-hook.sh -> HookServer -> SessionStore -> island model -> decision -> held HTTP response -> stdout
#
# Launches build/notchAgent.app with the TEST-ONLY flag `--test-autodecide` (answers each request through the same
# model actions as the buttons and hotkeys), on a private port and with a temp rules file. The composer section
# uses `--test-compose` (offline stub polish), a fake tmux and temp style / pane files. Never touches
# ~/.claude/settings.json, the real rules or style files, the network or a real tmux. Kills the app when done.
#
#   scripts/e2e.sh              # bundle first, then run
#   scripts/e2e.sh --no-bundle  # reuse build/notchAgent.app
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
PORT="${NOTCH_AGENT_E2E_PORT:-47491}"
APP_BIN="$ROOT/build/notchAgent.app/Contents/MacOS/notchAgent"
HOOK="$ROOT/hooks/notch-agent-hook.sh"
FIX="$ROOT/Tests/NotchAgentCoreTests/Fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notch-agent-e2e.XXXXXX")"
RULES="$WORK/rules.json"
APPROVALS="$WORK/approvals.json"
APP_PID=""
FAILS=0

ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
DENY='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from notchAgent."}}}'

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
  NOTCH_AGENT_PORT="$PORT" NOTCH_AGENT_RULES_FILE="$RULES" NOTCH_AGENT_APPROVALS_FILE="$APPROVALS" NOTCH_AGENT_LOG=1 NOTCH_AGENT_TEST_DECIDE_DELAY=0.5 \
    "$APP_BIN" --test-autodecide "$1" >>"$WORK/app.log" 2>&1 &
  APP_PID=$!
  local i
  for i in $(seq 1 50); do
    if curl -s --noproxy '*' --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok":true'; then return 0; fi
    sleep 0.1
  done
  bad "notchAgent did not start on port $PORT (mode $1)"
  tail -5 "$WORK/app.log"
  return 1
}

hook() { # event fixture -> stdout of notch-agent-hook.sh; exit code in $HOOK_RC
  NOTCH_AGENT_PORT="$PORT" "$HOOK" "$1" <"$FIX/$2.json"
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
  echo "port $PORT is already in use; set NOTCH_AGENT_E2E_PORT"
  exit 1
fi

echo "== 1. notchAgent not running"
fail_open "notchAgent not running"

echo "== 2. story through scripts/simulate.sh (default action: allow low, deny high)"
start_app default || exit 1
# 60 s cap: an unanswered request would otherwise hold the story for the full 580 s.
perl -e 'alarm 60; exec @ARGV' scripts/simulate.sh --port "$PORT" story | tee "$WORK/story.log"
check_eq "story: npm test request allowed" "$ALLOW" "$(grep -A1 'permission-request-bash-npm-test .*200' "$WORK/story.log" | tail -1 | sed 's/^ *//')"
check_eq "story: rm -rf request denied" "$DENY" "$(grep -A1 'permission-request-bash-rm-rf-outside .*200' "$WORK/story.log" | tail -1 | sed 's/^ *//')"

echo "== 3. the same through hooks/notch-agent-hook.sh (what Claude Code runs)"
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
learned="$(jq -r .decisions "$APPROVALS" 2>/dev/null)"
if [ -n "$learned" ] && [ "$learned" -gt 0 ] 2>/dev/null; then ok "approvals: the model learned from $learned decisions (temp file)"; else bad "approvals: nothing learned in $APPROVALS"; fi

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

echo "== 5. notchAgent quit"
stop_app
fail_open "after quitting notchAgent"

echo "== 6. prompt composer: stub polish -> learned style -> tmux argv (fake tmux, no network)"
SENTINEL="zq7sentinel"
PANES="$WORK/panes"
STYLE="$WORK/style.json"
TMUX_LOG="$WORK/tmux.log"
FAKE_TMUX="$WORK/bin/tmux"
SID="$(jq -r .session_id "$FIX/session-start.json")"
mkdir -p "$PANES" "$WORK/bin"
cat >"$FAKE_TMUX" <<'FAKE'
#!/bin/bash
# Fake tmux for the e2e check: logs each call as one line of shell-quoted arguments, answers the two
# queries notchAgent makes before sending, and keeps what load-buffer got on stdin.
{ printf '%q ' "$@"; printf '\n'; } >>"$FAKE_TMUX_LOG"
case "$3" in
  display-message) echo "4242 %7" ;;
  capture-pane) printf '────────\n❯ \n────────\n  ? for shortcuts\n' ;;
  load-buffer) cat >"$FAKE_TMUX_LOG.stdin" ;;
esac
exit 0
FAKE
chmod +x "$FAKE_TMUX"
jq -n --arg sid "$SID" '{session_id: $sid, pane_id: "%7", tmux_session: "notch-agent-e2e", socket_path: "/tmp/notch-agent-e2e.sock",
  server_pid: 4242, cwd: "/Users/dev/code/acme-web", started_at: "2026-11-15T20:00:00Z"}' >"$PANES/$SID.json"

compose_app() { # edit repeat
  stop_app
  : >"$TMUX_LOG"
  : >"$WORK/compose.log"
  NOTCH_AGENT_PORT="$PORT" NOTCH_AGENT_RULES_FILE="$RULES" NOTCH_AGENT_APPROVALS_FILE="$APPROVALS" NOTCH_AGENT_LOG=1 NOTCH_AGENT_STYLE_FILE="$STYLE" NOTCH_AGENT_PANES_DIR="$PANES" \
    NOTCH_AGENT_TMUX="$FAKE_TMUX" FAKE_TMUX_LOG="$TMUX_LOG" NOTCH_AGENT_TEST_COMPOSE_EDIT="$1" NOTCH_AGENT_TEST_COMPOSE_REPEAT="$2" \
    ANTHROPIC_API_KEY="" "$APP_BIN" --test-compose "$SENTINEL fix the flaky login test" >>"$WORK/compose.log" 2>&1 &
  APP_PID=$!
  local i
  for i in $(seq 1 50); do
    if curl -s --noproxy '*' --max-time 1 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok":true'; then break; fi
    sleep 0.1
  done
  hook SessionStart session-start >/dev/null
  for i in $(seq 1 100); do
    if [ "$(grep -c 'TEST MODE: compose round' "$WORK/compose.log")" -ge "$2" ]; then return 0; fi
    sleep 0.1
  done
  bad "composer: the test run did not finish"
  tail -5 "$WORK/compose.log"
  return 1
}

POLISHED="Zq7sentinel fix the flaky login test. Report what you changed."
if compose_app "" 1; then
  check_eq "composer: pane checked first (same server, same pane)" \
    "-S /tmp/notch-agent-e2e.sock display-message -p -t %7 $(printf '%q' '#{pid} #{pane_id}') " "$(sed -n 1p "$TMUX_LOG")"
  check_eq "composer: pane captured before typing" "-S /tmp/notch-agent-e2e.sock capture-pane -p -t %7 -S -30 " "$(sed -n 2p "$TMUX_LOG")"
  check_eq "composer: one-line prompt typed literally as one argument" \
    "-S /tmp/notch-agent-e2e.sock send-keys -t %7 -l -- $(printf '%q' "$POLISHED") " "$(sed -n 3p "$TMUX_LOG")"
  check_eq "composer: then Enter" "-S /tmp/notch-agent-e2e.sock send-keys -t %7 Enter " "$(sed -n 4p "$TMUX_LOG")"
  check_eq "composer: nothing else was run" "4" "$(wc -l <"$TMUX_LOG" | tr -d ' ')"
  check_eq "composer: outcome stored in the temp style file" "1" "$(jq '.outcomes | length' "$STYLE")"
  check_eq "composer: style file is private (0600)" "600" "$(stat -f '%Lp' "$STYLE")"
fi
rm -f "$STYLE"
if compose_app "run tests after edits" 2; then
  # Round 2: the learned line is already in the polish ("Run tests after edits."), then the same edit again.
  check_eq "composer: second polish carries the learned line; multi-line prompt loaded from stdin" \
    "$(printf 'Zq7sentinel fix the flaky login test. Run tests after edits. Report what you changed.\nrun tests after edits')" "$(cat "$TMUX_LOG.stdin")"
  if sed -n 3p "$TMUX_LOG" | grep -Eq '^-S /tmp/notch-agent-e2e.sock load-buffer -b notch-agent-[0-9A-F-]+ - $'; then ok "composer: load-buffer reads stdin (no prompt text in argv)"; else bad "composer: load-buffer argv: $(sed -n 3p "$TMUX_LOG")"; fi
  if sed -n 4p "$TMUX_LOG" | grep -Eq '^-S /tmp/notch-agent-e2e.sock paste-buffer -d -p -r -b notch-agent-[0-9A-F-]+ -t %7 $'; then ok "composer: bracketed paste into the pane"; else bad "composer: paste-buffer argv: $(sed -n 4p "$TMUX_LOG")"; fi
  check_eq "composer: then Enter" "-S /tmp/notch-agent-e2e.sock send-keys -t %7 Enter " "$(sed -n 5p "$TMUX_LOG")"
  check_eq "composer: the added line became a style note after one send" "true" \
    "$(jq '[.notes[] | select(.key == "add:run tests after edits" and .active)] | length == 1' "$STYLE")"
  check_eq "composer: the note was injected into the second polish and reinforced" "2" \
    "$(jq '.notes[] | select(.key == "add:run tests after edits") | .count' "$STYLE")"
  if grep -q 'compose round 1: polished=true sent=true style_changes=1' "$WORK/compose.log"; then ok "composer: one Learned chip after the first send"; else bad "composer: round 1 log: $(grep 'compose round 1' "$WORK/compose.log")"; fi
  if grep -qi "$SENTINEL" "$WORK/compose.log"; then bad "composer: prompt text leaked into the NOTCH_AGENT_LOG=1 app log"; else ok "composer: NOTCH_AGENT_LOG=1 app log has no prompt text"; fi
  if grep -q 'composer: polish ok' "$WORK/compose.log" && grep -q 'composer: sent to pane %7' "$WORK/compose.log"; then ok "composer: log has the counts-only lines"; else bad "composer: counts-only log lines missing"; fi
fi
hook SessionEnd session-end >/dev/null
stop_app
cat "$WORK/compose.log" >>"$WORK/app.log"

echo "== app log (decisions)"
grep -E 'TEST MODE|action:|hook server|composer:' "$WORK/app.log" | sed 's/^/    /'

if [ "$FAILS" -eq 0 ]; then echo "E2E PASSED"; else echo "E2E FAILED ($FAILS)"; fi
[ "$FAILS" -eq 0 ]
