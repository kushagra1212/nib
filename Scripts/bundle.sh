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

# Refuse to bundle a binary older than the sources.
#
# `swift build` defaults to debug while this script reads release, so building
# and then bundling silently ships whatever was in .build/release from before.
# A whole afternoon went into debugging behaviour that was never in the app.
NEWEST_SOURCE="$(find "$ROOT/Sources" -name '*.swift' -newer "$BIN" -print -quit)"
if [[ -n "$NEWEST_SOURCE" ]]; then
  echo "STALE: $BIN predates $(basename "$NEWEST_SOURCE")" >&2
  echo "  run: swift build -c $CONFIG" >&2
  exit 1
fi
if [[ ! -x "$ROOT/vendor/harper-ls" ]]; then
  echo "harper-ls missing -- run: Scripts/fetch-harper.sh" >&2
  exit 1
fi
if [[ ! -x "$ROOT/vendor/llama/llama-server" ]]; then
  echo "llama-server missing -- run: Scripts/fetch-llama.sh" >&2
  exit 1
fi

# Stop it before deleting the bundle it is running from.
#
# rm -rf on a live .app does not stop the process, it removes the ground from
# under it: the app stays in the menu bar until it next touches a resource and
# then quits, or simply disappears with no message. Looking for a crash after
# that finds nothing, because there wasn't one.
if pgrep -x nib >/dev/null; then
  echo "  stopping the running nib first"
  pkill -x nib || true
  sleep 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/nib"
cp "$ROOT/vendor/harper-ls" "$APP/Contents/Resources/harper-ls"

# llama-server and its libraries, kept together in one directory.
#
# They have to stay together: llama-server finds the libraries through an
# rpath of @loader_path, which means "beside me". Move the binary out on its
# own and it fails in dyld before it reaches main().
cp -R "$ROOT/vendor/llama" "$APP/Contents/Resources/llama"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  no icon; run: swift Scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns"
fi

# Sign with a real identity when the machine has one.
#
# An ad-hoc signature ("-") has no identity behind it, so macOS derives the
# designated requirement from the binary's own hash. Every rebuild changes that
# hash, the Accessibility grant no longer matches, and nib comes up blind while
# still listed and switched on in System Settings -- the toggle does nothing,
# because the entry points at a binary that no longer exists.
#
# A certificate makes the requirement "this bundle id, signed by this identity",
# which does not change when the code does. That is why ordinary apps keep their
# permissions across updates.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development|Developer ID Application/ { print $2; exit }'
)}"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null \
    && SIGNED_WITH="identity $SIGN_IDENTITY" \
    || { codesign --force --deep --sign - "$APP" 2>/dev/null; SIGNED_WITH="ad-hoc (identity failed)"; }
else
  codesign --force --deep --sign - "$APP" 2>/dev/null
  SIGNED_WITH="ad-hoc (no certificate found)"
fi

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
echo "  signed: $SIGNED_WITH"

if [[ "$SIGNED_WITH" == ad-hoc* ]]; then
  echo
  echo "  Ad-hoc signed, so any existing Accessibility grant is now stale."
  echo "  Toggling nib in System Settings will not help -- clear it:"
  echo "    tccutil reset Accessibility com.kushagra.nib"
fi
