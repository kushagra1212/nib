#!/usr/bin/env bash
# Assemble dist/nib.app from the SwiftPM build.
#
# A real bundle is not optional: macOS ties Accessibility permission to a
# bundle identity and code signature, and a bare executable re-prompts or
# silently fails to hold the grant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/nib.app"
BIN="$ROOT/.build/$CONFIG/nib"

if [[ ! -x "$BIN" ]]; then
  echo "no binary at $BIN -- run: swift build -c $CONFIG" >&2
  exit 1
fi
if [[ ! -x "$ROOT/vendor/harper-ls" ]]; then
  echo "harper-ls missing -- run: Scripts/fetch-harper.sh" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/nib"
cp "$ROOT/vendor/harper-ls" "$APP/Contents/Resources/harper-ls"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  no icon; run: swift Scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns"
fi

# Ad-hoc signature. Every rebuild produces a new code hash, and macOS binds
# Accessibility permission to that hash.
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "built $APP"
du -sh "$APP" | awk '{print "  size: " $1}'

# The failure this avoids is genuinely confusing: nib stays listed and switched
# on in Accessibility, but is no longer trusted, because the grant points at the
# previous binary. Toggling it does nothing; the entry has to be cleared.
if pgrep -x nib >/dev/null; then
  echo
  echo "  nib is running the OLD build. Restart it:"
  echo "    pkill -x nib && open $APP"
fi
echo
echo "  If nib was already granted Accessibility, that grant is now stale."
echo "  Clear it before relaunching:"
echo "    tccutil reset Accessibility com.kushagra.nib"
