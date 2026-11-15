#!/bin/bash
# Removes Nod's Claude Code hooks from a settings file (default ~/.claude/settings.json).
#
#   scripts/uninstall-hooks.sh [--settings PATH] [--dry-run]
#
# Removes only handlers that run a script named exactly nod-hook.sh (not my-nod-hook.sh), then drops the matcher groups, event
# arrays and the "hooks" object that became empty because of it. Everything else stays untouched.
# The file is backed up to <file>.nod-backup-<YYYYmmdd-HHMMSS> first. No file, or no Nod entries: no-op.
set -euo pipefail

SETTINGS="${HOME}/.claude/settings.json"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: uninstall-hooks.sh [--settings PATH] [--dry-run]

Removes Nod's Claude Code hooks (every handler that runs a script named nod-hook.sh).

  --settings PATH  settings file to edit (default: ~/.claude/settings.json)
  --dry-run        print the resulting JSON and write nothing
  -h, --help       show this help
EOF
}

die() {
  echo "uninstall-hooks: $*" >&2
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

if [ ! -e "$TARGET" ]; then
  echo "No settings file at $SETTINGS; nothing to uninstall"
  exit 0
fi
[ -f "$TARGET" ] || die "not a regular file: $TARGET"
if ! jq -e -s 'length == 1' "$TARGET" >/dev/null 2>&1; then
  die "$SETTINGS is not valid JSON; fix it first (nothing was changed)"
fi

# shellcheck disable=SC2016 # jq program, not shell expansions
JQ_LIB='
def is_nod: type == "object" and ((.command | type) == "string") and (.command | test("(^|[/ \"\u0027])nod-hook\\.sh[\"\u0027]?( |$)"));
def has_nod: type == "object" and ((.hooks | type) == "array") and any(.hooks[]; is_nod);
def count_nod:
  if type == "object" then
    [ (.hooks // {}) | objects | .[] | arrays | .[] | objects | (.hooks // []) | arrays | .[] | select(is_nod) ] | length
  else 0 end;
# On an event array: removes Nod handlers, dropping only the matcher groups that become empty because of it.
def strip_groups:
  map(if has_nod then (.hooks |= map(select(is_nod | not))) | select((.hooks | length) > 0) else . end);
# Removes Nod handlers from every event except those in $skip, dropping the event arrays that become empty.
def strip_nod($skip):
  if type == "object" and ((.hooks | type) == "object") then
    .hooks |= with_entries(
      .key as $k
      | if any($skip[]; . == $k) then .
        elif ((.value | type) == "array") and any(.value[]; has_nod) then
          (.value |= strip_groups) | select((.value | length) > 0)
        else . end)
  else . end;
'

# shellcheck disable=SC2016
JQ_UNINSTALL='
if count_nod > 0 then
  strip_nod([]) | if ((.hooks | type) == "object") and ((.hooks | length) == 0) then del(.hooks) else . end
else . end
'

removed=$(jq "$JQ_LIB count_nod" "$TARGET")
if [ "$removed" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    jq . "$TARGET"
    echo "No Nod hooks found in $SETTINGS; nothing changed" >&2
  else
    echo "No Nod hooks found in $SETTINGS; nothing changed"
  fi
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  jq "$JQ_LIB $JQ_UNINSTALL" "$TARGET"
  echo "uninstall-hooks: dry run, would remove $removed Nod entries; nothing written ($SETTINGS)" >&2
  exit 0
fi

DIR="$(dirname "$TARGET")"
TMP="$(mktemp "$DIR/.settings.nod-tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
jq "$JQ_LIB $JQ_UNINSTALL" "$TARGET" >"$TMP"
jq -e . "$TMP" >/dev/null 2>&1 || die "internal error: produced invalid JSON (nothing was changed)"

stamp="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET.nod-backup-$stamp"
n=1
while [ -e "$BACKUP" ]; do
  BACKUP="$TARGET.nod-backup-$stamp-$n"
  n=$((n + 1))
done
cp -p "$TARGET" "$BACKUP"
chmod "$(stat -f '%Lp' "$TARGET")" "$TMP" 2>/dev/null || true
mv -f "$TMP" "$TARGET"
trap - EXIT

echo "Removed $removed Nod hook entries from $SETTINGS (backup: $BACKUP)"
