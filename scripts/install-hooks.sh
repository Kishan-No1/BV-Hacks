#!/bin/bash
# Installs notchAgent's Claude Code hooks into a settings file (default ~/.claude/settings.json).
#
#   scripts/install-hooks.sh [--settings PATH] [--hook PATH] [--dry-run]
#
# For each of the nine events notchAgent uses it adds one matcher group without a matcher:
#   {"hooks":[{"type":"command","command":"'<abs hook path>' <Event>","timeout":<n>}]}
# timeout: 600 for PermissionRequest, 5 for the others, none for SessionEnd (its 1.5 s default budget).
# Idempotent: every handler that runs a script named exactly notch-agent-hook.sh (or nod-hook.sh, the name before
# the rename) is removed first, then re-added
# (an unrelated my-notch-agent-hook.sh is left alone).
# Unrelated keys and hooks are left alone. An existing file is backed up to
# <file>.notch-agent-backup-<YYYYmmdd-HHMMSS> before it is changed. Invalid JSON is refused (exit 1).
# Contract: docs/superpowers/plans/hook-contract.md section 5.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SETTINGS="${HOME}/.claude/settings.json"
HOOK=""
DRY_RUN=0
EVENTS='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","Notification","Stop","SessionEnd"]'

usage() {
  cat <<'EOF'
Usage: install-hooks.sh [--settings PATH] [--hook PATH] [--dry-run]

Adds notchAgent's Claude Code hooks for SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
PostToolUseFailure, PermissionRequest, Notification, Stop and SessionEnd.

  --settings PATH  settings file to edit (default: ~/.claude/settings.json)
  --hook PATH      hook script to register (default: ../hooks/notch-agent-hook.sh next to this script)
  --dry-run        print the resulting JSON and write nothing
  -h, --help       show this help

Running it again replaces notchAgent's entries instead of duplicating them. The file is backed up first.
EOF
}

die() {
  echo "install-hooks: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --settings)
      [ $# -ge 2 ] || die "--settings needs a path"
      SETTINGS="$2"
      shift 2
      ;;
    --settings=*)
      SETTINGS="${1#--settings=}"
      shift
      ;;
    --hook)
      [ $# -ge 2 ] || die "--hook needs a path"
      HOOK="$2"
      shift 2
      ;;
    --hook=*)
      HOOK="${1#--hook=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required (it ships with macOS 15 and later; or: brew install jq)"
[ -n "$SETTINGS" ] || die "--settings needs a path"

# Absolute path of the hook script.
if [ -z "$HOOK" ]; then
  [ -d "$SCRIPT_DIR/../hooks" ] || die "cannot find ../hooks next to $SCRIPT_DIR; pass --hook PATH"
  HOOK="$(cd "$SCRIPT_DIR/../hooks" && pwd -P)/notch-agent-hook.sh"
