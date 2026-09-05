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

# Nothing ships that has not sealed.
#
# bundle.sh checks this too, but the DMG is what people receive and it can be
# built from an app left over from an earlier run. A broken seal is silent
# locally -- Gatekeeper only enforces it once the file carries a quarantine
# flag, which a download always does and a local build never does.
if ! problems="$(codesign --verify --deep --strict "$APP" 2>&1)"; then
  echo "$problems" >&2
  echo "the app's signature does not verify -- rebuild with Scripts/bundle.sh" >&2
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

# And check the copy inside the image, which is the one people get.
#
# Mounted and verified rather than trusted: this is the last point at which a
# bad build can be stopped, and the failure it catches costs a user their
# install -- macOS kills the app on first launch and then deletes it.
MOUNT="$(hdiutil attach "$DMG" -nobrowse -readonly \
  | awk -F'\t' '/Volumes/ { print $NF }' | tail -1)"
if [[ -z "$MOUNT" ]]; then
  echo "could not mount $DMG to check it" >&2
  exit 1
fi
inside="$(codesign --verify --deep --strict "$MOUNT/nib.app" 2>&1)" || failed=1
hdiutil detach "$MOUNT" >/dev/null
if [[ "${failed:-0}" == 1 ]]; then
  echo "$inside" >&2
  echo "the app inside the DMG does not verify -- not shipping this" >&2
  rm -f "$DMG"
  exit 1
fi

echo "built $DMG"
echo "  signature verified inside the image"
du -h "$DMG" | awk '{print "  size: " $1}'
shasum -a 256 "$DMG" | awk '{print "  sha256: " $1}'
