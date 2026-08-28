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

# Ad-hoc signature. Every rebuild changes the hash, so macOS may ask for
# Accessibility permission again after each build during development.
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "built $APP"
du -sh "$APP" | awk '{print "  size: " $1}'
