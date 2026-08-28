#!/usr/bin/env bash
# Builds dist/nib-<version>.dmg from dist/nib.app.
#
# The disk image contains the app and a symlink to /Applications, which is the
# drag-to-install layout macOS users expect.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/nib.app"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
DMG="$ROOT/dist/nib-${VERSION}.dmg"
STAGING="$ROOT/dist/dmg"

if [[ ! -d "$APP" ]]; then
  echo "no app at $APP -- run Scripts/bundle.sh first" >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/nib.app"
ln -s /Applications "$STAGING/Applications"

# UDZO is compressed and read-only, which is what every other app ships.
hdiutil create \
  -volname "nib" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING"

echo "built $DMG"
du -h "$DMG" | awk '{print "  size: " $1}'
shasum -a 256 "$DMG" | awk '{print "  sha256: " $1}'