else
  case "$HOOK" in
    /*) ;;
    *) HOOK="$PWD/$HOOK" ;;
  esac
  HOOK_DIR="$(cd "$(dirname "$HOOK")" 2>/dev/null && pwd -P)" || die "hook directory does not exist: $(dirname "$HOOK")"
  HOOK="$HOOK_DIR/$(basename "$HOOK")"
fi
[ -f "$HOOK" ] || die "hook script not found: $HOOK"
case "$(basename "$HOOK")" in
  notch-agent-hook.sh) ;;
  *) die "the hook script must be named notch-agent-hook.sh (uninstall finds notchAgent's entries by that name): $HOOK" ;;
esac
[ -x "$HOOK" ] || echo "install-hooks: warning: $HOOK is not executable (chmod +x it)" >&2

# Follow a symlinked settings file so a dotfiles link stays a link.
TARGET="$SETTINGS"
case "$TARGET" in
  /*) ;;
  *) TARGET="$PWD/$TARGET" ;;
esac
hops=0
while [ -L "$TARGET" ] && [ $hops -lt 16 ]; do
  link="$(readlink "$TARGET")"
  case "$link" in
    /*) TARGET="$link" ;;
    *) TARGET="$(dirname "$TARGET")/$link" ;;
  esac
  hops=$((hops + 1))
done

# shellcheck disable=SC2016 # jq program, not shell expansions
JQ_LIB='
def is_notch_agent: type == "object" and ((.command | type) == "string") and (.command | test("(^|[/ \"\u0027])(notch-agent|nod)-hook\\.sh[\"\u0027]?( |$)"));
def has_notch_agent: type == "object" and ((.hooks | type) == "array") and any(.hooks[]; is_notch_agent);
def count_notch_agent:
  if type == "object" then
    [ (.hooks // {}) | objects | .[] | arrays | .[] | objects | (.hooks // []) | arrays | .[] | select(is_notch_agent) ] | length
  else 0 end;
# On an event array: removes notchAgent handlers, dropping only the matcher groups that become empty because of it.
def strip_groups:
  map(if has_notch_agent then (.hooks |= map(select(is_notch_agent | not))) | select((.hooks | length) > 0) else . end);
# Removes notchAgent handlers from every event except those in $skip, dropping the event arrays that become empty.
def strip_notch_agent($skip):
  if type == "object" and ((.hooks | type) == "object") then
    .hooks |= with_entries(
      .key as $k
      | if any($skip[]; . == $k) then .
        elif ((.value | type) == "array") and any(.value[]; has_notch_agent) then
          (.value |= strip_groups) | select((.value | length) > 0)
        else . end)
  else . end;
'

# shellcheck disable=SC2016
JQ_VALIDATE='
type == "object"
and (((.hooks // {}) | type) == "object")
and ([ $events[] as $e | ((.hooks // {})[$e] // []) | type == "array" ] | all)
'

# The command is the single-quoted hook path plus the event name: '/abs/path/notch-agent-hook.sh' PreToolUse
QUOTED_HOOK="'$(printf '%s' "$HOOK" | sed "s/'/'\\\\''/g")'"

# notchAgent's events are rewritten in place (notchAgent's old groups out, one new group appended) so the key order and
# every other group stay put and a second run produces the same bytes.
# shellcheck disable=SC2016
JQ_INSTALL='
def handler($ev):
  {type: "command", command: ($cmd + " " + $ev)}
  + (if $ev == "PermissionRequest" then {timeout: 600} elif $ev == "SessionEnd" then {} else {timeout: 5} end);
strip_notch_agent($events)
| .hooks = (.hooks // {})
| reduce $events[] as $ev (.; .hooks[$ev] = (((.hooks[$ev] // []) | strip_groups) + [{hooks: [handler($ev)]}]))
'

SOURCE=""
if [ -e "$TARGET" ]; then
  [ -f "$TARGET" ] || die "not a regular file: $TARGET"
  SOURCE="$TARGET"
  if ! jq -e -s 'length == 1' "$SOURCE" >/dev/null 2>&1; then
    die "$SETTINGS is not valid JSON; fix it first (nothing was changed)"
  fi
  if ! jq -e --argjson events "$EVENTS" "$JQ_VALIDATE" "$SOURCE" >/dev/null 2>&1; then
    die "$SETTINGS does not look like Claude Code settings (expected an object with an object \"hooks\"); nothing was changed"
  fi
fi

input() {
  if [ -n "$SOURCE" ]; then cat "$SOURCE"; else echo '{}'; fi
}

removed=$(input | jq "$JQ_LIB count_notch_agent")

if [ "$DRY_RUN" -eq 1 ]; then
  input | jq --arg cmd "$QUOTED_HOOK" --argjson events "$EVENTS" "$JQ_LIB $JQ_INSTALL"
  echo "install-hooks: dry run, nothing written ($SETTINGS)" >&2
  exit 0
fi

DIR="$(dirname "$TARGET")"
mkdir -p "$DIR"
TMP="$(mktemp "$DIR/.settings.notch-agent-tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

input | jq --arg cmd "$QUOTED_HOOK" --argjson events "$EVENTS" "$JQ_LIB $JQ_INSTALL" >"$TMP"
jq -e . "$TMP" >/dev/null 2>&1 || die "internal error: produced invalid JSON (nothing was changed)"

if [ -n "$SOURCE" ] && cmp -s "$TMP" "$SOURCE"; then
  echo "notchAgent hooks already installed in $SETTINGS (9 events, no changes)"
  exit 0
fi

BACKUP=""
if [ -n "$SOURCE" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  BACKUP="$TARGET.notch-agent-backup-$stamp"
  n=1
  while [ -e "$BACKUP" ]; do
    BACKUP="$TARGET.notch-agent-backup-$stamp-$n"
    n=$((n + 1))
  done
  cp -p "$SOURCE" "$BACKUP"
  chmod "$(stat -f '%Lp' "$SOURCE")" "$TMP" 2>/dev/null || true
else
  chmod 644 "$TMP"
fi
mv -f "$TMP" "$TARGET"
trap - EXIT

if [ -n "$BACKUP" ]; then
  if [ "$removed" -gt 0 ]; then
    echo "Reinstalled notchAgent hooks for 9 events in $SETTINGS (replaced $removed old entries; backup: $BACKUP)"
  else
    echo "Installed notchAgent hooks for 9 events in $SETTINGS (backup: $BACKUP)"
  fi
else
  echo "Installed notchAgent hooks for 9 events in $SETTINGS (new file)"
fi
