#!/bin/bash
# Builds notchAgent in release and wraps it into build/notchAgent.app (LSUIElement menu-bar agent, ad-hoc signed).
#
#   scripts/bundle.sh            # SCRATCH=.build/bundle by default
#   SCRATCH=.build/x scripts/bundle.sh
#
# Idempotent: the old bundle is removed first. Copies hooks/notch-agent-hook.sh and
# scripts/{install-hooks.sh,uninstall-hooks.sh,notch-agent-claude} into Contents/Resources when they exist.
# OWNER: workstream C (app-ui).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

SCRATCH="${SCRATCH:-.build/bundle}"
APP="$ROOT/build/notchAgent.app"
VERSION="0.1.0"

echo "bundle: swift build -c release --scratch-path $SCRATCH --product notchAgent" >&2
swift build -c release --scratch-path "$SCRATCH" --product notchAgent >&2
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"
BIN="$BIN_DIR/notchAgent"
[ -x "$BIN" ] || { echo "bundle: no binary at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/notchAgent"
chmod 755 "$APP/Contents/MacOS/notchAgent"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>dev.notchagent.app</string>
	<key>CFBundleName</key>
	<string>notchAgent</string>
	<key>CFBundleDisplayName</key>
	<string>notchAgent</string>
	<key>CFBundleExecutable</key>
	<string>notchAgent</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>notchAgent reads the song position, shuffle and repeat from Spotify's web player in Chrome and presses its buttons.</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

copy_resource() {
  local src="$1" dest="$2"
  if [ -f "$ROOT/$src" ]; then
    mkdir -p "$(dirname "$APP/Contents/Resources/$dest")"
    cp "$ROOT/$src" "$APP/Contents/Resources/$dest"
    chmod 755 "$APP/Contents/Resources/$dest"
  else
    echo "bundle: warning: $src not found, skipping" >&2
  fi
}
# The Now Playing helper (see helpers/now-playing/NowPlayingHelper.m): built with the Command Line Tools' clang.
mkdir -p "$APP/Contents/Resources/now-playing"
clang -dynamiclib -fobjc-arc -O2 -framework Foundation "$ROOT/helpers/now-playing/NowPlayingHelper.m" \
  -o "$APP/Contents/Resources/now-playing/NowPlayingHelper.dylib" >&2

copy_resource hooks/notch-agent-hook.sh hooks/notch-agent-hook.sh
copy_resource scripts/install-hooks.sh scripts/install-hooks.sh
copy_resource scripts/uninstall-hooks.sh scripts/uninstall-hooks.sh
copy_resource scripts/notch-agent-claude scripts/notch-agent-claude

codesign --force --sign - "$APP" >&2
echo "$APP"
